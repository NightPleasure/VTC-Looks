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
  * See u0 is bound as UAV in RootSignature below
  */
RWByteAddressBuffer mIOImage: register(u0);

/*
* Parameters which will be used by the shader
* The structure should exactly match the parameter structure
* in the host code
*/
cbuffer cb : register(b0)
{
	int     mPitch;
    int     mIs16f;
    int     mWidth;
    int     mHeight;
    float   mBrightness;
    float   mContrast;
    float   mHueCosSaturation;
    float   mHueSinSaturation;
};

// Thread-block size for execution
[numthreads(16, 16, 1)]

// Root Signature determines the order in which the different elements (CBV/UAV/SRV) are expected from the host code
// We recommend using Descriptor tables over Root Descriptors
[RootSignature("DescriptorTable(CBV(b0), visibility=SHADER_VISIBILITY_ALL),DescriptorTable(UAV(u0), visibility=SHADER_VISIBILITY_ALL)")]
void main(uint3 inXY : SV_DispatchThreadID)
{
	if (inXY.x < mWidth && inXY.y < mHeight)
	{
		uint dataSize;
		float4 pixel;
		if (mIs16f)
		{
			dataSize = sizeof(half4);
			pixel = float4(mIOImage.Load<half4>(mPitch * inXY.y + dataSize * inXY.x));
		}
		else
		{
			dataSize = sizeof(float4);
			pixel = mIOImage.Load<float4>(mPitch * inXY.y + dataSize * inXY.x);
		}
		
		/* RGB -> YUV */
		float srcY = pixel.z * 0.299f + pixel.y * 0.587f + pixel.x * 0.114f;
		float srcU = pixel.z * -0.168736f + pixel.y * -0.331264f + pixel.x * 0.5f;
		float srcV = pixel.z * 0.5f + pixel.y * -0.418688f + pixel.x * -0.081312f;

		/* Render ProcAmp */
		float destY = (mContrast * srcY) + mBrightness;
		float destU = (srcU * mHueCosSaturation) + (srcV * -mHueSinSaturation);
		float destV = (srcV * mHueCosSaturation) + (srcU *  mHueSinSaturation);

		/* YUV -> RGB */
		pixel.z = destY * 1.0f + destU * 0.0f + destV * 1.402f;
		pixel.y = destY * 1.0f + destU * -0.344136f + destV * -0.714136f;
		pixel.x = destY * 1.0f + destU * 1.772f + destV * 0.0f;
		
		if (mIs16f)
		{
			mIOImage.Store<half4>(mPitch * inXY.y + dataSize * inXY.x, half4(pixel));
		}
		else
		{
			mIOImage.Store<float4>(mPitch * inXY.y + dataSize * inXY.x, pixel);
		}
	}
}