
#include <gauge_field.h>
#include <blas_cublas.h>
#include <blas_quda.h>
#include <tune_quda.h>

#include <jitify_helper.cuh>

#if ((__CUDACC_VER_MAJOR__ == 10 && __CUDACC_VER_MINOR__ >= 1) || (__CUDACC_VER_MAJOR__ > 10))                         \
  && (__COMPUTE_CAPABILITY__ >= 700)

#include <kernels/coarse_op_preconditioned_mma.cuh>

#endif

namespace quda
{

  namespace mma
  {

#if ((__CUDACC_VER_MAJOR__ == 10 && __CUDACC_VER_MINOR__ >= 1) || (__CUDACC_VER_MAJOR__ > 10))                         \
  && (__COMPUTE_CAPABILITY__ >= 700)

    template <typename F> inline void setMaxDynamicSharedBytesPerBlock(F *func)
    {
#if CUDA_VERSION >= 9000
      qudaFuncSetAttribute((const void *)func, cudaFuncAttributePreferredSharedMemoryCarveout,
                           (int)cudaSharedmemCarveoutMaxShared);
      cudaFuncAttributes attr;
      cudaFuncGetAttributes(&attr, (const void *)func);
      qudaFuncSetAttribute((const void *)func, cudaFuncAttributeMaxDynamicSharedMemorySize,
                           deviceProp.sharedMemPerBlockOptin - attr.sharedSizeBytes);
#endif
    }

    template <bool compute_max_only, int bM, int bN, int bK, int block_y, int block_z, int min_block_cta = 1, class Arg>
    void launch_kernel(Arg &arg, int min_threads, TuneParam &tp, const cudaStream_t &stream)
    {
      tp.block.x = 1;
      tp.block.y = block_y;
      tp.block.z = block_z;
      constexpr int shared_bytes = shared_memory_bytes(bM, bN, bK);
      tp.shared_bytes = shared_bytes;

      constexpr bool divide_b_no = bM < Arg::M && bK == Arg::K && bN == Arg::N;

      constexpr int t_m = divide_b_no ? 1 : Arg::M / bM;
      constexpr int t_n = divide_b_no ? 1 : Arg::N / bN;

      tp.grid = dim3(min_threads * t_m * t_n, 2, 4);

      auto kernel = mma::CalculateYhatGPU<compute_max_only, Arg, bM, bN, bK, block_y, block_z, min_block_cta>;
      setMaxDynamicSharedBytesPerBlock(kernel);
      kernel<<<tp.grid, tp.block, tp.shared_bytes, stream>>>(arg);
    }

    template <bool compute_max_only, class Arg>
    typename std::enable_if<Arg::N == 48, void>::type launch_yhat_kernel(Arg &arg, int min_threads, TuneParam &tp,
                                                                         const cudaStream_t &stream)
    {
      // clang-format off
      switch (tp.aux.x) {
      case   0: launch_kernel<compute_max_only,  48,  48,  48,  24,  12>(arg, min_threads, tp, stream); break;
      case   1: launch_kernel<compute_max_only,  48,  48,  48,   6,  48>(arg, min_threads, tp, stream); break;
      case   2: launch_kernel<compute_max_only,  48,  48,  48,  12,  24>(arg, min_threads, tp, stream); break;
      default: errorQuda("tp.aux.x(=%d) is NOT supported by N = 48", tp.aux.x);
      }
      // clang-format on
    }

    template <bool compute_max_only, class Arg>
    typename std::enable_if<Arg::N == 64, void>::type launch_yhat_kernel(Arg &arg, int min_threads, TuneParam &tp,
                                                                         const cudaStream_t &stream)
    {
      // clang-format off
      switch (tp.aux.x) {
      case   0: launch_kernel<compute_max_only,  64,  64,  16,  32,   8>(arg, min_threads, tp, stream); break;
      case   1: launch_kernel<compute_max_only,  64,  64,  16,  16,  16>(arg, min_threads, tp, stream); break;
      case   2: launch_kernel<compute_max_only,  64,  64,  16,  32,  16>(arg, min_threads, tp, stream); break;
      case   3: launch_kernel<compute_max_only,  64,  64,  32,  32,  16>(arg, min_threads, tp, stream); break;
      case   4: launch_kernel<compute_max_only,  64,  64,  64,   8,  64>(arg, min_threads, tp, stream); break;
      case   5: launch_kernel<compute_max_only,  64,  64,  64,  16,  32>(arg, min_threads, tp, stream); break;
      case   6: launch_kernel<compute_max_only,  64,  64,  64,  32,  16>(arg, min_threads, tp, stream); break;
      default: errorQuda("tp.aux.x(=%d) is NOT supported by N = 64", tp.aux.x);
      }
      // clang-format on
    }

    template <bool compute_max_only, class Arg>
    typename std::enable_if<Arg::N == 128, void>::type launch_yhat_kernel(Arg &arg, int min_threads, TuneParam &tp,
                                                                          const cudaStream_t &stream)
    {
      // clang-format off
      switch (tp.aux.x) {
      case   0: launch_kernel<compute_max_only,  64,  64,  16,  32,  16,  2>(arg, min_threads, tp, stream); break;
      case   1: launch_kernel<compute_max_only,  32, 128, 128,  16,  32    >(arg, min_threads, tp, stream); break;
      case   2: launch_kernel<compute_max_only, 128, 128,  16,  64,   8    >(arg, min_threads, tp, stream); break;
      case   3: launch_kernel<compute_max_only, 128, 128,  16,  32,  16    >(arg, min_threads, tp, stream); break;
      case   4: launch_kernel<compute_max_only, 128, 128,  32,  16,  32    >(arg, min_threads, tp, stream); break;
      case   5: launch_kernel<compute_max_only, 128, 128,  32,  64,   8    >(arg, min_threads, tp, stream); break;
      case   6: launch_kernel<compute_max_only, 128, 128,  32,  32,  16    >(arg, min_threads, tp, stream); break;
      case   7: launch_kernel<compute_max_only, 128, 128,  32,  32,  32    >(arg, min_threads, tp, stream); break;
      case   8: launch_kernel<compute_max_only, 128, 128,   8,  64,   8    >(arg, min_threads, tp, stream); break;
      default: errorQuda("tp.aux.x(=%d) is NOT supported by N = 128", tp.aux.x);
      }
      // clang-format on
    }

    template <bool compute_max_only, class Arg>
    typename std::enable_if<Arg::N == 192, void>::type launch_yhat_kernel(Arg &arg, int min_threads, TuneParam &tp,
                                                                          const cudaStream_t &stream)
    {
      // clang-format off
      switch (tp.aux.x) {
      case   0: launch_kernel<compute_max_only,  64,  64,  16,  32,  16,  2>(arg, min_threads, tp, stream); break;
      case   1: launch_kernel<compute_max_only,  64,  64,  32,   8,  32    >(arg, min_threads, tp, stream); break;
      case   2: launch_kernel<compute_max_only,  64,  64,  32,  32,   8    >(arg, min_threads, tp, stream); break;
      case   3: launch_kernel<compute_max_only,  64,  64,  32,  16,  16    >(arg, min_threads, tp, stream); break;
      case   4: launch_kernel<compute_max_only,  64,  64,  32,  32,  16    >(arg, min_threads, tp, stream); break;
      default: errorQuda("tp.aux.x(=%d) is NOT supported by N = 192", tp.aux.x);
      }
      // clang-format on
    }

    template <typename Arg> class CalculateYhat : public Tunable
    {

      using Float = typename Arg::Float;
      Arg &arg;
      const LatticeField &meta;
      const int n;

      bool compute_max_only;

      long long flops() const
      {
        return 2l * arg.Y.VolumeCB() * 8 * n * n * (8 * n - 2);
      } // 8 from dir, 8 from complexity

      long long bytes() const { return arg.Y.VolumeCB() * 2l * n * n * 2l * (compute_max_only ? 2 : 3); }

      unsigned int minThreads() const { return arg.Y.VolumeCB(); }
      bool tuneGridDim() const { return false; } // don't tune the grid dimension

      int blockMin() const { return 1; }
      int blockStep() const { return 1; }
      unsigned int maxBlockSize(const TuneParam &param) const { return 1u; }

      bool advanceBlockDim(TuneParam &param) const { return false; }

    public:
      CalculateYhat(Arg &arg, const LatticeField &meta) : arg(arg), meta(meta), n(arg.M), compute_max_only(false)
      {
        if (meta.Location() == QUDA_CUDA_FIELD_LOCATION) {
#ifdef JITIFY
          create_jitify_program("kernels/coarse_op_preconditioned.cuh");
#endif
          arg.max_d = static_cast<Float *>(pool_device_malloc(sizeof(Float)));
        }
        arg.max_h = static_cast<Float *>(pool_pinned_malloc(sizeof(Float)));
        strcpy(aux, compile_type_str(meta));
        strcat(aux, comm_dim_partitioned_string());
      }

      virtual ~CalculateYhat()
      {
        if (meta.Location() == QUDA_CUDA_FIELD_LOCATION) { pool_device_free(arg.max_d); }
        pool_pinned_free(arg.max_h);
      }

      /**
        @brief Launcher for GPU instantiations of preconditioned coarse-link construction
       */
      void launch(TuneParam &tp, const cudaStream_t &stream)
      {
        if (compute_max_only) {
          if (!activeTuning()) { qudaMemsetAsync(arg.max_d, 0, sizeof(typename Arg::Float), stream); }
        }

#ifdef JITIFY
        using namespace jitify::reflection;
        jitify_error = program->kernel("quda::CalculateYhatGPU")
                         .instantiate(compute_max_only, Type<Arg>())
                         .configure(tp.grid, tp.block, tp.shared_bytes, stream)
                         .launch(arg);
#else
        if (compute_max_only) {
          launch_yhat_kernel<true>(arg, minThreads(), tp, stream);
        } else {
          launch_yhat_kernel<false>(arg, minThreads(), tp, stream);
        }
#endif
        if (compute_max_only) {
          if (!activeTuning()) { // only do copy once tuning is done
            qudaMemcpyAsync(arg.max_h, arg.max_d, sizeof(typename Arg::Float), cudaMemcpyDeviceToHost, stream);
            qudaStreamSynchronize(const_cast<cudaStream_t &>(stream));
          }
        }
      }

      void apply(const cudaStream_t &stream)
      {
        TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());
        launch(tp, stream);
      }

      /**
         Set if we're doing a max-only compute (fixed point only)
      */
      void setComputeMaxOnly(bool compute_max_only_) { compute_max_only = compute_max_only_; }

      virtual bool tuneSharedBytes() const { return false; }
      virtual bool tuneAuxDim() const { return true; }
      virtual bool advanceAux(TuneParam &param) const
      {
        int max_aux;
        // clang-format off
        switch (arg.M) {
        case  48: max_aux = 2; break;
        case  64: max_aux = 6; break;
        case 128: max_aux = 8; break;
        case 192: max_aux = 4; break;
        default: errorQuda("Unsupported number of coarse dof %d\n", arg.M);
        }
        // clang-format on

        if (param.aux.x < max_aux) {
          param.aux.x++;
          return true;
        }
        return false;
      }

      unsigned int sharedBytesPerBlock(const TuneParam &param) const
      {
        return n * (n + 4) * 2 * sizeof(half) * 2 * param.block.x;
      }

      unsigned int sharedBytesPerThread() const { return 0; }

      void initTuneParam(TuneParam &param) const
      {
        // Tunable::initTuneParam(param);
        param.block = dim3(1, 1, 1); // Ls must be contained in the block
        param.grid = dim3(minThreads(), 2, 4);
        // param.shared_bytes = sharedBytesPerBlock(param);
        param.aux.x = 0;
      }

      void defaultTuneParam(TuneParam &param) const { initTuneParam(param); }

      TuneKey tuneKey() const
      {
        char Aux[TuneKey::aux_n];
        strcpy(Aux, aux);
        strcat(Aux, ",mma");
        strcat(Aux, accumulate_precision() == QUDA_SINGLE_PRECISION ? ",fp32_acc" : ",fp16_acc");
        if (compute_max_only) strcat(Aux, ",compute_max_only");
        if (meta.Location() == QUDA_CUDA_FIELD_LOCATION) {
          strcat(Aux, meta.MemType() == QUDA_MEMORY_MAPPED ? ",GPU-mapped" : ",GPU-device");
        }
        return TuneKey(meta.VolString(), typeid(*this).name(), Aux);
      }
    };

    /**
       @brief Calculate the preconditioned coarse-link field and the clover inverse.

       @param Yhat[out] Preconditioned coarse link field
       @param Xinv[out] Coarse clover inverse field
       @param Y[out] Coarse link field
       @param X[out] Coarse clover field
     */
    template <typename storeFloat, typename Float, int N, QudaGaugeFieldOrder gOrder>
    void calculateYhat(GaugeField &Yhat, GaugeField &Xinv, const GaugeField &Y, const GaugeField &X)
    {
      // invert the clover matrix field
      const int n = X.Ncolor();
      if (X.Location() == QUDA_CUDA_FIELD_LOCATION && X.Order() == QUDA_FLOAT2_GAUGE_ORDER) {
        GaugeFieldParam param(X);
        // need to copy into AoS format for CUBLAS
        param.order = QUDA_MILC_GAUGE_ORDER;
        param.setPrecision(X.Precision() < QUDA_SINGLE_PRECISION ? QUDA_SINGLE_PRECISION : X.Precision());
        cudaGaugeField X_(param);
        cudaGaugeField Xinv_(param);
        X_.copy(X);
        blas::flops += cublas::BatchInvertMatrix((void *)Xinv_.Gauge_p(), (void *)X_.Gauge_p(), n, X_.Volume(),
                                                 X_.Precision(), X.Location());

        if (Xinv.Precision() < QUDA_SINGLE_PRECISION) Xinv.Scale(Xinv_.abs_max());

        Xinv.copy(Xinv_);

      } else if (X.Location() == QUDA_CUDA_FIELD_LOCATION && X.Order() == QUDA_MILC_GAUGE_ORDER) {
        blas::flops += cublas::BatchInvertMatrix((void *)Xinv.Gauge_p(), (void *)X.Gauge_p(), n, X.Volume(),
                                                 X.Precision(), X.Location());
      } else {
        errorQuda("Unsupported location=%d and order=%d", X.Location(), X.Order());
      }

      // now exchange Y halos of both forwards and backwards links for multi-process dslash
      const_cast<GaugeField &>(Y).exchangeGhost(QUDA_LINK_BIDIRECTIONAL);

      // compute the preconditioned links
      // Yhat_back(x-\mu) = Y_back(x-\mu) * Xinv^dagger(x) (positive projector)
      // Yhat_fwd(x) = Xinv(x) * Y_fwd(x)                  (negative projector)
      {
        int xc_size[5];
        for (int i = 0; i < 4; i++) xc_size[i] = X.X()[i];
        xc_size[4] = 1;

        // XXX: Change gauge field order
        GaugeFieldParam param_Y(Y);
        GaugeFieldParam param_Yhat(Yhat);
        GaugeFieldParam param_Xinv(Xinv);

        constexpr QudaGaugeFieldOrder gOrder_milc = QUDA_MILC_GAUGE_ORDER;

        param_Y.order = gOrder_milc;
        param_Yhat.order = gOrder_milc;
        param_Xinv.order = gOrder_milc;

        // need to copy into AoS format for CUBLAS
        param_Y.setPrecision(X.Precision());
        param_Yhat.setPrecision(X.Precision());
        param_Xinv.setPrecision(X.Precision());

        cudaGaugeField Y_(param_Y);
        cudaGaugeField Yhat_(param_Yhat);
        cudaGaugeField Xinv_(param_Xinv);

        Xinv_.copy(Xinv);
        Y_.copy(Y);

        constexpr bool use_native_ghosts = true;
        // use spin-ignorant accessor to make multiplication simpler
        typedef typename gauge::FieldOrder<Float, N, 1, gOrder_milc, use_native_ghosts, storeFloat> gCoarse;
        typedef typename gauge::FieldOrder<Float, N, 1, gOrder_milc, use_native_ghosts, storeFloat> gPreconditionedCoarse;
        gCoarse yAccessor(Y_);
        gPreconditionedCoarse yHatAccessor(Yhat_);
        gCoarse xInvAccessor(Xinv_);
        if (getVerbosity() >= QUDA_VERBOSE) printfQuda("Xinv = %e\n", Xinv_.norm2(0));

        int comm_dim[4];
        for (int i = 0; i < 4; i++) comm_dim[i] = comm_dim_partitioned(i);

        using yHatArg = quda::mma::CalculateYhatArg<Float, gPreconditionedCoarse, gCoarse, N>;
        yHatArg arg(yHatAccessor, yAccessor, xInvAccessor, xc_size, comm_dim, 1);

        CalculateYhat<yHatArg> yHat(arg, Y_);
        if (Yhat.Precision() == QUDA_HALF_PRECISION || Yhat.Precision() == QUDA_QUARTER_PRECISION) {
          yHat.setComputeMaxOnly(true);
          yHat.apply(0);

          double max_h_double = *arg.max_h;
          comm_allreduce_max(&max_h_double);
          *arg.max_h = static_cast<Float>(max_h_double);

          if (getVerbosity() >= QUDA_VERBOSE) printfQuda("Yhat Max = %e\n", *arg.max_h);

          Yhat_.Scale(*arg.max_h);
          arg.Yhat.resetScale(*arg.max_h);
        }
        yHat.setComputeMaxOnly(false);
        yHat.apply(0);

        Yhat.copy(Yhat_);

        // XXX: END Changing gauge field

        if (getVerbosity() >= QUDA_VERBOSE)
          for (int d = 0; d < 8; d++)
            printfQuda("Yhat[%d] = %e (%e %e = %e x %e)\n", d, Yhat.norm2(d), Yhat.abs_max(d),
                       Y.abs_max(d) * Xinv.abs_max(0), Y.abs_max(d), Xinv.abs_max(0));
      }

      // fill back in the bulk of Yhat so that the backward link is updated on the previous node
      // need to put this in the bulk of the previous node - but only send backwards the backwards
      // links to and not overwrite the forwards bulk
      Yhat.injectGhost(QUDA_LINK_BACKWARDS);

      // exchange forwards links for multi-process dslash dagger
      // need to put this in the ghost zone of the next node - but only send forwards the forwards
      // links and not overwrite the backwards ghost
      Yhat.exchangeGhost(QUDA_LINK_FORWARDS);
    }

    template <typename storeFloat, typename Float, int N>
    void calculateYhat(GaugeField &Yhat, GaugeField &Xinv, const GaugeField &Y, const GaugeField &X)
    {
      if (Y.FieldOrder() == QUDA_FLOAT2_GAUGE_ORDER) {
        constexpr QudaGaugeFieldOrder gOrder = QUDA_FLOAT2_GAUGE_ORDER;
        calculateYhat<storeFloat, Float, N, gOrder>(Yhat, Xinv, Y, X);
      } else {
        errorQuda("Unsupported field order %d", Y.FieldOrder());
      }
    }

    // template on the number of coarse degrees of freedom
    template <typename storeFloat, typename Float>
    void calculateYhat(GaugeField &Yhat, GaugeField &Xinv, const GaugeField &Y, const GaugeField &X)
    {
      switch (Y.Ncolor()) {
      case 48: calculateYhat<storeFloat, Float, 48>(Yhat, Xinv, Y, X); break;
#ifdef NSPIN4
      // case 12: calculateYhat<storeFloat,Float,12>(Yhat, Xinv, Y, X); break;
      case 64: calculateYhat<storeFloat, Float, 64>(Yhat, Xinv, Y, X); break;
#endif // NSPIN4
#ifdef NSPIN1
      case 128: calculateYhat<storeFloat, Float, 128>(Yhat, Xinv, Y, X); break;
      case 192: calculateYhat<storeFloat, Float, 192>(Yhat, Xinv, Y, X); break;
#endif // NSPIN1
      default: errorQuda("Unsupported number of coarse dof %d\n", Y.Ncolor()); break;
      }
    }

#endif

    // Does the heavy lifting of creating the coarse color matrices Y
    void calculateYhat(GaugeField &Yhat, GaugeField &Xinv, const GaugeField &Y, const GaugeField &X)
    {

#if ((__CUDACC_VER_MAJOR__ == 10 && __CUDACC_VER_MINOR__ >= 1) || (__CUDACC_VER_MAJOR__ > 10))                         \
  && (__COMPUTE_CAPABILITY__ >= 700)

#ifdef GPU_MULTIGRID
      if (Y.Location() == QUDA_CPU_FIELD_LOCATION) errorQuda("Unsupported field location %d\n", Y.Location());

      QudaPrecision precision = checkPrecision(Xinv, Y, X);
      if (getVerbosity() >= QUDA_SUMMARIZE) printfQuda("Computing Yhat field......\n");

      if (precision == QUDA_DOUBLE_PRECISION) {
#ifdef GPU_MULTIGRID_DOUBLE
        if (Yhat.Precision() != QUDA_DOUBLE_PRECISION) errorQuda("Unsupported precision %d\n", Yhat.Precision());
        calculateYhat<double, double>(Yhat, Xinv, Y, X);
#else
        errorQuda("Double precision multigrid has not been enabled");
#endif
      } else if (precision == QUDA_SINGLE_PRECISION) {
#if 0
        if (Yhat.Precision() == QUDA_SINGLE_PRECISION) {
          calculateYhat<float, float>(Yhat, Xinv, Y, X);
        } else {
          errorQuda("Unsupported precision %d\n", precision);
        }
#endif
      } else if (precision == QUDA_HALF_PRECISION) {
        if (Yhat.Precision() == QUDA_HALF_PRECISION) {
          calculateYhat<short, float>(Yhat, Xinv, Y, X);
        } else {
          errorQuda("Unsupported precision %d\n", precision);
        }
      } else {
        errorQuda("Unsupported precision %d\n", precision);
      }

      if (getVerbosity() >= QUDA_SUMMARIZE) printfQuda("....done computing Yhat field\n");
#else
      errorQuda("Multigrid has not been built");
#endif

#else
      errorQuda("MMA multigrid is not available for this setup.");
#endif
    }

  } // namespace mma

} // namespace quda