/*
 * D3D12ResourceHeap.h
 *
 * Copyright (c) 2015 Lukas Hermanns. All rights reserved.
 * Licensed under the terms of the BSD 3-Clause license (see LICENSE.txt).
 */

#ifndef LLGL_D3D12_RESOURCE_HEAP_H
#define LLGL_D3D12_RESOURCE_HEAP_H


#include <LLGL/ResourceHeap.h>
#include <LLGL/ResourceHeapFlags.h>
#include <LLGL/Container/ArrayView.h>
#include "D3D12PipelineLayout.h"
#include "../../DXCommon/ComPtr.h"
#include <d3d12.h>
#include <vector>
#include <cstddef>


namespace LLGL
{


struct ResourceHeapDescriptor;

class D3D12ResourceHeap final : public ResourceHeap
{

    public:

        void SetName(const char* name) override;

        std::uint32_t GetNumDescriptorSets() const override;

    public:

        D3D12ResourceHeap(
            ID3D12Device*                               device,
            const ResourceHeapDescriptor&               desc,
            const ArrayView<ResourceViewDescriptor>&    initialResourceViews = {}
        );

        // Creates resource view handles (SRV/UAV/CBV/Sampler) for the specified resource views in the D3D12 descriptor heaps.
        std::uint32_t CreateResourceViewHandles(
            ID3D12Device*                               device,
            std::uint32_t                               firstDescriptor,
            const ArrayView<ResourceViewDescriptor>&    resourceViews
        );

        // Inserts the resource barriers for the specified descritpor set into the command list.
        void InsertResourceBarriers(ID3D12GraphicsCommandList* commandList, std::uint32_t descriptorSet);

        // Returns the CPU descriptor handle for heap start of the specified descriptor set.
        D3D12_CPU_DESCRIPTOR_HANDLE GetCPUDescriptorHandleForHeapStart(D3D12_DESCRIPTOR_HEAP_TYPE heapType, std::uint32_t descriptorSet) const;

        // Returns the number of descriptors in the respective heap per set.
        UINT GetNumDescriptorsPerSet(D3D12_DESCRIPTOR_HEAP_TYPE heapType) const;

        // Returns the native D3D descriptor heap for the specified heap type.
        ID3D12DescriptorHeap* GetDescriptorHeap(D3D12_DESCRIPTOR_HEAP_TYPE heapType) const;

    private:

        struct BindingHandleLocation
        {
            UINT heapIndex      :  1;
            UINT handleOffset   : 31;
        };

    private:

        void CreateDescriptorHeap(
            ID3D12Device*                   device,
            D3D12_DESCRIPTOR_HEAP_TYPE      heapType,
            UINT                            numDescriptors
        );

        bool CreateShaderResourceView(ID3D12Device* device, D3D12_CPU_DESCRIPTOR_HANDLE cpuDescHandle, const ResourceViewDescriptor& desc);
        bool CreateUnorderedAccessView(ID3D12Device* device, D3D12_CPU_DESCRIPTOR_HANDLE cpuDescHandle, const ResourceViewDescriptor& desc);
        bool CreateConstantBufferView(ID3D12Device* device, D3D12_CPU_DESCRIPTOR_HANDLE cpuDescHandle, const ResourceViewDescriptor& desc);
        bool CreateSampler(ID3D12Device* device, D3D12_CPU_DESCRIPTOR_HANDLE cpuDescHandle, const ResourceViewDescriptor& desc);

        void ExchangeUAVResource(
            const D3D12DescriptorHeapLocation&  descriptorLocation,
            std::uint32_t                       descriptorSet,
            Resource&                           resource,
            std::uint32_t                       (&setRange)[2]
        );

        void EmplaceD3DUAVResource(
            const D3D12DescriptorHeapLocation&  descriptorLocation,
            std::uint32_t                       descriptorSet,
            ID3D12Resource*                     resource,
            std::uint32_t                       (&setRange)[2]
        );

        void UpdateBarriers(std::uint32_t descriptorSet);

        inline bool HasBarriers() const
        {
            return (barrierStride_ > 0);
        }

    private:

        ComPtr<ID3D12DescriptorHeap>                descriptorHeaps_[2];

        UINT                                        descriptorHandleStrides_[2] = {};
        UINT                                        descriptorSetStrides_[2]    = {};
        UINT                                        numDescriptorsPerSet_[2]    = {};
        UINT                                        numDescriptorSets_          = 0;    // Only used for 'GetNumDescriptorSets'

        SmallVector<D3D12DescriptorHeapLocation>    descriptorMap_;

        std::vector<ID3D12Resource*>                uavResourceHeap_;                   // Heap of UAV resources that require a barrier
        UINT                                        uavResourceSetStride_       = 0;    // Number of (potential) UAV resources per descriptor set
        UINT                                        uavResourceIndexOffset_     = 0;    // Subtracted offset for 'D3D12DescriptorHeapLocation::index'
        std::vector<char>                           barriers_;                          // Packed buffer for dyanmic struct { UINT N; D3D12_RESOURCE_BARRIER[N]; }
        UINT                                        barrierStride_              = 0;

};


} // /namespace LLGL


#endif



// ================================================================================
