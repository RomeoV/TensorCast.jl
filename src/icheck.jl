
export @check!, @einsum!, @tensor!

"""
    @check!(A[i, j, μ, ν])

Adds `A` to the store of known tensors, and records that it expects indices `i,j,μ,ν`.
If it is already in the store, then instead this checks whether the present indices differ 
from the saved ones. This happens while parsing your source code, there is zero run-time penalty. 

In addition, it can insert size checks to be performed at run-time. 
At the first occurrange these save `i: => size(A,1)` etc., and on subsequent uses of 
the same index (even on different tensors) give an error if the sizes do not match. 
If turned on, this will need to look up indices in a dictionary, which takes ... 50ns, really? 

Returns either `A` or `check!(A, stuff)`. 

    @check! B[i,j] C[μ,ν]

Checks several tensors, returns nothing. 

    @check!  alpha=true  tol=3  size=false  throw=false  info  empty

Controls options for `@check!` and related macros, these are the defaults:
* `alpha=true` turns on the parse-time checking, based on index letters
* `tol=3` sets how close together letters must be: `B[j,k]` is not an error but `B[a,b]` will be
* `size=false` turns off run-time size checking
* `throw=false` means that errors are given using `@error`, without interrupting your program
* `empty` deletes all saved letters and sizes -- there is one global store for each, for now
* `info` prints what's currently saved.
"""
macro check!(exs...)
    where = (mod=__module__, src=__source__)
    _check!(exs...; where=where)
end

const index_store = Dict{Symbol, Tuple}()
const size_store  = Dict{Symbol, Int}()

mutable struct CheckOptions
    alpha::Bool
    tol::Int
    size::Bool
    throw::Bool
end

const check_options = CheckOptions(true, 3, false, false)

function _check!(exs...; where=nothing)
    for ex in exs
        if @capture(ex, A_[vec__])
            if length(exs)==1
                return esc(check_one(ex, where))
            else
                check_one(ex, where)
            end

        elseif @capture(ex, alpha=val_Bool)
            check_options.alpha = val
        elseif @capture(ex, tol=val_Int)
            check_options.tol = val

        elseif @capture(ex, size=val_Bool)
            check_options.size = val

        elseif @capture(ex, throw=val_Bool)
            check_options.throw = val

        elseif ex == :empty
            empty!(index_store)
            empty!(size_store)
            @info "@check! stores emptied"

        elseif ex == :info
            @info "@check! info" check_options index_store size_store

        else 
            println(ex, "  ",typeof(ex))
            @error "@check! doesn't know what to do with $ex"

        end
    end
    return nothing
end

function check_one(ex, where=nothing)
    @capture(ex, A_[vec__]) || error("check_one can't understand $ex, expected something like A[i,j]")
    ind = Tuple(vec)

    if check_options.alpha
        got = get!(index_store, A, ind)

        if length(ind) > length(got)
            check_err("@check! $ex now has more indices than previous $got", where)
        elseif length(ind) < length(got)
            check_err("@check! $ex now has fewer indices than previous $got", where)
        else
            for (i, j) in zip(ind, got)
                isa(i,Int) || i==(:_) && continue # TODO better handling of (1, $c, word)
                si = String(i)
                sj = String(j)
                length(si)>1 || length(sj)>1 && continue    
                if abs(Int(si[1])-Int(sj[1])) > check_options.tol
                    check_err("@check! $ex now has index $i where previously it had $j", where)
                end
            end
        end
    end

    if check_options.size
        Astring = string(A,"[",join(ind," ,"),"]")
        return :( TensorSlice.check!($A, $ind, $Astring, $where) )
    else
        return A
    end
end

function check_err(str::String, where=nothing)
    if check_options.throw
        error(str)
    elseif where==nothing
        @error str
    else
        @error str  _module=where.mod  _line=where.src.line  _file=string(where.src.file)
    end
end

"""
    check!(A, (:i,:j), "A[i,j]", (mod=..., src=...))
Performs run-time size checking, on behalf of the `@check!` macro, returns `A`. 
The string and tuple are just for the error message. 
"""
function check!(A::AbstractArray{T,N}, ind::Tuple, str::String, where=nothing) where {T,N}
    if N != length(ind)
        check_err("check! expected $str, but got ndims = $N", where)
    else
        for (d,i) in enumerate(ind)
            sizeAd = size(A,d)
            got = get!(size_store, i, sizeAd)
            got == sizeAd || check_err("check! $str, index $i now has range $sizeAd instead of $got", where)
        end
    end
    A
end

"""
    @einsum! A[i,j] := B[i,k] * C[k,j]

Variant of `@einsum` from package Einsum.jl, 
equivalent to wrapping every tensor with `@check!()`.
"""
macro einsum!(ex)
    where = (mod=__module__, src=__source__)
    _einsum!(ex, where)
end

"""
    @tensor! A[i,j] := B[i,k] * C[k,j]

Variant of `@tensor` from package TensorOperations.jl, 
equivalent to wrapping every tensor with `@check!()`.
"""
macro tensor!(ex)
    where = (mod=__module__, src=__source__)
    _tensor!(ex, where)
end

function _tensor!(ex, where=nothing)
    if @capture(ex, lhs_ := rhs_ ) || @capture(ex, lhs_ = rhs_ )  

        outex = quote end
        function f(x)                                                         
            if @capture(x, A_[ijk__] )   
                push!(outex.args, check_one(x, where))                                      
            end                                                                    
            x                                                                    
        end   
        MacroTools.prewalk(f, rhs)

        if check_options.size == false
            check_one(lhs) # then these are only parse checks, outex is trash
        else
            push!(outex.args, :(out = TensorOperations.@tensor $ex) )
            push!(outex.args, check_one(lhs, where)) # lhs size may not be known until after @tensor
            push!(outex.args, :out )                 # make sure we still return what @tensor did
            return esc(outex)
        end
    else
        @warn "@tensor! not smart enough to process $ex yet, so ignoring checks"
    end
    return esc(:( TensorOperations.@tensor $ex ))
end

function _einsum!(ex, where=nothing)
    if @capture(ex, lhs_ := rhs_ ) || @capture(ex, lhs_ = rhs_ ) 

        outex = quote end
        function f(x)                                                         
            if @capture(x, A_[ijk__] )   
                push!(outex.args, check_one(x, where))                                      
            end                                                                    
            x                                                                    
        end   
        MacroTools.prewalk(f, rhs)

        if check_options.size == false
            check_one(lhs) # then these are only parse checks, outex is trash
        else
            push!(outex.args, :(out = Einsum.@einsum $ex) )
            push!(outex.args, check_one(lhs, where)) # lhs size may not be known until after @einsum
            push!(outex.args, :out )                 # make sure we still return what @einsum did
            return esc(outex)
        end
    else
        @warn "@einsum! not smart enough to process $ex yet, so ignoring checks"
    end
    return esc(:( Einsum.@einsum $ex ))
end

#==

using MacroTools, Einsum, TensorOperations
B = rand(2,3); C = rand(3,2);
A = B * C
@einsum A[i,j] := B[i,k] * C[k,j]
@tensor A[i,j] := B[i,k] * C[k,j]

@einsum A[i,j] := B[i,k] * C[k,zz] # not an error... will be fixed soon, https://github.com/ahwillia/Einsum.jl/pull/31


using TensorSlice


@check! size=true throw=false info

@einsum! A[i,j] := B[i,k] * C[k,j]

@tensor! A[i,j] := B[i,k] * C[k,j]

@check! info   # has ABC and ijk

@check! A[z,j] # compains about z
@check! B[i]   # complains about number

B5 = rand(2,5); C5 = rand(5,2);
@einsum! A[i,j] := B5[i,k] * C5[k,j] # complains about sizes
@tensor! A[i,j] := B5[i,k] * C5[k,j]

@einsum! A[i,j] := B5[i,k] * C5[k,zz] # complains about zz
@tensor! A[i,j] := B5[i,k] * C5[k,zz] # and errors


==#

