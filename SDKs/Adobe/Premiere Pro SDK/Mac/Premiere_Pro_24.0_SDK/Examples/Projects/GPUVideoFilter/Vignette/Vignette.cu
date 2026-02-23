#ifndef VIGNETTE_CU
    #define VIGNETTE_CU

    #include "VignetteGPU.h"

    #if __CUDACC_VER_MAJOR__ >= 9
        #include <cuda_fp16.h>
    #endif

	struct half4
	{
		half x, y, z, w;
	};

	inline __device__ float4 Half4ToFloat4(half4 inV)
	{
		float4 out;
		out.x = __half2float(inV.x);
		out.y = __half2float(inV.y);
		out.z = __half2float(inV.z);
		out.w = __half2float(inV.w);

		return out;
	}

	inline __device__ half4 Float4ToHalf4( float4 inV )
	{
		half4 out;
		out.x = __float2half_rn(inV.x);
		out.y = __float2half_rn(inV.y);
		out.z = __float2half_rn(inV.z);
		out.w = __float2half_rn(inV.w);

		return out;
	}

	// Vignette CUDA kernel

	__global__ void kVignetteCUDA (
		float4* inDestImg,
		const int inDestPitch,
		const int in16f,
		const int inWidth,
		const int inHeight,
		const float	inAmountF,
		const float	outer_aaF,
		const float	outer_bbF,
		const float	outer_abF,
		const float	inner_aaF,
		const float	inner_bbF,
		const float	inner_aabbF,
		const float	inner_abF,
		float	x_t,
		float	y_t
		)	
	{
		float4 dest;

		int x = blockIdx.x*blockDim.x + threadIdx.x;
		int y = blockIdx.y*blockDim.y + threadIdx.y;

		if ( x >= inWidth || y >= inHeight ) return;

		if ( in16f ) {
			//Pixel16*  in16 = (Pixel16*)  destImg;			
			//dest = Half4ToFloat4(  in16[y *  destPitch + x] );
			dest = Half4ToFloat4(((half4*)inDestImg)[y * inDestPitch + x]);
		} else {
			dest = inDestImg[y * inDestPitch + x];
		}
		
		x_t = x - x_t;
		y_t = y - y_t;

		float f = 0.0f;

		if (x_t != 0 || y_t != 0)
		{

			float xx = x_t * x_t;
			float yy = y_t * y_t;

			if (inner_aaF == outer_aaF)
			{
				f = xx*inner_bbF + yy * inner_aaF < inner_aabbF ? 0.0f : 1.0f;
			}
			else {
				float R = sqrt(xx + yy),
					r_i = inner_abF / sqrt(inner_bbF * xx + inner_aaF * yy) * R,
					r_o = outer_abF / sqrt(outer_bbF * xx + outer_aaF * yy) * R;
				f = min(1.0f, max(0.0f, (R - r_i) / (r_o - r_i)));
			}
		}

		f *= inAmountF;

		dest.x = max(0.0f, dest.x + f);
		dest.y = max(0.0f, dest.y + f);
		dest.z = max(0.0f, dest.z + f);

		if ( in16f ) {
			((half4*)inDestImg)[y * inDestPitch + x] = Float4ToHalf4(dest);

		} else {
			inDestImg[y * inDestPitch + x] = dest;
		}
	}
	
	void Vignette_CUDA (
		float *destBuf,
		int destPitch,
		int	is16f,
		int width,
		int height,
		VigInfoGPU *viP )
	{
		dim3 blockDim (16, 16, 1);
		dim3 gridDim ( (width + blockDim.x - 1)/ blockDim.x, (height + blockDim.y - 1) / blockDim.y, 1 );		

		kVignetteCUDA <<< gridDim, blockDim, 0 >>> ( (float4*) destBuf, destPitch, is16f, width, height,  
			viP->amountF,
			viP->outer_aaF,
			viP->outer_bbF,
			viP->outer_abF,
			viP->inner_aaF,
			viP->inner_bbF,
			viP->inner_aabbF,
			viP->inner_abF,
			viP->x_t,
			viP->y_t);

		cudaDeviceSynchronize();
	}

#endif 
