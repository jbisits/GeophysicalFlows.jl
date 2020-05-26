module MultilayerQG

export
  fwdtransform!,
  invtransform!,
  streamfunctionfrompv!,
  pvfromstreamfunction!,
  updatevars!,

  set_q!,
  set_ψ!,
  energies,
  fluxes

using
  FFTW,
  LinearAlgebra,
  Reexport

@reexport using FourierFlows

using LinearAlgebra: mul!, ldiv!
using FFTW: rfft, irfft
using FourierFlows: getfieldspecs, varsexpression, parsevalsum, parsevalsum2, superzeros

nothingfunction(args...) = nothing

"""
    Problem(; parameters...)

Construct a multi-layer QG problem.
"""
function Problem(;
    # Numerical parameters
          nx = 128,
          Lx = 2π,
          ny = nx,
          Ly = Lx,
          dt = 0.01,
    # Physical parameters
     nlayers = 2,                       # number of fluid layers
          f0 = 1.0,                     # Coriolis parameter
           β = 0.0,                     # y-gradient of Coriolis parameter
           g = 1.0,                     # gravitational constant
           U = zeros(ny, nlayers),      # imposed zonal flow U(y) in each layer
           H = [0.2, 0.8],              # rest fluid height of each layer
           ρ = [4.0, 5.0],              # density of each layer
         eta = zeros(nx, ny),           # topographic PV
    # Bottom Drag and/or (hyper)-viscosity
           μ = 0.0,
           ν = 0.0,
          nν = 1,
    # Timestepper and eqn options
     stepper = "RK4",
      calcFq = nothingfunction,
      linear = false,
           T = Float64)

   grid = TwoDGrid(nx, Lx, ny, Ly; T=T)
   params = Params(nlayers, T.(g), T.(f0), T.(β), T.(ρ), T.(H), T.(U), T.(eta), T.(μ), T.(ν), nν, grid, calcFq=calcFq)
   vars = calcFq == nothingfunction ? Vars(grid, params) : ForcedVars(grid, params)
   eqn = linear ? LinearEquation(params, grid) : Equation(params, grid)

  FourierFlows.Problem(eqn, stepper, dt, grid, vars, params)
end

abstract type BarotropicParams <: AbstractParams end

struct Params{T} <: AbstractParams
  # prescribed params
   nlayers :: Int            # Number of fluid layers
         g :: T              # Gravitational constant
        f0 :: T              # Constant planetary vorticity
         β :: T              # Planetary vorticity y-gradient
         ρ :: Array{T,3}     # Array with density of each fluid layer
         H :: Array{T,3}     # Array with rest height of each fluid layer
         U :: Array{T,3}     # Array with imposed constant zonal flow U(y) in each fluid layer
       eta :: Array{T,2}     # Array containing topographic PV
         μ :: T              # Linear bottom drag
         ν :: T              # Viscosity coefficient
        nν :: Int            # Hyperviscous order (nν=1 is plain old viscosity)
   calcFq! :: Function       # Function that calculates the forcing on QGPV q

  # derived params
        g′ :: Array{T,1}     # Array with the reduced gravity constants for each fluid interface
        Qx :: Array{T,3}     # Array containing x-gradient of PV due to eta in each fluid layer
        Qy :: Array{T,3}     # Array containing y-gradient of PV due to β, U, and eta in each fluid layer
         S :: Array{T,4}     # Array containing coeffients for getting PV from  streamfunction
      invS :: Array{T,4}     # Array containing coeffients for inverting PV to streamfunction
  rfftplan :: FFTW.rFFTWPlan{T,-1,false,3}  # rfft plan for FFTs
end

struct SingleLayerParams{T} <: BarotropicParams
  # prescribed params
         β :: T              # Planetary vorticity y-gradient
         U :: Array{T,3}     # Imposed constant zonal flow U(y)
       eta :: Array{T,2}     # Array containing topographic PV
         μ :: T              # Linear bottom drag
         ν :: T              # Viscosity coefficient
        nν :: Int            # Hyperviscous order (nν=1 is plain old viscosity)
   calcFq! :: Function       # Function that calculates the forcing on QGPV q

  # derived params
        Qx :: Array{T,3}     # Array containing x-gradient of PV due to eta
        Qy :: Array{T,3}     # Array containing meridional PV gradient due to β, U, and eta
  rfftplan :: FFTW.rFFTWPlan{T,-1,false,3}  # rfft plan for FFTs
end

function Params(nlayers, g, f0, β, ρ, H, U::Array{T,2}, eta, μ, ν, nν, grid::AbstractGrid{T}; calcFq=nothingfunction, effort=FFTW.MEASURE) where T

   ny, nx = grid.ny , grid.nx
  nkr, nl = grid.nkr, grid.nl
   kr, l  = grid.kr , grid.l

  U = reshape(U, (1, ny, nlayers))
  
  Uyy = repeat(irfft( -l.^2 .* rfft(U, [1, 2]),  1, [1, 2]), outer=(1, 1, 1))
  Uyy = repeat(Uyy, outer=(nx, 1, 1))

  etah = rfft(eta)
  etax = irfft(im * kr .* etah, nx)
  etay = irfft(im * l  .* etah, nx)

  Qx = zeros(nx, ny, nlayers)
  @views @. Qx[:, :, nlayers] += etax

  Qy = zeros(nx, ny, nlayers)
  Qy = @. β - Uyy
  @views @. Qy[:, :, nlayers] += etay

  rfftplanlayered = plan_rfft(Array{T,3}(undef, grid.nx, grid.ny, nlayers), [1, 2]; flags=effort)
  
  if nlayers==1
    return SingleLayerParams{T}(β, U, eta, μ, ν, nν, calcFq, Qx, Qy, rfftplanlayered)
  
  else # if nlayers≥2
    
    ρ = reshape(ρ, (1,  1, nlayers))
    H = reshape(H, (1,  1, nlayers))

  # g′ = g*(ρ[2:nlayers]-ρ[1:nlayers-1]) ./ ρ[1:nlayers-1] # definition match PYQG
    g′ = g * (ρ[2:nlayers] - ρ[1:nlayers-1]) ./ ρ[2:nlayers] # correct definition

    Fm = @. f0^2 / ( g′*H[2:nlayers  ] )
    Fp = @. f0^2 / ( g′*H[1:nlayers-1] )

    @views @. Qy[:, :, 1] -= Fp[1] * ( U[:, :, 2] - U[:, :, 1] )
    for j = 2:nlayers-1
      @. Qy[:, :, j] -= Fp[j] * ( U[:, :, j+1] - U[:, :, j] ) + Fm[j-1] * ( U[:, :, j-1] - U[:, :, j] )
    end
    @views @. Qy[:, :, nlayers] -= Fm[nlayers-1] * ( U[:, :, nlayers-1] - U[:, :, nlayers] )

    S = Array{T}(undef, (nkr, nl, nlayers, nlayers))
    calcS!(S, Fp, Fm, grid)

    invS = Array{T}(undef, (nkr, nl, nlayers, nlayers))
    calcinvS!(invS, Fp, Fm, grid)

    return Params{T}(nlayers, g, f0, β, ρ, H, U, eta, μ, ν, nν, calcFq, g′, Qx, Qy, S, invS, rfftplanlayered)
  
  end
end

function Params(nlayers, g, f0, β, ρ, H, U::Array{T,1}, eta, μ, ν, nν, grid::AbstractGrid{T}; calcFq=nothingfunction, effort=FFTW.MEASURE) where T
  
  if length(U) == nlayers
    U = reshape(U, (1, nlayers))
    U = repeat(U, outer=(grid.ny, 1))
  else
    U = reshape(U, (grid.ny, 1))
  end
  
  return Params(nlayers, g, f0, β, ρ, H, U, eta, μ, ν, nν, grid; calcFq=calcFq, effort=effort)
end

Params(nlayers, g, f0, β, ρ, H, U::T, eta, μ, ν, nν, grid::AbstractGrid{T}; calcFq=nothingfunction, effort=FFTW.MEASURE) where T = Params(nlayers, g, f0, β, ρ, H, repeat([U], outer=(grid.ny, 1)), eta, μ, ν, nν, grid; calcFq=calcFq, effort=effort)

numberoflayers(params::P) where P = P<:SingleLayerParams ? 1 : params.nlayers


# ---------
# Equations
# ---------

function hyperdissipation(params, grid::AbstractGrid{T}) where T
  L = Array{Complex{T}}(undef, (grid.nkr, grid.nl, numberoflayers(params)))
  @. L = - params.ν * grid.Krsq^params.nν
  @views @. L[1, 1, :] = 0
  return L
end

function LinearEquation(params, grid::AbstractGrid{T}) where T
  nlayers = numberoflayers(params)
  L = hyperdissipation(params, grid)
  return FourierFlows.Equation(L, calcNlinear!, grid)
end

function Equation(params, grid::AbstractGrid{T}) where T
  nlayers = numberoflayers(params)
  L = hyperdissipation(params, grid)
  return FourierFlows.Equation(L, calcN!, grid)
end


# ----
# Vars
# ----

abstract type BarotropicVars <: AbstractVars end

const physicalvars = [:q, :ψ, :u, :v]
const fouriervars = [ Symbol(var, :h) for var in physicalvars ]
const forcedfouriervars = cat(fouriervars, [:Fqh], dims=1)

varspecs = cat(
  getfieldspecs(physicalvars, :(Array{T,3})),
  getfieldspecs(fouriervars, :(Array{Complex{T},3})),
  dims=1)

forcedvarspecs = cat(
  getfieldspecs(physicalvars, :(Array{T,3})),
  getfieldspecs(forcedfouriervars, :(Array{Complex{T},3})),
  dims=1)

# Construct Vars types
eval(varsexpression(:Vars, physicalvars, fouriervars))
eval(varsexpression(:ForcedVars, physicalvars, forcedfouriervars))

"""
    Vars(g)

Returns the vars for unforced multi-layer QG problem with grid gr.
"""
function Vars(grid::AbstractGrid{T}, params) where T
  nx , ny = grid.nx , grid.ny
  nkr, nl = grid.nkr, grid.nl
  nlayers = numberoflayers(params)
  
  @zeros T (nx, ny, nlayers) q ψ u v
  @zeros Complex{T} (nkr, nl, nlayers) qh ψh uh vh
  
  return Vars(q, ψ, u, v, qh, ψh, uh, vh)
end

"""
    ForcedVars(g)

Returns the vars for forced multi-layer QG problem with grid gr.
"""
function ForcedVars(grid::AbstractGrid{T}, params) where T
  vars = Vars(grid, params)
  nlayers = numberoflayers(params)
  Fqh = zeros(Complex{T}, (grid.nkr, grid.nl, nlayers))
  
  return ForcedVars(getfield.(Ref(vars), fieldnames(typeof(vars)))..., Fqh)
end

fwdtransform!(varh, var, params::AbstractParams) = mul!(varh, params.rfftplan, var)
invtransform!(var, varh, params::AbstractParams) = ldiv!(var, params.rfftplan, varh)

function streamfunctionfrompv!(ψh, qh, params, grid)
  for j=1:grid.nl, i=1:grid.nkr
    @views ψh[i, j, :] .= params.invS[i, j, :, :] * qh[i, j, :]
  end
end

function pvfromstreamfunction!(qh, ψh, params, grid)
  for j=1:grid.nl, i=1:grid.nkr
    @views qh[i, j, :] .= params.S[i, j, :, :] * ψh[i, j, :]
  end
end

function streamfunctionfrompv!(ψh, qh, params::SingleLayerParams, grid)
  @. ψh = -grid.invKrsq * qh
end

function pvfromstreamfunction!(qh, ψh, params::SingleLayerParams, grid)
  @. qh = -grid.Krsq * ψh
end

"""
    calcS!(S, Fp, Fm, grid)

Constructs the stretching matrix S that connects q and ψ: q_{k,l} = S * ψ_{k,l}.
"""
function calcS!(S, Fp, Fm, grid)
  F = Matrix(Tridiagonal(Fm, -([Fp; 0] + [0; Fm]), Fp))
  for n=1:grid.nl, m=1:grid.nkr
     k² = grid.Krsq[m, n]
    Skl = - k²*I + F
    @views S[m, n, :, :] .= Skl
  end
  return nothing
end

"""
    calcinvS!(S, Fp, Fm, grid)

Constructs the inverse of the stretching matrix S that connects q and ψ:
ψ_{k,l} = invS * q_{k,l}.
"""
function calcinvS!(invS, Fp, Fm, grid)
  F = Matrix(Tridiagonal(Fm, -([Fp; 0] + [0; Fm]), Fp))
  for n=1:grid.nl, m=1:grid.nkr
    k² = grid.Krsq[m, n]
    if k² == 0
      k² = 1
    end
    Skl = - k²*I + F
    @views invS[m, n, :, :] .= I / Skl
  end
  @views invS[1, 1, :, :] .= 0
  nothing
end


# -------
# Solvers
# -------

function calcN!(N, sol, t, clock, vars, params, grid)
  nlayers = numberoflayers(params)
  calcN_advection!(N, sol, vars, params, grid)
  @views @. N[:, :, nlayers] += params.μ * grid.Krsq * vars.ψh[:, :, nlayers]   # bottom linear drag
  addforcing!(N, sol, t, clock, vars, params, grid)
  nothing
end

function calcNlinear!(N, sol, t, clock, vars, params, grid)
  nlayers = numberoflayers(params)
  calcN_linearadvection!(N, sol, vars, params, grid)
  @views @. N[:, :, nlayers] += params.μ * grid.Krsq * vars.ψh[:, :, nlayers]   # bottom linear drag
  addforcing!(N, sol, t, clock, vars, params, grid)
  nothing
end

"""
    calcN_advection!(N, sol, vars, params, gir)

Calculates the advection term.
"""
function calcN_advection!(N, sol, vars, params, grid)
  @. vars.qh = sol

  streamfunctionfrompv!(vars.ψh, vars.qh, params, grid)

  @. vars.uh = -im * grid.l  * vars.ψh
  @. vars.vh =  im * grid.kr * vars.ψh

  invtransform!(vars.u, vars.uh, params)
  @. vars.u += params.U                    # add the imposed zonal flow U
  @. vars.q  = vars.u * params.Qx
  fwdtransform!(vars.uh, vars.q, params)
  @. N = -vars.uh                          # -(U+u)*∂Q/∂x

  invtransform!(vars.v, vars.vh, params)
  @. vars.q = vars.v * params.Qy
  fwdtransform!(vars.vh, vars.q, params)
  @. N -= vars.vh                          # -v*∂Q/∂y

  invtransform!(vars.q, vars.qh, params)

  @. vars.u *= vars.q                      # u*q
  @. vars.v *= vars.q                      # v*q

  fwdtransform!(vars.uh, vars.u, params)
  fwdtransform!(vars.vh, vars.v, params)

  @. N -= im * grid.kr * vars.uh + im * grid.l * vars.vh    # -∂[(U+u)q]/∂x-∂[vq]/∂y

  return nothing
end


"""
    calcN_linearadvection!(N, sol, v, p, g)

Calculates the advection term of the linearized equations.
"""
function calcN_linearadvection!(N, sol, vars, params, grid)
  @. vars.qh = sol

  streamfunctionfrompv!(vars.ψh, vars.qh, params, grid)

  @. vars.uh = -im * grid.l  * vars.ψh
  @. vars.vh =  im * grid.kr * vars.ψh

  invtransform!(vars.u, vars.uh, params)
  @. vars.u += params.U                    # add the imposed zonal flow U
  @. vars.q  = vars.u * params.Qx
  fwdtransform!(vars.uh, vars.q, params)
  @. N = -vars.uh                          # -(U+u)*∂Q/∂x

  invtransform!(vars.v, vars.vh, params)
  @. vars.q = vars.v * params.Qy
  fwdtransform!(vars.vh, vars.q, params)
  @. N -= vars.vh                          # -v*∂Q/∂y

  invtransform!(vars.q, vars.qh, params)
  @. vars.u  = params.U
  @. vars.u *= vars.q                      # u*q

  fwdtransform!(vars.uh, vars.u, params)

  @. N -= im * grid.kr * vars.uh           # -∂[U*q]/∂x

  nothing
end

addforcing!(N, sol, t, clock, vars::Vars, params, grid) = nothing

function addforcing!(N, sol, t, clock, vars::ForcedVars, params, grid)
  params.calcFq!(vars.Fqh, sol, t, clock, vars, params, grid)
  @. N += vars.Fqh
  nothing
end


# ----------------
# Helper functions
# ----------------

"""
    updatevars!(prob)

Update `prob.vars` using `prob.sol`.
"""
function updatevars!(prob)
  params, vars, grid, sol = prob.params, prob.vars, prob.grid, prob.sol

  @. vars.qh = sol
  streamfunctionfrompv!(vars.ψh, vars.qh, params, grid)
  @. vars.uh = -im * grid.l  * vars.ψh
  @. vars.vh =  im * grid.kr * vars.ψh

  invtransform!(vars.q, deepcopy(vars.qh), params)
  invtransform!(vars.ψ, deepcopy(vars.ψh), params)
  invtransform!(vars.u, deepcopy(vars.uh), params)
  invtransform!(vars.v, deepcopy(vars.vh), params)
  return nothing
end


"""
    set_q!(prob)

Set the solution `prob.sol` as the transform of `q` and updates variables.
"""
function set_q!(prob, q)
  params, vars, sol = prob.params, prob.vars, prob.sol

  fwdtransform!(vars.qh, q, params)
  @. vars.qh[1, 1, :] = 0
  @. sol = vars.qh

  updatevars!(prob)
  return nothing
end


"""
    set_ψ!(prob)

Set the solution `prob.sol` to correspond to a streamfunction `ψ` and
updates variables.
"""
function set_ψ!(prob, ψ)
  params, vars, grid = prob.params, prob.vars, prob.grid

  fwdtransform!(vars.ψh, ψ, params)
  pvfromstreamfunction!(vars.qh, vars.ψh, params, grid)
  invtransform!(vars.q, vars.qh, params)
  set_q!(prob, vars.q)

  return nothing
end


"""
    energies(prob)

Returns the kinetic energy of each fluid layer KE_1,...,KE_nlayers, and the
potential energy of each fluid interface PE_{3/2},...,PE_{nlayers-1/2}.
"""
function energies(vars, params, grid, sol)
  nlayers = numberoflayers(params)
  KE, PE = zeros(nlayers), zeros(nlayers-1)

  @. vars.qh = sol
  streamfunctionfrompv!(vars.ψh, vars.qh, params, grid)

  @. vars.uh = grid.Krsq * abs2(vars.ψh)
  for j=1:nlayers
    KE[j] = 1/(2*grid.Lx*grid.Ly)*parsevalsum(vars.uh[:, :, j], grid)*params.H[j]/sum(params.H)
  end

  for j=1:nlayers-1
    PE[j] = 1/(2*grid.Lx*grid.Ly)*params.f0^2/params.g′[j]*parsevalsum(abs2.(vars.ψh[:, :, j+1].-vars.ψh[:, :, j]), grid)
  end

  return KE, PE
end

function energies(vars, params::SingleLayerParams, grid, sol)
  @. vars.qh = sol
  streamfunctionfrompv!(vars.ψh, vars.qh, params, grid)
  
  KE = 1/(2*grid.Lx*grid.Ly)*parsevalsum(grid.Krsq .* abs2.(vars.ψh), grid)
  
  return KE
end

energies(prob) = energies(prob.vars, prob.params, prob.grid, prob.sol)

"""
    fluxes(prob)

Returns the lateral eddy fluxes within each fluid layer
lateralfluxes_1,...,lateralfluxes_nlayers and also the vertical eddy fluxes for
each fluid interface verticalfluxes_{3/2},...,verticalfluxes_{nlayers-1/2}
"""
function fluxes(prob)
  vars, params, grid, sol = prob.vars, prob.params, prob.grid, prob.sol
  nlayers = numberoflayers(params)
  
  lateralfluxes, verticalfluxes = zeros(nlayers), zeros(nlayers-1)

  updatevars!(prob)

  @. vars.uh = im * grid.l * vars.uh
  invtransform!(vars.u, vars.uh, params)

  lateralfluxes = (sum( @. params.H * params.U * vars.v * vars.u; dims=(1,2) ))[1, 1, :]
  lateralfluxes *= grid.dx * grid.dy / (grid.Lx * grid.Ly * sum(params.H))

  for j=1:nlayers-1
    verticalfluxes[j] = sum( @views @. params.f0^2 / params.g′[j] * (params.U[: ,:, j] - params.U[:, :, j+1]) * vars.v[:, :, j+1] * vars.ψ[:, :, j] ; dims=(1,2) )[1]
    verticalfluxes[j] *= grid.dx * grid.dy / (grid.Lx * grid.Ly * sum(params.H))
  end

  lateralfluxes, verticalfluxes
end

end # module
