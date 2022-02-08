using CUDA.CUDNN: CUDNN_BN_MIN_EPSILON, cudnnBatchNormalizationBackward,
                  cudnnBatchNormalizationForwardInference, CUDNN_BATCHNORM_SPATIAL,
                  cudnnBatchNormalizationForwardTraining


# TODO: replace with new cudnn normalization interface
# https://github.com/JuliaGPU/CUDA.jl/blob/master/lib/cudnn/normalization.jl

mutable struct BNCache
  mean
  ivar
end

BNCache() = BNCache(nothing, nothing)

@inline _wsize(y) = ntuple(i -> i == ndims(y) - 1 ? 1 : size(y, i), ndims(y))

function batchnorm(g::Nothing, b::Nothing, x::DenseCuArray,
                running_mean, running_var, momentum;
                kws...)
  affine_sz = _wsize(x)
  g = fill!(similar(x, affine_sz), 1)
  b = fill!(similar(x, affine_sz), 0)
  
  batchnorm(g, b, x, running_mean, running_var, momentum;
                     kws...)
end

# NOTE: CuDNN supports only 4D and 5D Tensors for BatchNorm Operations
# so reshape a 2D Tensor into 4D
batchnorm(g::DenseCuArray{T}, b::DenseCuArray{T}, x::DenseCuArray{T,2},
          running_mean, running_var, momentum;
          kws...) where T<:Union{Float32, Float64} =
  dropdims(batchnorm(g, b, reshape(x, 1, 1, size(x, 1), size(x, 2)), 
                     running_mean, running_var, momentum;
                     kws...), 
            dims = (1, 2))

function batchnorm(g::DenseCuArray{T}, b::DenseCuArray{T}, x::Union{DenseCuArray{T,4},DenseCuArray{T,5}},
                    running_mean, running_var, momentum;
                    kws...) where T<:Union{Float32, Float64}
  cudnnBNForward!(similar(x), g, b, x, running_mean, running_var, momentum; kws...)
end

function cudnnBNForward!(y::DenseCuArray{T}, g::DenseCuArray{T}, b::DenseCuArray{T}, x::DenseCuArray{T},
                        running_mean, running_var, momentum; 
                        cache = nothing, 
                        alpha = T(1), beta = T(0),
                        eps = T(1e-5), 
                        training = true,
                        affine = true,
                        track_stats = true) where T<:Union{Float32, Float64}
  dims = _wsize(x)
  if eps < CUDNN_BN_MIN_EPSILON
    # warn("eps ",eps," is too small for CuDNN so eps has been assigned the value ", CUDNN_BN_MIN_EPSILON)
    eps = CUDNN_BN_MIN_EPSILON
  end
  xd = cudnnTensorDescriptor(x)
  yd = cudnnTensorDescriptor(y)
  gd = cudnnTensorDescriptor(CUDNN_TENSOR_NCHW, cudnnDataType(T), Cint(length(dims)), dim4(dims,Val(CUDNN_TENSOR_NCHW)))

  if !track_stats
    running_mean = CU_NULL
    running_var = CU_NULL
  end

  if training
    if cache !== nothing
      mean = zeros(CuArray{T}, dims...)
      ivar = ones(CuArray{T}, dims...)
    else
      mean = CU_NULL
      ivar = CU_NULL
    end

    cudnnBatchNormalizationForwardTraining(handle(), CUDNN_BATCHNORM_SPATIAL, scalingParameter(T, alpha), scalingParameter(T, beta), xd, x, yd, y, gd, g, b, momentum, running_mean, running_var, eps, mean, ivar)

    if cache !== nothing
      cache.mean = mean
      cache.ivar = ivar
    end
  else
    cudnnBatchNormalizationForwardInference(handle(), CUDNN_BATCHNORM_SPATIAL, scalingParameter(T, alpha), scalingParameter(T, beta), xd, x, yd, y, gd, g, b, running_mean, running_var, eps)
  end
  return y
end

function ∇batchnorm(g::Nothing, b::Nothing, x::DenseCuArray, dy::DenseCuArray,
                  running_mean, running_var, momentum; kws...)
  affine_sz = _wsize(x)
  g = fill!(similar(x, affine_sz), 1)
  b = fill!(similar(x, affine_sz), 0)
  ∇batchnorm(g, b, x, dy, running_mean, running_var, momentum; kws...)
end

function ∇batchnorm(g::DenseCuArray{T}, b::DenseCuArray{T}, x::DenseCuArray{T, 2}, dy::DenseCuArray{T, 2},
            running_mean, running_var, momentum;
            kws...) where T<:Union{Float32, Float64}
  dg, db, dx = ∇batchnorm(g, b, reshape(x, 1, 1, size(x, 1), size(x, 2)), reshape(dy, 1, 1, size(dy, 1),
                          size(dy, 2)), running_mean, running_var, momentum; kws...)
  (dg, db, dropdims(dx, dims = (1, 2)))
end


function ∇batchnorm(g::DenseCuArray{T}, b::DenseCuArray{T}, x::DenseCuArray{T}, dy::DenseCuArray{T},
                    running_mean, running_var, momentum;
                    affine=true, kws...) where T<:Union{Float32, Float64}
  dg = similar(g)
  db = similar(b)
  dx = similar(x)
  cudnnBNBackward!(dg, g, db, dx, x, dy, running_mean, running_var, T(momentum); kws...)
  if affine
    (dg, db, dx)
  else
    # CUDNN always calculates dg and db, therefore we just have to drop them  
    (nothing, nothing, dx)
  end
end

function cudnnBNBackward!(dg::DenseCuArray{T}, g::DenseCuArray{T}, db::DenseCuArray{T},
                          dx::DenseCuArray{T}, x::DenseCuArray{T}, dy::DenseCuArray{T},
                          running_mean, running_var,
                          momentum; cache = nothing, eps = T(1e-5),
                          alpha = T(1), beta = T(0),
                          dalpha = T(1), dbeta = T(0), training = true, 
                          track_stats = true) where T<:Union{Float32, Float64}
  
  if !track_stats
    running_mean = CU_NULL
    running_var = CU_NULL
  end

  xd = cudnnTensorDescriptor(x)
  dyd = cudnnTensorDescriptor(dy)
  dxd = cudnnTensorDescriptor(dx)
  gd = cudnnTensorDescriptor(CUDNN_TENSOR_NCHW, cudnnDataType(T), Cint(length(_wsize(x))), dim4(_wsize(x),Val(CUDNN_TENSOR_NCHW)))
  if cache !== nothing
    mean, ivar = cache.mean, cache.ivar
    @debug "mean and ivar are fetched from the cache"
  else
    mean, ivar = CU_NULL, CU_NULL
  end

  if eps < CUDNN_BN_MIN_EPSILON
    eps = CUDNN_BN_MIN_EPSILON
  end

  cudnnBatchNormalizationBackward(handle(), CUDNN_BATCHNORM_SPATIAL, 
        scalingParameter(T, alpha), scalingParameter(T, beta), scalingParameter(T, dalpha), scalingParameter(T, dbeta), 
        xd, x, dyd, dy, dxd, dx, gd, g, dg, db, eps, 
        mean, ivar)
end

function rrule(::typeof(batchnorm), g, b, x, running_mean, running_var, momentum; kws...)
  y = batchnorm(g, b, x, running_mean, running_var, momentum; kws...) 
  function batchnorm_pullback(Δ)
    dg, db, dx = ∇batchnorm(g, b, x, Δ, running_mean, running_var, momentum; kws...)
    NoTangent(), something(dg, NoTangent()), something(db, NoTangent()), dx, NoTangent(), NoTangent(), NoTangent()
  end
  y, batchnorm_pullback
end
