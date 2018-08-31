### Indexing with WeightedIndex

# We inject indexing with `WeightedIndex` at a non-exported point in the dispatch heirarchy.
# This is to avoid ambiguities with methods that specialize on the array type rather than
# the index type.
Base.to_indices(A, I::Tuple{Vararg{Union{Int,WeightedIndex}}}) = I
@propagate_inbounds Base._getindex(::IndexLinear, A::AbstractVector, i::Int) = getindex(A, i)  # ambiguity resolution
@inline function Base._getindex(::IndexStyle, A::AbstractArray{T,N}, I::Vararg{Union{Int,WeightedIndex},N}) where {T,N}
    interp_getindex(A, I)
end

# This follows a "move processed indexes to the back" strategy, so J contains the yet-to-be-processed
# indexes and I all the processed indexes.
interp_getindex(A::AbstractArray{T,N}, J::Tuple{Int,Vararg{Any,L}}, I::Vararg{Int,M}) where {T,N,L,M} =
    interp_getindex(A, Base.tail(J), I..., J[1])
function interp_getindex(A::AbstractArray{T,N}, J::Tuple{WeightedIndex,Vararg{Any,L}}, I::Vararg{Int,M}) where {T,N,L,M}
    wi = J[1]
    _interp_getindex(A, indexes(wi), weights(wi), Base.tail(J), I...)
end
interp_getindex(A::AbstractArray{T,N}, ::Tuple{}, I::Vararg{Int,N}) where {T,N} =   # termination
    @inbounds A[I...]  # all bounds-checks have already happened

# version for WeightedAdjIndex
_interp_getindex(A, i::Int, weights::NTuple{K,Number}, rest, I::Vararg{Int,M}) where {M,K} =
    weights[1] * interp_getindex(A, rest, I..., i) + _interp_getindex(A, i+1, Base.tail(weights), rest, I...)
_interp_getindex(A, i::Int, weights::Tuple{Number}, rest, I::Vararg{Int,M}) where M =
    weights[1] * interp_getindex(A, rest, I..., i)
_interp_getindex(A, i::Int, weights::Tuple{}, rest, I::Vararg{Int,M}) where M =
    error("exhausted weights, this should never happen")  # helps inference

# version for WeightedArbIndex
_interp_getindex(A, indexes::NTuple{K,Int}, weights::NTuple{K,Number}, rest, I::Vararg{Int,M}) where {M,K} =
    weights[1] * interp_getindex(A, rest, I..., indexes[1]) + _interp_getindex(A, Base.tail(indexes), Base.tail(weights), rest, I...)
_interp_getindex(A, indexes::Tuple{Int}, weights::Tuple{Number}, rest, I::Vararg{Int,M}) where M =
    weights[1] * interp_getindex(A, rest, I..., indexes[1])
_interp_getindex(A, indexes::Tuple{}, weights::Tuple{}, rest, I::Vararg{Int,M}) where M =
    error("exhausted weights and indexes, this should never happen")


### Primary evaluation entry points (itp(x...), gradient(itp, x...), and hessian(itp, x...))

itpinfo(itp) = (tcollect(itpflag, itp), axes(itp))

@inline function (itp::BSplineInterpolation{T,N})(x::Vararg{Number,N}) where {T,N}
    @boundscheck (checkbounds(Bool, itp, x...) || Base.throw_boundserror(itp, x))
    wis = weightedindexes((value_weights,), itpinfo(itp)..., x)
    itp.coefs[wis...]
end
@propagate_inbounds function (itp::BSplineInterpolation{T,N})(x::Vararg{Number,M}) where {T,M,N}
    inds, trailing = split_trailing(itp, x)
    @boundscheck (check1(trailing) || Base.throw_boundserror(itp, x))
    @assert length(inds) == N
    itp(inds...)
end

@inline function gradient(itp::BSplineInterpolation{T,N}, x::Vararg{Number,N}) where {T,N}
    @boundscheck checkbounds(Bool, itp, x...) || Base.throw_boundserror(itp, x)
    wis = weightedindexes((value_weights, gradient_weights), itpinfo(itp)..., x)
    SVector(map(inds->itp.coefs[inds...], wis))
end
@propagate_inbounds function gradient!(dest, itp::BSplineInterpolation{T,N}, x::Vararg{Number,N}) where {T,N}
    dest .= gradient(itp, x...)
end

@inline function hessian(itp::BSplineInterpolation{T,N}, x::Vararg{Number,N}) where {T,N}
    @boundscheck checkbounds(Bool, itp, x...) || Base.throw_boundserror(itp, x)
    wis = weightedindexes((value_weights, gradient_weights, hessian_weights), itpinfo(itp)..., x)
    symmatrix(map(inds->itp.coefs[inds...], wis))
end
@propagate_inbounds function hessian!(dest, itp::BSplineInterpolation{T,N}, x::Vararg{Number,N}) where {T,N}
    dest .= hessian(itp, x...)
end

checkbounds(::Type{Bool}, itp::AbstractInterpolation, x::Vararg{Number,N}) where N =
    checklubounds(lbounds(itp), ubounds(itp), x)

checklubounds(ls, us, xs) = _checklubounds(true, ls, us, xs)
_checklubounds(tf::Bool, ls, us, xs) = _checklubounds(tf & (ls[1] <= xs[1] <= us[1]),
                                                        Base.tail(ls), Base.tail(us), Base.tail(xs))
_checklubounds(tf::Bool, ::Tuple{}, ::Tuple{}, ::Tuple{}) = tf

# Leftovers from AbstractInterpolation
@inline function (itp::BSplineInterpolation)(x::Vararg{UnexpandedIndexTypes})
    itp(to_indices(itp, x)...)
end
@inline function (itp::BSplineInterpolation)(x::Vararg{ExpandedIndexTypes})
    itp.(Iterators.product(x...))
end


function weightedindexes(fs::F, itpflags::NTuple{N,Flag}, knots::NTuple{N,AbstractVector}, xs::NTuple{N,Number}) where {F,N}
    parts = map((flag, knotvec, x)->weightedindex_parts(fs, flag, knotvec, x), itpflags, knots, xs)
    weightedindexes(parts...)
end

weightedindexes(i::Vararg{Int,N}) where N = i  # the all-NoInterp case

const PositionCoefs{P,C} = NamedTuple{(:position,:coefs),Tuple{P,C}}
const ValueParts{P,W} = PositionCoefs{P,Tuple{W}}
weightedindexes(parts::Vararg{Union{Int,ValueParts},N}) where N = maybe_weightedindex.(positions.(parts), valuecoefs.(parts))
maybe_weightedindex(i::Integer, _::Integer) = Int(i)
maybe_weightedindex(pos, coefs::Tuple) = WeightedIndex(pos, coefs)

positions(i::Int) = i
valuecoefs(i::Int) = i
gradcoefs(i::Int) = i
hesscoefs(i::Int) = i
positions(t::PositionCoefs) = t.position
valuecoefs(t::PositionCoefs) = t.coefs[1]
gradcoefs(t::PositionCoefs) = t.coefs[2]
hesscoefs(t::PositionCoefs) = t.coefs[3]

const GradParts{P,W1,W2} = PositionCoefs{P,Tuple{W1,W2}}
function weightedindexes(parts::Vararg{Union{Int,GradParts},N}) where N
    # Create (wis1, wis2, ...) where wisn is used to evaluate the gradient along the nth *chosen* dimension
    # Example: if itp is a 3d interpolation of form (Linear, NoInterp, Quadratic) then we will return
    #    (gwi1, i2, wi3), (wi1, i2, gwi3)
    # where wik are value-coefficient WeightedIndexes along dimension k
    #       gwik are gradient-coefficient WeightedIndexes along dimension k
    #       i2 is the integer index along dimension 2
    # These will result in a 2-vector gradient.
    # TODO: check whether this is inferrable
    slot_substitute(parts, positions.(parts), valuecoefs.(parts), gradcoefs.(parts))
end

# Skip over NoInterp dimensions
slot_substitute(kind::Tuple{Int,Vararg{Any}}, p, v, g) = slot_substitute(Base.tail(kind), p, v, g)
# Substitute the dth dimension's gradient coefs for the remaining coefs
slot_substitute(kind, p, v, g) = (maybe_weightedindex.(p, substitute_ruled(v, kind, g)), slot_substitute(Base.tail(kind), p, v, g)...)
# Termination
slot_substitute(kind::Tuple{}, p, v, g) = ()

const HessParts{P,W1,W2,W3} = PositionCoefs{P,Tuple{W1,W2,W3}}
function weightedindexes(parts::Vararg{Union{Int,HessParts},N}) where N
    # Create (wis1, wis2, ...) where wisn is used to evaluate the nth *chosen* hessian component
    # Example: if itp is a 3d interpolation of form (Linear, NoInterp, Quadratic) then we will return
    #    (hwi1, i2, wi3), (gwi1, i2, gwi3), (wi1, i2, hwi3)
    # where wik are value-coefficient WeightedIndexes along dimension k
    #       gwik are 1st-derivative WeightedIndexes along dimension k
    #       hwik are 2nd-derivative WeightedIndexes along dimension k
    #       i2 is just the index along dimension 2
    # These will result in a 2x2 hessian [hc1 hc2; hc2 hc3] where
    #    hc1 = coefs[hwi1, i2, wi3]
    #    hc2 = coefs[gwi1, i2, gwi3]
    #    hc3 = coefs[wi1,  i2, hwi3]
    slot_substitute(parts, parts, positions.(parts), valuecoefs.(parts), gradcoefs.(parts), hesscoefs.(parts))
end

# Skip over NoInterp dimensions
function slot_substitute(kind1::Tuple{Int,Vararg{Any}}, kind2::Tuple{Int,Vararg{Any}}, p, v, g, h)
    @assert(kind1 == kind2)
    kind = Base.tail(kind1)
    slot_substitute(kind, kind, p, v, g, h)
end
function slot_substitute(kind1, kind2::Tuple{Int,Vararg{Any}}, p, v, g, h)
    kind = Base.tail(kind1)
    slot_substitute(kind, kind, p, v, g, h)
end
slot_substitute(kind1::Tuple{Int,Vararg{Any}}, kind2, p, v, g, h) = slot_substitute(Base.tail(kind1), kind2, p, v, g, h)
# Substitute the dth dimension's gradient coefs for the remaining coefs
function slot_substitute(kind1::K, kind2::K, p, v, g, h) where K
    (maybe_weightedindex.(p, substitute_ruled(v, kind1, h)), slot_substitute(Base.tail(kind1), kind2, p, v, g, h)...)
end
function slot_substitute(kind1, kind2, p, v, g, h)
    ss = substitute_ruled(substitute_ruled(v, kind1, g), kind2, g)
    (maybe_weightedindex.(p, ss), slot_substitute(Base.tail(kind1), kind2, p, v, g, h)...)
end
# Termination
slot_substitute(kind1::Tuple{}, kind2::Tuple{Int,Vararg{Any}}, p, v, g, h) = _slot_substitute(kind1::Tuple{}, kind2, p, v, g, h)
slot_substitute(kind1::Tuple{}, kind2, p, v, g, h) = _slot_substitute(kind1::Tuple{}, kind2, p, v, g, h)
function _slot_substitute(kind1::Tuple{}, kind2, p, v, g, h)
    # finish "column" and continue on to the next "column"
    kind = Base.tail(kind2)
    slot_substitute(kind, kind, p, v, g, h)
end
slot_substitute(kind1::Tuple{}, kind2::Tuple{}, p, v, g, h) = ()


weightedindex_parts(fs::F, itpflag::BSpline, ax, x) where F =
    weightedindex_parts(fs, degree(itpflag), ax, x)

function weightedindex_parts(fs::F, deg::Degree, ax::AbstractUnitRange{<:Integer}, x) where F
    pos, δx = positions(deg, ax,  x)
    (position=pos, coefs=fmap(fs, deg, δx))
end


# there is a Heisenbug, when Base.promote_op is inlined into getindex_return_type
# thats why we use this @noinline fence
@noinline _promote_mul(a,b) = Base.promote_op(*, a, b)

@noinline function getindex_return_type(::Type{BSplineInterpolation{T,N,TCoefs,IT,Axs}}, argtypes::Tuple) where {T,N,TCoefs,IT<:DimSpec{BSpline},Axs}
    reduce(_promote_mul, eltype(TCoefs), argtypes)
end

function getindex_return_type(::Type{BSplineInterpolation{T,N,TCoefs,IT,Axs}}, ::Type{I}) where {T,N,TCoefs,IT<:DimSpec{BSpline},Axs,I}
    _promote_mul(eltype(TCoefs), I)
end

# This handles round-towards-the-middle for points on half-integer edges
roundbounds(x::Integer, bounds::Tuple{Real,Real}) = x
roundbounds(x::Integer, bounds::AbstractUnitRange) = x
roundbounds(x::Number, bounds::Tuple{Real,Real}) = _roundbounds(x, bounds)
roundbounds(x::Number, bounds::AbstractUnitRange) = _roundbounds(x, bounds)
function _roundbounds(x::Number, bounds::Union{Tuple{Real,Real}, AbstractUnitRange})
    l, u = first(bounds), last(bounds)
    h = half(x)
    xh = x+h
    ifelse(x < u+half(u), floor(xh), ceil(xh)-1)
end

floorbounds(x::Integer, ax::Tuple{Real,Real}) = x
floorbounds(x::Integer, ax::AbstractUnitRange) = x
floorbounds(x, ax::Tuple{Real,Real}) = _floorbounds(x, ax)
floorbounds(x, ax::AbstractUnitRange) = _floorbounds(x, ax)
function _floorbounds(x, ax::Union{Tuple{Real,Real}, AbstractUnitRange})
    l = first(ax)
    h = half(x)
    ifelse(x < l, floor(x+h), floor(x+zero(h)))
end

half(x) = oneunit(x)/2

symmatrix(h::NTuple{1,Any}) = SMatrix{1,1}(h)
symmatrix(h::NTuple{3,Any}) = SMatrix{2,2}((h[1], h[2], h[2], h[3]))
symmatrix(h::NTuple{6,Any}) = SMatrix{3,3}((h[1], h[2], h[3], h[2], h[4], h[5], h[3], h[5], h[6]))
function symmatrix(h::Tuple{L,Any}) where L
    @noinline incommensurate(L) = error("$L must be equal to N*(N+1)/2 for integer N")
    N = ceil(Int, sqrt(L))
    (N*(N+1))÷2 == L || incommensurate(L)
    l = Matrix{Int}(undef, N, N)
    l[:,1] = 1:N
    idx = N
    for j = 2:N, i = 1:N
        if i < j
            l[i,j] = l[j,i]
        else
            l[i,j] = (idx+=1)
        end
    end
    if @generated
        hexprs = [:(h[$i]) for i in vec(l)]
        :(SMatrix{$N,$N}($(hexprs...,)))
    else
        SMatrix{N,N}([h[i] for i in vec(l)]...)
    end
end
