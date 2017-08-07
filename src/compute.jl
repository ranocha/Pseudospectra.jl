#=
Computational kernels for pseudospectra computations.

This file is part of Pseudospectra.jl, whose LICENSE file applies.

Julia implementation
Copyright (c) 2017 Ralph A. Smith

Portions derived from EigTool:
 Copyright (c) 2002-2014, The Chancellor, Masters and Scholars
 of the University of Oxford, and the EigTool Developers. All rights reserved.
 EigTool is maintained on GitHub:  https://github.com/eigtool
=#

# normally hardwired, but change to get test coverage w/o huge problems
# or to get reference solutions for comparison.
type ComputeThresholds
    minlancs4psa::Int # use SVD for n < this
    maxstdqr4hess::Int # use HessQR for n > this (in rectangular case)
    minnev::Int # number of ew's to acquire for projection
end
const psathresholds = ComputeThresholds(55,200,20)

"""
    psa_compute(T,eigA,opts,S=I) -> (Z,x,y,levels,err,Tproj,eigAproj,algo)

Compute pseudospectra of a (decomposed) matrix.

Uses a modified version of L.Trefethen's `psa` code
(Acta Numerica 1999). The matrix `T` should be upper triangular (e.g. from
a call to `schur()`); otherwise less efficient methods are used.

# Arguments
- `T`:      input matrix
- `S=I`:    2nd matrix, if rectangular and problem is now generalised
- `eigA`:   eigenvalues of the matrix, also produced by `schur()`
- `opts::Dict{Symbol,Any}`: holding options. Keys used here are as follows:
  - `:npts`: grid will have npts*npts nodes (REQUIRED)
  - `:levels::Vector{Real}` `log10(ϵ)` for the desired ϵ levels; default depends on actual levels in contour plot
  - `:ax`: axis on which to plot `[min_real, max_real, min_imag, max_imag]` (REQUIRED)
  - `:re_calc_lev`: automatically recompute ϵ levels? Default: true
  - `:Aisreal`: is the input matrix real (symmetric (pseudo)spectra)? This is needed because `T` could be complex even if `A` was real. Default: true
  - `:proj_lev`: the proportion by which to extend the axes in all directions before projection. If negative, exclude subspace of eigenvalues smaller than inverse fraction. Default: ∞ (i.e., no projection)

Note: projection is only done for square, dense matrices.  Projection for
sparse matrices may be handled (outside this function) by a Krylov method
which reduces the matrix to a projected Hessenberg form before invoking
`psa_compute`.

# Outputs:
- `Z`         the singular values over the grid
- `x`         the x coordinates of the grid lines
- `y`         the y coordinates of the grid lines
- `levels`    the levels used for the contour plot (if automatically calculated)
- `err`       an error flag, used if automatic level creation failed:
  - 0:  No error
  - -1:  No levels in range specified (either manually, or if matrix too normal to show levels)
  - -2:  Matrix so non-normal, only zero singular values everywhere
  - -3:  Computation cancelled
- `Tproj`:     the projected matrix (an alias to `T` if no projection was done)
- `eigAproj`:  eigenvalues projected onto
- `algo::Symbol`: indicates which algorithm was used
"""
function psa_compute(Targ, eigA, opts, S=I; myprintln=println, mywarn=warn,
                     psatol = 1e-5)

    m,n = size(Targ)
    eigAproj = copy(eigA) # default
    if isa(S,UniformScaling)
        ms,ns = 1,1
    else
        ms,ns = size(S)
    end
    comp_opts = Dict{Symbol,Any}()
    if !haskey(opts,:recompute_levels)
        comp_opts[:recompute_levels] = false
    end
    if haskey(opts,:levels)
        levels = opts[:levels]
        if length(levels) == 1
            levels = levels * ones(Int,2)
        end
    else
        levels = -8:-1
        comp_opts[:recompute_levels] = true
    end
    if isempty(get(opts,:ax,zeros(0)))
        error("Axis opts[:ax] must be specified for pseudospectrum computation")
    end

    all_opts = merge(comp_opts, opts)

    ax = all_opts[:ax]
    proj_lev = get(all_opts,:proj_lev,Inf)
    re_calc_lev = all_opts[:recompute_levels]
    verbosity = get(all_opts,:verbosity,1)

    npts = all_opts[:npts]
    if all_opts[:scale_equal]
        y_dist = ax[4]-ax[3]
        x_dist = ax[2]-ax[1]
        if x_dist > y_dist
            x_npts = npts
            y_npts = max(5,ceil(Int,y_dist/x_dist*npts))
        else
            y_npts = npts
            x_npts = max(5,ceil(Int,x_dist/y_dist*npts))
        end
    else
        x_npts = npts
        y_npts = npts
    end
    if all_opts[:real_matrix] && ax[4] > 0 && ax[3] < 0
        y, n_mirror_pts = shift_axes(ax,y_npts)
    else
        n_mirror_pts = 0
        y = collect(linspace(ax[3],ax[4],y_npts))
    end
    x = collect(linspace(ax[1],ax[2],x_npts))
    lx = length(x) # why??
    ly = length(y)
    Z = ones(ly,lx)+Inf

    # Trefethen/Wright projection scheme:
    if !issparse(Targ) && n==m
        # restrict to interesting subspace by ignoring eigenvectors whose
        # eigenvalues lie outside rectangle around current axes
        axis_w = ax[2]-ax[1]
        axis_h = ax[4]-ax[3]
        if proj_lev >= 0
            proj_w = axis_w * proj_lev
            proj_h = axis_h * proj_lev
        else
            proj_size = -1 / proj_lev
        end
        np = 0
        ew_range = ax
        # iteratively extend range until 20 (or all) ews are included
        if m > psathresholds.minnev
            local selection
            while np < psathresholds.minnev
                if proj_lev >= 0
                    ew_range = [ew_range[1] - proj_w, ew_range[2] + proj_w,
                                ew_range[3] - proj_h, ew_range[4] + proj_h]
                    selection = find((real(eigA) .> ew_range[1])
                                     .& (real(eigA) .< ew_range[2])
                                     .& (imag(eigA) .> ew_range[3])
                                     .& (imag(eigA) .< ew_range[4]))
                else
                    selection = find(abs.(eigA) .> proj_size)
                    proj_size *= (1/2)
                end
                np = length(selection)
                if proj_lev == 0
                    # restrict to ews visible in window
                    break
                end
            end

        else
            np = m
        end
        # if no need to project (all ews in range)
        if m == np
            wb_offset = 0.0
            m = size(Targ,1)
            # if !opts[:no_waitbar]
            # TODO: post waitbar
            # end
            eigAproj = copy(eigA)
            Tproj = Targ # no mutation, so just dup binding
        else
            wb_offset = 0.2
            if verbosity > 1
                println("projection reduces rank $m -> $np")
            end
            m = np
            n = np
            # restrict eigenvalues and matrix
            eigAproj = eigA[selection]

            Tproj = copy(Targ)
            # if we have some eigenvalues in our window
            if m>0
                # TODO: post waitbar

                # do the projection
                for i=1:m
                    for k=selection[i]-1:-1:i
                        G,r = givens(conj(Tproj[k,k+1]),
                                     conj(Tproj[k,k]-Tproj[k+1,k+1]),
                                     k+1,k)
                        A_mul_Bc!(Tproj,G)
                        A_mul_B!(G,Tproj)
                    end
                    # TODO: update waitbar
                    # TODO: check for pause ll 291ff
                    # TODO: check for stop/cancel
                end
                Tproj = triu(Tproj[1:m,1:m])
            end
        end
    else
        Tproj = Targ
        wb_offset = 0
        # TODO: post waitbar
    end # projection branch

    # compute resolvent norms

    already_timed = false
    ttime = 0 # holds total time spent on LU and Lanczos so far
    # TODO: msgbar_handle = ??
    first_time = true
    prevtstr = ""
    local no_est_time, progmeter

    Tc = complex(eltype(Targ))

    maxit = 99 # bound on Lanczos iterations

    if issparse(Targ)
        algo = :sparse_direct
        Tproj = Targ
        # reverse order so first row is likely to have a complex gridpt
        # (better timing for LU)
        for j=ly:-1:1
            # TODO: update waitbar
            # wb_offset+(1-wb_offset)*(ly-j)/ly

            # TODO: check for pause

            # TODO: check for stop/cancel

            # loop over points in x-direction
            for k=1:lx
                zpt = x[k] + y[j]*im
                t0 = time()
                F = lufact(Targ - zpt*S)
                σold = 0
                qold = zeros(m)
                β = 0
                H = zeros(1,1)+0im
                q = normalize!(randn(n) + randn(n)*im)
                w = similar(q)
                v = similar(q)
                local σ
                for l=1:maxit
                    A_ldiv_B!(w,F,q)
#                    println("sizes w,q,v: ",size(w)," ",size(q)," ",size(v))
                    Ac_ldiv_B!(v,F,w)
                    v = v - β * qold
                    α = real(vecdot(q,v))
                    v = v - α * q
                    β = norm(v)
                    qold = q
                    q = v * (1 / β)
                    Hold = H
                    H = zeros(Tc,l+1,l+1)
                    copy!(view(H,1:l,1:l),Hold)
                    H[l+1,l] = β
                    H[l,l+1] = β
                    H[l,l] = α
                    # calculate eigenvalues of H
                    # if error is too big, just set a large value
                    try
                        HEF = eigfact(H[1:l,1:l])
                        σ = maximum(HEF.values)
                    catch JE
                        σ = 1e308
                        break
                    end
                    if (abs(σold / σ - 1)) < 1e-3
                        break
                    end
                    σold = σ
                end
                Z[j,k] = 1/sqrt(σ)

                # set message if we haven't already done so
                if !already_timed
                    if first_time
                        # we skip timing first point since it likely
                        # includes overhead
                        first_time = false
                    else
                        ttime = time() - t0
                        total_time = ttime*lx*ly
                        no_est_time = (total_time < 10)
                        if !no_est_time
                            if myprintln == println
                                progmeter = Progress(ly,1,
                                                     "Computing pseudospectra...", 20)
                            else
                                # double second pt time to account for first
                                ttime = ttime * 2
                                total_time,timestr = prettytime(total_time)
                                the_message = (myname *
                                               ": estimated remaining time is "
                                               * timestr)
                                myprintln(the_message)
                                prevtstr = timestr
                            end
                            already_timed = true
                        end
                    end
                else
                    ttime = ttime + time() - t0
                end
            end # for k=1:lx
            if !no_est_time
                if myprintln == println
                    update!(progmeter,ly-j+1)
                else
                    total_time = ttime * (j-1) / (ly-j+1)
                    total_time,timestr = prettytime(total_time)
                    if (total_time > 0) && (timestr != prevtstr)
                        the_message = (myname * ": estimated remaining time is "
                                       * timestr)
                        myprintln(the_message)
                        prevtstr = timestr
                    end
                end
                    # drawnow
            end
        end
    else # matrix is dense
        step = get_step_size(m,ly,:psacore)
        for j=ly:-step:1
            # TODO: check for pause
            # TODO: check for cancel

            last_y = max(j-step+1,1)
            # if !opts[:no_waitbar]
            # TODO: post waitbar
            #  end
            q = randn(n) + randn(n)*im
            q = q / norm(q)
            t0 = time()
            Z[j:-1:last_y,:],algo = psacore(Tproj,S,q,x,y[j:-1:last_y],
                                       m-n+1; tol=psatol)

            if !already_timed
                if first_time
                    # we skip timing first batch since it likely
                    # includes codegen overhead
                    first_time = false
                else
                    ttime = time() - t0
                    total_time = ttime * ceil(ly/step)
                    no_est_time = (total_time < 10)
                    if !no_est_time
                        if myprintln == println
                            progmeter = Progress(ly,1,
                                                 "Computing pseudospectra...", 20)
                        else
                            ttime = ttime * 2 # account for first batch
                            total_time,timestr = prettytime(total_time)
                            the_message = (myname *
                                           ": estimated remaining time is "
                                           * timestr)
                            myprintln(the_message)
                            prevtstr = timestr
                        end
                        already_timed = true
                    end
                end
            else # already timed
                ttime = ttime + time() - t0
                if !no_est_time
                    if myprintln == println
                        update!(progmeter, ly-j+1)
                    else
                        total_time = ttime * ((floor((j-1)/step))
                                              /(ceil(ly/step) - floor((j-1)/step)))
                        total_time, timestr = prettytime(total_time)
                        if (total_time > 0) && (timestr != prevtstr)
                            the_message = (myname *
                                           ": estimated remaining time is "
                                           * timestr)
                            myprintln(the_message)
                            prevtstr = timestr
                        end
                    end
                end
            end # timing
        end # ly loop
    end # if sparse/dense

    # if !opts[:no_waitbar]
    # TODO: flash done and close
    # end

    # map data (and y) if accounting for symmetry
    if n_mirror_pts < 0
        # bottom half is master
        Z = vcat(Z,flipdim(Z[end+n_mirror_pts+1:end,:],1))
        y = vcat(y,-reverse(y[end+n_mirror_pts+1:end]))
    else
        if y[1] != 0
            Z = vcat(flipdim(Z[1:n_mirror_pts,:],1),Z)
            y = vcat(-reverse(y[1:n_mirror_pts]),y)
        else
            Z = vcat(flipdim(Z[2:n_mirror_pts+1,:],1),Z)
            y = vcat(-reverse(y[2:n_mirror_pts+1]),y)
        end
    end
    ps_tiny = 10*sqrt(realmin(eltype(Z)))
    (verbosity > 1) && println("range of Z: ",extrema(Z))
    clamp!(Z,ps_tiny,Inf)

    err = 0
    # maybe recalc levels
    if re_calc_lev
        levels,err = recalc_levels(Z,ax)
        if err != 0
            if err == -1
                mywarn("Range too small---no contours to plot. Refine grid or zoom out.")
            elseif err == -2
                mywarn("Matrix too non-normal---resolvent norm is "
                * "computationally infinite within current axes. Zoom out!")
            end
            return Z,x,y,levels,err,Tproj,eigAproj,algo
        end
    else
        # check that user-supplied levels will plot something
        if ((minimum(levels) > log10(maximum(Z)))
            | (maximum(levels) < log10(minimum(Z))))
            levels, err = recalc_levels(Z,ax)
            mywarn("No contours to plot in requested range; 'Smart' levels used.")
            return Z,x,y,levels,err,Tproj,eigAproj,algo
        end
    # check range of Z
        if minimum(levels) < log10(ps_tiny)+1
            mywarn("Smallest level allowed by machine precision reached; "
            * "levels may be inaccurate.")
        end
    end
    return Z,x,y,levels,err,Tproj,eigAproj,algo
end

"""
    psacore(T,S,q,x,y,bw;tol=1e-5) -> Z,algo

Compute pseudospectra of a dense triangular matrix

# Arguments
- `T::Matrix{Number}`: long-triangular matrix whose pseudospectra to compute
- `S`: 2nd matrix from generalised pencil `zS-T`. Set to `I` if
           the problem is not generalised
- `q::Vector{Number}`: starting vector for the inverse-Lanczos iteration
           (the same vector is used to start each point in the
           grid defined by `x` and `y`). `q` **must be normalised to
           have unit length.**
- `x::Vector{Real}`: real-part grid to compute the pseudospectra over
- `y::Vector{Real}`: imaginary-part grid to compute the pseudospectra over
- `tol::Real=1e-5`:  tolerance to use to determine when to stop the
           inverse-Lanczos iteration
- `bw::Int`: bandwidth of the input matrix

# Result
- `Z::Matrix{Real}`: the singular values corresponding to the grid points `x` and `y`.
- `algo::Symbol`: indicates algorithm used
"""
function psacore(T, S, q0, x, y, bw; tol = 1e-5, mywarn=warn)
    if isreal(T)
        Twork = T .+ 0.0im
    else
        Twork = copy(T)
    end
    lx = length(x)
    ly = length(y)
    m,n = size(Twork)

    if m<n
        throw(ArgumentError("Matrix size must be m x n with m >= n"))
    end

    use_eye =  isa(S,UniformScaling)
    if !use_eye
        ms,ns = size(S)
        if (ms != m) || (ns != n)
            throw(ArgumentError("Dimension mismatch for S & T"))
        end
    end

    Z = zeros(ly,lx)
    diaga = diag(Twork)
    cdiaga = conj(diaga)

    # for small matrices just use SVD
    if n < psathresholds.minlancs4psa
        algo = :SVD
        if use_eye
            for j=1:ly
                for k=1:lx
                    zpt = x[k] + y[j]*im
                    Twork[1:m+1:end] = diaga - zpt
                    F = svdfact(Twork)
                    Z[j,k] = minimum(F[:S])
                end
            end
        else
            for j=1:ly
                for k=1:lx
                    zpt = x[k] + y[j]*im
                    A = Twork - zpt*S
                    F = svdfact(A)
                    Z[j,k] = minimum(F[:S])
                end
            end
        end
    else
        qt = copy(q0)
        maxit = 99
        H = zeros(maxit+1,maxit+1)
        if m==n
            T1 = copy(Twork)
            T2 = T1'
        end
        unwarned = true
        for j=1:ly
            for k=1:lx
                zpt = x[k]+y[j]*im
                if m != n
                    if use_eye
                        Twork[1:m+1:end] = diaga - zpt
                        T1 = copy(Twork)
                    else
                        T1 = Twork - zpt*S
                    end
                    # for large rectangular Hessenberg, use HessQR algorithm
                    if (bw == 2) && (m > psathresholds.maxstdqr4hess)
                        algo = :HessQR
                        for jj=1:n-1
                            # DEVNOTE: not using A_mul_B!(G,T1)
                            # because we don't want to mutate top of T1
                            G,r = givens(T1[jj,jj],T1[jj+1,jj],1,2)
                            T1[jj:jj+1,jj:end] = G * T1[jj:jj+1,jj:end]
                        end
                    else
                        Qtmp,T1 = qr(T1)
                        algo = :rect_qr
                    end
                    T1 = triu(T1[1:n,1:n])
                    T2 = T1'
                else # square
                    algo = :sq_lanc
                    T1[1:m+1:end] = diaga - zpt
                    T2[1:m+1:end] = cdiaga - zpt'
                end
                q = copy(qt)
                qold = zeros(n)
                β = 0.0
                σold = 0.0
                local σ
                #T2t = LowerTriangular(T2)
                #T1t = UpperTriangular(T1)
                for l=1:maxit
                    v = T1 \ (T2 \ q) - β * qold
                    # this should be identical and faster, but fails. Why?
                    # v = T1t \ (T2t \ q) - β * qold
                    α = real(vecdot(q,v)) # (q' * v)
                    v = v - α * q
                    β = norm(v)
                    qold = copy(q)
                    q = v / β
                    H[l+1,l] = β
                    H[l,l+1] = β
                    H[l,l] = α
                    try
                        d,v = eig(H[1:l,1:l])
                        σ = maximum(d)
                    catch JE
                        if unwarned
                            # println("H:")
                            # display(H[1:l,1:l])
                            # println()
                            mywarn("σ-min set to smallest possible value.")
                            unwarned = false
                        end
                        σ = 1e308
                        break
                    end
                    if (abs(σold / σ - 1) < tol || β == 0)
                        break
                    end
                    σold = σ
                end
                Z[j,k] = 1/sqrt(σ)
            end
        end
    end # svd/lanczos branch
    return Z,algo
end