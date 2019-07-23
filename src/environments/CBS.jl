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
# Action
@with_kw struct Action
    e::Edge{Int}    = Edge(-1,-1)
    Δt::Int         = 1
end
# LowLevelEnv
function construct_distance_array(G,goal)
    if goal.vtx != -1 && nv(G) > goal.vtx
        d = gdistances(G,goal.vtx)
    else
        d = Vector{Float64}()
    end
    return d
end
@with_kw struct LowLevelEnv{G <: AbstractGraph} <: AbstractLowLevelEnv{State,Action}
    graph::G                    = Graph()
    constraints::ConstraintTable = ConstraintTable()
    goal::State                 = State()
    agent_idx::Int              = -1
    # helpers
    dists::Dict{Int,Vector{Float64}} = Dict(agent_idx => construct_distance_array(graph,goal))
end
function CRCBS.initialize_mapf(env::LowLevelEnv,starts::Vector{State},goals::Vector{State})
    dists = Dict(i => construct_distance_array(env.graph,g) for (i,g) in enumerate(goals))
    MAPF(LowLevelEnv(graph=env.graph,dists=dists), starts, goals)
end
################################################################################
######################## Low-Level (Independent) Search ########################
################################################################################
# build_env
function CRCBS.build_env(mapf::MAPF{E,S,G}, node::ConstraintTreeNode, idx::Int) where {S,G,E<:LowLevelEnv}
    LowLevelEnv(
        graph = mapf.env.graph,
        constraints = get_constraints(node,idx),
        goal = mapf.goals[idx],
        agent_idx = idx,
        dists = mapf.env.dists
        )
end
# heuristic
CRCBS.heuristic(env::LowLevelEnv,s) = env.dists[env.agent_idx][s.vtx]
# states_match
CRCBS.states_match(s1::State,s2::State) = (s1.vtx == s2.vtx)
CRCBS.states_match(env::LowLevelEnv,s1::State,s2::State) = (s1.vtx == s2.vtx)
# is_goal
function CRCBS.is_goal(env::LowLevelEnv,s::State)
    if states_match(s, env.goal)
        ###########################
        # Cannot terminate if there is a constraint on the goal state in the
        # future (e.g. the robot will need to move out of the way so another
        # robot can pass)
        for constraint in env.constraints.sorted_state_constraints
            if s.t < get_time_of(constraint)
                if states_match(s, get_sp(constraint.v))
                    # @show s.t, get_time_of(constraint)
                    return false
                end
            end
        end
        ###########################
        return true
    end
    return false
end
# check_termination_criteria
CRCBS.check_termination_criteria(env::LowLevelEnv,cost,path,s) = false
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
CRCBS.get_transition_cost(env::LowLevelEnv,s::State,a::Action,sp::State) = 1
# violates_constraints
function CRCBS.violates_constraints(env::LowLevelEnv, path, s::State, a::Action, sp::State)
    t = length(path) + 1
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
# initialize_root_node
function CRCBS.initialize_root_node(mapf::MAPF{E,S,G}) where {S,G,E<:LowLevelEnv}
    ConstraintTreeNode(
        solution = LowLevelSolution{State,Action}([Path{State,Action}() for a in 1:num_agents(mapf)]),
        constraints = Dict{Int,ConstraintTable}(
            i=>ConstraintTable(a=i) for i in 1:num_agents(mapf)
            ),
        id = 1)
end
# default_solution
function CRCBS.default_solution(mapf::MAPF{E,S,G}) where {S,G,E<:LowLevelEnv}
    return LowLevelSolution{State,Action}(), typemax(Int)
end

################################################################################
############################### HELPER FUNCTIONS ###############################
################################################################################
""" Helper for displaying Paths """
function convert_to_vertex_lists(path::Path{State,Action})
    vtx_list = [n.sp.vtx for n in path.path_nodes]
    if length(path) > 0
        vtx_list = [get_s(get_path_node(path,1)).vtx, vtx_list...]
    end
    vtx_list
end
function convert_to_vertex_lists(solution::LowLevelSolution{State,Action})
    return [convert_to_vertex_lists(path) for path in solution]
end

end