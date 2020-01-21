/*
 * MTResourceHeap.mm
 * 
 * This file is part of the "LLGL" project (Copyright (c) 2015-2019 by Lukas Hermanns)
 * See "LICENSE.txt" for license information.
 */

#include "MTResourceHeap.h"
#include "MTPipelineLayout.h"
#include "../Buffer/MTBuffer.h"
#include "../Texture/MTSampler.h"
#include "../Texture/MTTexture.h"
#include "../../CheckedCast.h"
#include "../../ResourceBindingIterator.h"
#include "../../../Core/Helper.h"
#include <LLGL/ResourceHeapFlags.h>


namespace LLGL
{


/*
 * Internal structures
 */

/*

The internal buffer of MTResourceHeap is tightly packed which stores all segments of binding points consecutively.
Here is an illustration of the buffer layout for one Texture resouce (at binding point 4) and two Sampler resources (at binding points 5 and 6) on a 64-bit build:

Offset      Attribute                                   Value   Description                                         Segment
--------------------------------------------------------------------------------------------------------------------------------------------
0x00000000  MTResourceViewHeapSegment1::segmentSize        20   Size of this segment                                \
0x00000008  MTResourceViewHeapSegment1::range::location     4   First binding point                                  |-- Texture segment
0x0000000C  MTResourceViewHeapSegment1::range::length       1   Number of binding points                             |
0x00000010  texture[0]                                      1   1st Metal texture ID (of type id<MTLTexture>)        /
0x00000018  MTResourceViewHeapSegment1::segmentSize         20   Size of this segment                                \
0x00000020  MTResourceViewHeapSegment1::range::location     5   First binding point                                  |
0x00000024  MTResourceViewHeapSegment1::range::length       2   Number of binding points                             |-- Sampler segment
0x00000028  sampler[0]                                      1   1st Metal sampler ID (of type id<MTLSamplerState>)   |
0x00000030  sampler[1]                                      2   2nd Metal sampler ID (of type id<MTLSamplerState>)  /

*/

// Resource view heap (RVH) segment structure with one dynamic sub-buffer for id<MTLBuffer>, id<MTLTexture>, or id<MTLSamplerState>
struct MTResourceViewHeapSegment1
{
    std::size_t segmentSize;
    NSRange     range;
};

/*
Resource view heap (RVH) segment structure with two dynamic sub-buffers,
one for <NSUInteger> and one for <id<MTLBuffer>>
*/
struct MTResourceViewHeapSegment2
{
    std::size_t segmentSize;
    std::size_t offsetEnd0;
    NSRange     range;
};

struct MTResourceBinding
{
    NSUInteger  slot;
    id          object;
    NSUInteger  offset;
};


/*
 * MTResourceHeap class
 */

MTResourceHeap::MTResourceHeap(const ResourceHeapDescriptor& desc)
{
    /* Initialize segmentation header */
    InitMemory(segmentationHeader_);

    /* Get pipeline layout object */
    auto pipelineLayoutMT = LLGL_CAST(MTPipelineLayout*, desc.pipelineLayout);
    if (!pipelineLayoutMT)
        throw std::invalid_argument("failed to create resource heap due to missing pipeline layout");

    /* Validate binding descriptors */
    const auto& bindings            = pipelineLayoutMT->GetBindings();
    const auto  numBindings         = bindings.size();
    const auto  numResourceViews    = desc.resourceViews.size();

    if (numBindings == 0)
        throw std::invalid_argument("cannot create resource heap without bindings in pipeline layout");
    if (numResourceViews % numBindings != 0)
        throw std::invalid_argument("failed to create resource heap because due to mismatch between number of resources and bindings");

    /* Build buffer segments */
    static const long vertexStages = (StageFlags::VertexStage | StageFlags::TessEvaluationStage);
    static const long fragmentStages = (StageFlags::FragmentStage);
    static const long kernelStages = (StageFlags::ComputeStage | StageFlags::TessControlStage);

    for (std::size_t i = 0; i < numResourceViews; i += numBindings)
    {
        ResourceBindingIterator resourceIterator { desc.resourceViews, bindings, i };
        ::memset(&segmentationHeader_, 0, sizeof(segmentationHeader_));

        /* Build vertex resource segments */
        BuildBufferSegments(resourceIterator, vertexStages, segmentationHeader_.numVertexBufferSegments);
        BuildTextureSegments(resourceIterator, vertexStages, segmentationHeader_.numVertexTextureSegments);
        BuildSamplerSegments(resourceIterator, vertexStages, segmentationHeader_.numVertexSamplerSegments);

        /* Build fragment resource segments */
        BuildBufferSegments(resourceIterator, fragmentStages, segmentationHeader_.numFragmentBufferSegments);
        BuildTextureSegments(resourceIterator, fragmentStages, segmentationHeader_.numFragmentTextureSegments);
        BuildSamplerSegments(resourceIterator, fragmentStages, segmentationHeader_.numFragmentSamplerSegments);

        /* Build kernel resource segments (and store buffer offset to kernel segments) */
        if (i == 0)
        {
            if (buffer_.size() > UINT16_MAX)
                throw std::out_of_range("internal buffer for resource heap exceeded limit of 2^16 (65536) bytes");
            bufferOffsetKernel_ = static_cast<std::uint16_t>(buffer_.size());
        }

        BuildBufferSegments(resourceIterator, kernelStages, segmentationHeader_.numKernelBufferSegments);
        BuildTextureSegments(resourceIterator, kernelStages, segmentationHeader_.numKernelTextureSegments);
        BuildSamplerSegments(resourceIterator, kernelStages, segmentationHeader_.numKernelSamplerSegments);
    }

    /* Store buffer stride */
    stride_ = buffer_.size() / (numResourceViews / numBindings);

    /* Store resource usage bits in segmentation header */
    StoreResourceUsage();
}

std::uint32_t MTResourceHeap::GetNumDescriptorSets() const
{
    return (stride_ > 0 ? buffer_.size() / stride_ : 0);
}

void MTResourceHeap::BindGraphicsResources(id<MTLRenderCommandEncoder> renderEncoder, std::uint32_t firstSet)
{
    auto byteAlignedBuffer = GetSegmentationHeapStart(firstSet);
    if (segmentationHeader_.hasVertexResources)
        BindVertexResources(renderEncoder, byteAlignedBuffer);
    if (segmentationHeader_.hasFragmentResources)
        BindFragmentResources(renderEncoder, byteAlignedBuffer);
}

void MTResourceHeap::BindComputeResources(id<MTLComputeCommandEncoder> computeEncoder, std::uint32_t firstSet)
{
    if (segmentationHeader_.hasKernelResources)
    {
        auto byteAlignedBuffer = GetSegmentationHeapStart(firstSet) + bufferOffsetKernel_;
        BindKernelResources(computeEncoder, byteAlignedBuffer);
    }
}

bool MTResourceHeap::HasGraphicsResources() const
{
    return ((segmentationHeader_.hasVertexResources | segmentationHeader_.hasFragmentResources) != 0);
}

bool MTResourceHeap::HasComputeResources() const
{
    return (segmentationHeader_.hasKernelResources != 0);
}


/*
 * ======= Private: =======
 */

using MTResourceBindingFunc = std::function<MTResourceBinding(Resource* resource, NSUInteger slot)>;

static std::vector<MTResourceBinding> CollectMTResourceBindings(
    ResourceBindingIterator&        resourceIterator,
    const ResourceType              resourceType,
    long                            affectedStage,
    const MTResourceBindingFunc&    resourceFunc)
{
    /* Collect all binding points of the specified resource type */
    BindingDescriptor bindingDesc;
    resourceIterator.Reset(resourceType, 0, affectedStage);

    std::vector<MTResourceBinding> resourceBindings;
    resourceBindings.reserve(resourceIterator.GetCount());

    while (auto resource = resourceIterator.Next(bindingDesc))
        resourceBindings.push_back(resourceFunc(resource, static_cast<NSUInteger>(bindingDesc.slot)));

    /* Sort resources by slot index */
    std::sort(
        resourceBindings.begin(), resourceBindings.end(),
        [](const MTResourceBinding& lhs, const MTResourceBinding& rhs)
        {
            return (lhs.slot < rhs.slot);
        }
    );

    return resourceBindings;
}

void MTResourceHeap::BuildBufferSegments(ResourceBindingIterator& resourceIterator, long stage, std::uint8_t& numSegments)
{
    /* Collect all buffers */
    auto resourceBindings = CollectMTResourceBindings(
        resourceIterator,
        ResourceType::Buffer,
        stage,
        [](Resource* resource, NSUInteger slot) -> MTResourceBinding
        {
            auto bufferMT = LLGL_CAST(MTBuffer*, resource);
            return { slot, bufferMT->GetNative(), 0 };
        }
    );

    /* Build all resource segments for type <MTResourceViewHeapSegment2> */
    BuildAllSegments(
        resourceBindings,
        std::bind(&MTResourceHeap::BuildSegment2, this, std::placeholders::_1, std::placeholders::_2),
        numSegments
    );
}

void MTResourceHeap::BuildTextureSegments(ResourceBindingIterator& resourceIterator, long stage, std::uint8_t& numSegments)
{
    /* Collect all textures */
    auto resourceBindings = CollectMTResourceBindings(
        resourceIterator,
        ResourceType::Texture,
        stage,
        [](Resource* resource, NSUInteger slot) -> MTResourceBinding
        {
            auto textureMT = LLGL_CAST(MTTexture*, resource);
            return { slot, textureMT->GetNative(), 0 };
        }
    );

    /* Build all resource segments for type <MTResourceViewHeapSegment1> */
    BuildAllSegments(
        resourceBindings,
        std::bind(&MTResourceHeap::BuildSegment1, this, std::placeholders::_1, std::placeholders::_2),
        numSegments
    );
}

void MTResourceHeap::BuildSamplerSegments(ResourceBindingIterator& resourceIterator, long stage, std::uint8_t& numSegments)
{
    /* Collect all samplers */
    auto resourceBindings = CollectMTResourceBindings(
        resourceIterator,
        ResourceType::Sampler,
        stage,
        [](Resource* resource, NSUInteger slot) -> MTResourceBinding
        {
            auto samplerMT = LLGL_CAST(MTSampler*, resource);
            return { slot, samplerMT->GetNative(), 0 };
        }
    );

    /* Build all resource segments for type <MTResourceViewHeapSegment1> */
    BuildAllSegments(
        resourceBindings,
        std::bind(&MTResourceHeap::BuildSegment1, this, std::placeholders::_1, std::placeholders::_2),
        numSegments
    );
}

void MTResourceHeap::BuildAllSegments(
    const std::vector<MTResourceBinding>&   resourceBindings,
    const BuildSegmentFunc&                 buildSegmentFunc,
    std::uint8_t&                           numSegments)
{
    if (!resourceBindings.empty())
    {
        /* Initialize iterators for sub-ranges of input bindings */
        auto        itStart = resourceBindings.begin();
        auto        itPrev  = itStart;
        auto        it      = itStart;
        NSUInteger  count   = 0;

        for (++it, ++count; it != resourceBindings.end(); ++it, ++count)
        {
            if (it->slot > itPrev->slot + 1)
            {
                /* Build next segment */
                buildSegmentFunc(itStart, count);
                ++numSegments;
                count   = 0;
                itStart = it;
            }
            itPrev = it;
        }

        if (itStart != resourceBindings.end())
        {
            /* Add last segment */
            buildSegmentFunc(itStart, count);
            ++numSegments;
        }
    }
}

void MTResourceHeap::BuildSegment1(MTResourceBindingIter it, NSUInteger count)
{
    std::size_t startOffset = buffer_.size();

    /* Allocate space for segment */
    const auto segmentSize = sizeof(MTResourceViewHeapSegment1) + sizeof(id) * count;
    buffer_.resize(startOffset + segmentSize);

    /* Write segment header */
    auto segment = reinterpret_cast<MTResourceViewHeapSegment1*>(&buffer_[startOffset]);
    {
        segment->segmentSize    = segmentSize;
        segment->range.location = it->slot;
        segment->range.length   = count;
    }

    /* Write segment body */
    auto segmentIDs = reinterpret_cast<id*>(&buffer_[startOffset + sizeof(MTResourceViewHeapSegment1)]);
    for (NSUInteger i = 0; i < count; ++i, ++it)
        segmentIDs[i] = it->object;
}

void MTResourceHeap::BuildSegment2(MTResourceBindingIter it, NSUInteger count)
{
    std::size_t startOffset = buffer_.size();

    /* Allocate space for segment */
    const auto segmentOffsetEnd0    = sizeof(MTResourceViewHeapSegment2) + sizeof(NSUInteger) * count;
    const auto segmentSize          = segmentOffsetEnd0 + sizeof(id) * count;
    buffer_.resize(startOffset + segmentSize);

    /* Write segment header */
    auto segment = reinterpret_cast<MTResourceViewHeapSegment2*>(&buffer_[startOffset]);
    {
        segment->segmentSize    = segmentSize;
        segment->offsetEnd0     = segmentOffsetEnd0;
        segment->range.location = it->slot;
        segment->range.length   = count;
    }

    /* Write first part of segment body (of type <NSUInteger>) */
    auto segmentTargets = reinterpret_cast<NSUInteger*>(&buffer_[startOffset + sizeof(MTResourceViewHeapSegment2)]);
    auto begin = it;
    for (NSUInteger i = 0; i < count; ++i, ++it)
        segmentTargets[i] = it->offset;

    /* Write second part of segment body (of type <id>) */
    auto segmentIDs = reinterpret_cast<id*>(&buffer_[startOffset + segmentOffsetEnd0]);
    it = begin;
    for (NSUInteger i = 0; i < count; ++i, ++it)
        segmentIDs[i] = it->object;
}

static id<MTLBuffer> const* CastToMTLBuffers(const std::int8_t* byteAlignedBuffer)
{
    using MTBufferArrayType = id<MTLBuffer> const*;
    return reinterpret_cast<MTBufferArrayType>(byteAlignedBuffer);
}

static id<MTLTexture> const* CastToMTLTextures(const std::int8_t* byteAlignedBuffer)
{
    using MTTextureArrayType = id<MTLTexture> const*;
    return reinterpret_cast<MTTextureArrayType>(byteAlignedBuffer);
}

static id<MTLSamplerState> const* CastToMTLSamplerStates(const std::int8_t* byteAlignedBuffer)
{
    using MTSamplerStateArrayType = id<MTLSamplerState> const*;
    return reinterpret_cast<MTSamplerStateArrayType>(byteAlignedBuffer);
}

void MTResourceHeap::BindVertexResources(id<MTLRenderCommandEncoder> cmdEncoder, const std::int8_t*& byteAlignedBuffer)
{
    /* Bind all buffers */
    for (std::uint8_t i = 0; i < segmentationHeader_.numVertexBufferSegments; ++i)
    {
        auto segment = reinterpret_cast<const MTResourceViewHeapSegment2*>(byteAlignedBuffer);
        [cmdEncoder
            setVertexBuffers:   CastToMTLBuffers(byteAlignedBuffer + segment->offsetEnd0)
            offsets:            reinterpret_cast<const NSUInteger*>(byteAlignedBuffer + sizeof(MTResourceViewHeapSegment2))
            withRange:          segment->range
        ];
        byteAlignedBuffer += segment->segmentSize;
    }

    /* Bind all textures */
    for (std::uint8_t i = 0; i < segmentationHeader_.numVertexTextureSegments; ++i)
    {
        auto segment = reinterpret_cast<const MTResourceViewHeapSegment1*>(byteAlignedBuffer);
        [cmdEncoder
            setVertexTextures:  CastToMTLTextures(byteAlignedBuffer + sizeof(MTResourceViewHeapSegment1))
            withRange:          segment->range
        ];
        byteAlignedBuffer += segment->segmentSize;
    }

    /* Bind all samplers */
    for (std::uint8_t i = 0; i < segmentationHeader_.numVertexSamplerSegments; ++i)
    {
        auto segment = reinterpret_cast<const MTResourceViewHeapSegment1*>(byteAlignedBuffer);
        [cmdEncoder
            setVertexSamplerStates: CastToMTLSamplerStates(byteAlignedBuffer + sizeof(MTResourceViewHeapSegment1))
            withRange:              segment->range
        ];
        byteAlignedBuffer += segment->segmentSize;
    }
}

void MTResourceHeap::BindFragmentResources(id<MTLRenderCommandEncoder> cmdEncoder, const std::int8_t*& byteAlignedBuffer)
{
    /* Bind all buffers */
    for (std::uint8_t i = 0; i < segmentationHeader_.numFragmentBufferSegments; ++i)
    {
        auto segment = reinterpret_cast<const MTResourceViewHeapSegment2*>(byteAlignedBuffer);
        [cmdEncoder
            setFragmentBuffers: CastToMTLBuffers(byteAlignedBuffer + segment->offsetEnd0)
            offsets:            reinterpret_cast<const NSUInteger*>(byteAlignedBuffer + sizeof(MTResourceViewHeapSegment2))
            withRange:          segment->range
        ];
        byteAlignedBuffer += segment->segmentSize;
    }

    /* Bind all textures */
    for (std::uint8_t i = 0; i < segmentationHeader_.numFragmentTextureSegments; ++i)
    {
        auto segment = reinterpret_cast<const MTResourceViewHeapSegment1*>(byteAlignedBuffer);
        [cmdEncoder
            setFragmentTextures:    CastToMTLTextures(byteAlignedBuffer + sizeof(MTResourceViewHeapSegment1))
            withRange:              segment->range
        ];
        byteAlignedBuffer += segment->segmentSize;
    }

    /* Bind all samplers */
    for (std::uint8_t i = 0; i < segmentationHeader_.numFragmentSamplerSegments; ++i)
    {
        auto segment = reinterpret_cast<const MTResourceViewHeapSegment1*>(byteAlignedBuffer);
        [cmdEncoder
            setFragmentSamplerStates:   CastToMTLSamplerStates(byteAlignedBuffer + sizeof(MTResourceViewHeapSegment1))
            withRange:                  segment->range
        ];
        byteAlignedBuffer += segment->segmentSize;
    }
}

void MTResourceHeap::BindKernelResources(id<MTLComputeCommandEncoder> cmdEncoder, const std::int8_t*& byteAlignedBuffer)
{
    /* Bind all buffers */
    for (std::uint8_t i = 0; i < segmentationHeader_.numKernelBufferSegments; ++i)
    {
        auto segment = reinterpret_cast<const MTResourceViewHeapSegment2*>(byteAlignedBuffer);
        [cmdEncoder
            setBuffers: CastToMTLBuffers(byteAlignedBuffer + segment->offsetEnd0)
            offsets:    reinterpret_cast<const NSUInteger*>(byteAlignedBuffer + sizeof(MTResourceViewHeapSegment2))
            withRange:  segment->range
        ];
        byteAlignedBuffer += segment->segmentSize;
    }

    /* Bind all textures */
    for (std::uint8_t i = 0; i < segmentationHeader_.numKernelTextureSegments; ++i)
    {
        auto segment = reinterpret_cast<const MTResourceViewHeapSegment1*>(byteAlignedBuffer);
        [cmdEncoder
            setTextures:    CastToMTLTextures(byteAlignedBuffer + sizeof(MTResourceViewHeapSegment1))
            withRange:      segment->range
        ];
        byteAlignedBuffer += segment->segmentSize;
    }

    /* Bind all samplers */
    for (std::uint8_t i = 0; i < segmentationHeader_.numKernelSamplerSegments; ++i)
    {
        auto segment = reinterpret_cast<const MTResourceViewHeapSegment1*>(byteAlignedBuffer);
        [cmdEncoder
            setSamplerStates:   CastToMTLSamplerStates(byteAlignedBuffer + sizeof(MTResourceViewHeapSegment1))
            withRange:          segment->range
        ];
        byteAlignedBuffer += segment->segmentSize;
    }
}

void MTResourceHeap::StoreResourceUsage()
{
    if ( ( segmentationHeader_.numVertexBufferSegments  |
           segmentationHeader_.numVertexTextureSegments |
           segmentationHeader_.numVertexSamplerSegments ) != 0 )
    {
        segmentationHeader_.hasVertexResources = 1;
    }

    if ( ( segmentationHeader_.numFragmentBufferSegments  |
           segmentationHeader_.numFragmentTextureSegments |
           segmentationHeader_.numFragmentSamplerSegments ) != 0 )
    {
        segmentationHeader_.hasFragmentResources = 1;
    }

    if ( ( segmentationHeader_.numKernelBufferSegments  |
           segmentationHeader_.numKernelTextureSegments |
           segmentationHeader_.numKernelSamplerSegments ) != 0 )
    {
        segmentationHeader_.hasKernelResources = 1;
    }
}

const std::int8_t* MTResourceHeap::GetSegmentationHeapStart(std::uint32_t firstSet) const
{
    return (buffer_.data() + stride_ * firstSet);
}


} // /namespace LLGL



// ================================================================================
