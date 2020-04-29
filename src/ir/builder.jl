import PyCall: PyObject

const XFloat  = Union{Float64,Float32,Float16}
const XInt    = Union{Int64,Int32,Int16}
const XScalar = Union{XFloat,XInt}

const julia2numpy = Dict(
  Float64 => "float64",
  Float32 => "float32",
  Int64   => "int64",
  Bool    => "bool")

const numpy2julia = Dict(v => k for (k, v) in julia2numpy)

numpytype(T) = xlaclient.np.dtype(julia2numpy[T])
primitivetype(T) = xlaclient.dtype_to_etype(numpytype(T))
juliatype(T) = numpy2julia[T.name]

# Shapes

struct Shape{T,N}
  dims::NTuple{N,Int}
end

Shape(T::Type{<:XScalar}, sh::NTuple{N,Integer}) where N = Shape{T,N}(sh)

shapeof(x::AbstractArray) = Shape{eltype(x),ndims(x)}(size(x))

Base.eltype(::Shape{T}) where T = T
Base.ndims(::Shape{T,N}) where {T,N} = N

PyObject(sh::Shape) = xlaclient.Shape.array_shape(numpytype(eltype(sh)), sh.dims)
pyshape(sh::Shape) = PyObject(sh)

Base.show(io::IO, sh::Shape) = print(io, eltype(sh), "[", join(sh.dims, ","), "]")

function Shape(sh::PyObject)
  T = juliatype(sh.numpy_dtype())
  size = sh.dimensions()
  Shape{T,length(size)}(size)
end

shapeof(p::PyObject) = p.is_array() ? Shape(p) : (shapeof.(p.tuple_shapes())...,)

pyshape(x::Tuple) = xlaclient.Shape.tuple_shape(pyshape.(x))

pyshape(x::Type{<:XScalar}) = pyshape(Shape(x, ()))

# Values

struct XArray{T,N} <: AbstractArray{T,N}
  buffer::PyObject
end

function setup_finaliser(x)
  delete = x.buffer.delete # work around a segfault on exit
  finalizer(buf -> ispynull(delete) || delete(), x.buffer)
end

function XArray(data::Array{<:XScalar})
  buffer = xlaclient.Buffer.from_pyval(data)
  x = XArray{eltype(data),ndims(data)}(buffer)
  setup_finaliser(x)
  return x
end

function XArray(buf::PyObject, own = true)
  sh = Shape(buf.shape())
  x = XArray{eltype(sh),ndims(sh)}(buf)
  own && setup_finaliser(x)
  return x
end

PyObject(x::XArray) = x.buffer

Base.size(x::XArray) = x.buffer.shape().dimensions()
Base.collect(x::XArray) = convert(Array, x.buffer.to_py())
Base.print_array(io::IO, x::XArray) = Base.print_array(io, collect(x))
Base.show_vector(io::IO, x::XArray) = Base.show_vector(io, collect(x))

scalar(x::PyObject) = get(x, ())
scalar(x::Array) = x[]
scalar(x::XArray{T,0}) where T = scalar(x.buffer.to_py()) # Array or PyObject? Seems to be random
scalar(x::XArray) = x

xla(x::XArray) = x
xla(x::AbstractArray{<:XScalar}) = XArray(x)
xla(x::Number) = XArray(fill(x))
xla(x::Tuple) = xla.(x)

function wrapvalue(p::PyObject)
  p.shape().is_tuple() ? (wrapvalue.(p.destructure())...,) : scalar(XArray(p))
end

default_device() = xlaclient.get_local_backend().devices()[1]

buffer(x::Array{<:XScalar}) = xlaclient.Buffer.from_pyval(x)
buffer(x::XScalar) = xlaclient.Buffer.from_pyval(x)

# IR Builder

shapeof(builder, op) = shapeof(builder.GetShape(op))

function settypes!(builder, comp::IR, ops...; with = identity)
  Ts = map(op -> with(shapeof(builder, op)), ops)
  argtypes(comp)[:] = [Ts...]
  return comp
end

function build(ir::IR)
  builder = xlaclient.ComputationBuilder("")
  env = Dict()
  resolve(x::Variable) = env[x]
  resolve(x::QuoteNode) = const!(builder, x.value)
  resolve(x) = const!(builder, x)
  for (v, T) in zip(arguments(ir), argtypes(ir))
    env[v] = builder.ParameterWithShape(pyshape(T))
  end
  for (v, st) in ir
    ex = st.expr
    if isexpr(ex, :call)
      env[v] = build!(builder, ex.args[1], resolve.(ex.args[2:end])...)
    elseif ex isa IR
      env[v] = ex
    elseif isexpr(ex)
      error("Invalid XLA expression $(ex)")
    else
      env[v] = const!(builder, ex)
    end
  end
  if isreturn(blocks(ir)[end])
    ret = returnvalue(blocks(ir)[end])
    # TODO handle the variable case
    !(ret isa Variable) && const!(builder, ret)
  end
  return builder.Build()
end

function compile(ir::IR)
  ir = controlflow(ir)
  comp = build(ir).Compile()
  return (xs...) -> wrapvalue.(comp.Execute(buffer.(xs)))[1]
end