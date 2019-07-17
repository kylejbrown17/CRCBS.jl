export
    A_star_impl!,
    A_star

"""
    The internal loop of the A* algorithm.
"""
function A_star_impl!(env::E where {E <: AbstractLowLevelEnv{S,A}},# the graph
    frontier,               # an initialized heap containing the active nodes
    # explored::Dict{S,Bool},
    explored::Set{S},
    heuristic::Function) where {S,A}

    while !isempty(frontier)
        (cost_so_far, path, s) = dequeue!(frontier)
        if is_goal(env,s)
            # TODO Check for constraints that take effect later than the completion time
            return path
        elseif check_termination_criteria(env,cost_so_far,path,s)
            break
        end

        for a in get_possible_actions(env,s)
            sp = get_next_state(env,s,a)
            # Skip node if it violates any of the constraints
            if violates_constraints(env,path,s,a,sp)
                continue
            end
            if !(sp in explored)
                new_path = cat(path, PathNode(s, a, sp))
                path_cost = cost_so_far + get_transition_cost(env,s,a,sp)
                enqueue!(frontier,
                    (path_cost, new_path, sp) => path_cost + heuristic(sp))
            end
        end
        push!(explored,s)
    end
    Path{S,A}()
end

# g(n) = cost of the path from the start node to n,
# h(n) = heuristic estimate of cost from n to goal
# f(n) = g(n) + h(n)

"""
    A generic implementation of the [A* search algorithm](http://en.wikipedia.org/wiki/A%2A_search_algorithm)
    that operates on an Environment and initial state.

    args:
    - env::E <: AbstractLowLevelEnv{S,A}
    - start_state::S
    - is_goal::Function
    - heuristic::Function (optional)

    The following methods must be implemented:
    - is_goal(s::S)
    - check_termination_criteria(cost::PathCost,path::Path{S,A},state::S)
    - get_possible_actions(env::E,s::S)
    - get_next_state(env::E,s::S,a::A,sp::S)
    - get_transition_cost(env::E,s::S,a::A)
    - violates_constraints(env::E,s::S,path::Path{S,A})
"""
function A_star(env::E where {E <: AbstractLowLevelEnv{S,A}},# the graph
    start_state::S,
    heuristic::Function = s -> 0.0) where {S,A}

    initial_cost = 0
    frontier = PriorityQueue{Tuple{PathCost, Path{S,A}, S}, PathCost}()
    enqueue!(frontier, (initial_cost, Path{S,A}(), start_state)=>initial_cost)
    explored = Set{S}()

    A_star_impl!(env,frontier,explored,heuristic)
end