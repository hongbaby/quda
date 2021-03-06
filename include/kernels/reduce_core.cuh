#pragma once

#include <color_spinor_field_order.h>
#include <blas_helper.cuh>
#include <cub_helper.cuh>

namespace quda
{

  namespace blas
  {

    template <typename store_t, int N, typename y_store_t, int Ny, typename Reducer_>
    struct ReductionArg : public ReduceArg<typename Reducer_::reduce_t> {
      using Reducer = Reducer_;
      Spinor<store_t, N> X;
      Spinor<y_store_t, Ny> Y;
      Spinor<store_t, N> Z;
      Spinor<store_t, N> W;
      Spinor<y_store_t, Ny> V;
      Reducer r;

      const int length;
      const int nParity;
      ReductionArg(ColorSpinorField &x, ColorSpinorField &y, ColorSpinorField &z, ColorSpinorField &w,
                   ColorSpinorField &v, Reducer r, int length, int nParity) :
        X(x),
        Y(y),
        Z(z),
        W(w),
        V(v),
        r(r),
        length(length),
        nParity(nParity)
      { ; }
    };

    /**
       Generic reduction kernel with up to four loads and three saves.
    */
    template <int block_size, typename real, int n, typename Arg>
    __global__ void reduceKernel(Arg arg)
    {
      // n is real numbers per thread
      using vec = vector_type<complex<real>, n/2>;
      unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
      unsigned int parity = blockIdx.y;
      unsigned int gridSize = gridDim.x * blockDim.x;

      using reduce_t = typename Arg::Reducer::reduce_t;
      reduce_t sum;
      ::quda::zero(sum);

      while (i < arg.length) {
        vec x, y, z, w, v;
        arg.X.load(x, i, parity);
        arg.Y.load(y, i, parity);
        arg.Z.load(z, i, parity);
        arg.W.load(w, i, parity);
        arg.V.load(v, i, parity);

        arg.r.pre();
        arg.r(sum, x, y, z, w, v);
        arg.r.post(sum);

        if (arg.r.write.X) arg.X.save(x, i, parity);
        if (arg.r.write.Y) arg.Y.save(y, i, parity);
        if (arg.r.write.Z) arg.Z.save(z, i, parity);
        if (arg.r.write.W) arg.W.save(w, i, parity);
        if (arg.r.write.V) arg.V.save(v, i, parity);

        i += gridSize;
      }

      ::quda::reduce<block_size, reduce_t>(arg, sum, parity);
    }

    /**
       Generic reduction kernel with up to four loads and three saves.
    */
    template <typename real, int n, typename Arg> auto reduceCPU(Arg &arg)
    {
      // n is real numbers per thread
      using vec = vector_type<complex<real>, n/2>;

      using reduce_t = typename Arg::Reducer::reduce_t;
      reduce_t sum;
      ::quda::zero(sum);

      for (int parity = 0; parity < arg.nParity; parity++) {
        for (int i = 0; i < arg.length; i++) {
          vec x, y, z, w, v;
          arg.X.load(x, i, parity);
          arg.Y.load(y, i, parity);
          arg.Z.load(z, i, parity);
          arg.W.load(w, i, parity);
          arg.V.load(v, i, parity);

          arg.r.pre();
          arg.r(sum, x, y, z, w, v);
          arg.r.post(sum);

          if (arg.r.write.X) arg.X.save(x, i, parity);
          if (arg.r.write.Y) arg.Y.save(y, i, parity);
          if (arg.r.write.Z) arg.Z.save(z, i, parity);
          if (arg.r.write.W) arg.W.save(w, i, parity);
          if (arg.r.write.V) arg.V.save(v, i, parity);
        }
      }

      return sum;
    }

    /**
       Base class from which all reduction functors should derive.

       @tparam reduce_t The fundamental reduction type
       @tparam site_unroll Whether each thread must update the entire site
    */
    template <typename reduce_t_, bool site_unroll_ = false>
    struct ReduceFunctor {
      using reduce_t = reduce_t_;
      static constexpr bool site_unroll = site_unroll_;

      //! pre-computation routine called before the "M-loop"
      virtual __device__ __host__ void pre() { ; }

      //! post-computation routine called after the "M-loop"
      virtual __device__ __host__ void post(reduce_t &sum) { ; }
    };

    /**
       Return the L1 norm of x
    */
    template <typename reduce_t, typename T> __device__ __host__ reduce_t norm1_(const typename VectorType<T, 2>::type &a)
    {
      return static_cast<reduce_t>(sqrt(a.x * a.x + a.y * a.y));
    }

    template <typename reduce_t, typename real>
    struct Norm1 : public ReduceFunctor<reduce_t> {
      static constexpr write<> write{ };
      Norm1(const real &a, const real &b) { ; }
      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i=0; i < x.size(); i++) sum += norm1_<reduce_t, real>(x[i]);
      }
      constexpr int streams() const { return 1; } //! total number of input and output streams
      constexpr int flops() const { return 2; }   //! flops per element
    };

    /**
       Return the L2 norm of x
    */
    template <typename reduce_t, typename T> __device__ __host__ void norm2_(reduce_t &sum, const typename VectorType<T, 2>::type &a)
    {
      sum += static_cast<reduce_t>(a.x) * static_cast<reduce_t>(a.x);
      sum += static_cast<reduce_t>(a.y) * static_cast<reduce_t>(a.y);
    }

    template <typename reduce_t, typename real>
    struct Norm2 : public ReduceFunctor<reduce_t> {
      static constexpr write<> write{ };
      Norm2(const real &a, const real &b) { ; }
      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i = 0; i < x.size(); i++) norm2_<reduce_t,real>(sum, x[i]);
      }
      constexpr int streams() const { return 1; } //! total number of input and output streams
      constexpr int flops() const { return 2; }   //! flops per element
    };

    /**
       Return the real dot product of x and y
    */
    template <typename reduce_t, typename T>
    __device__ __host__ void dot_(reduce_t &sum, const typename VectorType<T, 2>::type &a, const typename VectorType<T, 2>::type &b)
    {
      sum += static_cast<reduce_t>(a.x) * static_cast<reduce_t>(b.x);
      sum += static_cast<reduce_t>(a.y) * static_cast<reduce_t>(b.y);
    }

    template <typename reduce_t, typename real>
    struct Dot : public ReduceFunctor<reduce_t> {
      static constexpr write<> write{ };
      Dot(const real &a, const real &b) { ; }
      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i = 0; i < x.size(); i++) dot_<reduce_t, real>(sum, x[i], y[i]);
      }
      constexpr int streams() const { return 2; } //! total number of input and output streams
      constexpr int flops() const { return 2; }   //! flops per element
    };

    /**
       First performs the operation z[i] = a*x[i] + b*y[i]
       Return the norm of y
    */
    template <typename reduce_t, typename real>
    struct axpbyzNorm2 : public ReduceFunctor<reduce_t> {
      static constexpr write<0, 0, 1> write{ };
      const real a;
      const real b;
      axpbyzNorm2(const real &a, const real &b) : a(a), b(b) { ; }
      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i = 0; i < x.size(); i++) {
          z[i] = a * x[i] + b * y[i];
          norm2_<reduce_t, real>(sum, z[i]);
        }
      }
      constexpr int streams() const { return 3; } //! total number of input and output streams
      constexpr int flops() const { return 4; }   //! flops per element
    };

    /**
       First performs the operation y[i] += a*x[i]
       Return real dot product (x,y)
    */
    template <typename reduce_t, typename real>
    struct AxpyReDot : public ReduceFunctor<reduce_t> {
      static constexpr write<0, 1> write{ };
      const real a;
      AxpyReDot(const real &a, const real &b) : a(a) { ; }
      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i = 0; i < x.size(); i++) {
          y[i] += a * x[i];
          dot_<reduce_t, real>(sum, x[i], y[i]);
        }
      }
      constexpr int streams() const { return 3; } //! total number of input and output streams
      constexpr int flops() const { return 4; }   //! flops per element
    };

    /**
       First performs the operation y[i] = a*x[i] + y[i] (complex-valued)
       Second returns the norm of y
    */
    template <typename reduce_t, typename real>
    struct caxpyNorm2 : public ReduceFunctor<reduce_t> {
      static constexpr write<0, 1> write{ };
      const complex<real> a;
      caxpyNorm2(const complex<real> &a, const complex<real> &b) : a(a) { ; }
      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i = 0; i < x.size(); i++) {
          y[i] = cmac(a, x[i], y[i]);
          norm2_<reduce_t, real>(sum, y[i]);
        }
      }
      constexpr int streams() const { return 3; } //! total number of input and output streams
      constexpr int flops() const { return 6; }   //! flops per element
    };

    /**
       double caxpyXmayNormCuda(float a, float *x, float *y, n){}
       First performs the operation y[i] = a*x[i] + y[i]
       Second performs the operator x[i] -= a*z[i]
       Third returns the norm of x
    */
    template <typename reduce_t, typename real>
    struct caxpyxmaznormx : public ReduceFunctor<reduce_t> {
      static constexpr write<1, 1> write{ };
      const complex<real> a;
      caxpyxmaznormx(const complex<real> &a, const complex<real> &b) : a(a) { ; }
      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i = 0; i < x.size(); i++) {
          y[i] = cmac(a, x[i], y[i]);
          x[i] = cmac(-a, z[i], x[i]);
          norm2_<reduce_t, real>(sum, x[i]);
        }
      }
      constexpr int streams() const { return 5; } //! total number of input and output streams
      constexpr int flops() const { return 10; }  //! flops per element
    };

    /**
       double cabxpyzAxNorm(float a, complex b, float *x, float *y, float *z){}
       First performs the operation z[i] = y[i] + a*b*x[i]
       Second performs x[i] *= a
       Third returns the norm of x
    */
    template <typename reduce_t, typename real>
    struct cabxpyzaxnorm : public ReduceFunctor<reduce_t> {
      static constexpr write<1, 0, 1> write{ };
      const real a;
      const complex<real> b;
      cabxpyzaxnorm(const complex<real> &a, const complex<real> &b) : a(a.real()), b(b) { ; }
      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i = 0; i < x.size(); i++) {
          x[i] *= a;
          z[i] = cmac(b, x[i], y[i]);
          norm2_<reduce_t, real>(sum, z[i]);
        }
      }
      constexpr int streams() const { return 4; } //! total number of input and output streams
      constexpr int flops() const { return 10; }  //! flops per element
    };

    /**
       Returns complex-valued dot product of x and y
    */
    template <typename reduce_t, typename T>
    __device__ __host__ void cdot_(reduce_t &sum, const typename VectorType<T, 2>::type &a, const typename VectorType<T, 2>::type &b)
    {
      using scalar = typename scalar<reduce_t>::type;
      sum.x += static_cast<scalar>(a.x) * static_cast<scalar>(b.x);
      sum.x += static_cast<scalar>(a.y) * static_cast<scalar>(b.y);
      sum.y += static_cast<scalar>(a.x) * static_cast<scalar>(b.y);
      sum.y -= static_cast<scalar>(a.y) * static_cast<scalar>(b.x);
    }

    template <typename real_reduce_t, typename real>
    struct Cdot : public ReduceFunctor<complex<real_reduce_t>> {
      using reduce_t = complex<real_reduce_t>;
      static constexpr write<> write{ };
      Cdot(const complex<real> &a, const complex<real> &b) { ; }
      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i = 0; i < x.size(); i++) cdot_<reduce_t, real>(sum, x[i], y[i]);
      }
      constexpr int streams() const { return 2; } //! total number of input and output streams
      constexpr int flops() const { return 4; }   //! flops per element
    };

    /**
       double caxpyDotzyCuda(float a, float *x, float *y, float *z, n){}
       First performs the operation y[i] = a*x[i] + y[i]
       Second returns the dot product (z,y)
    */
    template <typename real_reduce_t, typename real>
    struct caxpydotzy : public ReduceFunctor<complex<real_reduce_t>> {
      using reduce_t = complex<real_reduce_t>;
      static constexpr write<0, 1> write{ };
      const complex<real> a;
      caxpydotzy(const complex<real> &a, const complex<real> &b) : a(a) { ; }
      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i = 0; i < x.size(); i++) {
          y[i] = cmac(a, x[i], y[i]);
          cdot_<reduce_t, real>(sum, z[i], y[i]);
        }
      }
      constexpr int streams() const { return 4; } //! total number of input and output streams
      constexpr int flops() const { return 8; }   //! flops per element
    };

    /**
       First returns the dot product (x,y)
       Returns the norm of x
    */
    template <typename reduce_t, typename InputType>
    __device__ __host__ void cdotNormA_(reduce_t &sum, const InputType &a, const InputType &b)
    {
      using real = typename scalar<InputType>::type;
      using scalar = typename scalar<reduce_t>::type;
      cdot_<reduce_t, real>(sum, a, b);
      norm2_<scalar, real>(sum.z, a);
    }

    /**
       First returns the dot product (x,y)
       Returns the norm of y
    */
    template <typename reduce_t, typename InputType>
    __device__ __host__ void cdotNormB_(reduce_t &sum, const InputType &a, const InputType &b)
    {
      using real = typename scalar<InputType>::type;
      using scalar = typename scalar<reduce_t>::type;
      cdot_<reduce_t, real>(sum, a, b);
      norm2_<scalar, real>(sum.z, b);
    }

    template <typename real_reduce_t, typename real>
    struct CdotNormA : public ReduceFunctor<typename VectorType<real_reduce_t, 3>::type> {
      using reduce_t = typename VectorType<real_reduce_t, 3>::type;
      static constexpr write<> write{ };
      CdotNormA(const real &a, const real &b) { ; }
      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i = 0; i < x.size(); i++) cdotNormA_<reduce_t>(sum, x[i], y[i]);
      }
      constexpr int streams() const { return 2; } //! total number of input and output streams
      constexpr int flops() const { return 6; }   //! flops per element
    };

    /**
       This convoluted kernel does the following:
       y += a*x + b*z, z -= b*w, norm = (z,z), dot = (u, z)
    */
    template <typename real_reduce_t, typename real>
    struct caxpbypzYmbwcDotProductUYNormY_ : public ReduceFunctor<typename VectorType<real_reduce_t, 3>::type> {
      using reduce_t = typename VectorType<real_reduce_t, 3>::type;
      static constexpr write<0, 1, 1> write{ };
      const complex<real> a;
      const complex<real> b;
      caxpbypzYmbwcDotProductUYNormY_(const complex<real> &a, const complex<real> &b) : a(a), b(b) { ; }
      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i = 0; i < x.size(); i++) {
          y[i] = cmac(a, x[i], y[i]);
          y[i] = cmac(b, z[i], y[i]);
          z[i] = cmac(-b, w[i], z[i]);
          cdotNormB_<reduce_t>(sum, v[i], z[i]);
        }
      }
      constexpr int streams() const { return 7; } //! total number of input and output streams
      constexpr int flops() const { return 18; }  //! flops per element
    };

    /**
       Specialized kernel for the modified CG norm computation for
       computing beta.  Computes y = y + a*x and returns norm(y) and
       dot(y, delta(y)) where delta(y) is the difference between the
       input and out y vector.
    */
    template <typename real_reduce_t, typename real>
    struct axpyCGNorm2 : public ReduceFunctor<complex<real_reduce_t>> {
      using reduce_t = complex<real_reduce_t>;
      static constexpr write<0, 1> write{ };
      const real a;
      axpyCGNorm2(const real &a, const real &b) : a(a) { ; }
      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i = 0; i < x.size(); i++) {
          auto y_new = y[i] + a * x[i];
          norm2_<real_reduce_t, real>(sum.x, y_new);
          dot_<real_reduce_t, real>(sum.y, y_new, y_new - y[i]);
          y[i] = y_new;
        }
      }
      constexpr int streams() const { return 3; } //! total number of input and output streams
      constexpr int flops() const { return 6; }   //! flops per real element
    };

    /**
       This kernel returns (x, x) and (r,r) and also returns the
       so-called heavy quark norm as used by MILC: 1 / N * \sum_i (r,
       r)_i / (x, x)_i, where i is site index and N is the number of
       sites.  We must enforce that each thread updates an entire
       lattice hence the site_unroll template parameter must be set
       true.
    */
    template <typename real_reduce_t, typename real>
    struct HeavyQuarkResidualNorm_ : public ReduceFunctor<typename VectorType<real_reduce_t, 3>::type, true> {
      using reduce_t = typename VectorType<real_reduce_t, 3>::type;
      static constexpr write<> write{ };
      reduce_t aux;
      HeavyQuarkResidualNorm_(const real &a, const real &b) : aux {} { ; }

      __device__ __host__ void pre()
      {
        aux.x = 0;
        aux.y = 0;
      }

      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i = 0; i < x.size(); i++) {
          norm2_<real_reduce_t, real>(aux.x, x[i]);
          norm2_<real_reduce_t, real>(aux.y, y[i]);
        }
      }

      //! sum the solution and residual norms, and compute the heavy-quark norm
      __device__ __host__ void post(reduce_t &sum)
      {
        sum.x += aux.x;
        sum.y += aux.y;
        sum.z += (aux.x > 0.0) ? (aux.y / aux.x) : static_cast<real>(1.0);
      }

      constexpr int streams() const { return 2; } //! total number of input and output streams
      constexpr int flops() const { return 4; }   //! undercounts since it excludes the per-site division
    };

    /**
      Variant of the HeavyQuarkResidualNorm kernel: this takes three
      arguments, the first two are summed together to form the
      solution, with the third being the residual vector.  This
      removes the need an additional xpy call in the solvers,
      improving performance.  We must enforce that each thread updates
      an entire lattice hence the site_unroll template parameter must
      be set true.
    */
    template <typename real_reduce_t, typename real>
    struct xpyHeavyQuarkResidualNorm_ : public ReduceFunctor<typename VectorType<real_reduce_t, 3>::type, true> {
      using reduce_t = typename VectorType<real_reduce_t, 3>::type;
      static constexpr write<> write{ };
      reduce_t aux;
      xpyHeavyQuarkResidualNorm_(const real &a, const real &b) : aux {} { ; }

      __device__ __host__ void pre()
      {
        aux.x = 0;
        aux.y = 0;
      }

      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i = 0; i < x.size(); i++) {
          norm2_<real_reduce_t, real>(aux.x, x[i] + y[i]);
          norm2_<real_reduce_t, real>(aux.y, z[i]);
        }
      }

      //! sum the solution and residual norms, and compute the heavy-quark norm
      __device__ __host__ void post(reduce_t &sum)
      {
        sum.x += aux.x;
        sum.y += aux.y;
        sum.z += (aux.x > 0.0) ? (aux.y / aux.x) : static_cast<real>(1.0);
      }

      constexpr int streams() const { return 3; } //! total number of input and output streams
      constexpr int flops() const { return 5; }
    };

    /**
       double3 tripleCGReduction(V x, V y, V z){}
       First performs the operation norm2(x)
       Second performs the operatio norm2(y)
       Third performs the operation dotPropduct(y,z)
    */
    template <typename real_reduce_t, typename real>
    struct tripleCGReduction_ : public ReduceFunctor<typename VectorType<real_reduce_t, 3>::type> {
      using reduce_t = typename VectorType<real_reduce_t, 3>::type;
      static constexpr write<> write{ };
      using scalar = typename scalar<reduce_t>::type;
      tripleCGReduction_(const real &a, const real &b) { ; }
      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i = 0; i < x.size(); i++) {
          norm2_<real_reduce_t, real>(sum.x, x[i]);
          norm2_<real_reduce_t, real>(sum.y, y[i]);
          dot_<real_reduce_t, real>(sum.z, y[i], z[i]);
        }
      }
      constexpr int streams() const { return 3; } //! total number of input and output streams
      constexpr int flops() const { return 6; }   //! flops per element
    };

    /**
       double4 quadrupleCGReduction(V x, V y, V z){}
       First performs the operation norm2(x)
       Second performs the operatio norm2(y)
       Third performs the operation dotPropduct(y,z)
       Fourth performs the operation norm(z)
    */
    template <typename real_reduce_t, typename real>
    struct quadrupleCGReduction_ : public ReduceFunctor<typename VectorType<real_reduce_t, 4>::type> {
      using reduce_t = typename VectorType<real_reduce_t, 4>::type;
      static constexpr write<> write{ };
      quadrupleCGReduction_(const real &a, const real &b) { ; }
      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i = 0; i < x.size(); i++) {
          norm2_<real_reduce_t, real>(sum.x, x[i]);
          norm2_<real_reduce_t, real>(sum.y, y[i]);
          dot_<real_reduce_t, real>(sum.z, y[i], z[i]);
          norm2_<real_reduce_t, real>(sum.w, w[i]);
        }
      }
      constexpr int streams() const { return 3; } //! total number of input and output streams
      constexpr int flops() const { return 8; }   //! flops per element
    };

    /**
       double quadrupleCG3InitNorm(d a, d b, V x, V y, V z, V w, V v){}
        z = x;
        w = y;
        x += a*y;
        y -= a*v;
        norm2(y);
    */
    template <typename reduce_t, typename real>
    struct quadrupleCG3InitNorm_ : public ReduceFunctor<reduce_t> {
      static constexpr write<1, 1, 1, 1> write{ };
      const real a;
      quadrupleCG3InitNorm_(const real &a, const real &b) : a(a) { ; }
      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i = 0; i < x.size(); i++) {
          z[i] = x[i];
          w[i] = y[i];
          x[i] += a * y[i];
          y[i] -= a * v[i];
          norm2_<reduce_t, real>(sum, y[i]);
        }
      }
      constexpr int streams() const { return 6; } //! total number of input and output streams
      constexpr int flops() const { return 6; }   //! flops per element check if it's right
    };

    /**
       double quadrupleCG3UpdateNorm(d gamma, d rho, V x, V y, V z, V w, V v){}
        tmpx = x;
        tmpy = y;
        x = b*(x + a*y) + (1-b)*z;
        y = b*(y + a*v) + (1-b)*w;
        z = tmpx;
        w = tmpy;
        norm2(y);
    */
    template <typename reduce_t, typename real>
    struct quadrupleCG3UpdateNorm_ : public ReduceFunctor<reduce_t> {
      static constexpr write<1, 1, 1, 1> write{ };
      const real a;
      const real b;
      quadrupleCG3UpdateNorm_(const real &a, const real &b) : a(a), b(b) { ; }
      template <typename T> __device__ __host__ void operator()(reduce_t &sum, T &x, T &y, T &z, T &w, T &v)
      {
#pragma unroll
        for (int i = 0; i < x.size(); i++) {
          auto tmpx = x[i];
          auto tmpy = y[i];
          x[i] = b * (x[i] + a * y[i]) + ((real)1.0 - b) * z[i];
          y[i] = b * (y[i] - a * v[i]) + ((real)1.0 - b) * w[i];
          z[i] = tmpx;
          w[i] = tmpy;
          norm2_<reduce_t, real>(sum, y[i]);
        }
      }
      constexpr int streams() const { return 7; } //! total number of input and output streams
      constexpr int flops() const { return 16; }  //! flops per element check if it's right
    };

  } // namespace blas

} // namespace quda
