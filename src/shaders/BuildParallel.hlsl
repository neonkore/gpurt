/*
 ***********************************************************************************************************************
 *
 *  Copyright (c) 2018-2024 Advanced Micro Devices, Inc. All Rights Reserved.
 *
 *  Permission is hereby granted, free of charge, to any person obtaining a copy
 *  of this software and associated documentation files (the "Software"), to deal
 *  in the Software without restriction, including without limitation the rights
 *  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 *  copies of the Software, and to permit persons to whom the Software is
 *  furnished to do so, subject to the following conditions:
 *
 *  The above copyright notice and this permission notice shall be included in all
 *  copies or substantial portions of the Software.
 *
 *  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 *  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 *  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 *  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 *  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 *  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 *  SOFTWARE.
 *
 **********************************************************************************************************************/
#define BUILD_PARALLEL 1

#if GPURT_ENABLE_GPU_DEBUG
#define DEBUG_BUFFER "UAV(u6),"
#else
#define DEBUG_BUFFER
#endif

#define RootSig "RootConstants(num32BitConstants=1, b0),"\
                "CBV(b1),"\
                "UAV(u0),"\
                "UAV(u1),"\
                "UAV(u2),"\
                "UAV(u3),"\
                "UAV(u4),"\
                "UAV(u5),"\
                 DEBUG_BUFFER \
                "DescriptorTable(UAV(u0, numDescriptors = 4294967295, space = 1)),"\
                "DescriptorTable(UAV(u0, numDescriptors = 4294967295, space = 2)),"\
                "DescriptorTable(UAV(u0, numDescriptors = 4294967295, space = 3)),"\
                "DescriptorTable(CBV(b0, numDescriptors = 4294967295, space = 1)),"\
                "DescriptorTable(UAV(u0, numDescriptors = 1, space = 2147420894)),"\
                "CBV(b255)"\

#include "../shared/rayTracingDefs.h"

#define TASK_COUNTER_BUFFER   ScratchGlobal
#define TASK_COUNTER_OFFSET   (ShaderConstants.offsets.taskLoopCounters + TASK_LOOP_BUILD_PARALLEL_COUNTER_OFFSET)
#define NUM_TASKS_DONE_OFFSET (ShaderConstants.offsets.taskLoopCounters + TASK_LOOP_BUILD_PARALLEL_TASKS_DONE_OFFSET)

struct RootConstants
{
    uint numThreadGroups;
};

[[vk::push_constant]] ConstantBuffer<RootConstants> ShaderRootConstants : register(b0);
[[vk::binding(1, 1)]] ConstantBuffer<BuildShaderConstants> ShaderConstants : register(b1);

[[vk::binding(0, 0)]] globallycoherent RWByteAddressBuffer DstBuffer          : register(u0);
[[vk::binding(1, 0)]] globallycoherent RWByteAddressBuffer DstMetadata        : register(u1);
[[vk::binding(2, 0)]] globallycoherent RWByteAddressBuffer ScratchBuffer      : register(u2);
[[vk::binding(3, 0)]] globallycoherent RWByteAddressBuffer ScratchGlobal      : register(u3);
[[vk::binding(4, 0)]] RWByteAddressBuffer                  InstanceDescBuffer : register(u4);
[[vk::binding(5, 0)]] RWByteAddressBuffer                  EmitBuffer         : register(u5);

#define SrcBuffer InstanceDescBuffer
#include "BuildCommonScratch.hlsl"
#include "CompactCommon.hlsl"
#undef SrcBuffer

#define MAX_LDS_ELEMENTS (16 * BUILD_THREADGROUP_SIZE)
groupshared uint SharedMem[MAX_LDS_ELEMENTS];

#include "TaskQueueCounter.hlsl"

// The encode path uses SrcBuffer and DstBuffer as the true acceleration structure base.
#define SrcBuffer DstMetadata
#include "EncodeCommon.hlsl"
#include "EncodePairedTriangleImpl.hlsl"
#undef SrcBuffer

[[vk::binding(0, 2)]] ConstantBuffer<GeometryArgs> GeometryConstants[] : register(b0, space1);

[[vk::binding(0, 3)]] RWBuffer<float3>           GeometryBuffer[]  : register(u0, space1);
[[vk::binding(0, 4)]] RWByteAddressBuffer        IndexBuffer[]     : register(u0, space2);
#if !AMD_VULKAN
// DXC does not support arrays of structured buffers for SPIRV currently. See issue 3281 / PR 4663).
[[vk::binding(0, 5)]] RWStructuredBuffer<float4> TransformBuffer[] : register(u0, space3);
#endif

//======================================================================================================================
// Returns number of threads launched
uint GetNumThreads()
{
    return ShaderRootConstants.numThreadGroups * BUILD_THREADGROUP_SIZE;
}

//======================================================================================================================
// Wait for the task counter to reach the specified value
void WaitForEncodeTasksToFinish(
    uint numTasksWait)
{
    const uint offset = ShaderConstants.offsets.encodeTaskCounter + ENCODE_TASK_COUNTER_NUM_PRIMITIVES_OFFSET;
    do
    {
        DeviceMemoryBarrier();
    } while (FetchTaskCounter(offset) < numTasksWait);
}

// Include implementations for each pass without shader entry points and resource declarations
#define NO_SHADER_ENTRYPOINT 1

#include "GenerateMortonCodes.hlsl"
#include "RadixSort/ScanExclusiveInt4DLBCommon.hlsl"
#include "RadixSort/RadixSortParallel.hlsl"
#include "BuildBVHPLOC.hlsl"
#include "BuildQBVH.hlsl"
#include "BuildBVHTDTR.hlsl"
#include "BuildBVH.hlsl"
#include "BuildFastAgglomerativeLbvh.hlsl"
#include "RefitBoundsImpl.hlsl"
#include "TriangleSplitting.hlsl"
#include "PairCompression.hlsl"
#include "Rebraid.hlsl"
#include "MergeSort.hlsl"

//======================================================================================================================
uint CurrentSplitState()
{
    return Settings.rebraidType == RebraidType::V2 ? ShaderConstants.offsets.rebraidState :
                                                     ShaderConstants.offsets.triangleSplitState;
}

//======================================================================================================================
uint CurrentSplitTaskQueueCounter()
{
    return Settings.rebraidType == RebraidType::V2 ? ShaderConstants.offsets.rebraidTaskQueueCounter :
                                                     ShaderConstants.offsets.triangleSplitTaskQueueCounter;
}

//======================================================================================================================
void GenerateMortonCodes(
    uint globalId,
    uint numPrimitives)
{
    const BoundingBox sceneBounds = FetchSceneBounds(ShaderConstants.offsets.sceneBounds);

    const float3 sceneExtent = sceneBounds.max - sceneBounds.min;
    const float3 sceneMin    = sceneBounds.min;

    const uint primCount = numPrimitives;

    uint numSizeBits = ShaderConstants.numMortonSizeBits;

    float2  sizeMinMax = float2(0, 0);

    if (ShaderConstants.numMortonSizeBits > 0)
    {
        sizeMinMax = FetchSceneSize(ShaderConstants.offsets.sceneBounds);

        if (sizeMinMax.x >= sizeMinMax.y)
        {
            numSizeBits = 0;
        }
    }

    for (uint primitiveIndex = globalId; primitiveIndex < primCount; primitiveIndex += GetNumThreads())
    {
        GenerateMortonCodesImpl(
            sceneMin,
            sceneExtent,
            primitiveIndex,
            ShaderConstants.offsets.bvhLeafNodeData,
            ShaderConstants.offsets.mortonCodes,
            Settings.doTriangleSplitting,
            ShaderConstants.offsets.triangleSplitBoxes,
            Settings.enableVariableBitsMortonCode,
            Settings.useMortonCode30,
            ShaderConstants.numMortonSizeBits,
            sizeMinMax);
    }
}

//======================================================================================================================
// Reorder scratch leaves based on sorted prim indices
void SortScratchLeaves(
    uint globalId,
    uint numActivePrims)
{
    for (uint primIndex = globalId; primIndex < numActivePrims; primIndex += GetNumThreads())
    {
        CopyUnsortedScratchLeafNode(
            primIndex,
            numActivePrims,
            ShaderConstants.offsets.primIndicesSorted,
            ShaderConstants.offsets.bvhLeafNodeData,
            ShaderConstants.offsets.bvhNodeData);
    }
}

//======================================================================================================================
void BuildBvhLinear(
    uint globalId,
    uint numActivePrims,
    uint numPrimitives)
{
    const uint numInternalNodes = numActivePrims - 1;

    for (uint nodeIndex = globalId; nodeIndex < numInternalNodes; nodeIndex += GetNumThreads())
    {
        SplitInternalNodeLbvh(
            nodeIndex,
            numActivePrims,
            CalculateBvhNodesOffset(ShaderConstants, numActivePrims),
            ShaderConstants.offsets.primIndicesSorted,
            ShaderConstants.offsets.mortonCodesSorted,
            Settings.useMortonCode30,
            Settings.noCopySortedNodes);
    }
}

//======================================================================================================================
void RefitBounds(
    uint globalId,
    uint numActivePrims)
{
    for (uint primIndex = globalId; primIndex < numActivePrims; primIndex += GetNumThreads())
    {
        RefitBoundsImpl(
            primIndex,
            numActivePrims,
            ShaderConstants.offsets.propagationFlags,
            CalculateBvhNodesOffset(ShaderConstants, numActivePrims),
            ShaderConstants.offsets.bvhLeafNodeData,
            ShaderConstants.offsets.primIndicesSorted,
            Settings.doTriangleSplitting,
            Settings.noCopySortedNodes,
            Settings.enableEarlyPairCompression,
            EnableLatePairCompression(),
            Settings.enablePairCostCheck,
            ShaderConstants.offsets.triangleSplitBoxes,
            ShaderConstants.offsets.numBatches,
            ShaderConstants.offsets.batchIndices,
            Settings.fp16BoxNodesMode,
            Settings.fp16BoxModeMixedSaThreshold,
            0xFFFFFFFF,
            0
        );
    }
}

//======================================================================================================================
void FastAgglomerativeLbvh(
    uint globalId,
    uint numActivePrims)
{
    const FastLBVHArgs args = GetFastLbvhArgs(numActivePrims);

    for (uint primIndex = globalId; primIndex < numActivePrims; primIndex += GetNumThreads())
    {
        FastAgglomerativeLbvhImpl(primIndex, args);
    }
}

//======================================================================================================================
void TriangleSplitting(
    uint       globalId,
    uint       localId,
    uint       groupId)
{
    TriangleSplittingArgs args          = (TriangleSplittingArgs)0;

    args.numThreadGroups                = ShaderRootConstants.numThreadGroups;
    args.numPrimitives                  = ShaderConstants.numPrimitives;
    args.maxNumPrimitives               = ShaderConstants.maxNumPrimitives;
    args.numSizeBits                    = ShaderConstants.numMortonSizeBits;
    args.scratchLeafNodesScratchOffset  = ShaderConstants.offsets.bvhLeafNodeData;
    args.splitBoxesScratchOffset        = ShaderConstants.offsets.triangleSplitBoxes;
    args.refList0ScratchOffset          = ShaderConstants.offsets.triangleSplitRefs0;
    args.refList1ScratchOffset          = ShaderConstants.offsets.triangleSplitRefs1;
    args.splitPrioritiesScratchOffset   = ShaderConstants.offsets.splitPriorities;
    args.currentStateScratchOffset      = CurrentSplitState();
    args.taskQueueCounterScratchOffset  = CurrentSplitTaskQueueCounter();
    args.atomicFlagsScratchOffset       = ShaderConstants.offsets.splitAtomicFlags;
    args.dynamicBlockIndexScratchOffset = ShaderConstants.offsets.dynamicBlockIndex;
    args.sceneBoundsByteOffset          = ShaderConstants.offsets.sceneBounds;
    args.tsBudgetPerTriangle            = ShaderConstants.tsBudgetPerTriangle;
    args.encodeTaskCounterScratchOffset = ShaderConstants.offsets.encodeTaskCounter;

    TriangleSplittingImpl(globalId, localId, groupId, args);
}

//======================================================================================================================
void BuildBvhPloc(
    inout uint numTasksWait,
    inout uint waveId,
    uint       globalId,
    uint       localId,
    uint       groupId,
    uint       numActivePrims)
{
    BuildPlocArgs plocArgs;

    plocArgs.numThreads                     = GetNumThreads();
    plocArgs.scratchNodesScratchOffset      = CalculateBvhNodesOffset(ShaderConstants, numActivePrims);
    plocArgs.clusterList0ScratchOffset      = ShaderConstants.offsets.clusterList0;
    plocArgs.clusterList1ScratchOffset      = ShaderConstants.offsets.clusterList1;
    plocArgs.neighbourIndicesScratchOffset  = ShaderConstants.offsets.neighborIndices;
    plocArgs.currentStateScratchOffset      = ShaderConstants.offsets.currentState;
    plocArgs.taskQueueCounterScratchOffset  = ShaderConstants.offsets.plocTaskQueueCounter;
    plocArgs.atomicFlagsScratchOffset       = ShaderConstants.offsets.atomicFlagsPloc;
    plocArgs.offsetsScratchOffset           = ShaderConstants.offsets.clusterOffsets;
    plocArgs.dynamicBlockIndexScratchOffset = ShaderConstants.offsets.dynamicBlockIndex;
    plocArgs.numBatchesScratchOffset        = ShaderConstants.offsets.numBatches;
    plocArgs.baseBatchIndicesScratchOffset  = ShaderConstants.offsets.batchIndices;
    plocArgs.fp16BoxNodesInBlasMode         = Settings.fp16BoxNodesMode;
    plocArgs.fp16BoxModeMixedSaThresh       = Settings.fp16BoxModeMixedSaThreshold;
    plocArgs.plocRadius                     = Settings.plocRadius;
    plocArgs.splitBoxesByteOffset           = ShaderConstants.offsets.triangleSplitBoxes;
    plocArgs.primIndicesSortedScratchOffset = ShaderConstants.offsets.primIndicesSorted;
    plocArgs.numLeafNodes                   = ShaderConstants.numLeafNodes;
    plocArgs.unsortedBvhLeafNodesOffset     = ShaderConstants.offsets.bvhLeafNodeData;

    BuildBvhPlocImpl(globalId, localId, groupId, numActivePrims, plocArgs);
}

//======================================================================================================================
void Rebraid(
    uint       globalId,
    uint       localId,
    uint       groupId)
{
    RebraidArgs args;

    args.numPrimitives                      = ShaderConstants.numPrimitives;
    args.numThreadGroups                    = ShaderRootConstants.numThreadGroups;
    args.maxNumPrims                        = ShaderConstants.rebraidFactor * ShaderConstants.numPrimitives;
    args.bvhLeafNodeDataScratchOffset       = ShaderConstants.offsets.bvhLeafNodeData;
    args.sceneBoundsOffset                  = ShaderConstants.offsets.sceneBounds;
    args.stateScratchOffset                 = CurrentSplitState();
    args.taskQueueCounterScratchOffset      = CurrentSplitTaskQueueCounter();
    args.atomicFlagsScratchOffset           = ShaderConstants.offsets.splitAtomicFlags;
    args.encodeArrayOfPointers              = ShaderConstants.encodeArrayOfPointers;
    args.enableMortonSize                   = ShaderConstants.numMortonSizeBits > 0;
    args.numIterations                      = Settings.numRebraidIterations;
    args.qualityHeuristic                   = Settings.rebraidQualityHeuristic;

    RebraidImpl(globalId, localId, groupId, args);
}

//======================================================================================================================
void BuildBvhTD(
    uint       globalId,
    uint       localId,
    uint       groupId,
    uint       numPrimitives)
{
    TDArgs args;

    args.NumPrimitives                = numPrimitives;
    args.NumThreads                   = GetNumThreads();
    args.MaxRefCountSize              = numPrimitives * ShaderConstants.rebraidFactor;
    args.LengthPercentage             = 0.1;
    args.BvhNodeDataScratchOffset     = ShaderConstants.offsets.bvhNodeData;
    args.BvhLeafNodeDataScratchOffset = ShaderConstants.offsets.bvhLeafNodeData;
    args.SceneBoundsOffset            = ShaderConstants.offsets.sceneBounds;
    args.RefScratchOffset             = ShaderConstants.offsets.tdRefs;
    args.TDNodeScratchOffset          = ShaderConstants.offsets.tdNodeList;
    args.TDBinsScratchOffset          = ShaderConstants.offsets.tdBins;
    args.CurrentStateScratchOffset    = ShaderConstants.offsets.tdState;
    args.TdTaskQueueCounterScratchOffset = ShaderConstants.offsets.tdTaskQueueCounter;
    args.EncodeArrayOfPointers        = ShaderConstants.encodeArrayOfPointers;

    BuildBVHTDImpl(globalId, localId, groupId, args);
}

//======================================================================================================================
void PairCompression(
    uint globalId,
    uint localId,
    uint numActivePrims)
{
    const uint buildInfo  = ReadAccelStructHeaderField(ACCEL_STRUCT_HEADER_INFO_OFFSET);
    const uint buildFlags = (buildInfo >> ACCEL_STRUCT_HEADER_INFO_FLAGS_SHIFT) & ACCEL_STRUCT_HEADER_INFO_FLAGS_MASK;

    PairCompressionArgs args;

    args.scratchNodesScratchOffset    = CalculateBvhNodesOffset(ShaderConstants, numActivePrims);
    args.numBatchesScratchOffset      = ShaderConstants.offsets.numBatches;
    args.batchIndicesScratchOffset    = ShaderConstants.offsets.batchIndices;
    args.indexBufferInfoScratchOffset = ShaderConstants.offsets.indexBufferInfo;
    args.flagsScratchOffset           = ShaderConstants.offsets.propagationFlags;
    args.buildFlags                   = buildFlags;

    PairCompressionImpl(globalId, localId, args);
}

//======================================================================================================================
BuildQbvhArgs GetBuildQbvhArgs(
    uint numLeafNodes,
    uint numActivePrims)
{
    BuildQbvhArgs qbvhArgs;

    const uint rootNodeIndex = FetchRootNodeIndex(
        Settings.enableFastLBVH, ShaderConstants.offsets.fastLBVHRootNodeIndex);

    qbvhArgs.numPrimitives               = numLeafNodes;
    qbvhArgs.metadataSizeInBytes         = DstMetadata.Load(ACCEL_STRUCT_METADATA_SIZE_OFFSET);
    qbvhArgs.numThreads                  = GetNumThreads();
    qbvhArgs.scratchNodesScratchOffset   = CalculateBvhNodesOffset(ShaderConstants, numActivePrims);
    qbvhArgs.qbvhStackScratchOffset      = ShaderConstants.offsets.qbvhGlobalStack;
    qbvhArgs.stackPtrsScratchOffset      = ShaderConstants.offsets.qbvhGlobalStackPtrs;
    qbvhArgs.splitBoxesByteOffset        = ShaderConstants.offsets.triangleSplitBoxes;
    qbvhArgs.triangleCompressionMode     = Settings.triangleCompressionMode;
    qbvhArgs.fp16BoxNodesInBlasMode      = Settings.fp16BoxNodesMode;
    qbvhArgs.encodeArrayOfPointers       = ShaderConstants.encodeArrayOfPointers;
    qbvhArgs.rebraidEnabled              = (Settings.rebraidType != RebraidType::Off);
    qbvhArgs.enableFusedInstanceNode     = Settings.enableFusedInstanceNode;
    qbvhArgs.enableFastLBVH              = Settings.enableFastLBVH;
    qbvhArgs.fastLBVHRootNodeIndex       = rootNodeIndex;
    qbvhArgs.unsortedBvhLeafNodesOffset  = ShaderConstants.offsets.bvhLeafNodeData;

    return qbvhArgs;

}

//======================================================================================================================
void InitBuildQbvh(
    uint globalId,
    uint numLeafNodes,
    uint numActivePrims)
{
    const BuildQbvhArgs qbvhArgs = GetBuildQbvhArgs(numLeafNodes, numActivePrims);
    InitBuildQbvhImpl(globalId, qbvhArgs);
}

//======================================================================================================================
void BuildQbvh(
    uint globalId,
    uint localId,
    uint numLeafNodes,
    uint numActivePrims)
{
    const BuildQbvhArgs qbvhArgs = GetBuildQbvhArgs(numLeafNodes, numActivePrims);

    {
        BuildQbvhImpl(globalId, localId, numActivePrims, qbvhArgs, (Settings.topLevelBuild != 0));
    }
}

//======================================================================================================================
void writeDebugCounter(uint counterStageOffset)
{
    if (Settings.enableBVHBuildDebugCounters)
    {
        IncreaseDebugCounters(ShaderConstants.offsets.debugCounters, counterStageOffset);
    }
}

//======================================================================================================================
void MergeSort(inout uint numTasksWait, inout uint waveId, uint localId, uint groupId, uint numPrimitives)
{
    MergeSortImpl(numTasksWait,
                  waveId,
                  localId,
                  groupId,
                  numPrimitives,
                  ShaderConstants.offsets.mortonCodes,
                  ShaderConstants.offsets.mortonCodesSorted,
                  ShaderConstants.offsets.primIndicesSorted,
                  ShaderConstants.offsets.primIndicesSortedSwap,
                  Settings.useMortonCode30);
}

//======================================================================================================================
// Initialize headers and task counters
void InitAccelerationStructure()
{
    // Initalize headers (metadata task counter is initialized using the CP)
    if (Settings.topLevelBuild && (ShaderConstants.numPrimitives == 0))
    {
        DstMetadata.Store(ACCEL_STRUCT_METADATA_VA_LO_OFFSET, 0);
        DstMetadata.Store(ACCEL_STRUCT_METADATA_VA_HI_OFFSET, 0);
    }
    else
    {
        DstMetadata.Store(ACCEL_STRUCT_METADATA_VA_LO_OFFSET, ShaderConstants.resultBufferAddrLo);
        DstMetadata.Store(ACCEL_STRUCT_METADATA_VA_HI_OFFSET, ShaderConstants.resultBufferAddrHi);
    }
    DstMetadata.Store(ACCEL_STRUCT_METADATA_SIZE_OFFSET, ShaderConstants.header.metadataSizeInBytes);

    DstBuffer.Store(0, ShaderConstants.header);

    // Initialise encode counters
    ScratchBuffer.Store(
        ShaderConstants.offsets.encodeTaskCounter + ENCODE_TASK_COUNTER_NUM_PRIMITIVES_OFFSET, 0);

    // Early triangle pairing and triangle splitting dynamically increment primitive reference counter. Initialise
    // counters to 0 when these features are enabled
    const uint primRefInitCount =
        (Settings.enableEarlyPairCompression || Settings.doTriangleSplitting) ? 0 : ShaderConstants.numPrimitives;

    ScratchBuffer.Store(
        ShaderConstants.offsets.encodeTaskCounter + ENCODE_TASK_COUNTER_PRIM_REFS_OFFSET, primRefInitCount);

    // Initialize valid scratch buffer counters to 0
    InitScratchCounter(ShaderConstants.offsets.plocTaskQueueCounter);
    InitScratchCounter(ShaderConstants.offsets.tdTaskQueueCounter);
    InitScratchCounter(CurrentSplitTaskQueueCounter());
    ClearNumBatches(ShaderConstants.offsets.numBatches);

    // Initialize scene bounds
    const uint maxVal = FloatToUint(FLT_MAX);
    const uint minVal = FloatToUint(-FLT_MAX);

    uint offset = ShaderConstants.offsets.sceneBounds;
    ScratchBuffer.Store3(offset, maxVal.xxx);
    offset += sizeof(uint3);
    ScratchBuffer.Store3(offset, minVal.xxx);
    offset += sizeof(uint3);
    ScratchBuffer.Store2(offset, uint2(maxVal, minVal));
    offset += sizeof(uint2);

    if (Settings.rebraidType == RebraidType::V2)
    {
        ScratchBuffer.Store3(offset, maxVal.xxx);
        offset += sizeof(uint3);
        ScratchBuffer.Store3(offset, minVal.xxx);
    }
}

#if !AMD_VULKAN
//======================================================================================================================
// Encode primitives for each geometry.
void EncodePrimitives(
    uint globalId,
    uint localId)
{
    for (uint geometryIndex = 0; geometryIndex < ShaderConstants.numDescs; geometryIndex++)
    {
        const uint numPrimitives = GeometryConstants[geometryIndex].NumPrimitives;
        const uint primitiveOffset = GeometryConstants[geometryIndex].PrimitiveOffset;

        GeometryArgs geometryArgs = GeometryConstants[geometryIndex];
        geometryArgs.BuildFlags = 0; // Indicate this is not an update

        if (globalId == 0)
        {
            WriteGeometryInfo(
                geometryArgs, primitiveOffset, geometryArgs.NumPrimitives, DECODE_PRIMITIVE_STRIDE_TRIANGLE);
        }

        for (uint primitiveIndex = globalId; primitiveIndex < numPrimitives; primitiveIndex += GetNumThreads())
        {
            // not an update, just check the "enableEarlyPairCompression" and decide which Encode path to use
            if (Settings.enableEarlyPairCompression == true)
            {
                EncodePairedTriangleNodeImpl(
                    GeometryBuffer[geometryIndex],
                    IndexBuffer[geometryIndex],
                    TransformBuffer[geometryIndex],
                    geometryArgs,
                    primitiveIndex,
                    globalId,
                    primitiveOffset,
                    0);
            }
            else
            {
                EncodeTriangleNode(
                    GeometryBuffer[geometryIndex],
                    IndexBuffer[geometryIndex],
                    TransformBuffer[geometryIndex],
                    geometryArgs,
                    primitiveIndex,
                    primitiveOffset,
                    0,
                    false); // Don't write to the update stack
            }
        }
    }
}
#endif

//======================================================================================================================
[RootSignature(RootSig)]
[numthreads(BUILD_THREADGROUP_SIZE, 1, 1)]
void BuildBvh(
    uint globalIdIn : SV_DispatchThreadID,
    uint localIdIn  : SV_GroupThreadID,
    uint groupIdIn  : SV_GroupID)
{
    uint globalId = globalIdIn;
    uint localId = localIdIn;
    uint groupId = groupIdIn;

    uint waveId = 0;
    uint numTasksWait = 0;

    if (Settings.doEncode == false)
    {
        WaitForEncodeTasksToFinish(ShaderConstants.numPrimitives);
    }

    INIT_TASK;

#if !AMD_VULKAN
    if (Settings.doEncode)
    {
        BEGIN_TASK(1);

        if (globalId == 0)
        {
            InitAccelerationStructure();
        }

        END_TASK(1);

        BEGIN_TASK(ShaderRootConstants.numThreadGroups);

        EncodePrimitives(globalId, localId);

        END_TASK(ShaderRootConstants.numThreadGroups);
    }
#endif

    DeviceMemoryBarrierWithGroupSync();

    if (Settings.doTriangleSplitting)
    {
        TriangleSplitting(globalId, localId, groupId);
    }
    else if (Settings.rebraidType == RebraidType::V2)
    {
        Rebraid(globalId, localId, groupId);
    }

    // Note, the primitive reference counter in scratch represents the following.
    //
    // BLAS Default: Number of triangles processed by Encode.
    // BLAS EarlyPairCompression: Number of triangle references including paired triangles.
    // BLAS TriangleSplitting: Number of split triangle references.
    // TLAS Default: Number of instances processed by Encode.
    // TLAS Rebraid: Number of rebraided instances created by the rebraid process.
    //
    // TODO: Support early triangle pairing with triangle splitting.
    //
    const uint numPrimitives = FetchTaskCounter(
        ShaderConstants.offsets.encodeTaskCounter + ENCODE_TASK_COUNTER_PRIM_REFS_OFFSET);

    uint numActivePrims;

    if (Settings.enableTopDownBuild)
    {
        BuildBvhTD(globalId, localId, groupId, numPrimitives);

        numActivePrims = ReadAccelStructHeaderField(ACCEL_STRUCT_HEADER_NUM_ACTIVE_PRIMS_OFFSET);
    }
    else
    {
        bool needRefit = false;

        if ((Settings.fastBuildThreshold) && (numPrimitives <= Settings.fastBuildThreshold) && (numPrimitives <= WaveGetLaneCount()))
        {
            BEGIN_TASK(1);

            FastBuildBVH(globalId,
                         numPrimitives,
                         ShaderConstants.offsets.bvhLeafNodeData,
                         ShaderConstants.offsets.bvhNodeData);

            END_TASK(1);
            needRefit = true;
            numActivePrims = ReadAccelStructHeaderField(ACCEL_STRUCT_HEADER_NUM_ACTIVE_PRIMS_OFFSET);
        }
        else
        {
            BEGIN_TASK(ShaderRootConstants.numThreadGroups);

            GenerateMortonCodes(globalId, numPrimitives);

            END_TASK(ShaderRootConstants.numThreadGroups);
            writeDebugCounter(COUNTER_MORTONGEN_OFFSET);
            numActivePrims = ReadAccelStructHeaderField(ACCEL_STRUCT_HEADER_NUM_ACTIVE_PRIMS_OFFSET);

            if (numActivePrims > 0)
            {
                if (Settings.enableMergeSort)
                {
                    MergeSort(numTasksWait, waveId, localId, groupId, numPrimitives);
                }
                else
                {
                    RadixSort(numTasksWait, waveId, globalId, localId, groupId, numPrimitives, Settings.radixSortScanLevel, Settings.useMortonCode30);
                }
                writeDebugCounter(COUNTER_MORTON_SORT_OFFSET);
                // Note there is an implicit sync on the last pass of the sort

                if (Settings.noCopySortedNodes == false)
                {
                    BEGIN_TASK(ShaderRootConstants.numThreadGroups);

                    SortScratchLeaves(globalId, numActivePrims);

                    END_TASK(ShaderRootConstants.numThreadGroups);
                    writeDebugCounter(COUNTER_SORTLEAF_OFFSET);
                }
                // If noCopySortedNodes is on, the unsorted leaves will stay where the
                // Encode step put them. On top of that, if TS or Rebraid is also on,
                // there might be a gap between the last inner node and the first leaf
                // if we place the root of the tree at ShaderConstants.offsets.bvhNodeData.
                // To avoid that gap, the root is moved forward by numLeafNodes - numActivePrims
                // nodes from this point onwards.

                if (Settings.buildMode == BUILD_MODE_PLOC)
                {
                    BuildBvhPloc(numTasksWait, waveId, globalId, localId, groupId, numActivePrims);
                    writeDebugCounter(COUNTER_BUILDPLOC_OFFSET);
                }
                else
                {
                    if (Settings.enableFastLBVH == false)
                    {
                        BEGIN_TASK(ShaderRootConstants.numThreadGroups);

                        BuildBvhLinear(globalId, numActivePrims, numPrimitives);

                        END_TASK(ShaderRootConstants.numThreadGroups);
                        writeDebugCounter(COUNTER_BUILDLBVH_OFFSET);
                        needRefit = true;
                    }
                    else
                    {
                        BEGIN_TASK(ShaderRootConstants.numThreadGroups);

                        FastAgglomerativeLbvh(globalId, numActivePrims);

                        END_TASK(ShaderRootConstants.numThreadGroups);
                        writeDebugCounter(COUNTER_BUILDFASTLBVH_OFFSET);
                    }
                }
            }
        }

        if (numActivePrims > 0)
        {
            if (needRefit)
            {
                BEGIN_TASK(ShaderRootConstants.numThreadGroups);

                RefitBounds(globalId, numActivePrims);

                END_TASK(ShaderRootConstants.numThreadGroups);

                writeDebugCounter(COUNTER_REFIT_OFFSET);
            }

            const uint geometryType = ReadAccelStructHeaderField(ACCEL_STRUCT_HEADER_GEOMETRY_TYPE_OFFSET);

            if (EnableLatePairCompression() && (geometryType == GEOMETRY_TYPE_TRIANGLES))
            {
                const uint numBatches = FetchNumBatches(ShaderConstants.offsets.numBatches);

                BEGIN_TASK(RoundUpQuotient(numBatches, BUILD_THREADGROUP_SIZE));

                PairCompression(globalId, localId, numActivePrims);

                END_TASK(RoundUpQuotient(numBatches, BUILD_THREADGROUP_SIZE));
            }
        }
        else if (Settings.topLevelBuild)
        {
            writeDebugCounter(COUNTER_EMPTYPRIM_OFFSET);
        }
    }

    if (numActivePrims > 0)
    {
        // Note, BuildQBVH only needs to run for valid leaf nodes. numActivePrims already represents
        // valid leaf nodes when rebraid or triangle splitting is enabled.
        uint numLeafNodes = numActivePrims;

        // Fetch leaf node count when triangle compression is enabled.
        if (EnableLatePairCompression())
        {
            numLeafNodes = ReadAccelStructHeaderField(ACCEL_STRUCT_HEADER_NUM_LEAF_NODES_OFFSET);
        }

        BEGIN_TASK(ShaderRootConstants.numThreadGroups);

        InitBuildQbvh(globalId, numLeafNodes, numActivePrims);

        END_TASK(ShaderRootConstants.numThreadGroups);
        writeDebugCounter(COUNTER_INITQBVH_OFFSET);

        BEGIN_TASK(RoundUpQuotient(GetNumInternalNodeCount(numLeafNodes), BUILD_THREADGROUP_SIZE));

        BuildQbvh(globalId, localId, numLeafNodes, numActivePrims);

        END_TASK(RoundUpQuotient(GetNumInternalNodeCount(numLeafNodes), BUILD_THREADGROUP_SIZE));

        writeDebugCounter(COUNTER_BUILDQBVH_OFFSET);

    }

    BEGIN_TASK(1);

    PostHwBvhBuild(localId, numActivePrims);

    END_TASK(1);
    writeDebugCounter(COUNTER_EMITCOMPACTSIZE_OFFSET);
}
