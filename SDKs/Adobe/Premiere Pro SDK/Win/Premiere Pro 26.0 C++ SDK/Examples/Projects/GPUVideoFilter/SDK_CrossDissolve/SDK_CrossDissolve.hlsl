/*************************************************************************
 * ADOBE CONFIDENTIAL
 * ___________________
 *
 * Copyright 2023 Adobe
 * All Rights Reserved.
 *
 * NOTICE: All information contained herein is, and remains
 * the property of Adobe and its suppliers, if any. The intellectual
 * and technical concepts contained herein are proprietary to Adobe
 * and its suppliers and are protected by all applicable intellectual
 * property laws, including trade secret and copyright laws.
 * Dissemination of this information or reproduction of this material
 * is strictly forbidden unless prior written permission is obtained
 * from Adobe.
 **************************************************************************/
 /*
 * Buffers associated with the shader
 * Read-Write/Write buffers are registered as UAVs while
 * Read-only buffers are registered as SRVs
 * See u0 is bound as UAV in RootSignature below while
 * t0/t1 are bound as SRVs
 */
ByteAddressBuffer OutImg: register(t0);
ByteAddressBuffer InImg: register(t1);
RWByteAddressBuffer DestImg: register(u0);

/*
* Parameters which will be used by the shader
* The structure should exactly match the parameter structure
* in the host code
*/
cbuffer cb: register(b0)
{
	uint mOutPitch;
	uint mInPitch;
	uint mDestPitch;
	int mIs16f;
	uint mWidth;
	uint mHeight;
	float mProgress;
	int mFlip;
};

// Thread-block size for execution
[numthreads(16, 16, 1)]

// Root Signature determines the order in which the different elements (CBV/UAV/SRV) are expected from the host code
// We recommend using Descriptor tables over Root Descriptors
[RootSignature("DescriptorTable(CBV(b0)),DescriptorTable(UAV(u0)),DescriptorTable(SRV(t0, numDescriptors = 2, flags=DESCRIPTORS_VOLATILE))")]
void main(uint3 inXY : SV_DispatchThreadID)
{
	uint dataSize;
	float4 outgoing, incoming, dest;
	if ( inXY.x >= mWidth || inXY.y >= mHeight ) return;
	if (mIs16f)
	{
		dataSize = sizeof(half4);
		outgoing = float4(OutImg.Load<half4>(mOutPitch * inXY.y + dataSize * inXY.x));
		incoming = float4(InImg.Load<half4>(mInPitch * inXY.y + dataSize * inXY.x));
	}
	else
	{
		dataSize = sizeof(float4);
		outgoing = OutImg.Load<float4>(mOutPitch * inXY.y + dataSize * inXY.x);
		incoming = InImg.Load<float4>(mInPitch * inXY.y + dataSize * inXY.x);
	}
	
	float outgoingAlphaWeighted = outgoing.w * (1.0f - mProgress);
	float incomingAlphaWeighted  = incoming.w * mProgress; 
	float newAlpha = outgoingAlphaWeighted  + incomingAlphaWeighted ; 
	float recipNewAlpha = newAlpha != 0.0f ? 1.0f / newAlpha : 0.0f;
	
	dest.x = (outgoing.x * outgoingAlphaWeighted + incoming.x * incomingAlphaWeighted) * recipNewAlpha; 
	dest.y = (outgoing.y * outgoingAlphaWeighted + incoming.y * incomingAlphaWeighted) * recipNewAlpha; 
	dest.z = (outgoing.z * outgoingAlphaWeighted + incoming.z * incomingAlphaWeighted) * recipNewAlpha; 
	dest.w = newAlpha;
	
	if (mIs16f)
	{
		DestImg.Store<half4>(mDestPitch * inXY.y + dataSize * inXY.x, half4(dest));
	}
	else
	{
		DestImg.Store<float4>(mDestPitch * inXY.y + dataSize * inXY.x, dest);
	}
}