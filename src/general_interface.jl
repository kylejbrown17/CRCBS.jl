export
    build_env,
    states_match,
    is_goal,
    wait,
    get_possible_actions,
    get_next_state,
    get_transition_cost,
    get_path_cost,
    get_heuristic_cost,
    violates_constraints,
    check_termination_criteria,

    DefaultState,
    DefaultAction,
    DefaultPathNode,
    DefaultPathCost,
    DefaultEnvironment

################################################################################
######################## General Methods to Implement ##########################
################################################################################

# Other methods to override that are implemented as defaults in common.jl:
# - detect_conflicts!(conflict_table,n1::PathNode,n2::PathNode,i::Int,j::Int,t::Int)

"""
    `build_env(mapf::AbstractMAPF, node::ConstraintTreeNode, idx::Int)`

    Constructs a new low-level search environment for a conflict-based search
    mapf solver
"""
function build_env end

"""
    `state_match(s1::S,s2::S)`

    returns true if s1 and s2 match (not necessarily the same as equal)
"""
function states_match end

"""
    `is_goal(env,s)`

    Returns true if state `s` satisfies the goal condition of environment `env`
"""
function is_goal end

"""
    `wait(s)`

    returns an action that corresponds to waiting at state s
"""
function wait end

"""
    `get_possible_actions(env::E <: AbstractLowLevelEnv{S,A,C}, s::S)`

    return type must support iteration
"""
function get_possible_actions end

"""
    `get_next_state(env::E <: AbstractLowLevelEnv{S,A,C}, s::S, a::A)`

    returns a next state s
"""
function get_next_state end

"""
    `get_transition_cost(env::E <: AbstractLowLevelEnv{S,A,C},s::S,a::A,sp::S)`

    return scalar cost for transitioning from `s` to `sp` via `a`
"""
function get_transition_cost end

"""
    `get_path_cost(env::E <: AbstractLowLevelEnv{S,A,C},path::Path{S,A,C})`

    get the cost associated with a search path so far
"""
function get_path_cost end

"""
    `get_heuristic_cost(env::E <: AbstractLowLevelEnv{S,A,C},state::S)`

    get a heuristic "cost-to-go" from `state`
"""
function get_heuristic_cost end

"""
    `violates_constraints(env::E <: AbstractLowLevelEnv{S,A,C},
        path::Path{S,A,C},s::S,a::A,sp::S)`

    returns `true` if taking action `a` from state `s` violates any constraints
    associated with `env`
"""
function violates_constraints end

"""
    `check_termination_criteria(env::E <: AbstractLowLevelEnv{S,A,C}, cost,
        path::Path{S,A,C}, s::S)`

    returns true if any termination criterion is satisfied
"""
function check_termination_criteria end

# Some default types for use later
struct DefaultState end
struct DefaultAction end
struct DefaultPathCost <: AbstractCostModel{Float64} end
wait(DefaultState) = DefaultAction()
get_next_state(s::DefaultState,a::DefaultAction) = DefaultState()
get_next_state(env,s::DefaultState,a::DefaultAction) = DefaultState()
const DefaultPathNode = PathNode{DefaultState,DefaultAction}
struct DefaultEnvironment <: AbstractLowLevelEnv{DefaultState,DefaultAction,DefaultPathCost} end
