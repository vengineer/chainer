#include "xchainer/cuda/cuda_device.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

#include <cuda_runtime.h>

#include "xchainer/array.h"
#include "xchainer/cuda/cublas.h"
#include "xchainer/cuda/cuda_runtime.h"
#include "xchainer/cuda/reduce.cuh"
#include "xchainer/device.h"
#include "xchainer/dtype.h"
#include "xchainer/enum.h"
#include "xchainer/error.h"
#include "xchainer/indexable_array.h"
#include "xchainer/indexer.h"
#include "xchainer/native/native_device.h"
#include "xchainer/numeric_limits.h"
#include "xchainer/reduction_kernel_arg.h"
#include "xchainer/routines/creation.h"
#include "xchainer/scalar.h"
#include "xchainer/shape.h"

namespace xchainer {
namespace cuda {

namespace {

template <typename T>
__global__ void FillKernel(IndexableArray<T> out_iarray, T value, Indexer indexer) {
    for (int64_t i = blockIdx.x * blockDim.x + threadIdx.x; i < indexer.total_size(); i += blockDim.x * gridDim.x) {
        indexer.Set(i);
        out_iarray[indexer] = value;
    }
}

template <typename T>
__global__ void CopyKernel(IndexableArray<const T> a_iarray, IndexableArray<T> out_iarray, Indexer indexer) {
    for (int64_t i = blockIdx.x * blockDim.x + threadIdx.x; i < indexer.total_size(); i += blockDim.x * gridDim.x) {
        indexer.Set(i);
        out_iarray[indexer] = a_iarray[indexer];
    }
}

template <typename T>
__global__ void ArangeKernel(T start, T step, IndexableArray<T> out_iarray, Indexer indexer) {
    for (int64_t i = blockIdx.x * blockDim.x + threadIdx.x; i < indexer.total_size(); i += blockDim.x * gridDim.x) {
        indexer.Set(i);
        out_iarray[indexer] = start + step * i;
    }
}

template <typename InT, typename OutT>
__global__ void AstypeKernel(IndexableArray<const InT> a_iarray, IndexableArray<OutT> out_iarray, Indexer indexer) {
    for (int64_t i = blockIdx.x * blockDim.x + threadIdx.x; i < indexer.total_size(); i += blockDim.x * gridDim.x) {
        indexer.Set(i);
        out_iarray[indexer] = static_cast<OutT>(a_iarray[indexer]);
    }
}

template <typename T>
__global__ void EqualKernel(
        IndexableArray<const T> x1_iarray, IndexableArray<const T> x2_iarray, IndexableArray<bool> out_iarray, Indexer indexer) {
    const int64_t total_size = indexer.total_size();
    for (int64_t i = blockIdx.x * blockDim.x + threadIdx.x; i < total_size; i += blockDim.x * gridDim.x) {
        indexer.Set(i);
        out_iarray[indexer] = x1_iarray[indexer] == x2_iarray[indexer];
    }
}

template <typename T>
__global__ void AddKernel(
        IndexableArray<const T> x1_iarray, IndexableArray<const T> x2_iarray, IndexableArray<T> out_iarray, Indexer indexer) {
    const int64_t total_size = indexer.total_size();
    for (int64_t i = blockIdx.x * blockDim.x + threadIdx.x; i < total_size; i += blockDim.x * gridDim.x) {
        indexer.Set(i);
        out_iarray[indexer] = x1_iarray[indexer] + x2_iarray[indexer];
    }
}

template <typename T>
__global__ void SubtractKernel(
        IndexableArray<const T> x1_iarray, IndexableArray<const T> x2_iarray, IndexableArray<T> out_iarray, Indexer indexer) {
    const int64_t total_size = indexer.total_size();
    for (int64_t i = blockIdx.x * blockDim.x + threadIdx.x; i < total_size; i += blockDim.x * gridDim.x) {
        indexer.Set(i);
        out_iarray[indexer] = x1_iarray[indexer] - x2_iarray[indexer];
    }
}

template <typename T>
__global__ void MultiplyASKernel(IndexableArray<const T> x1_iarray, T x2_value, IndexableArray<T> out_iarray, Indexer indexer) {
    const int64_t total_size = indexer.total_size();
    for (int64_t i = blockIdx.x * blockDim.x + threadIdx.x; i < total_size; i += blockDim.x * gridDim.x) {
        indexer.Set(i);
        out_iarray[indexer] = x1_iarray[indexer] * x2_value;
    }
}

template <typename T>
__global__ void MultiplyKernel(
        IndexableArray<const T> x1_iarray, IndexableArray<const T> x2_iarray, IndexableArray<T> out_iarray, Indexer indexer) {
    const int64_t total_size = indexer.total_size();
    for (int64_t i = blockIdx.x * blockDim.x + threadIdx.x; i < total_size; i += blockDim.x * gridDim.x) {
        indexer.Set(i);
        out_iarray[indexer] = x1_iarray[indexer] * x2_iarray[indexer];
    }
}

template <typename T>
__global__ void DivideKernel(
        IndexableArray<const T> lhs_iarray, IndexableArray<const T> rhs_iarray, IndexableArray<T> out_iarray, Indexer indexer) {
    const int64_t total_size = indexer.total_size();
    for (int64_t i = blockIdx.x * blockDim.x + threadIdx.x; i < total_size; i += blockDim.x * gridDim.x) {
        indexer.Set(i);
        out_iarray[indexer] = lhs_iarray[indexer] / rhs_iarray[indexer];
    }
}

template <typename T>
__global__ void IfLessElseASSAKernel(
        IndexableArray<const T> x1_iarray,
        T x2_value,
        T pos_value,
        IndexableArray<const T> neg_iarray,
        IndexableArray<T> out_iarray,
        Indexer indexer) {
    const int64_t total_size = indexer.total_size();
    for (int64_t i = blockIdx.x * blockDim.x + threadIdx.x; i < total_size; i += blockDim.x * gridDim.x) {
        indexer.Set(i);
        out_iarray[indexer] = x1_iarray[indexer] < x2_value ? pos_value : neg_iarray[indexer];
    }
}

template <typename T>
__global__ void ExpKernel(IndexableArray<const T> x_iarray, IndexableArray<T> out_iarray, Indexer indexer) {
    const int64_t total_size = indexer.total_size();
    for (int64_t i = blockIdx.x * blockDim.x + threadIdx.x; i < total_size; i += blockDim.x * gridDim.x) {
        indexer.Set(i);
        out_iarray[indexer] = std::exp(x_iarray[indexer]);
    }
}

template <typename T>
__global__ void LogKernel(IndexableArray<const T> x_iarray, IndexableArray<T> out_iarray, Indexer indexer) {
    const int64_t total_size = indexer.total_size();
    for (int64_t i = blockIdx.x * blockDim.x + threadIdx.x; i < total_size; i += blockDim.x * gridDim.x) {
        indexer.Set(i);
        out_iarray[indexer] = std::log(x_iarray[indexer]);
    }
}

}  // namespace

std::shared_ptr<void> CudaDevice::Allocate(size_t bytesize) {
    if (bytesize == 0) {
        return nullptr;
    }
    CheckCudaError(cudaSetDevice(index()));
    void* raw_ptr = nullptr;
    // Be careful to be exception-safe, i.e.,
    // do not throw any exceptions before creating shared_ptr when memory allocation is succeeded
    cudaError_t status = cudaMallocManaged(&raw_ptr, bytesize, cudaMemAttachGlobal);
    if (status != cudaSuccess) {
        cuda::Throw(status);
    }
    return std::shared_ptr<void>{raw_ptr, cudaFree};
}

void CudaDevice::MemoryCopyFrom(void* dst, const void* src, size_t bytesize, Device& src_device) {
    assert(IsPointerCudaMemory(dst));
    if (&src_device == this || nullptr != dynamic_cast<CudaDevice*>(&src_device)) {
        // Copy between CUDA devices
        CheckCudaError(cudaMemcpy(dst, src, bytesize, cudaMemcpyDeviceToDevice));
    } else {
        assert(nullptr != dynamic_cast<native::NativeDevice*>(&src_device) &&
               "CudaDevice only supports copy between cuda or native devices.");
        // Copy from native device
        CheckCudaError(cudaMemcpy(dst, src, bytesize, cudaMemcpyHostToDevice));
    }
}

void CudaDevice::MemoryCopyTo(void* dst, const void* src, size_t bytesize, Device& dst_device) {
    assert(src == nullptr || IsPointerCudaMemory(src));
    if (&dst_device == this || nullptr != dynamic_cast<CudaDevice*>(&dst_device)) {
        // Copy between CUDA devices
        CheckCudaError(cudaMemcpy(dst, src, bytesize, cudaMemcpyDeviceToDevice));
    } else {
        assert(nullptr != dynamic_cast<native::NativeDevice*>(&dst_device) &&
               "CudaDevice only supports copy between cuda or native devices.");
        // Copy to native device
        CheckCudaError(cudaMemcpy(dst, src, bytesize, cudaMemcpyDeviceToHost));
    }
}

std::shared_ptr<void> CudaDevice::TransferDataFrom(
        Device& src_device, const std::shared_ptr<void>& src_ptr, size_t offset, size_t bytesize) {
    std::shared_ptr<void> dst_ptr = Allocate(bytesize);
    MemoryCopyFrom(dst_ptr.get(), &(static_cast<int8_t*>(src_ptr.get())[offset]), bytesize, src_device);
    return dst_ptr;
}

std::shared_ptr<void> CudaDevice::TransferDataTo(Device& dst_device, const std::shared_ptr<void>& src_ptr, size_t offset, size_t bytesize) {
    std::shared_ptr<void> dst_ptr = dst_device.Allocate(bytesize);
    MemoryCopyTo(dst_ptr.get(), &(static_cast<int8_t*>(src_ptr.get())[offset]), bytesize, dst_device);
    return dst_ptr;
}

std::shared_ptr<void> CudaDevice::FromHostMemory(const std::shared_ptr<void>& src_ptr, size_t bytesize) {
    std::shared_ptr<void> dst_ptr = Allocate(bytesize);
    CheckCudaError(cudaMemcpy(dst_ptr.get(), src_ptr.get(), bytesize, cudaMemcpyHostToDevice));
    return dst_ptr;
}

void CudaDevice::Fill(const Array& out, Scalar value) {
    CheckCudaError(cudaSetDevice(index()));
    VisitDtype(out.dtype(), [&](auto pt) {
        using T = typename decltype(pt)::type;
        static const int kMaxBlockSize = CudaOccupancyMaxPotentialBlockSize(&FillKernel<T>).block_size;

        IndexableArray<T> out_iarray{out};
        Indexer indexer{out.shape()};
        int64_t grid_size = (indexer.total_size() + kMaxBlockSize - 1) / kMaxBlockSize;
        int64_t block_size = std::min<int64_t>(indexer.total_size(), kMaxBlockSize);

        FillKernel<<<grid_size, block_size>>>(out_iarray, static_cast<T>(value), indexer);
    });
}

void CudaDevice::Arange(Scalar start, Scalar step, const Array& out) {
    CheckCudaError(cudaSetDevice(index()));
    VisitDtype(out.dtype(), [&](auto pt) {
        using T = typename decltype(pt)::type;
        static const int kMaxBlockSize = CudaOccupancyMaxPotentialBlockSize(&ArangeKernel<T>).block_size;

        IndexableArray<T> out_iarray{out};
        Indexer indexer{out.shape()};
        int64_t grid_size = (indexer.total_size() + kMaxBlockSize - 1) / kMaxBlockSize;
        int64_t block_size = std::min<int64_t>(indexer.total_size(), kMaxBlockSize);

        ArangeKernel<<<grid_size, block_size>>>(static_cast<T>(start), static_cast<T>(step), out_iarray, indexer);
    });
}

namespace {

template <typename T>
struct ArgMaxImpl {
    struct MaxAndArgMax {
        T max;
        int64_t argmax;
    };
    __device__ MaxAndArgMax Identity() { return {T{}, -1}; }
    __device__ MaxAndArgMax MapIn(T in, int64_t index) { return {in, index}; }
    __device__ void Reduce(MaxAndArgMax next, MaxAndArgMax& accum) {
        if (accum.argmax < 0 || accum.max < next.max) {
            accum = next;
        }
    }
    __device__ int64_t MapOut(MaxAndArgMax accum) { return accum.argmax; }
};

}  // namespace

void CudaDevice::ArgMax(const Array& a, const std::vector<int8_t>& axis, const Array& out) {
    CheckDevicesCompatible(a, out);
    CheckCudaError(cudaSetDevice(index()));
    VisitDtype(a.dtype(), [&](auto pt) {
        using T = typename decltype(pt)::type;
        Reduce(MakeReductionKernelArg<T, int64_t>(a, axis, out), ArgMaxImpl<T>{});
    });
}

namespace {

template <typename T>
struct SumImpl {
    __device__ T Identity() { return T{0}; }
    __device__ T MapIn(T in, int64_t /*index*/) { return in; }
    __device__ void Reduce(T next, T& accum) { accum += next; }
    __device__ T MapOut(T accum) { return accum; }
};

}  // namespace

void CudaDevice::Sum(const Array& a, const std::vector<int8_t>& axis, const Array& out) {
    assert(internal::IsValidReductionShape(a.shape(), axis, out.shape(), true));
    CheckDevicesCompatible(a, out);

    VisitDtype(out.dtype(), [&](auto pt) {
        using T = typename decltype(pt)::type;
        Reduce(MakeReductionKernelArg<T, T>(a, axis, out), SumImpl<T>{});
    });
}

namespace {
template <typename T>
struct AMaxImpl {
    __device__ T Identity() { return NumericLimits<T>::LowestOrInf(); }
    __device__ T MapIn(T in, int64_t /*index*/) { return in; }
    __device__ void Reduce(T next, T& accum) {
        if (accum < next) {
            accum = next;
        }
    }
    __device__ T MapOut(T accum) { return accum; }
};
}  // namespace

void CudaDevice::AMax(const Array& a, const std::vector<int8_t>& axis, const Array& out) {
    assert(internal::IsValidReductionShape(a.shape(), axis, out.shape(), true));
    CheckDevicesCompatible(a, out);

    VisitDtype(out.dtype(), [&](auto pt) {
        using T = typename decltype(pt)::type;
        Reduce(MakeReductionKernelArg<T, T>(a, axis, out), AMaxImpl<T>{});
    });
}

void CudaDevice::Copy(const Array& a, const Array& out) {
    CheckDevicesCompatible(a, out);
    CheckCudaError(cudaSetDevice(index()));
    VisitDtype(out.dtype(), [&](auto pt) {
        using T = typename decltype(pt)::type;
        static const int kMaxBlockSize = CudaOccupancyMaxPotentialBlockSize(&CopyKernel<T>).block_size;

        IndexableArray<const T> a_iarray{a};
        IndexableArray<T> out_iarray{out};
        Indexer indexer{out.shape()};

        int64_t total_size = indexer.total_size();
        int64_t grid_size = (total_size + kMaxBlockSize - 1) / kMaxBlockSize;
        int64_t block_size = std::min<int64_t>(total_size, kMaxBlockSize);

        CopyKernel<<<grid_size, block_size>>>(a_iarray, out_iarray, indexer);
    });
}

void CudaDevice::Astype(const Array& a, const Array& out) {
    CheckDevicesCompatible(a, out);
    CheckCudaError(cudaSetDevice(index()));

    auto do_astype = [&](auto in_pt, auto out_pt) {
       using InT = typename decltype(in_pt)::type;
       using OutT = typename decltype(out_pt)::type;
       static const int kMaxBlockSize = CudaOccupancyMaxPotentialBlockSize(&AstypeKernel<InT, OutT>).block_size;

       IndexableArray<const InT> a_iarray{a};
       IndexableArray<OutT> out_iarray{out};
       Indexer indexer{out.shape()};

       int64_t total_size = indexer.total_size();
       int64_t grid_size = (total_size + kMaxBlockSize - 1) / kMaxBlockSize;
       int64_t block_size = std::min<int64_t>(total_size, kMaxBlockSize);

       AstypeKernel<<<grid_size, block_size>>>(a_iarray, out_iarray, indexer);
    };

    VisitDtype(out.dtype(), [&](auto out_pt) {
        VisitDtype(a.dtype(), do_astype, out_pt);
    });
}

void CudaDevice::Equal(const Array& x1, const Array& x2, const Array& out) {
    CheckDevicesCompatible(x1, x2, out);
    CheckCudaError(cudaSetDevice(index()));
    VisitDtype(x1.dtype(), [&](auto pt) {
        using T = typename decltype(pt)::type;
        static const int kMaxBlockSize = CudaOccupancyMaxPotentialBlockSize(&EqualKernel<T>).block_size;

        IndexableArray<const T> x1_iarray{x1};
        IndexableArray<const T> x2_iarray{x2};
        IndexableArray<bool> out_iarray{out};
        Indexer indexer{out.shape()};

        int64_t total_size = indexer.total_size();
        int64_t grid_size = (total_size + kMaxBlockSize - 1) / kMaxBlockSize;
        int64_t block_size = std::min<int64_t>(total_size, kMaxBlockSize);

        EqualKernel<<<grid_size, block_size>>>(x1_iarray, x2_iarray, out_iarray, indexer);
    });
}

// TODO(sonots): support stream
void CudaDevice::Add(const Array& x1, const Array& x2, const Array& out) {
    CheckDevicesCompatible(x1, x2, out);
    CheckCudaError(cudaSetDevice(index()));
    VisitDtype(out.dtype(), [&](auto pt) {
        using T = typename decltype(pt)::type;
        static const int kMaxBlockSize = CudaOccupancyMaxPotentialBlockSize(&AddKernel<T>).block_size;

        IndexableArray<const T> x1_iarray{x1};
        IndexableArray<const T> x2_iarray{x2};
        IndexableArray<T> out_iarray{out};
        Indexer indexer{out.shape()};

        int64_t total_size = indexer.total_size();
        int64_t grid_size = (total_size + kMaxBlockSize - 1) / kMaxBlockSize;
        int64_t block_size = std::min<int64_t>(total_size, kMaxBlockSize);

        AddKernel<<<grid_size, block_size>>>(x1_iarray, x2_iarray, out_iarray, indexer);
    });
}

void CudaDevice::Subtract(const Array& x1, const Array& x2, const Array& out) {
    CheckDevicesCompatible(x1, x2, out);
    CheckCudaError(cudaSetDevice(index()));
    VisitDtype(out.dtype(), [&](auto pt) {
        using T = typename decltype(pt)::type;
        static const int kMaxBlockSize = CudaOccupancyMaxPotentialBlockSize(&AddKernel<T>).block_size;

        IndexableArray<const T> x1_iarray{x1};
        IndexableArray<const T> x2_iarray{x2};
        IndexableArray<T> out_iarray{out};
        Indexer indexer{out.shape()};

        int64_t total_size = indexer.total_size();
        int64_t grid_size = (total_size + kMaxBlockSize - 1) / kMaxBlockSize;
        int64_t block_size = std::min<int64_t>(total_size, kMaxBlockSize);

        SubtractKernel<<<grid_size, block_size>>>(x1_iarray, x2_iarray, out_iarray, indexer);
    });
}

// TODO(sonots): support stream
void CudaDevice::Multiply(const Array& x1, const Array& x2, const Array& out) {
    CheckDevicesCompatible(x1, x2, out);
    CheckCudaError(cudaSetDevice(index()));
    VisitDtype(out.dtype(), [&](auto pt) {
        using T = typename decltype(pt)::type;
        static const int kMaxBlockSize = CudaOccupancyMaxPotentialBlockSize(&MultiplyKernel<T>).block_size;

        IndexableArray<const T> x1_iarray{x1};
        IndexableArray<const T> x2_iarray{x2};
        IndexableArray<T> out_iarray{out};
        Indexer indexer{out.shape()};

        int64_t total_size = indexer.total_size();
        int64_t grid_size = (total_size + kMaxBlockSize - 1) / kMaxBlockSize;
        int64_t block_size = std::min<int64_t>(total_size, kMaxBlockSize);

        MultiplyKernel<<<grid_size, block_size>>>(x1_iarray, x2_iarray, out_iarray, indexer);
    });
}

void CudaDevice::MultiplyAS(const Array& x1, Scalar x2, const Array& out) {
    CheckDevicesCompatible(x1, out);
    CheckCudaError(cudaSetDevice(index()));
    VisitDtype(out.dtype(), [&](auto pt) {
        using T = typename decltype(pt)::type;
        static const int kMaxBlockSize = CudaOccupancyMaxPotentialBlockSize(&MultiplyASKernel<T>).block_size;

        IndexableArray<const T> x1_iarray{x1};
        IndexableArray<T> out_iarray{out};
        Indexer indexer{out.shape()};

        int64_t total_size = indexer.total_size();
        int64_t grid_size = (total_size + kMaxBlockSize - 1) / kMaxBlockSize;
        int64_t block_size = std::min<int64_t>(total_size, kMaxBlockSize);

        MultiplyASKernel<<<grid_size, block_size>>>(x1_iarray, static_cast<T>(x2), out_iarray, indexer);
    });
}

void CudaDevice::Divide(const Array& lhs, const Array& rhs, const Array& out) {
    CheckDevicesCompatible(lhs, rhs, out);
    cudaSetDevice(index());
    VisitDtype(lhs.dtype(), [&](auto pt) {
        using T = typename decltype(pt)::type;
        static const int kMaxBlockSize = CudaOccupancyMaxPotentialBlockSize(&AddKernel<T>).block_size;

        IndexableArray<const T> lhs_iarray{lhs};
        IndexableArray<const T> rhs_iarray{rhs};
        IndexableArray<T> out_iarray{out};
        Indexer indexer{lhs.shape()};

        int64_t total_size = indexer.total_size();
        int64_t grid_size = (total_size + kMaxBlockSize - 1) / kMaxBlockSize;
        int64_t block_size = std::min<int64_t>(total_size, kMaxBlockSize);

        DivideKernel<<<grid_size, block_size>>>(lhs_iarray, rhs_iarray, out_iarray, indexer);
    });
}

void CudaDevice::IfLessElseASSA(const Array& x1, Scalar x2, Scalar pos, const Array& neg, const Array& out) {
    CheckDevicesCompatible(x1, neg, out);
    CheckCudaError(cudaSetDevice(index()));
    VisitDtype(out.dtype(), [&](auto pt) {
        using T = typename decltype(pt)::type;
        static const int kMaxBlockSize = CudaOccupancyMaxPotentialBlockSize(&IfLessElseASSAKernel<T>).block_size;

        IndexableArray<const T> x1_iarray{x1};
        IndexableArray<const T> neg_iarray{neg};
        IndexableArray<T> out_iarray{out};
        Indexer indexer{out.shape()};
        T x2_value{x2};
        T pos_value{pos};

        int64_t total_size = indexer.total_size();
        int64_t grid_size = (total_size + kMaxBlockSize - 1) / kMaxBlockSize;
        int64_t block_size = std::min<int64_t>(total_size, kMaxBlockSize);

        IfLessElseASSAKernel<<<grid_size, block_size>>>(x1_iarray, x2_value, pos_value, neg_iarray, out_iarray, indexer);
    });
}

namespace {

// Dispatch gemm routines based on the element type T
template <typename T>
struct Gemm;

template <>
struct Gemm<float> {
    template <typename... Args>
    void operator()(Args&&... args) const {
        CheckCublasError(cublasSgemm(std::forward<Args>(args)...));
    }
};

template <>
struct Gemm<double> {
    template <typename... Args>
    void operator()(Args&&... args) const {
        CheckCublasError(cublasDgemm(std::forward<Args>(args)...));
    }
};

struct GemmInputLayout {
    int64_t ld = 0;
    cublasOperation_t trans = CUBLAS_OP_T;

    // Makes the array C or Fortran contiguous and configure leading dimension and transposition accordingly.
    Array Configure(const Array& a) {
        assert(a.ndim() == 2);
        if (a.strides()[0] == a.element_bytes() && a.strides()[0] * a.shape()[0] == a.strides()[1]) {
            // Fortran contiguous
            ld = a.shape()[0];
            return a;
        }
        // Force C contiguous
        ld = a.shape()[1];
        trans = CUBLAS_OP_N;  // transposed
        return a.IsContiguous() ? a : a.AsConstant(CopyKind::kCopy);
    }
};

template <typename T>
T* GetOffsetData(const Array& a) {
    uint8_t* offset_ptr = static_cast<uint8_t*>(a.raw_data()) + a.offset();
    return reinterpret_cast<T*>(offset_ptr);  // NOLINT: reinterpret_cast
}

}  // namespace

void CudaDevice::Dot(const Array& a, const Array& b, const Array& out) {
    CheckDevicesCompatible(a, b, out);
    CheckCudaError(cudaSetDevice(index()));

    assert(a.ndim() == 2);
    assert(b.ndim() == 2);
    assert(out.ndim() == 2);

    int64_t m = a.shape()[0];
    int64_t k = a.shape()[1];
    int64_t n = b.shape()[1];
    assert(b.shape()[0] == k);
    assert(out.shape()[0] == m);
    assert(out.shape()[1] == n);

    if (m == 1 && n == 1) {
        // TODO(beam2d): Write a custom reduction kernel.
        Array l = a.AsConstant();
        Array r = b.AsConstant();
        Array o = out.AsConstant();
        Sum(l.Reshape({k}) * r.Reshape({k}), {0}, o.Reshape({}));
        return;
    }

    bool is_out_contiguous = out.IsContiguous();
    Array out_contiguous = is_out_contiguous ? out : EmptyLike(out, *this);

    auto gemm_impl = [&](auto pt) {
        using T = typename decltype(pt)::type;

        // Note that cuBLAS uses Fortran order.
        // To compute out = a x b, we use cuBLAS to compute out^T = b^T x a^T (here x is the matrix product).

        GemmInputLayout a_layout;
        GemmInputLayout b_layout;
        Array a_config = a_layout.Configure(a);
        Array b_config = b_layout.Configure(b);

        cublasHandle_t handle = static_cast<CudaBackend&>(backend()).cublas_handle();
        const T one = 1;
        const T zero = 0;
        const T* a_ptr = GetOffsetData<const T>(a_config);
        const T* b_ptr = GetOffsetData<const T>(b_config);
        T* out_ptr = GetOffsetData<T>(out_contiguous);
        Gemm<T>{}(handle, b_layout.trans, a_layout.trans, n, m, k, &one, b_ptr, b_layout.ld, a_ptr, a_layout.ld, &zero, out_ptr, n);
    };

    if (a.dtype() == Dtype::kFloat32) {
        gemm_impl(PrimitiveType<float>{});
    } else if (a.dtype() == Dtype::kFloat64) {
        gemm_impl(PrimitiveType<double>{});
    } else {
        throw NotImplementedError("dot is not implemented for non-float types in CUDA");
    }

    if (!is_out_contiguous) {
        Copy(out_contiguous, out);
    }
}

void CudaDevice::Exp(const Array& x, const Array& out) {
    CheckDevicesCompatible(x, out);
    CheckCudaError(cudaSetDevice(index()));
    VisitFloatingPointDtype(out.dtype(), [&](auto pt) {
        using T = typename decltype(pt)::type;
        static const int kMaxBlockSize = CudaOccupancyMaxPotentialBlockSize(&ExpKernel<T>).block_size;

        IndexableArray<const T> x_iarray{x};
        IndexableArray<T> out_iarray{out};
        Indexer indexer{out.shape()};

        int64_t total_size = indexer.total_size();
        int64_t grid_size = (total_size + kMaxBlockSize - 1) / kMaxBlockSize;
        int64_t block_size = std::min<int64_t>(total_size, kMaxBlockSize);

        ExpKernel<<<grid_size, block_size>>>(x_iarray, out_iarray, indexer);
    });
}

void CudaDevice::Log(const Array& x, const Array& out) {
    CheckDevicesCompatible(x, out);
    CheckCudaError(cudaSetDevice(index()));
    VisitFloatingPointDtype(out.dtype(), [&](auto pt) {
        using T = typename decltype(pt)::type;
        static const int kMaxBlockSize = CudaOccupancyMaxPotentialBlockSize(&LogKernel<T>).block_size;

        IndexableArray<const T> x_iarray{x};
        IndexableArray<T> out_iarray{out};
        Indexer indexer{out.shape()};

        int64_t total_size = indexer.total_size();
        int64_t grid_size = (total_size + kMaxBlockSize - 1) / kMaxBlockSize;
        int64_t block_size = std::min<int64_t>(total_size, kMaxBlockSize);

        LogKernel<<<grid_size, block_size>>>(x_iarray, out_iarray, indexer);
    });
}

void CudaDevice::Take(const Array& /*a*/, const Array& /*indices*/, int64_t /*axis*/, const Array& /*out*/) {
    // TODO(niboshi): Implement
    throw NotImplementedError("");
}

void CudaDevice::Synchronize() {
    CheckCudaError(cudaSetDevice(index()));
    CheckCudaError(cudaDeviceSynchronize());
}

}  // namespace cuda
}  // namespace xchainer
