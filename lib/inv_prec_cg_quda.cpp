#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <iostream>

#include <quda_internal.h>
#include <color_spinor_field.h>
#include <blas_quda.h>
#include <dslash_quda.h>
#include <invert_quda.h>
#include <util_quda.h>
#include <sys/time.h>
#include <face_quda.h>
#include <domain_decomposition.h>
#include <resize_quda.h>

// I need to add functionality to the conjugate-gradient solver.
// Should I do this by simple inheritance, or should I use a decorator? 
// Is it even possible to use a decorator?

namespace quda {

  // set the required parameters for the inner solver
  void fillInnerCGInvertParam(QudaInvertParam &inner, const QudaInvertParam &outer) {
    inner.tol = outer.tol_precondition;
    inner.maxiter = outer.maxiter_precondition;
    inner.reliable_delta = 1e-20; // no reliable updates within the inner solver

    inner.cuda_prec = outer.cuda_prec_precondition; // preconditioners are uni-precision solvers
    inner.cuda_prec_sloppy = outer.cuda_prec_precondition;

    inner.verbosity = outer.verbosity;

    inner.iter = 0;
    inner.gflops = 0;
    inner.secs = 0;

    inner.inv_type_precondition = QUDA_CG_INVERTER; // used to tell the inner solver it is an inner solver

    if (outer.inv_type == QUDA_CG_INVERTER && outer.cuda_prec_sloppy != outer.cuda_prec_precondition)
      inner.preserve_source = QUDA_PRESERVE_SOURCE_NO;
    else inner.preserve_source = QUDA_PRESERVE_SOURCE_YES; // What does this mean?

  } // copied from inv_gcr_quda.cpp



  PreconCG::PreconCG(const DiracMatrix &mat, const DiracMatrix &matSloppy, const DiracMatrix &matPrec, QudaInvertParam &invParam, TimeProfile &profile) :
    Solver(invParam, profile), mat(mat), matSloppy(matSloppy), matPrecon(matPrec), K(NULL)
  {
    Kparam = newQudaInvertParam();

    for(int dir=0; dir<4; ++dir) Kparam.domain_overlap[dir] = invParam.domain_overlap[dir];
    fillInnerCGInvertParam(Kparam, invParam);


    Kparam.dslash_type   = invParam.dslash_type;
    Kparam.inv_type      = invParam.inv_type;
    Kparam.solution_type = invParam.solution_type;
    Kparam.solve_type    = invParam.solve_type;
    Kparam.matpc_type    = invParam.matpc_type;
    Kparam.dirac_order   = invParam.dirac_order;


    Kparam.input_location  = invParam.input_location;
    Kparam.output_location = invParam.output_location;
    Kparam.mass = invParam.mass;
    Kparam.dagger = invParam.dagger;
    Kparam.mass_normalization = invParam.mass_normalization;
    Kparam.preserve_source = invParam.preserve_source;

    Kparam.cpu_prec = invParam.cpu_prec;
    Kparam.cuda_prec = invParam.cuda_prec_precondition;
    Kparam.cuda_prec_sloppy = invParam.cuda_prec_precondition;


    //K = new CG(matPrecon, matPrecon, Kparam, profile);
    K = new SimpleCG(matPrecon, Kparam, profile);
  }


  PreconCG::~PreconCG() {
    if (K) delete K;
  }

  void PreconCG::operator()(cudaColorSpinorField& x, cudaColorSpinorField &b)
  {
    printfQuda("Calling preconditioned solver\n");
    int k=0;
    int rUpdate;

    cudaColorSpinorField* minvrPre_ptr;
    cudaColorSpinorField* rPre_ptr;
    cudaColorSpinorField* minvr_ptr;
    cudaColorSpinorField* p_ptr;

    // Find the maximum domain overlap.
    // This will determine the number of faces needed by the vector r.
    // Have to be very careful to ensure that setting the number of 
    // ghost faces here doesn't screw anything up further down the line.
    int max_overlap = Kparam.domain_overlap[0];
    for(int dir=1; dir<4; ++dir){
      if(Kparam.domain_overlap[dir] > max_overlap){ 
        max_overlap = Kparam.domain_overlap[dir];
      }
    }


    int X[4]; // smaller sublattice dimensions
    int Y[4]; // extended subdomain dimensions
    X[0] = b.X(0)*2; // assume QUDA_PARITY_SITE_SUBSET
    X[1] = b.X(1);
    X[2] = b.X(2);
    X[3] = b.X(3);
    for(int dir=0; dir<4; ++dir) Y[dir] = X[dir] + 2*Kparam.domain_overlap[dir];


    printfQuda("Y = %d %d %d %d\n", Y[0], Y[1], Y[2], Y[3]);
    fflush(stdout);

    DecompParam dparam;
    initDecompParam(&dparam,X,Y);
    DecompParam param2;
    initDecompParam(&param2,X,X);
    int domain_overlap[4];
    for(int dir=0; dir<4; ++dir) domain_overlap[dir] = invParam.domain_overlap[dir];

    ColorSpinorParam param(b);
    param.nFace  = max_overlap;
    printfQuda("Here 0\n");
    printfQuda("param.nFace = %d\n", param.nFace);
    fflush(stdout);
    param.create = QUDA_COPY_FIELD_CREATE; 
    cudaColorSpinorField r(b,param);

    printfQuda("Here 1\n");
    fflush(stdout);


    Extender extendCuda(r); // function object used to implement overlapping domains

    param.nFace  = b.Nface();
    param.create = QUDA_ZERO_FIELD_CREATE;
    cudaColorSpinorField y(b,param);
    printfQuda("Here 2\n");
    fflush(stdout);
    if(K) minvr_ptr = new cudaColorSpinorField(b,param);
      
    printfQuda("Here 3\n");
    fflush(stdout);

    mat(r, x, y); // operator()(cudaColorSpinorField& out, cudaColorSpinorField& in,
    // => r = A*x;
    printfQuda("Here 4\n");
    fflush(stdout);

    double r2 = xmyNormCuda(b,r);
    rUpdate++;
    printfQuda("Here 5\n");
    fflush(stdout);

    param.precision = invParam.cuda_prec_sloppy;
    cudaColorSpinorField Ap(x,param);
    printfQuda("Here 6\n");
    fflush(stdout);
    cudaColorSpinorField tmp(x,param);
    printfQuda("Here 7\n");
    fflush(stdout);

    ColorSpinorParam prec_param(x);
    prec_param.create = QUDA_COPY_FIELD_CREATE;
    prec_param.precision = invParam.cuda_prec_precondition;

    if(K){
      prec_param.create     = QUDA_ZERO_FIELD_CREATE;
      prec_param.precision  = invParam.cuda_prec_precondition;
      prec_param.nColor     = 3;
      prec_param.nDim       = 4;
      prec_param.pad        = r.Pad(); // Not sure if this will cause a problem
      prec_param.nSpin      = 1;
      prec_param.siteSubset = QUDA_PARITY_SITE_SUBSET;
      prec_param.siteOrder  = QUDA_EVEN_ODD_SITE_ORDER;
      prec_param.fieldOrder = QUDA_FLOAT2_FIELD_ORDER;
      for(int dir=0; dir<4; ++dir) prec_param.x[dir] = Y[dir];
      prec_param.x[0] /= 2; // since QUDA_PARITY_SITE_SUBSET


      printfQuda("Here 8\n");
      fflush(stdout);
      rPre_ptr = new cudaColorSpinorField(prec_param);
      printfQuda("Here 9\n");
      fflush(stdout);
      // HACK!!!
      int domain_overlap[4];
      for(int dir=0; dir<4; ++dir) domain_overlap[dir] = invParam.domain_overlap[dir];

      if(max_overlap){
        extendCuda(*rPre_ptr,r,dparam,domain_overlap);
      }else{
        *rPre_ptr = r;
      }
      printfQuda("Here 10\n");
      fflush(stdout);
      // Create minvrPre_ptr 
      minvrPre_ptr = new cudaColorSpinorField(*rPre_ptr);
      printfQuda("Here 11\n");
      fflush(stdout);
      globalReduce = false;
      (*K)(*minvrPre_ptr, *rPre_ptr);  
      globalReduce = true;

      printfQuda("r.Precision() = %d, rPre_ptr->Precision() = %d\n", r.Precision(), rPre_ptr->Precision());
      fflush(stdout);
      if(max_overlap){
        cropCuda(*minvr_ptr, *minvrPre_ptr, dparam);
      }else{
        *minvr_ptr = *minvrPre_ptr;
      }

      p_ptr = new cudaColorSpinorField(*minvr_ptr);
    }else{
      printfQuda("Creating p_ptr\n");
      fflush(stdout);
      p_ptr = new cudaColorSpinorField(r);
    }



    double src_norm = norm2(b);
    double stop = src_norm*invParam.tol*invParam.tol; // stopping condition
    double alpha = 0.0, beta=0.0;
    double pAp;
    double rMinvr  = 0;
    double rMinvr_old = 0.0;
    double r_new_Minvr_old = 0.0;
    double r2_old = 0;
    r2 = norm2(r);

    if(K) rMinvr = reDotProductCuda(r,*minvr_ptr);

    while(r2 > stop && k < invParam.maxiter){
      mat(Ap, *p_ptr, tmp);
      pAp   = reDotProductCuda(*p_ptr,Ap);

      alpha = (K) ? rMinvr/pAp : r2/pAp;
      Complex cg_norm = axpyCGNormCuda(-alpha, Ap, r); 
      // r --> r - alpha*A*p

      if(K){
        rMinvr_old = rMinvr;
        r_new_Minvr_old = reDotProductCuda(r,*minvr_ptr);
        //  zeroCuda(*rPre_ptr);

        if(max_overlap){       
          extendCuda(*rPre_ptr,r,dparam,domain_overlap);
        }else{
          *rPre_ptr = r;
        }

        *minvrPre_ptr = *rPre_ptr;


        globalReduce = false;
        (*K)(*minvrPre_ptr, *rPre_ptr);
        globalReduce = true;

        if(max_overlap){
          cropCuda(*minvr_ptr, *minvrPre_ptr, dparam);
        }else{
          *minvr_ptr = *minvrPre_ptr;
        }
        rMinvr = reDotProductCuda(r,*minvr_ptr);

        beta = (rMinvr - r_new_Minvr_old)/rMinvr_old; 
        r2 = real(cg_norm);
        // x = x + alpha*p, p = Minvr + beta*p
        axpyZpbxCuda(alpha, *p_ptr, x, *minvr_ptr, beta);
      }else{
        r2_old = r2;
        r2 = real(cg_norm);

        beta = r2/r2_old;
        axpyZpbxCuda(alpha, *p_ptr, x, r, beta);
      }
      printfQuda("r2 = %e\n", r2);
      // update x and p
      // x = x + alpha*p
      // p = Minv_r + beta*p
      ++k;
    }
    printfQuda("Number of outer-solver iterations = %d\n",k);

    // compute the true residual 
    mat(r, x, y);
    double true_res = xmyNormCuda(b, r);
    invParam.true_res = sqrt(true_res / src_norm);
    printfQuda("true_res = %e\n", invParam.true_res);

    // FIX THIS!!
    if(K){ // These are only needed if preconditioning is used
      delete minvrPre_ptr;
      delete rPre_ptr;
      delete minvr_ptr;
    }
    delete p_ptr;

    return;
  }


} // namespace quda
