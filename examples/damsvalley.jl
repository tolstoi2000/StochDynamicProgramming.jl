#############################################################################
# Solve a hydro-electric dam valley problem where each dam outflow is an inflow
# of the next dam with additional quadratic final cost
#
# This example have two features :
# -- multidimensional stock
# -- final quadratic costs
#############################################################################
##################################################
# Set a seed for reproductability:
srand(2713)

using StochDynamicProgramming, JuMP
using Clp

SOLVER = ClpSolver()
##################################################
##################################################
# PROBLEM DEFINITION
##################################################
const N_DAMS = 5    # number of dams in the valley
const N_STAGES = 12 # number of stages in the problem
const N_ALEAS = 10  # discretization of alea

# Cost are negative as we sell the electricity produced by
# dams (and we want to minimize our problem)
const COST = -66*2.7*(1 + .5*(rand(N_STAGES) - .5))

# Constants:
const VOLUME_MAX = 80
const VOLUME_MIN = 0

const CONTROL_MAX = 40
const CONTROL_MIN = 0

# Define initial value of stocks:
const X0 = [40 for i in 1:N_DAMS]

# Dynamic of stocks:

# The problem has the following structure:
# dam1 -> dam2 -> dam3 -> ... -> dam N
# We need to define the corresponding dynamic:
Bu = zeros(N_DAMS,N_DAMS)
for i in 1:N_DAMS
     Bu[i,i]= -1
end
for i in 1:N_DAMS-1
     Bu[i+1,i]= 1
end
const B = [Bu Bu]
const A = eye(N_DAMS)
# Define dynamic of the dam: x_{t+1}=Ax_t + Bu_t + w_t
# here u_t = [u_turbined u_spilled], where u_spilled is not valorized
# for each dam we thus have x_{t+1}^i = x_t^i - (u_turbined^i + u_spilled^i) + (u_turbined^{i+1} + u_spilled^{i+1})
function dynamic(t, x, u, w)
    return A*x + B*u + w
end

# Define cost corresponding to each timestep:
function cost_t(t, x, u, w)
    return COST[t] * sum(u[1:N_DAMS])
end

# We define here final cost a quadratic problem
# we penalize the final costs if it is greater than 40.
function final_cost_dams!(model, m)
    # Here, model is the optimization problem at time T - 1
    # so that xf (x future) is the final stock
    alpha = JuMP.getvariable(m, :alpha)
    w = JuMP.getvariable(m, :w)
    x = JuMP.getvariable(m, :x)
    u = JuMP.getvariable(m, :u)
    xf = JuMP.getvariable(m, :xf)
    @variable(m,z[1:N_DAMS] >= 0)
    @constraint(m, alpha == 0.) #FIXME justify
    @constraint(m, z + xf .>= 40)
    @objective(m, Min, model.costFunctions(model.stageNumber-1, x, u, w) + 500.*sum(xf[i]*xf[i] for i=1:N_DAMS))
end

##################################################
# SDDP parameters:
##################################################
# Number of forward pass:
const FORWARD_PASS = 10.
const EPSILON = .01
# Maximum number of iterations
const MAX_ITER = 40
##################################################

"""Build probability distribution at each timestep.
Return a Vector{NoiseLaw}"""
function generate_probability_laws()
    laws = Vector{NoiseLaw}(N_STAGES-1)
    # uniform probabilities:
    proba = 1/N_ALEAS*ones(N_ALEAS)
    for t=1:N_STAGES-1
        support = rand(0:9, N_DAMS, N_ALEAS)
        laws[t] = NoiseLaw(support, proba)
    end
    return laws
end

"""Instantiate the problem."""
function init_problem()
    aleas = generate_probability_laws()

    x_bounds = [(VOLUME_MIN, VOLUME_MAX) for i in 1:N_DAMS]
    u_bounds = vcat([(CONTROL_MIN, CONTROL_MAX) for i in 1:N_DAMS], [(0., 200) for i in 1:N_DAMS]);
    model = LinearSPModel(N_STAGES, u_bounds,
                          X0, cost_t,
                          dynamic, aleas,
                          Vfinal=final_cost_dams!)

    # Add bounds for stocks:
    set_state_bounds(model, x_bounds)

    params = SDDPparameters(SOLVER,
                            passnumber=FORWARD_PASS,
                            compute_ub=10,
                            gap=EPSILON,
                            max_iterations=MAX_ITER)
    return model, params
end

# Solve the problem:
model, params = init_problem()
sddp = @time solve_SDDP(model, params, 2)
