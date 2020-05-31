#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <math.h>
#include <string.h>
#include <complex>

#include <util_quda.h>
#include <host_utils.h>
#include <command_line_params.h>
#include <dslash_reference.h>
#include <contract_reference.h>
#include "misc.h"

// google test
#include <gtest/gtest.h>

// In a typical application, quda.h is the only QUDA header required.
#include <quda.h>

namespace quda
{
  extern void setTransferGPU(bool);
}

#include <Eigen/Dense>
using namespace Eigen;

void fillEigenArrayColMaj(MatrixXcd &EigenArr, complex<double>* arr, int rows, int cols, int counter = 0){
  for(int j=0; j<cols; j++) {
    for(int i=0; i<rows; i++) {
      EigenArr(i,j) = arr[counter];
      counter++;
    }
  }
}

void fillEigenArrayRowMaj(MatrixXcd &EigenArr, complex<double>* arr, int rows, int cols, int counter = 0){
  for(int i=0; i<rows; i++) {
    for(int j=0; j<cols; j++) {
      EigenArr(i,j) = arr[counter];
      counter++;
    }
  }
}

void diffEigenArrayColMaj(MatrixXcd &EigenArr, complex<double>* arr, int rows, int cols, int counter = 0){
  for(int j=0; j<cols; j++) {
    for(int i=0; i<rows; i++) {
      EigenArr(i,j) -= arr[counter];
      counter++;
    }
  }
}

void diffEigenArrayRowMaj(MatrixXcd &EigenArr, complex<double>* arr, int rows, int cols, int counter = 0){
  for(int i=0; i<rows; i++) {
    for(int j=0; j<cols; j++) {
      EigenArr(i,j) -= arr[counter];
      counter++;
    }
  }
}

void cublasGEMMQudaVerify(void *arrayA, void *arrayB, void *arrayCcopy, void*arrayC,
			  QudaCublasParam *cublas_param){

  // Problem parameters
  int m = cublas_param->m;
  int n = cublas_param->n;
  int k = cublas_param->k;
  int lda = cublas_param->lda;
  int ldb = cublas_param->ldb;
  int ldc = cublas_param->ldc;  
  complex<double> alpha = cublas_param->alpha;
  complex<double> beta = cublas_param->beta;

  // Eigen objects to store data
  MatrixXcd A = MatrixXd::Zero(m, lda);
  MatrixXcd B = MatrixXd::Zero(k, ldb);
  MatrixXcd C = MatrixXd::Zero(m, ldc);

  // Pointers to data
  complex<double>* A_ptr = (complex<double>*)(&arrayA)[0];
  complex<double>* B_ptr = (complex<double>*)(&arrayB)[0];
  complex<double>* C_ptr = (complex<double>*)(&arrayC)[0];
  complex<double>* Ccopy_ptr = (complex<double>*)(&arrayCcopy)[0];

  // Populate Eigen objects
  if(cublas_param->data_order == QUDA_CUBLAS_DATAORDER_COL) {
    fillEigenArrayColMaj(A, A_ptr, lda, m);
    fillEigenArrayColMaj(B, B_ptr, ldb, k);
    fillEigenArrayColMaj(C, Ccopy_ptr, ldc, m);    
  }
  else {
    fillEigenArrayRowMaj(A, A_ptr, m, lda);
    fillEigenArrayRowMaj(B, B_ptr, ldb, k);
    fillEigenArrayRowMaj(C, Ccopy_ptr, ldc, m);        
  }

  // Apply the matrix operation types to A and B
  switch(cublas_param->trans_a) {
  case QUDA_CUBLAS_OP_T : A.transposeInPlace(); break;
  case QUDA_CUBLAS_OP_C : A.adjointInPlace(); break;
  case QUDA_CUBLAS_OP_N : break;
  default :
    errorQuda("Unknown cuBLAS op type %d", cublas_param->trans_a);
  }

  switch(cublas_param->trans_b) {
  case QUDA_CUBLAS_OP_T : B.transposeInPlace(); break;
  case QUDA_CUBLAS_OP_C : B.adjointInPlace(); break;
  case QUDA_CUBLAS_OP_N : break;
  default :
    errorQuda("Unknown cuBLAS op type %d", cublas_param->trans_b);
  }

  // Perform GEMM
  C = alpha * A * B + beta * C;  

  // Check Eigen result against cuBLAS
  if(cublas_param->data_order == QUDA_CUBLAS_DATAORDER_COL) {
    diffEigenArrayColMaj(C, C_ptr, ldc, m);
  }
  else {
    diffEigenArrayRowMaj(C, C_ptr, ldc, m);
  }
  printfQuda("(C_host - C_gpu) Frobenius norm = %e. Relative deviation = %e\n", C.norm(), C.norm()/(C.rows() * C.cols()));
}

void display_test_info()
{
  printfQuda("running the following test:\n");

  printfQuda("prec    sloppy_prec\n");
  printfQuda("%s   %s\n", get_prec_str(prec), get_prec_str(prec_sloppy));
  
  printfQuda("cuBLAS interface test\n");
  printfQuda("Grid partition info:     X  Y  Z  T\n");
  printfQuda("                         %d  %d  %d  %d\n", dimPartitioned(0), dimPartitioned(1), dimPartitioned(2),
             dimPartitioned(3));
  return;
}

int main(int argc, char **argv)
{

  // QUDA initialise
  //-----------------------------------------------------------------------------
  // command line options
  auto app = make_app();
  try {
    app->parse(argc, argv);
  } catch (const CLI::ParseError &e) {
    return app->exit(e);
  }

  // initialize QMP/MPI, QUDA comms grid and RNG (host_utils.cpp)
  initComms(argc, argv, gridsize_from_cmdline);

  // call srand() with a rank-dependent seed
  initRand();
  setQudaPrecisions();    
  display_test_info();

  // initialize the QUDA library
  initQuda(device);
  //-----------------------------------------------------------------------------

  QudaCublasParam cublas_param = newQudaCublasParam();
  cublas_param.trans_a = cublas_trans_a;
  cublas_param.trans_b = cublas_trans_b;
  cublas_param.m = cublas_mnk[0];
  cublas_param.n = cublas_mnk[1];
  cublas_param.k = cublas_mnk[2];
  cublas_param.lda = cublas_leading_dims[0];
  cublas_param.ldb = cublas_leading_dims[1];
  cublas_param.ldc = cublas_leading_dims[2];
  cublas_param.alpha = (__complex__ double)cublas_alpha_re_im[0];  
  cublas_param.beta  = (__complex__ double)cublas_beta_re_im[0];
  cublas_param.data_order = cublas_data_order;
  cublas_param.data_type = cublas_data_type;

  // Testing for batch not yet supported.
  cublas_param.batch_count = cublas_batch;
  
  uint64_t refA_size = cublas_param.m * cublas_param.lda; //A_mk
  uint64_t refB_size = cublas_param.n * cublas_param.ldb; //B_kn
  uint64_t refC_size = cublas_param.n * cublas_param.ldc; //C_mn

  // Reference data is always in complex double
  size_t data_size = 2 * sizeof(double);
  
  void *refA = malloc(refA_size * data_size);
  void *refB = malloc(refB_size * data_size);
  void *refC = malloc(refC_size * data_size);
  void *refCcopy = malloc(refC_size * data_size);

  // Populate the real part with rands
  for (uint64_t i = 0; i < 2 * refA_size; i+=2) {
    ((double *)refA)[i] = rand() / (double)RAND_MAX;
  }
  for (uint64_t i = 0; i < 2 * refB_size; i+=2) {
    ((double *)refB)[i] = rand() / (double)RAND_MAX;
  }
  for (uint64_t i = 0; i < 2 * refC_size; i+=2) {
    ((double *)refC)[i] = rand() / (double)RAND_MAX;
    ((double *)refCcopy)[i] = ((double *)refC)[i];
  }

  // Populate the imaginary part with rands or zeros
  if (cublas_param.data_type == QUDA_CUBLAS_DATATYPE_S || cublas_param.data_type == QUDA_CUBLAS_DATATYPE_D) {
    for (uint64_t i = 1; i < 2 * refA_size; i+=2) {
      ((double *)refA)[i] = 0.0;
    }
    for (uint64_t i = 1; i < 2 * refB_size; i+=2) {
      ((double *)refB)[i] = 0.0;
    }
    for (uint64_t i = 1; i < 2 * refC_size; i+=2) {
      ((double *)refC)[i] = 0.0;
      ((double *)refCcopy)[i] = ((double *)refC)[i];
    }
  } else {
    for (uint64_t i = 1; i < 2 * refA_size; i+=2) {
      ((double *)refA)[i] = rand() / (double)RAND_MAX;
    }
    for (uint64_t i = 1; i < 2 * refB_size; i+=2) {
      ((double *)refB)[i] = rand() / (double)RAND_MAX;
    }
    for (uint64_t i = 1; i < 2 * refC_size; i+=2) {
      ((double *)refC)[i] = rand() / (double)RAND_MAX;
      ((double *)refCcopy)[i] = ((double *)refC)[i];
    }    
  }

  void *arrayA;
  void *arrayB;
  void *arrayC;
  void *arrayCcopy;

  // Create new arrays appropriate for the requested problem, and copy the data.
  switch (cublas_param.data_type) {
  case QUDA_CUBLAS_DATATYPE_S :
    arrayA = malloc(refA_size * sizeof(float));
    arrayB = malloc(refB_size * sizeof(float));
    arrayC = malloc(refC_size * sizeof(float));
    arrayCcopy = malloc(refC_size * sizeof(float));
    // Populate 
    for (uint64_t i = 0; i < 2 * refA_size; i+=2) {
      ((float *)arrayA)[i/2] = ((double *)refA)[i]; 
    }
    for (uint64_t i = 0; i < 2 * refB_size; i+=2) {
      ((float *)arrayB)[i/2] = ((double *)refB)[i]; 
    }
    for (uint64_t i = 0; i < 2 * refC_size; i+=2) {
      ((float *)arrayC)[i/2] = ((double *)refC)[i];
      ((float *)arrayCcopy)[i/2] = ((double *)refC)[i]; 
    }
    break;
  case QUDA_CUBLAS_DATATYPE_D :
    arrayA = malloc(refA_size * sizeof(double));
    arrayB = malloc(refB_size * sizeof(double));
    arrayC = malloc(refC_size * sizeof(double));
    arrayCcopy = malloc(refC_size * sizeof(double));
    // Populate 
    for (uint64_t i = 0; i < 2 * refA_size; i+=2) {
      ((double *)arrayA)[i/2] = ((double *)refA)[i]; 
    }
    for (uint64_t i = 0; i < 2 * refB_size; i+=2) {
      ((double *)arrayB)[i/2] = ((double *)refB)[i]; 
    }
    for (uint64_t i = 0; i < 2 * refC_size; i+=2) {
      ((double *)arrayC)[i/2] = ((double *)refC)[i];
      ((double *)arrayCcopy)[i/2] = ((double *)refC)[i]; 
    }
    break;
  case QUDA_CUBLAS_DATATYPE_C :
    arrayA = malloc(refA_size * 2 * sizeof(float));
    arrayB = malloc(refB_size * 2 * sizeof(float));
    arrayC = malloc(refC_size * 2 * sizeof(float));
    arrayCcopy = malloc(refC_size * 2 * sizeof(float));
    // Populate 
    for (uint64_t i = 0; i < 2 * refA_size; i++) {
      ((float *)arrayA)[i] = ((double *)refA)[i]; 
    }
    for (uint64_t i = 0; i < 2 * refB_size; i++) {
      ((float *)arrayB)[i] = ((double *)refB)[i]; 
    }
    for (uint64_t i = 0; i < 2 * refC_size; i++) {
      ((float *)arrayC)[i] = ((double *)refC)[i];
      ((float *)arrayCcopy)[i] = ((double *)refC)[i]; 
    }
    break;
  case QUDA_CUBLAS_DATATYPE_Z :
    arrayA = malloc(refA_size * 2 * sizeof(double));
    arrayB = malloc(refB_size * 2 * sizeof(double));
    arrayC = malloc(refC_size * 2 * sizeof(double));
    arrayCcopy = malloc(refC_size * 2 * sizeof(double));
    // Populate 
    for (uint64_t i = 0; i < 2 * refA_size; i++) {
      ((double *)arrayA)[i] = ((double *)refA)[i]; 
    }
    for (uint64_t i = 0; i < 2 * refB_size; i++) {
      ((double *)arrayB)[i] = ((double *)refB)[i]; 
    }
    for (uint64_t i = 0; i < 2 * refC_size; i++) {
      ((double *)arrayC)[i] = ((double *)refC)[i];
      ((double *)arrayCcopy)[i] = ((double *)refC)[i]; 
    }
    break;
  default :
    errorQuda("Unrecognised data type %d\n", cublas_param.data_type);
  }
  
  // Perform GPU GEMM Blas operation
  cublasGEMMQuda(arrayA, arrayB, arrayC, &cublas_param);
  
  if(verify_results) {

    // Copy data from problem sized array to reference sized array.
    void *checkA = malloc(refA_size * data_size);
    void *checkB = malloc(refB_size * data_size);
    void *checkC = malloc(refC_size * data_size);
    void *checkCcopy = malloc(refC_size * data_size);

    memset(checkA, 0, refA_size * data_size);
    memset(checkB, 0, refB_size * data_size);
    memset(checkC, 0, refC_size * data_size);
    memset(checkCcopy, 0, refC_size * data_size);
    
    switch (cublas_param.data_type) {
    case QUDA_CUBLAS_DATATYPE_S :
      for (uint64_t i = 0; i < 2 * refA_size; i+=2) {
	((double *)checkA)[i] = ((float *)arrayA)[i/2]; 
      }
      for (uint64_t i = 0; i < 2 * refB_size; i+=2) {
	((double *)checkB)[i] = ((float *)arrayB)[i/2]; 
      }
      for (uint64_t i = 0; i < 2 * refC_size; i+=2) {
	((double *)checkC)[i] = ((float *)arrayC)[i/2]; 
	((double *)checkCcopy)[i] = ((float *)arrayCcopy)[i/2]; 
      }
      break;      
    case QUDA_CUBLAS_DATATYPE_D :
      for (uint64_t i = 0; i < 2 * refA_size; i+=2) {
	((double *)checkA)[i] = ((double *)arrayA)[i/2]; 
      }
      for (uint64_t i = 0; i < 2 * refB_size; i+=2) {
	((double *)checkB)[i] = ((double *)arrayB)[i/2]; 
      }
      for (uint64_t i = 0; i < 2 * refC_size; i+=2) {
	((double *)checkC)[i] = ((double *)arrayC)[i/2]; 
	((double *)checkCcopy)[i] = ((double *)arrayCcopy)[i/2]; 
      }
      break;      
    case QUDA_CUBLAS_DATATYPE_C :
      for (uint64_t i = 0; i < 2 * refA_size; i++) {
	((double *)checkA)[i] = ((float *)arrayA)[i]; 
      }
      for (uint64_t i = 0; i < 2 * refB_size; i++) {
	((double *)checkB)[i] = ((float *)arrayB)[i]; 
      }
      for (uint64_t i = 0; i < 2 * refC_size; i++) {
	((double *)checkC)[i] = ((float *)arrayC)[i];
	((double *)checkCcopy)[i] = ((float *)arrayCcopy)[i]; 
      }
      break;
    case QUDA_CUBLAS_DATATYPE_Z :
      for (uint64_t i = 0; i < 2 * refA_size; i++) {
	((double *)checkA)[i] = ((double *)arrayA)[i]; 
      }
      for (uint64_t i = 0; i < 2 * refB_size; i++) {
	((double *)checkB)[i] = ((double *)arrayB)[i]; 
      }
      for (uint64_t i = 0; i < 2 * refC_size; i++) {
	((double *)checkC)[i] = ((double *)arrayC)[i];
	((double *)checkCcopy)[i] = ((double *)arrayCcopy)[i]; 
      }
      break;
    default :
      errorQuda("Unrecognised data type %d\n", cublas_param.data_type);
    }
    
    cublasGEMMQudaVerify(checkA, checkB, checkCcopy, checkC, &cublas_param);
    
    free(checkA);
    free(checkB);
    free(checkC);
    free(checkCcopy);
  }

  free(refA);
  free(refB);
  free(refC);
  free(refCcopy);
  
  free(arrayA);
  free(arrayB);
  free(arrayC);
  free(arrayCcopy);

  // finalize the QUDA library
  endQuda();

  // finalize the communications layer
  finalizeComms();

  return 0;
}