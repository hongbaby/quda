#include <stdlib.h>
#include <stdio.h>

#include <quda_internal.h>
#include <dslash_quda.h>

#define BLOCK_DIM 64

#include <dslash_textures.h>
#include <dslash_constants.h>

// kludge to avoid '#include nested too deeply' error
#define DD_DAG 0
#include <dslash_def.h>
#undef DD_DAG
#define DD_DAG 1
#include <dslash_def.h>
#undef DD_DAG

#include <clover_def.h> // kernels for applying the clover term alone

#include <blas_quda.h>

int dslashCudaSharedBytes(QudaPrecision precision) {
  return BLOCK_DIM*SHARED_FLOATS_PER_THREAD*precision;
}

template <int spinorN, typename spinorFloat, typename gaugeFloat>
void dslashCuda(spinorFloat *out, float *outNorm, const gaugeFloat *gauge0, const gaugeFloat *gauge1, 
		const QudaReconstructType reconstruct, const spinorFloat *in, const float *inNorm,
		const int parity, const int dagger, const spinorFloat *x, const float *xNorm, 
		const double &a, const int volume, const int length) {

  dim3 gridDim(volume/BLOCK_DIM, 1, 1);
  dim3 blockDim(BLOCK_DIM, 1, 1);

  int shared_bytes = blockDim.x*SHARED_FLOATS_PER_THREAD*bindSpinorTex<spinorN>(length, in, inNorm, x, xNorm);

  if (x==0) { // not doing xpay
    if (reconstruct == QUDA_RECONSTRUCT_12) {
      if (!dagger) {
	dslash12Kernel <<<gridDim, blockDim, shared_bytes>>> 
	  (out, outNorm, gauge0, gauge1, in, inNorm, parity);
      } else {
	dslash12DaggerKernel <<<gridDim, blockDim, shared_bytes>>> 
	  (out, outNorm, gauge0, gauge1, in, inNorm, parity);
      }
    } else {
      if (!dagger) {
	dslash8Kernel <<<gridDim, blockDim, shared_bytes>>> 
	  (out, outNorm, gauge0, gauge1, in, inNorm, parity);
      } else {
	dslash8DaggerKernel <<<gridDim, blockDim, shared_bytes>>> 
	  (out, outNorm, gauge0, gauge1, in, inNorm, parity);
      }
    }
  } else { // doing xpay
    if (reconstruct == QUDA_RECONSTRUCT_12) {
      if (!dagger) {
	dslash12XpayKernel <<<gridDim, blockDim, shared_bytes>>> 
	  (out, outNorm, gauge0, gauge1, in, inNorm, parity, x, xNorm, a);
      } else {
	dslash12DaggerXpayKernel <<<gridDim, blockDim, shared_bytes>>> 
	  (out, outNorm, gauge0, gauge1, in, inNorm, parity, x, xNorm, a);
      }
    } else if (reconstruct == QUDA_RECONSTRUCT_8) {
      if (!dagger) {
	dslash8XpayKernel <<<gridDim, blockDim, shared_bytes>>> 
	  (out, outNorm, gauge0, gauge1, in, inNorm, parity, x, xNorm, a);
      } else {
	dslash8DaggerXpayKernel <<<gridDim, blockDim, shared_bytes>>>
	  (out, outNorm, gauge0, gauge1, in, inNorm, parity, x, xNorm, a);
      }
    }
  }
  
}

// Wilson wrappers
void dslashCuda(void *out, void *outNorm, const FullGauge gauge, const void *in, const void *inNorm, 
		const int parity, const int dagger, const void *x, const void *xNorm, 
		const double k, const int volume, const int length, const QudaPrecision precision) {

  void *gauge0, *gauge1;
  bindGaugeTex(gauge, parity, &gauge0, &gauge1);

  if (precision == QUDA_DOUBLE_PRECISION) {
#if (__CUDA_ARCH__ == 130)
    dslashCuda<2>((double2*)out, (float*)outNorm, (double2*)gauge0, (double2*)gauge1, 
		  gauge.reconstruct, (double2*)in, (float*)inNorm, parity, dagger, 
		  (double2*)x, (float*)xNorm, k, volume, length);
#else
    errorQuda("Double precision not supported on this GPU");
#endif
  } else if (precision == QUDA_SINGLE_PRECISION) {
    dslashCuda<4>((float4*)out, (float*)outNorm, (float4*)gauge0, (float4*)gauge1,
		  gauge.reconstruct, (float4*)in, (float*)inNorm, parity, dagger, 
		  (float4*)x, (float*)xNorm, k, volume, length);
  } else if (precision == QUDA_HALF_PRECISION) {
    dslashCuda<4>((short4*)out, (float*)outNorm, (short4*)gauge0, (short4*)gauge1,
		  gauge.reconstruct, (short4*)in, (float*)inNorm, parity, dagger, 
		  (short4*)x, (float*)xNorm, k, volume, length);
  }
  checkCudaError();

}


template <int N, typename spinorFloat>
void cloverCuda(spinorFloat *out, float *outNorm, const FullClover clover, 
		const spinorFloat *in, const float *inNorm, const int parity, 
		const int volume, const int length)
{
  dim3 gridDim(volume/BLOCK_DIM, 1, 1);
  dim3 blockDim(BLOCK_DIM, 1, 1);

  void *cloverP, *cloverNormP;
  QudaPrecision clover_prec = bindCloverTex(clover, parity, &cloverP, &cloverNormP);
  int shared_bytes = blockDim.x*SHARED_FLOATS_PER_THREAD*bindSpinorTex<N>(length, in, inNorm);

  if (clover_prec == QUDA_DOUBLE_PRECISION) {
#if (__CUDA_ARCH__ == 130)
    cloverKernel <<<gridDim, blockDim, shared_bytes>>> 
      (out, outNorm, (double2*)cloverP, (float*)cloverNormP, in, inNorm, parity);
#else
    errorQuda("Double precision not supported on this GPU");
#endif
  } else if (clover_prec == QUDA_SINGLE_PRECISION) {
    cloverKernel <<<gridDim, blockDim, shared_bytes>>> 
      (out, outNorm, (float4*)cloverP, (float*)cloverNormP, in, inNorm, parity);
  } else {
    cloverKernel <<<gridDim, blockDim, shared_bytes>>> 
      (out, outNorm, (short4*)cloverP, (float*)cloverNormP, in, inNorm, parity);
  }
}

void cloverCuda(void *out, void *outNorm, const FullGauge gauge, const FullClover clover, 
		const void *in, const void *inNorm, const int parity, const int volume,
		const int length, const QudaPrecision precision) {

  if (precision == QUDA_DOUBLE_PRECISION) {
#if (__CUDA_ARCH__ == 130)
    cloverCuda<2>((double2*)out, (float*)outNorm, clover, (double2*)in, 
		  (float*)inNorm, parity, volume, length);
#else
    errorQuda("Double precision not supported on this GPU");
#endif
  } else if (precision == QUDA_SINGLE_PRECISION) {
    cloverCuda<4>((float4*)out, (float*)outNorm, clover, (float4*)in, 
		  (float*)inNorm, parity, volume, length);
  } else if (precision == QUDA_HALF_PRECISION) {
    cloverCuda<4>((short4*)out, (float*)outNorm, clover, (short4*)in,
		  (float*)inNorm, parity, volume, length);
  }
  checkCudaError();

}

// Clover wrappers
template <int N, typename spinorFloat, typename cloverFloat, typename gaugeFloat>
void cloverDslashCuda(spinorFloat *out, float *outNorm, const gaugeFloat gauge0, 
		      const gaugeFloat gauge1, const QudaReconstructType reconstruct, 
		      const cloverFloat *clover, const float *cloverNorm, const spinorFloat *in, 
		      const float* inNorm, const int parity, const int dagger, const spinorFloat *x, 
		      const float* xNorm, const double &a, const int volume, const int length)
{
  dim3 gridDim(volume/BLOCK_DIM, 1, 1);
  dim3 blockDim(BLOCK_DIM, 1, 1);

  int shared_bytes = blockDim.x*SHARED_FLOATS_PER_THREAD*bindSpinorTex<N>(length, in, inNorm, x, xNorm);

  if (x==0) { // not xpay
    if (reconstruct == QUDA_RECONSTRUCT_12) {
      if (!dagger) {
	cloverDslash12Kernel <<<gridDim, blockDim, shared_bytes>>> 
	  (out, outNorm, gauge0, gauge1, clover, cloverNorm, in, inNorm, parity);
      } else {
	cloverDslash12DaggerKernel <<<gridDim, blockDim, shared_bytes>>>
	  (out, outNorm, gauge0, gauge1, clover, cloverNorm, in, inNorm, parity);
      }
      if (!dagger) {
	cloverDslash8Kernel <<<gridDim, blockDim, shared_bytes>>> 	
	  (out, outNorm, gauge0, gauge1, clover, cloverNorm, in, inNorm, parity);
      } else {
	cloverDslash8DaggerKernel <<<gridDim, blockDim, shared_bytes>>>
	  (out, outNorm, gauge0, gauge1, clover, cloverNorm, in, inNorm, parity);
      }
    }
  } else { // doing xpay
    if (reconstruct == QUDA_RECONSTRUCT_12) {
      if (!dagger) {
	cloverDslash12XpayKernel <<<gridDim, blockDim, shared_bytes>>> 
	  (out, outNorm, gauge0, gauge1, clover, cloverNorm, in, inNorm, parity, x, xNorm, a);
      } else {
	cloverDslash12DaggerXpayKernel <<<gridDim, blockDim, shared_bytes>>>
	  (out, outNorm, gauge0, gauge1, clover, cloverNorm, in, inNorm, parity, x, xNorm, a);
      }
      if (!dagger) {
	cloverDslash8XpayKernel <<<gridDim, blockDim, shared_bytes>>> 	
	  (out, outNorm, gauge0, gauge1, clover, cloverNorm, in, inNorm, parity, x, xNorm, a);
      } else {
	cloverDslash8DaggerXpayKernel <<<gridDim, blockDim, shared_bytes>>>
	  (out, outNorm, gauge0, gauge1, clover, cloverNorm, in, inNorm, parity, x, xNorm, a);
      }
    }
  }

}

void cloverDslashCuda(void *out, void *outNorm, const FullGauge gauge, const FullClover cloverInv,
		      const void *in, const void *inNorm, const int parity, const int dagger, 
		      const void *x, const void *xNorm, const double a, const int volume, 
		      const int length, const QudaPrecision precision) {

  void *cloverP, *cloverNormP;
  QudaPrecision clover_prec = bindCloverTex(cloverInv, parity, &cloverP, &cloverNormP);

  void *gauge0, *gauge1;
  bindGaugeTex(gauge, parity, &gauge0, &gauge1);

  if (precision == QUDA_DOUBLE_PRECISION) {
#if (__CUDA_ARCH__ == 130)
    cloverDslashCuda<2>((double2*)out, (float*)outNorm, (double2*)gauge0, (double2*)gauge1, 
			gauge.reconstruct, (double2*)cloverP, (float*)cloverNormP, (double2*)in, 
			(float*)inNorm, parity, dagger, (double2*)x, (float*)xNorm, a, volume, length);
#else
    errorQuda("Double precision not supported on this GPU");
#endif
  } else if (precision == QUDA_SINGLE_PRECISION) {
    cloverDslashCuda<4>((float4*)out, (float*)outNorm, (float4*)gauge0, (float4*)gauge1, 
			gauge.reconstruct, (float4*)cloverP, (float*)cloverNormP, (float4*)in, 
			(float*)inNorm, parity, dagger, (float4*)x, (float*)xNorm, a, volume, length);
  } else if (precision == QUDA_HALF_PRECISION) {
    cloverDslashCuda<4>((short4*)out, (float*)outNorm, (short4*)gauge0, (short4*)gauge1, 
			gauge.reconstruct, (short4*)cloverP, (float*)cloverNormP, (short4*)in,
			(float*)inNorm, parity, dagger, (short4*)x, (float*)xNorm, a, volume, length);
  }

  checkCudaError();

}
