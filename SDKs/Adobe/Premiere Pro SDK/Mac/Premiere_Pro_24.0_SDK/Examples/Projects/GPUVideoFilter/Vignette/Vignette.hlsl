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
* (See u0 is bound as UAV in RootSignature below)
*/
RWByteAddressBuffer mBuffer: register(u0);

/*
* Parameters which will be used by the shader
* The structure should exactly match the parameter structure
* in the host code
*/
cbuffer cb : register(b0)
{
    int     mDestPitch;
    int     mIs16f;
    int     mWidth;
    int     mHeight;
    float   mAmountF;
    float   mOuter_aaF;
    float   mOuter_bbF;
    float   mOuter_abF;
    float   mInner_aaF;
    float   mInner_bbF;
    float   mInner_aabbF;
    float   mInner_abF;
    float   mX_t;
    float   mY_t;
};

// Thread-block size for execution
[numthreads(16, 16, 1)]

// Root Signature determines the order in which the different elements (CBV/UAV/SRV) are expected from the host code
// We recommend using Descriptor tables over Root Descriptors
[RootSignature("DescriptorTable(CBV(b0)),DescriptorTable(UAV(u0))")]
void main(uint3 inXY : SV_DispatchThreadID)
{
	if (inXY.x < mWidth && inXY.y < mHeight)
	{
		uint dataSize;
		float4 pixel;
		if (mIs16f)
		{
			dataSize = sizeof(half4);
			pixel = float4(mBuffer.Load<half4>(mDestPitch * inXY.y + dataSize * inXY.x));
		}
		else
		{
			dataSize = sizeof(float4);
			pixel = mBuffer.Load<float4>(mDestPitch * inXY.y + dataSize * inXY.x);
		}
		
		float x_t = inXY.x - mX_t;
		float y_t = inXY.y - mY_t;
		float f = 0.0f;
		if (x_t != 0 || y_t != 0)
		{
			float xx = x_t * x_t;
			float yy = y_t * y_t;
			if (mInner_aaF == mOuter_aaF)
			{
				f = xx * mInner_bbF + yy * mInner_aaF < mInner_aabbF ? 0.0f : 1.0f;
			}
			else
			{
				float R = sqrt(xx + yy),
					r_i = mInner_abF / sqrt(mInner_bbF * xx + mInner_aaF * yy) * R,
					r_o = mOuter_abF / sqrt(mOuter_bbF * xx + mOuter_aaF * yy) * R;
				f = min(1.0f, max(0.0f, (R - r_i) / (r_o - r_i)));
			}
		}
		
		f *= mAmountF;
		
		pixel.x = max(0.0f, pixel.x + f);
		pixel.y = max(0.0f, pixel.y + f);
		pixel.z = max(0.0f, pixel.z + f);
		if (mIs16f)
		{
			mBuffer.Store<half4>(mDestPitch * inXY.y + dataSize * inXY.x, half4(pixel));
		}
		else
		{
			mBuffer.Store<float4>(mDestPitch * inXY.y + dataSize * inXY.x, pixel);
		}
	}
}