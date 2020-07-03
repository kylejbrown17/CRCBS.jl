export
    CBS

# CBS submodule
module CBS

using ..CRCBS
using Parameters, LightGraphs, DataStructures

################################################################################
############################### ENVIRONMENT DEF ################################
################################################################################
# State
@with_kw struct State
    vtx::Int        = -1 # vertex of graph
    t::Int          = -1
end
Base.string(s::State) = "(v=$(s.vtx),t=$(s.t))"
# Action
@with_kw struct Action
    e::Edge{Int}    = Edge(-1,-1)
    Δt::Int         = 1
end
Base.string(a::Action) = "(e=$(a.e.src) → $(a.e.dst))"
# LowLevelEnv
@with_kw struct LowLevelEnv{C<:AbstractCostModel,H<:AbstractCostModel,G<:AbstractGraph,T} <: AbstractLowLevelEnv{State,Action,C}
    graph::G                    = Graph()
    constraints::T              = ConstraintTable{PathNode{State,Action}}()
    goal::State                 = State()
    agent_idx::Int              = -1
    # helpers # TODO parameterize LowLevelEnv by heuristic type as well
    heuristic::H                = NullHeuristic() #PerfectHeuristic(graph,Vector{Int}(),Vector{Int}())
    cost_model::C               = SumOfTravelTime()
end
CRCBS.get_cost_model(env::E) where {E<:LowLevelEnv} = env.cost_model
CRCBS.get_heuristic_model(env::E) where {E<:LowLevelEnv} = env.heuristic
# TODO implement a check to be sure that no two agents have the same goal
################################################################################
######################## Low-Level (Independent) Search ########################
################################################################################
# build_env
function CRCBS.build_env(mapf::MAPF{E,S,G}, node::ConstraintTreeNode, idx::Int) where {S,G,E<:LowLevelEnv}
    t_goal = -1
    for constraint in sorted_state_constraints(get_constraints(node,idx))
        sp = get_sp(constraint.v)
        if states_match(mapf.goals[idx], sp)
            # @show s.t, get_time_of(constraint)
            t_goal = max(t_goal,sp.t+1)
        end
    end
    typeof(mapf.env)(
        graph = mapf.env.graph,
        constraints = get_constraints(node,idx),
        goal = State(mapf.goals[idx],t=t_goal),
        agent_idx = idx,
        heuristic = get_heuristic_model(mapf.env),  # TODO update the heuristic model
        cost_model = get_cost_model(mapf.env)       # TODO update the cost model
        )
end
# heuristic
CRCBS.get_heuristic_cost(env::E,s::State) where {E<:LowLevelEnv} = CRCBS.get_heuristic_cost(env,get_heuristic_model(env),s)
function CRCBS.get_heuristic_cost(env::E,h::H,s::State) where {E<:LowLevelEnv,H<:Union{PerfectHeuristic,DefaultPerfectHeuristic}}
    get_heuristic_cost(h, env.goal.vtx, s.vtx)
end
function CRCBS.get_heuristic_cost(env::E,h::H,s::State) where {E<:LowLevelEnv, H<:ConflictTableHeuristic}
    get_heuristic_cost(h, env.agent_idx, s.vtx, s.t)
end

# states_match
CRCBS.states_match(s1::State,s2::State) = (s1.vtx == s2.vtx)
CRCBS.states_match(env::LowLevelEnv,s1::State,s2::State) = (s1.vtx == s2.vtx)
# is_goal
function CRCBS.is_goal(env::LowLevelEnv,s::State)
    if states_match(s, env.goal)
        if s.t >= env.goal.t
            return true
        end
    end
    return false
end
# check_termination_criteria
# CRCBS.check_termination_criteria(env::LowLevelEnv,cost,path,s) = false
# CRCBS.check_termination_criteria(solver,env::LowLevelEnv,cost,s) = iterations(solver) > iteration_limit(solver)
# wait
CRCBS.wait(s::State) = Action(e=Edge(s.vtx,s.vtx))
CRCBS.wait(env::LowLevelEnv,s::State) = Action(e=Edge(s.vtx,s.vtx))
# get_possible_actions
struct ActionIter
    s::Int # source state
    neighbor_list::Vector{Int} # length of target edge list
end
struct ActionIterState
    idx::Int # idx of target node
end
ActionIterState() = ActionIterState(0)
function Base.iterate(it::ActionIter)
    iter_state = ActionIterState(0)
    return iterate(it,iter_state)
end
function Base.iterate(it::ActionIter, iter_state::ActionIterState)
    iter_state = ActionIterState(iter_state.idx+1)
    if iter_state.idx > length(it.neighbor_list)
        return nothing
    end
    Action(e=Edge(it.s,it.neighbor_list[iter_state.idx])), iter_state
end
Base.length(iter::ActionIter) = length(iter.neighbor_list)
CRCBS.get_possible_actions(env::LowLevelEnv,s::State) = ActionIter(s.vtx,outneighbors(env.graph,s.vtx))
# get_next_state
CRCBS.get_next_state(s::State,a::Action) = State(a.e.dst,s.t+a.Δt)
CRCBS.get_next_state(env::LowLevelEnv,s::State,a::Action) = get_next_state(s,a)
# get_transition_cost
function CRCBS.get_transition_cost(env::E,c::TravelTime,s::State,a::Action,sp::State) where {E<:LowLevelEnv}
    return cost_type(c)(a.Δt)
end
function CRCBS.get_transition_cost(env::E,c::C,s::State,a::Action,sp::State) where {E<:LowLevelEnv,C<:ConflictCostModel}
    return get_conflict_value(c, env.agent_idx, sp.vtx, sp.t)
end
function CRCBS.get_transition_cost(env::E,c::TravelDistance,s::State,a::Action,sp::State) where {E<:LowLevelEnv}
    return (s.vtx == sp.vtx) ? 0.0 : 1.0
end
# violates_constraints
# function CRCBS.violates_constraints(env::LowLevelEnv, path, s::State, a::Action, sp::State)
function CRCBS.violates_constraints(env::LowLevelEnv, s::State, a::Action, sp::State)
    # t = length(path) + 1
    t = sp.t
    if StateConstraint(get_agent_id(env.constraints),PathNode(s,a,sp),t) in env.constraints.state_constraints
        return true
    elseif ActionConstraint(get_agent_id(env.constraints),PathNode(s,a,sp),t) in env.constraints.action_constraints
        return true
    end
    return false
    # cs = StateConstraint(get_agent_id(env.constraints),PathNode(s,a,sp),t)
    # constraints = env.constraints.sorted_state_constraints
    # idx = max(1, find_index_in_sorted_array(constraints, cs)-1)
    # for i in idx:length(constraints)
    #     c = constraints[i]
    #     if c == cs
    #         @show s,a,sp
    #         return true
    #     end
    #     if c.t < cs.t
    #         break
    #     end
    # end
    # ca = StateConstraint(get_agent_id(env.constraints),PathNode(s,a,sp),t)
    # constraints = env.constraints.sorted_action_constraints
    # idx = max(1, find_index_in_sorted_array(constraints, ca)-1)
    # for i in idx:length(constraints)
    #     c = constraints[i]
    #     if c == ca
    #         @show s,a,sp
    #         return true
    #     end
    #     if c.t < ca.t
    #         break
    #     end
    # end
    # return false
end

################################################################################
###################### Conflict-Based Search (High-Level) ######################
################################################################################
# detect_state_conflict
function CRCBS.detect_state_conflict(n1::PathNode{State,Action},n2::PathNode{State,Action})
    if n1.sp.vtx == n2.sp.vtx
        return true
    end
    return false
end
CRCBS.detect_state_conflict(env::LowLevelEnv,n1::PathNode{State,Action},n2::PathNode{State,Action}) = detect_state_conflict(n1,n2)
# detect_action_conflict
function CRCBS.detect_action_conflict(n1::PathNode{State,Action},n2::PathNode{State,Action})
    if (n1.a.e.src == n2.a.e.dst) && (n1.a.e.dst == n2.a.e.src)
        return true
    end
    return false
end
CRCBS.detect_action_conflict(env::LowLevelEnv,n1::PathNode{State,Action},n2::PathNode{State,Action}) = detect_action_conflict(n1,n2)

################################################################################
############################### HELPER FUNCTIONS ###############################
################################################################################
""" Helper for displaying Paths """
function CRCBS.convert_to_vertex_lists(path::Path{State,Action})
    vtx_list = [n.sp.vtx for n in path.path_nodes]
    if length(path) > 0
        vtx_list = [get_s(get_path_node(path,1)).vtx, vtx_list...]
    end
    vtx_list
end
function CRCBS.convert_to_vertex_lists(solution::L) where {T,C,L<:LowLevelSolution{State,Action,T,C}}
    return [convert_to_vertex_lists(path) for path in get_paths(solution)]
end

end
