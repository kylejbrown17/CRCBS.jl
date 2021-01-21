# Profiling

To run the suite of experiments described in the [ICRA paper](https://arxiv.org/abs/2006.08845), 
run the script below (if you wish to use [Gurobi](https://www.gurobi.com/downloads/), 
you'll need to obtain a license and install [Gurobi.jl](https://github.com/jump-dev/Gurobi.jl).

```julia
# copied from CRCBS/scripts/icra_experiments.jl
using CRCBS 
# NOTE that the experiments described in "Optimal Sequential Task Assignment and 
# Path Finding for Multi-Agent Robotic Assembly Planning", Brown et al. 
# were performed using Gurobi as the black box MILP solver. To use the default
# (GLPK), simply comment out the following two lines.
using Gurobi
set_default_milp_optimizer!(Gurobi.Optimizer)

## ICRA experiments
# You may want to redefine base_dir
# -------------------------- #
base_dir            = joinpath("/scratch/task_graphs_experiments")
# -------------------------- #
problem_dir         = joinpath(base_dir,"pctapf_problem_instances")
base_results_path   = joinpath(base_dir,"pctapf_results")

feats = [
    RunTime(),
    FeasibleFlag(),
    OptimalFlag(),
    OptimalityGap(),
    SolutionCost(),
    PrimaryCost(),
    SolutionAdjacencyMatrix(),
]
solver_configs = [
    (
        solver = NBSSolver(
            assignment_model = CRCBSMILPSolver(AssignmentMILP()),
            path_planner = CBSSolver(ISPS()),
            ),
        results_path = joinpath(base_results_path,"AssignmentMILP"),
        feats = feats,
        objective = MakeSpan(),
    ),
]

base_config = Dict(
    :env_id => "env_2",
    :num_trials => 16,
    :max_parents => 3,
    :depth_bias => 0.4,
    :dt_min => 0,
    :dt_max => 0,
    :dt_collect => 0,
    :dt_deliver => 0,
)
size_configs = [Dict(:M => m, :N => n) for (n,m) in Base.Iterators.product(
    [10,20,30,40],[10,20,30,40,50,60]
)][:]
problem_configs = map(d->merge(d,base_config), size_configs)

# loader = PCTA_Loader() # to test task assignment only
loader = PCTAPF_Loader()
add_env!(loader,"env_2",init_env_2())
write_problems!(loader,problem_configs,problem_dir)
for solver_config in solver_configs
    set_runtime_limit!(solver_config.solver,100)
    warmup(loader,solver_config,problem_dir)
    run_profiling(loader,solver_config,problem_dir)
end
```