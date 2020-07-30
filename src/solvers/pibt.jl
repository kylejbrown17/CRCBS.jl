# Priority Inheritance with Backtracking for Iterative Multi-agent Path Finding
# Okumura et al, IJCAI 2019
# https://www.ijcai.org/Proceedings/2019/0076.pdf
export PIBTPlanner

@with_kw struct PIBTPlanner{C}
    logger::SolverLogger{C} = SolverLogger{C}()
end

export
    ReservationTable,
    reserve!,
    is_reserved,
    clear_reservations!

"""
    ReservationTable
"""
struct ReservationTable
    state_reservations::SparseVector{Bool,Int}
    action_reservations::SparseVector{Bool,Int}
end
function ReservationTable(n_states::Int,n_actions::Int)
    ReservationTable(
        sparse(zeros(Bool,n_states)),
        sparse(zeros(Bool,n_actions)),
        )
end
function ReservationTable(env)
    ReservationTable(num_states(env),num_actions(env))
end
function reserve_state!(table::ReservationTable,env,s)
    idx,_ = serialize(env,s,-1)
    table.state_reservations[idx] = true
    table
end
function reserve_action!(table::ReservationTable,env,a)
    idx,_ = serialize(env,a,-1)
    table.action_reservations[idx] = true
    table
end
function reserve!(table::ReservationTable,env,s,a,sp)
    reserve_state!(table,env,sp)
    reserve_action!(table,env,a)
    table
end
function is_reserved(table::ReservationTable,env,s,a,sp)
    s_idx,_ = serialize(env,sp,-1)
    a_idx,_ = serialize(env,a,-1)
    return table.state_reservations[s_idx] || table.action_reservations[a_idx]
end
function clear_reservations!(table::ReservationTable)
    table.state_reservations .= false
    table.action_reservations .= false
    dropzeros!(table.state_reservations)
    dropzeros!(table.action_reservations)
    table
end


abstract type AbstractPIBTCache end

export PIBTCache

"""
    PIBTCache{S,A}

Contains info to be passed along through recursive calls to the PIBT algorithm
for multi-agent path planning.
Info to be stored:
- current state of each agent (should be lined up at the same time step)
- priority of each agent
- the planned action (and associated next state) for each agent
- the search environment for each agent, which contains e.g., the agent's goal,
    cost_model, heuristic_model, etc.
- a conflict table of sorts to indicate which states/actions are reserved
- countdown flags that identify which paths are "active". If pibt is operating
on a "ragged" plan, where some paths have been planned further into the future
than others, it needs to ensure that planning does not continue for a given path
until all of the other paths have "caught up" to it.
"""
struct PIBTCache{T,E,S,A} <: AbstractPIBTCache
    solution::T
    envs::Vector{E}
    states::Vector{S}
    actions::Vector{A}
    priorities::Vector{Int}
    undecided::Set{Int} # agent ids
    # occupied::Set{Int}
    occupied::ReservationTable
    timers::Vector{Int}
    active_countdowns::Vector{Int}
end
get_envs(cache::PIBTCache) = cache.envs
get_solution(cache::PIBTCache) = cache.solution
get_states(cache::PIBTCache) = cache.states
get_actions(cache::PIBTCache) = cache.actions
get_priorities(cache::PIBTCache) = cache.priorities
get_undecided(cache::PIBTCache) = cache.undecided # agent ids
get_occupied(cache::PIBTCache) = cache.occupied
get_timers(cache::PIBTCache) = cache.timers
get_active_countdowns(cache::PIBTCache) = cache.active_countdowns

get_active_agents(cache::PIBTCache) = findall(get_active_countdowns(cache) .<= 0)
get_inactive_agents(cache::PIBTCache) = findall(get_active_countdowns(cache) .> 0)

get_cost_model(cache::PIBTCache) = get_cost_model(cache.envs[1])

for op in [:is_reserved,:reserve!,:reserve_state!,:reserve_action!,:clear_reservations!
    ]
    @eval $op(cache::PIBTCache,args...) = $op(get_occupied(cache),args...)
end

"""
    reset_reservations!

Removes all existing reservations, then inserts all reservations that arise from
paths that are already planned (non-active).
"""
function reset_reservations!(cache::PIBTCache)
    clear_reservations!(cache)
    for i in get_inactive_agents(cache)
        env = get_envs(cache)[i]
        s = get_states(cache)[i]
        a = get_actions(cache)[i]
        sp = get_next_state(env,s,a)
        reserve_state!(cache,env,sp)
        reserve_action!(cache,env,a)
        reserve_action!(cache,env,reverse(a)) # reserve the action in both directions
    end
end

"""
    Fills `undecided` with all active agents (inactive agents have already
    selected their actions)
"""
function reset_undecided!(cache::PIBTCache)
    union!(get_undecided(cache),Set(get_active_agents(cache)))
end
function set_action!(cache::PIBTCache,i,a)
    get_actions(cache)[i] = a
end
function is_active(cache::PIBTCache,i)
    return get_active_countdowns(cache)[i] <= 0
end

"""
    get_conflict_index(cache,i,s,a,sp)

Returns the index of an agent that currently occupies `sp`, or -1 if there is no
such agent.
"""
function get_conflict_index(cache::PIBTCache,i,s,a,sp)
    for (k,sk) in enumerate(get_states(cache))
        if states_match(sp,sk) && k != i
            if k in get_undecided(cache)
                return k
            end
        end
    end
    return -1
end

function is_consistent(cache::PIBTCache,mapf)
    for (env,s) in zip(get_envs(cache),get_states(cache))
        if !is_goal(env,s)
            return false
        end
    end
    return true
end

function pibt_set_priorities!(solver,mapf,cache)
    get_priorities(cache) .= reverse(sortperm(
        [(t,i) for (i,t) in enumerate(get_timers(cache))]
        ))
    log_info(3,solver,"priorities: ", get_priorities(cache))
    return cache
end
function pibt_init_cache(solver,mapf,
        solution = get_initial_solution(mapf),
        )
    N = num_agents(mapf)
    node = initialize_root_node(solver,mapf)
    envs = Vector{base_env_type(mapf)}(map(i->build_env(solver,mapf,node,i), 1:N))
    priorities = collect(1:N)
    undecided = Set{Int}()
    # occupied = Set{Int}()
    occupied = ReservationTable(mapf)
    timers = zeros(Int,N)
    end_idxs = map(get_end_index, get_paths(solution))
    active_countdowns = end_idxs .- minimum(end_idxs)
    # states = map(p->get_final_state(p), get_paths(solution))
    states = [
        get_s(p,get_end_index(p)+1-t) for (p,t) in zip(
            get_paths(solution),active_countdowns)
            ]
    # actions = map(i->wait(envs[i],states[i]), 1:N)
    actions = [
        get_a(p,get_end_index(p)+1-t) for (p,t) in zip(
            get_paths(solution),active_countdowns)
            ]
    cache = PIBTCache(
        solution,
        envs,
        states,
        actions,
        priorities,
        undecided,
        occupied,
        timers,
        active_countdowns,
    )
    pibt_set_priorities!(solver,mapf,cache)
    reset_undecided!(cache)
    reset_reservations!(cache)
    cache
end

function pibt_update_solution!(solver,solution,cache)
    for (i,(p,env,s,a)) in enumerate(zip(get_paths(solution),get_envs(cache),get_states(cache),get_actions(cache)))
        if !is_active(cache,i)
            continue
        end
        sp = get_next_state(env,s,a)
        add_to_path!(p,env,s,a,sp)
        set_path_cost!(solution,get_cost(p),i)
    end
    set_cost!(solution, aggregate_costs(
        get_cost_model(cache),
        get_path_costs(solution)
        ))
    solution
end
function pibt_update_env!(solver,mapf,cache,i)
    node = initialize_root_node(solver,mapf)
    get_envs(cache)[i] = build_env(solver,mapf,node,-1)
end
function pibt_update_envs!(solver,mapf,cache)
    for (i,(s,env)) in enumerate(zip(get_states(cache),get_envs(cache)))
        if !is_active(cache,i)
            continue
        end
        if is_goal(env,s) && is_valid(get_goal(env))
            pibt_update_env!(solver,mapf,cache,i)
            get_timers(cache)[i] = 0
        end
    end
end
function pibt_update_cache!(solver,mapf,cache)
    pibt_update_solution!(solver,get_solution(cache),cache)
    get_timers(cache) .+= 1
    get_active_countdowns(cache) .= max.(0, get_active_countdowns(cache) .- 1)
    for (i,p) in enumerate(get_paths(get_solution(cache)))
        # s = get_final_state(p)
        # get_states(cache)[i] = s
        # get_actions(cache)[i] = wait(get_envs(cache)[i],s)
        t = get_end_index(p)+1-get_active_countdowns(cache)[i]
        get_states(cache)[i] = get_s(p,t)
        get_actions(cache)[i] = get_a(p,t)
    end
    reset_undecided!(cache)
    reset_reservations!(cache)
    pibt_update_envs!(solver,mapf,cache)
    if any(get_timers(cache) .== 0)
        pibt_set_priorities!(solver,mapf,cache)
    end
    return cache
end
function pibt_next_agent_id(solver,cache)
    for i in sortperm(get_priorities(cache))
        if i in get_undecided(cache)
            return i
        end
    end
    return -1
end

export pibt_step!

"""
    pibt_step!(solver,mapf,i,j=-1)

i is the id of the higher priority agent, j is the index of the lower priority
agent.
"""
function pibt_step!(solver,mapf,cache,i,j=-1)
    log_info(3,solver,"pibt_step!( ... i = ",i,", j = ",j," )")
    env = get_envs(cache)[i]
    s = get_states(cache)[i]
    # TODO if this path is ahead of the current planning time index, skip it
    # n = get_path_node()
    sj = get(get_states(cache), j, state_type(mapf)())
    a_list = sorted_actions(env,s) # NOTE does NOT need to exclude wait()
    while ~isempty(a_list)
        a = a_list[1]
        sp = get_next_state(env,s,a)
        if !is_reserved(cache,env,s,a,sp) && !states_match(sp,sj)
            reserve!(cache,env,s,a,sp)
            log_info(3,solver,"reserve!( ... a = ",string(a),", sp = ",string(sp)," )")
            k = get_conflict_index(cache,i,s,a,sp)
            if k != -1
                log_info(3,solver,"get_conflict_index( i = ",i,", sp = ",string(sp)," ) : ",k)
                if pibt_step!(solver,mapf,cache,k,i)
                    set_action!(cache,i,a)
                    setdiff!(cache.undecided,i)
                    return true
                else
                    deleteat!(a_list,1)
                    break
                end
            else
                set_action!(cache,i,a)
                setdiff!(cache.undecided,i)
                return true
            end
        else
            log_info(3,solver,"illegal action ",string(a))
            deleteat!(a_list,1)
        end
    end
    set_action!(cache,i,wait(env,s))
    return false
end

export pibt!

function pibt!(solver, mapf)
    cache = pibt_init_cache(solver,mapf)
    while !is_consistent(cache,mapf)
        try
            increment_iteration_count!(solver)
            enforce_iteration_limit(solver)
        catch e
            if isa(e,SolverException)
                bt = catch_backtrace()
                showerror(stdout,e)
                return get_solution(cache), is_consistent(cache,mapf)
            else
                rethrow(e)
            end
        end
        log_info(3,solver,"PIBT iterations = ",iterations(solver))
        # update cache
        while !isempty(cache.undecided)
            i = pibt_next_agent_id(solver,cache)
            if ~pibt_step!(solver,mapf,cache,i)
                return get_solution(cache), false
            end
        end
        # update cache
        pibt_update_cache!(solver,mapf,cache)
        log_info(3,solver,"solution: ",convert_to_vertex_lists(get_solution(cache)))
    end
    return get_solution(cache), is_consistent(cache,mapf)
end
