export
    MultiStageCBS

module MultiStageCBS

using ..CRCBS
using Parameters, LightGraphs, DataStructures

################################################################################
############################### ENVIRONMENT DEF ################################
################################################################################
# state
@with_kw struct State
    vtx::Int    = -1 # vertex of graph
    stage::Int  = -1 # which stage of the sequence
    t::Int      = -1
end
CRCBS.is_valid(state::State) = state.vtx > 0
# action
@with_kw struct Action
    e::Edge{Int}    = Edge(-1,-1)
    Δt::Int         = 1
end
@with_kw struct LowLevelEnv{C<:AbstractCostModel,H<:LowLevelSearchHeuristic,G<:AbstractGraph} <: AbstractLowLevelEnv{State,Action,C}
    graph::G                        = Graph()
    constraints::ConstraintTable    = ConstraintTable()
    goal_sequence::Vector{State}    = Vector{State}()
    agent_idx::Int                  = -1
    cost_model::C                   = SumOfTravelTime()
    heuristic::H                    = NullHeuristic() # MultiStagePerfectHeuristic(graph,Vector{Vector{Int}}())
end
CRCBS.get_cost_model(env::E) where {E<:LowLevelEnv} = env.cost_model
CRCBS.get_heuristic_model(env::E) where {E<:LowLevelEnv} = env.heuristic
################################################################################
######################## Low-Level (Independent) Search ########################
################################################################################
# build_env
function CRCBS.build_env(mapf::MAPF{E,S,G}, node::N, idx::Int)  where {S,G,E <: LowLevelEnv,N<:ConstraintTreeNode}
    E(
        graph = mapf.env.graph,
        constraints = get_constraints(node,idx),
        goal_sequence = mapf.goals[idx],
        agent_idx = idx,
        cost_model = get_cost_model(mapf.env),
        heuristic = get_heuristic_model(mapf.env)
        )
end
# heuristic
CRCBS.get_heuristic_cost(env::E,s::State) where {E<:LowLevelEnv} = CRCBS.get_heuristic_cost(env,get_heuristic_model(env),s)
function CRCBS.get_heuristic_cost(env::E,h::MultiStagePerfectHeuristic,s::State) where {E<:LowLevelEnv}
    get_heuristic_cost(h, env.agent_idx, s.stage, s.vtx)
end
# states_match
CRCBS.states_match(s1::State,s2::State) = (s1.vtx == s2.vtx)
function CRCBS.is_valid(path::Path{State,Action},start::State,goals::Vector{State})
    valid = true
    stage = 1
    if states_match(start,goals[stage])
        stage += 1
    end
    for k in 1:length(path)
        node = get_path_node(path,k)
        if states_match(get_sp(node),goals[stage])
            stage += 1
        end
        if stage > length(goals)
            return true
        end
    end
    return false
end
# is_goal
function CRCBS.is_goal(env::E,s::State) where {E<:LowLevelEnv}
    if states_match(s, env.goal_sequence[s.stage])
        ###########################
        # Cannot terminate if there is a constraint on the goal state in the
        # future (e.g. the robot will need to move out of the way so another
        # robot can pass)
        if s.stage == length(env.goal_sequence) # terminal goal state
            for constraint in env.constraints.sorted_state_constraints
                if s.t < get_time_of(constraint)
                    if states_match(s, get_sp(constraint.v))
                        # @show s.t, get_time_of(constraint)
                        return false
                    end
                end
            end
            return true # done!
        else
            return false # not done yet!
        end
        ###########################
    end
    return false
end
# check_termination_criteria
CRCBS.check_termination_criteria(env::E,cost,path,s) where {E<:LowLevelEnv} = false
# wait
CRCBS.wait(s::State) = Action(e=Edge(s.vtx,s.vtx))
CRCBS.wait(env::E,s::State) where {E<:LowLevelEnv} = Action(e=Edge(s.vtx,s.vtx))
# get_possible_actions
struct ActionIter
    # env::LowLevelEnv
    s::Int # source state
    neighbor_list::Vector{Int} # length of target edge list
end
struct ActionIterState
    idx::Int # idx of target node
end
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
CRCBS.get_possible_actions(env::E,s::State) where {E<:LowLevelEnv} = ActionIter(s.vtx,outneighbors(env.graph,s.vtx))
# get_next_state
function CRCBS.get_next_state(s::State,a::Action)
    @assert(is_valid(s))
    @assert(s.vtx == a.e.src)
    State(a.e.dst, s.stage, s.t+a.Δt)
end
function CRCBS.get_next_state(env::E,s::State,a::Action) where {E<:LowLevelEnv}
    @assert(is_valid(s))
    @assert(s.stage <= length(env.goal_sequence))
    stage = s.stage
    if states_match(s, env.goal_sequence[s.stage])
        stage = min(stage+1, length(env.goal_sequence))
    end
    return State(a.e.dst, stage, s.t+a.Δt)
end
# get_transition_cost
function CRCBS.get_transition_cost(env::E,c::TravelTime,s::State,a::Action,sp::State) where {E<:LowLevelEnv}
    get_cost_type(c)(a.Δt)
end
# violates_constraints
function CRCBS.violates_constraints(env::E, path, s::State, a::Action, sp::State) where {E<:LowLevelEnv}
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
function CRCBS.detect_state_conflict(env::E,n1::PathNode{State,Action},n2::PathNode{State,Action}) where {E<:LowLevelEnv}
    detect_state_conflict(n1,n2)
end
# detect_action_conflict
function CRCBS.detect_action_conflict(n1::PathNode{State,Action},n2::PathNode{State,Action})
    if (n1.a.e.src == n2.a.e.dst) && (n1.a.e.dst == n2.a.e.src)
        return true
    end
    return false
end
function CRCBS.detect_action_conflict(env::E,n1::PathNode{State,Action},n2::PathNode{State,Action}) where {E<:LowLevelEnv}
    detect_action_conflict(n1,n2)
end

################################################################################
############################### HELPER FUNCTIONS ###############################
################################################################################
""" Helper for displaying Paths """
function convert_to_vertex_lists(path::Path)
    vtx_list = [n.sp.vtx for n in path.path_nodes]
    if length(path) > 0
        vtx_list = [get_s(get_path_node(path,1)).vtx, vtx_list...]
    end
    vtx_list
end
function convert_to_vertex_lists(solution::E) where {E<:LowLevelEnv}
    return [convert_to_vertex_lists(path) for path in get_paths(solution)]
end

end # end module MultiStageCBS