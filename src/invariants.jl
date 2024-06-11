export necromancy

@doc raw"""
    _ghost_invariants(K::AbstractArray{BigFloat})

Internal function to compute numerical approximations to the ghost invariants starting from the array `K` of ghost overlaps.
"""
function _ghost_invariants(K::AbstractArray{BigFloat})
    ords = size(K)
    r, n = length(ords), prod(ords)
    prec = precision(K[1])

    V = Vandermonde{BigFloat}[]
    a = Matrix{BigFloat}[]
    b = Vector{BigFloat}[]
    s = Vector{BigFloat}[]
    for j=1:r
        notj = Tuple( setdiff( 1:r, j) )
        # first compute "l_j".
        for l = 1:n÷ords[j]
            c = dropdims(sum( K.^l ; dims=notj); dims=notj)
            # If these are distinct and nonzero with at least 10 bits above
            # our base precision, then we've found l_j
            if all( abs.([diff(sort(c)); c]) .> BigFloat(2)^(10-prec) )
                push!( V, Vandermonde(c))
                push!( b, V[j] \ circshift(c,-1) )
                break
            end
        end
        # now compute a and s
        # note: s is called "e" in the draft, but that conflicts with e(z).
        # These are the power sums in the c_{j,t,l_j} over each t.
        push!( a, zeros(BigFloat, (ords[j], n÷ords[j])) )
        push!( s, [ sum( (V[j].c).^k ) for k=1:ords[j] ] )
        for l = 1:n÷ords[j]
            x = dropdims(sum( K.^l ; dims=notj); dims=notj)
            a[j][:,l] = V[j] \ x
        end
    end

    return a, b, s
end



@doc raw"""
    necromancy( F::AdmissibleTuple [; max_prec = 2^23, verbose = false])

Compute numerical approximations to the ghost invariants of `F`.
The maximum number of bits used in integer relation finding is set to `max_prec` (default of 1 MB) and `verbose` can be toggled `true` or `false`.

# Examples

Check that the principle SIC in ``d=7`` satisfies the equiangularity conditions.

```jldoctest
julia> d = 7; F = AdmissibleTuple(d)
AdmissibleTuple( d = 7, K = ℚ(√8), q = 2, Q = ⟨1,-6,1⟩, h = 1 )

julia> ψ = necromancy(F);

julia> all([ abs2(ψ'wh(p,ψ)) for p=1:d^2-1] .≈ 1/(d+1))
true
```
"""
function necromancy(F::AdmissibleTuple;
    max_prec::Integer = 2^23,
    overlap_precision_max_tol::Float64 = 1e-6,
    overlap_target_prec::Integer = 30,
    base::Integer = 2,
    verbose::Bool = false)
    # Ensure that we have initialized the class field for F
    ghostclassfield(F)
    signswitch(F)
    hb = lll(maximal_order(F.H)).basis_nf # find an LLL-reduced basis for H
    gb = F.g.(hb) # the Galois-conjugate basis
    eH = real_embeddings(F.H)[1] # fix a real embedding

    # the normal form orders of the Galois group and a maximal p-orbit
    ords, porb = galois_order_orbit(F)
    r, n = length(ords), prod(ords)

    # get a low-precision ghost
    prec = 128
    setprecision(BigFloat, prec; base = 2)
    verbose && println("Computing the ghost.")
    ψ = (verbose ? (@time ghost(F)) : ghost(F) )
    x = zeros(Complex{Float64},F.d)

    # new target precision.
    max_prec < 128 && error("max_prec should be at least 128 bits.")
    while prec ≤ max_prec
        verbose && println("target precision ≥ $prec bits")

        # this is a hack since too much precision makes it hard to converge,
        # and d = 5 is so small that we already overshoot at 256.
        if F.d == 5; prec = 200; end

        # bump up the precision
        verbose && println("Current precision = ",precision(real(ψ[1]))," bits.")
        ψ = precision_bump( ψ, prec; base = 2, verbose = verbose)
        ϕ = circshift(reverse(ψ),1)
        ϕ .*= (F.d+1)/ϕ'ψ # include normalization factors
        verbose && println("new precision = ",precision(real(ψ[1]))," bits")

        # compute the ghost overlaps
        verbose && println("Computing the high-precision ghost overlaps.")
        K = ( verbose ? (@time [ real(ϕ'wh(p,ψ)) for p in porb]) :
                [ real(ϕ'wh(p,ψ)) for p in porb] )

        # compute the ghost invariants
        verbose && println("Computing the ghost invariants.")
        a,b,s = ( verbose ? (@time _ghost_invariants(K)) : _ghost_invariants(K) )

        # sign-switch to the SIC invariants.
        verbose && println("Sign-switching to the SIC invariants.")
        # create a high precision embedding map and sign-switching automorphism
        fH = x -> BigFloat.(real.(evaluation_function( eH, prec).(x)))
        primalbasis = fH.(hb)
        dualbasis   = fH.(gb)
        dual = x -> _dualize( primalbasis, dualbasis, x )
        # sign-switch
        for j=1:r
            a[j] = dual.(a[j])
            b[j] = dual.(b[j])
            s[j] = dual.(s[j])
            s[j] = reverse(pow_to_elem_sym_poly(s[j]))
        end
        # From this point on we are in SIC world.

        # Lower the precision back to standard BigFloat plus a 64-bit buffer.
        setprecision( BigFloat, 320; base=2)

        # if any of the invariants are Nan or Inf, try again.
        finite_invariants  = all(map( x -> all(isfinite.(x)), a))
        finite_invariants &= all(map( x -> all(isfinite.(x)), b))
        finite_invariants &= all(map( x -> all(isfinite.(x)), s))

        if !finite_invariants
            verbose && println("Some invariants were infinite.\n    ...Doubling precision.")
        else
            θ = map( x -> -roots(BigFloat.(x)) , s)

            # Compute c', map to elementary symmetric polynomials
            # then find roots to get K'
            L = Matrix{Complex{BigFloat}}[]
            for j = 1:r
                θprime = [ θ[j][1] ]
                for k = 2:ords[j]
                    push!( θprime, dot( b[j], [ θprime[k-1]^n for n=0:(ords[j]-1) ] ) )
                end
                push!( L, Vandermonde(θprime) * a[j] )
                for t = 1:ords[j]
                    L[j][t,:] = -roots( reverse(pow_to_elem_sym_poly(L[j][t,:])) )
                end
                L[j] = L[j] / sqrt(BigFloat(F.d)+1)
            end

            # now intersect to get x, which is nu up to an unknown Galois action.
            unique_intersections = true
            x = Array{Complex{BigFloat}}(undef,Tuple(ords)...)
            # x = zeros(Complex{BigFloat},Tuple(ords)...)
            for k = 0:n-1
                t = radix(k,ords) .+ 1
                Kt = Tuple([ L[j][t[j],:] for j = 1:r])
                # intersect at 256-bit precision by default
                a = reduce( (x,y) -> _approx_complex_intersection(x,y; prec = 256), Kt)
                if length(a) == 1
                    x[t...] = a[1]
                else
                    verbose && println("Intersection error.\n    Doubling precision.")
                    unique_intersections = false
                    break
                end
            end

            # if intersections are unique, return to the original BigFloat precision
            if unique_intersections
                setprecision( BigFloat, 256; base=2)
                x = complex.( BigFloat.(real.(x)), BigFloat.(imag.(x)) )
                if all(abs.(x[:]) .≈ 1.0)
                    # return x # this will just return the overlap phases
                    verbose && println("All SIC overlaps are phases!")
                    break # break the while loop
                else
                    verbose && println("Some outputs aren't complex phases.\n    Doubling precision.")
                end
            end
        end
        # if we run out of precision, return to standard BigFloat precision and err.
        prec *= 2
        if (prec > max_prec)
            setprecision( BigFloat, 256; base=2)
            error("max_prec exceeded without convergence.")
        end
        # print("\n")
    end # while

    # Now try every shift in the Galois group until one of them gives a SIC
    verbose && println("Now searching through Galois shifts using matrix completion.")
    for k = 0:n-1
        ψ = matrix_completion(circshift(x,radix(k,ords)),F)
        sot = sic_overlap_test(ψ)
        if sot < overlap_precision_max_tol
            verbose && println("Fiducial vector found with all overlaps correct to ≤ $sot.")
            break
        end
    end

    verbose && println("Increasing precision...")
    # need to implement precision bumping for SICs.
    z = re_im_proj(Complex{BigFloat}.(ψ))
    precision_bump!(z, _olp_func, overlap_target_prec; base = base, verbose = verbose)
    ψ = re_im_proj(z)
    return ψ/sqrt(ψ'ψ)
end



@doc """
    _dualize( primal::Vector{T}, dual::Vector{T}, x::T) where T::AbstractFloat

Internal function that takes an `AbstractFloat` number `x`, rounds it into the `primal` basis, then expands it again in the `dual` basis.
If `x` is not faithfully represented in the `primal` basis then the result is unpredictable.
If `primal` and `dual` are related by a galois automorphism `g`, then ideally this outputs an approximation of `g(x)`.
"""
function _dualize( primal::Vector{T}, dual::Vector{T}, x::T) where T<:AbstractFloat
    t = guess_int_null_vec( [ primal; x] )
    return -dot( dual, t[1:end-1] ) / t[end]
end


@doc """
    _approx_complex_intersection(A::AbstractVector, B::AbstractVector; prec::Integer = 256, base::Integer = 2)

Internal function to compute the intersection of two complex lists using a default tolerance of 256 bit precision.
"""
function _approx_complex_intersection(A::AbstractVector, B::AbstractVector; prec::Integer = 256, base::Integer = 2)

    scale = BigInt(base)^prec

    # helper function to scale and round a Complex{BigFloat} to Complex{BigInt}
    function scale_round(z)
        re = round(BigInt, real(z) * scale)
        im = round(BigInt, imag(z) * scale)
        return complex(re, im)
    end

    # scale and round both lists
    rounded_A = Set{Complex{BigInt}}(scale_round.(A))
    rounded_B = Set{Complex{BigInt}}(scale_round.(B))

    # intersection of rounded lists
    intersection_rounded = intersect(rounded_A, rounded_B)

    # convert back to original scale
    intersection = Set{Complex{BigFloat}}()
    for z in intersection_rounded
        # scale back
        original = complex(real(z) / scale, imag(z) / scale)
        push!(intersection, original)
    end

    # convert back to an array before returning
    return collect(intersection)
end
