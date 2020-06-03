#ifndef CUBLAS_LIB
#include <blas_lapack.h>
#include <Eigen/LU>

namespace quda {

  namespace blas_lapack {

    void init() {}

    void destroy() {}
    
    using namespace Eigen;

    template<typename EigenMatrix, typename Float>
    void invertEigen(std::complex<Float> *A_eig, std::complex<Float> *Ainv_eig, int n, uint64_t batch) {
      
      EigenMatrix res = EigenMatrix::Zero(n,n);
      EigenMatrix inv;
      for(int j = 0; j<n; j++) {
	for(int k = 0; k<n; k++) {
	  res(j,k) = A_eig[batch*n*n + j*n + k];
	}
      }
      
      inv = res.inverse();
      
      for(int j=0; j<n; j++) {
	for(int k=0; k<n; k++) {
	  Ainv_eig[batch*n*n + j*n + k] = inv(j,k);
	}
      }
    }
    
    long long BatchInvertMatrix(void *Ainv, void* A, const int n, const uint64_t batch, QudaPrecision prec, QudaFieldLocation location)
    {
      long long flops = 0;
      printfQuda("BatchInvertMatrixGENERIC: Nc = %d, batch = %lu\n",
		 n, batch);
      
      timeval start, stop;
      gettimeofday(&start, NULL);
      
      if (prec == QUDA_SINGLE_PRECISION) {
	
	std::complex<float> *A_eig = (std::complex<float> *)A;
	std::complex<float> *Ainv_eig = (std::complex<float> *)Ainv;
	
#pragma omp parallel for
	for(uint64_t i=0; i<batch; i++) {
	  invertEigen<MatrixXcf, float>(A_eig, Ainv_eig, n, i);
	}
	flops += batch*FLOPS_CGETRF(n,n);
      }
      else if (prec == QUDA_DOUBLE_PRECISION) {
	
	std::complex<double> *A_eig = (std::complex<double> *)A;
	std::complex<double> *Ainv_eig = (std::complex<double> *)Ainv;
	
#pragma omp parallel for
	for(uint64_t i=0; i<batch; i++) {
	  invertEigen<MatrixXcd, double>(A_eig, Ainv_eig, n, i);
	}
	flops += batch*FLOPS_ZGETRF(n,n);  
      } else {
	errorQuda("%s not implemented for precision = %d", __func__, prec);
      }
      
      gettimeofday(&stop, NULL);
      long dsh = stop.tv_sec - start.tv_sec;
      long dush = stop.tv_usec - start.tv_usec;
      double timeh = dsh + 0.000001*dush;
      
      printfQuda("CPU: Batched matrix inversion completed in %f seconds with GFLOPS = %f\n", timeh, 1e-9 * flops / timeh);
      
      return flops;
    }
  } // namespace blas_lapack
} // namespace quda
#endif