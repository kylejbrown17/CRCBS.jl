module CRCBS

using Parameters
using DataStructures
using LightGraphs, MetaGraphs
using LinearAlgebra
using NearestNeighbors

include("utils.jl")

export
    MAPF,
    GraphPath,
    traversal_time,
    LowLevelSolution,
    is_valid,
    NodeConflict,
    detect_node_conflict,
    invalid_node_conflict,
    EdgeConflict,
    detect_edge_conflict,
    invalid_edge_conflict,
    CBSConstraint,
    ConstraintTreeNode,
    ConstraintDict,
    get_constraints,
    # get_constraint_dict,
    add_constraint!,
    compare_constraint_nodes,
    combine_constraints,
    get_cost,
    empty_constraint_node,
    get_next_conflicts,
    get_conflicts,
    generate_constraints_from_conflict,
    low_level_search!,
    CBS,

    generate_random_grid_graph,
    initialize_full_grid_graph,
    initialize_regular_grid_graph


"""
    A MAPF is an instance of a Multi Agent Path Finding problem. It consists of
    a graph `G` whose edges have unit length, as well as a set of start and goal
    vertices on that graph. Note that this is the _labeled_ case, where each
    agent has a specific assigned destination.
"""
struct MAPF{G <: AbstractGraph} # Multi Agent Path Finding Problem
    graph::G
    starts::Vector{Int}
    goals::Vector{Int}
end

""" Type alias for a path through the graph """
const GraphPath = Vector{Edge{Int}}

"""
    Returns the edge at time t or a "self-loop" edge on the final node of the
    path
"""
function get_edge(path::GraphPath, t::Int)
    if length(path) < t
        return Edge(path[end].dst,path[end].dst)
    else
        return path[t]
    end
end
get_start_node(path::GraphPath) = path[1].src
get_final_node(path::GraphPath) = path[end].dst

"""
    returns the time for traversal of a GraphPath. Defaults to the length of the
    path, but it may be useful in case we need to override later
"""
traversal_time(path::GraphPath) = length(path)

""" Type alias for a list of agent paths """
const LowLevelSolution = Vector{GraphPath}

"""
    checks if a solution is valid
"""
function is_valid(solution::LowLevelSolution,mapf::MAPF)
    for (i,path) in enumerate(solution)
        if get_start_node(path) != mapf.starts[i]
            return false
        end
        if get_final_node(path) != mapf.goals[i]
            return false
        end
    end
    return true
end

"""
    Encodes a conflict wherein two agents occupy a particular node at a
    particular time
"""
struct NodeConflict
    agent1_id::Int
    agent2_id::Int
    node_id::Int
    t::Int
end

""" Checks for a `NodeConflict` between two `Edge`s """
function detect_node_conflict(edge1::Edge,edge2::Edge)
    if edge1.dst == edge2.dst
        return true
    end
    return false
end

""" Checks for a `NodeConflict` between two `GraphPath`s at time t """
function detect_node_conflict(path1::GraphPath,path2::GraphPath,t::Int)
    e1 = get_edge(path1,t)
    e2 = get_edge(path2,t)
    if detect_node_conflict(e1,e2)
        return true
    end
    return false
end

""" Returns an invalid NodeConflict """
invalid_node_conflict() = NodeConflict(-1,-1,-1,-1)

""" Checks if a node conflict is valid """
is_valid(conflict::NodeConflict) = (conflict.agent1_id != -1)

"""
    Encodes a conflict between two agents at a particular edge at a particular
    time. This means that the agents are trying to swap places at time t.
"""
struct EdgeConflict
    agent1_id::Int
    agent2_id::Int
    node1_id::Int
    node2_id::Int
    t::Int
end

""" Checks for an `EdgeConflict` between two `Edge`s """
function detect_edge_conflict(edge1::Edge,edge2::Edge)
    if (edge1.src == edge2.dst) && (edge1.dst == edge2.src)
        return true
    end
    return false
end

""" Checks for an `EdgeConflict` between two `GraphPath`s at time t """
function detect_edge_conflict(path1::GraphPath,path2::GraphPath,t::Int)
    e1 = get_edge(path1,t)
    e2 = get_edge(path2,t)
    if detect_edge_conflict(e1,e2)
        return true
    end
    return false
end

""" Returns an invalid EdgeConflict """
invalid_edge_conflict() = EdgeConflict(-1,-1,-1,-1,-1)

""" checks if an edge node is invalid """
is_valid(conflict::EdgeConflict) = (conflict.agent1_id != -1)

"""
    Encodes a constraint that agent `a` may not occupy vertex `v` at time `t`
"""
struct CBSConstraint
    a::Int # agent ID
    v::Int # vertex ID
    t::Int # time ID
end

"""
    constraint dictionary for fast constraint lookup within a_star
"""
@with_kw struct ConstraintDict
    dict::Dict{CBSConstraint,Bool} = Dict{CBSConstraint,Bool}()
    a::Int = -1 # agent_id
end

""" Helper function to merge two instances of `ConstraintDict` """
function Base.merge(d1::ConstraintDict,d2::ConstraintDict)
    @assert(d1.a==d2.a)
    ConstraintDict(
        merge(d1.dict,d2.dict),
        d1.a
    )
end

"""
     combines two `Dict`s of `ConstraintDict`s into a single `Dict` of
     `ConstraintDict`s where the value associated with each key in the
     resulting dictionary is the union of the values for the input dictionaries
     at that key
"""
function combine_constraints(dict1::Dict{K,ConstraintDict},dict2::Dict{K,ConstraintDict}) where K
    new_dict = typeof(dict1)()
    for k in union(collect(keys(dict1)),collect(keys(dict2)))
        new_dict[k] = merge(get(dict1,k,ConstraintDict()), get(dict1,k,ConstraintDict()))
    end
    return new_dict
end

"""
    A node of a constraint tree. Each node has a set of constraints, a candidate
    solution (set of robot paths), and a cost
"""
@with_kw mutable struct ConstraintTreeNode
    # maps agent_id to the set of constraints involving that agent
    constraints::Dict{Int,ConstraintDict} = Dict{Int,ConstraintDict}()
    # set of paths (one per agent) through graph
    solution::LowLevelSolution = LowLevelSolution()
    # cost = sum([length(path) for path in solution])
    cost::Int = -1
    # index of parent node
    parent::Int = -1
    # indices of two child nodes
    children::Tuple{Int,Int} = (-1,-1)
    # unique id
    id::Int = -1
end
const NULL_NODE = -1

"""
    retrieve constraints corresponding to this node and this path
"""
function get_constraints(node::ConstraintTreeNode, path_id::Int)
    return get(node.constraints, path_id, ConstraintDict())
end

"""
    check if a set of constraints is violated by a node and path
"""
function violates_constraint(constraints::ConstraintDict,v,path)
    t = length(path) + 1
    return get(constraints.dict,CBSConstraint(constraints.a,v,t),false)
end

"""
    Construct and empty `ConstraintTreeNode` from a `MAPF` instance
"""
function ConstraintTreeNode(mapf::MAPF)
    ConstraintTreeNode(
        constraints = Dict{Int,ConstraintDict}(
            i=>ConstraintDict(a=i) for i in 1:length(mapf.starts)
            ))
end

"""
    adds a constraint to a ConstraintTreeNode
"""
function add_constraint!(node::ConstraintTreeNode,constraint::CBSConstraint,mapf::MAPF)
    # if !haskey(node.constraints[constraint.a])
    # push!(node.constraints[constraint.a],constraint)
    if (constraint.v != mapf.goals[constraint.a])
        node.constraints[constraint.a].dict[constraint] = true
        return true
    end
    return false
end

"""
    checks to see if two `ConstraintTreeNode`s are identical (in terms of their
    constraints)
"""
function compare_constraint_nodes(node1::ConstraintTreeNode,node2::ConstraintTreeNode)
    constraints1 = union([collect(keys(v)) for (k,v) in node1.constraints])
    constraints2 = union([collect(keys(v)) for (k,v) in node2.constraints])
    return length(setdiff(constraints1,constraints2)) == 0
end

"""
    Helper function to get the cost of a particular solution
"""
function get_cost(paths::LowLevelSolution)
    return sum([length(p) for p in paths])
end
"""
    Helper function to get the cost of a particular node
"""
function get_cost(node::ConstraintTreeNode)
    return get_cost(node.solution)
end

"""
    Returns an empty `ConstraintTreeNode`
"""
function empty_constraint_node()
    ConstraintTreeNode()
end

"""
    Returns a `NodeConflict` and an `EdgeConflict` next conflicts.
    The function returns after finding the FIRST conflice (NodeConflict or
        EdgeConflict), which means that at least one of the returned conflicts
        will always be invalid. The rational for returning both anyway is to
        preserve stability of the function's return type.
    If node_conflict and edge_conflict are both invalid, the search has reached
        the end of the paths.

    args:
    - t_:       time index at which to begin the search
    - i_:       index of path 1 at which to begin the search
    - j_:       index of path 2 at which to begin the search
    - tmax:     maximum lookahead time (defaults to the length of the longest
        path)
    Search begins at time `t_`, `paths[i_]`, `paths[j_]`, then returns after
        finding the first conflict.
"""
function get_next_conflicts(paths::LowLevelSolution,
        i_::Int=1,
        j_::Int=2,
        t_::Int=1,
        tmax::Int=maximum([traversal_time(p) for p in paths])
        )
    node_conflict = invalid_node_conflict()
    edge_conflict = invalid_edge_conflict()
    # begin search from time t, paths[i_], paths[j_]
    t = t_; i = i_; j_ = max(j_,i+1)

    path1 = paths[i]
    e1 = get_edge(path1,t)
    for j in j_:length(paths)
        path2 = paths[j]
        e2 = get_edge(path2,t)
        if detect_node_conflict(e1,e2)
            node_conflict = NodeConflict(i,j,e1.dst,t)
            return node_conflict, edge_conflict
        elseif detect_edge_conflict(e1,e2)
            edge_conflict = EdgeConflict(i,j,e1.dst,e2.dst,t)
            return node_conflict, edge_conflict
        end
    end
    # Continue search from next time step
    for t in t_+1:tmax
        for (i,path1) in enumerate(paths)
            e1 = get_edge(path1,t)
            for j in i+1:length(paths)
                path2 = paths[j]
                e2 = get_edge(path2,t)
                if detect_node_conflict(e1,e2)
                    node_conflict = NodeConflict(i,j,e1.dst,t)
                    return node_conflict, edge_conflict
                elseif detect_edge_conflict(e1,e2)
                    edge_conflict = EdgeConflict(i,j,e1.dst,e2.dst,t)
                    return node_conflict, edge_conflict
                end
            end
        end
    end
    return node_conflict, edge_conflict
end

# """
#     Returns the next conflict that is not already in the current ConstraintTreeNode
# """

"""
    Returns a list of all conflicts that occur in a given solution

    args:
    - paths:        a list of graph edges to be traversed by the agents
"""
function get_conflicts(paths::LowLevelSolution)
    # TODO Make this way faster
    node_conflicts = Vector{NodeConflict}()
    edge_conflicts = Vector{EdgeConflict}()
    t_max = maximum([length(path) for path in paths])
    nc, ec = get_next_conflicts(paths)
    while true
        if is_valid(nc)
            push!(node_conflicts, nc)
            conflict = nc
        elseif is_valid(ec)
            push!(edge_conflicts, ec)
            conflict = ec
        else
            break
        end
        nc, ec = get_next_conflicts(
            paths,
            conflict.agent1_id,
            conflict.agent2_id+1,
            conflict.t,
            t_max
            )
    end
    return node_conflicts, edge_conflicts
end

"""
    generates a set of constraints from a NodeConflict
"""
function generate_constraints_from_conflict(conflict::NodeConflict)
    return [
        # Agent 1 may not occupy node at time t
        CBSConstraint(
            conflict.agent1_id,
            conflict.node_id,
            conflict.t
        ),
        # Agent 2 may not occupy node at time t
        CBSConstraint(
            conflict.agent2_id,
            conflict.node_id,
            conflict.t
        )
        ]
end

"""
    generates a set of constraints from an EdgeConflict
"""
function generate_constraints_from_conflict(conflict::EdgeConflict)
    return [
        # Agent 1 may not occupy node 2 at time t + 1
        CBSConstraint(
            conflict.agent1_id,
            conflict.node2_id,
            conflict.t + 1
        ),
        # Agent 2 may not occupy node 1 at time t + 1
        CBSConstraint(
            conflict.agent2_id,
            conflict.node1_id,
            conflict.t + 1
        )
        ]
end

"""
    Returns a low level solution for a MAPF with constraints
"""
function low_level_search!(mapf::MAPF,node::ConstraintTreeNode,path_finder=LightGraphs.a_star)
    # compute an initial solution
    solution = LowLevelSolution()
    for i in 1:length(mapf.starts)
        # TODO allow passing custom heuristic
        path = path_finder(mapf.graph,mapf.starts[i],mapf.goals[i],get_constraints(node,i))
        push!(solution,path)
    end
    # sum of individual costs (SIC)
    cost = get_cost(solution)
    node.solution = solution
    node.cost = get_cost(solution)
    # TODO check if solution is valid
    return solution, cost
    return true
end

"""
    The Conflict-Based search algorithm for multi-agent path finding
"""
function CBS(mapf::MAPF,path_finder=LightGraphs.a_star)
    # priority queue that stores nodes in order of their cost
    priority_queue = PriorityQueue{ConstraintTreeNode,Int}()

    root_node = ConstraintTreeNode(mapf)
    low_level_search!(mapf,root_node)
    if is_valid(root_node.solution,mapf)
        enqueue!(priority_queue, root_node => root_node.cost)
    end

    while length(priority_queue) > 0
        node = dequeue!(priority_queue)
        # check for conflicts
        node_conflict, edge_conflict = get_next_conflicts(node.solution)
        if is_valid(node_conflict)
            # Create constraints from node_conflict
            constraints = generate_constraints_from_conflict(node_conflict)
        elseif is_valid(edge_conflict)
            # Create constraints from edge_conflict
            constraints = generate_constraints_from_conflict(edge_conflict)
        else
            # Done! No conflicts in solution
            print("Solution Found!\n")
            return node.solution, node.cost
        end

        # generate new nodes from constraints
        for constraint in constraints
            new_node = ConstraintTreeNode(constraints=copy(node.constraints))
            if add_constraint!(new_node,constraint,mapf)
                low_level_search!(mapf,new_node)
                if is_valid(new_node.solution, mapf)
                    enqueue!(priority_queue, new_node => new_node.cost)
                end
            end
        end
    end
    print("No Solution Found. Returning default solution")
    return LowLevelSolution(), typemax(Int)
end

"""
    A dummy function for initializing a grid graph

    TODO: extend to incorporate obstacles
"""
function initialize_full_grid_graph()
    dx = 1.0
    dy = 1.0
    x_pts=collect(0.0:dx:10.0)
    y_pts=collect(0.0:dy:10.0)
    G = MetaGraph() # navigation graph
    pts = []
    for x in x_pts
        for y in y_pts
            if !((4.0 <= x <= 6.0) && (4.0 <= y <= 6.0)) # check obstacle condition
                push!(pts,[x;y])
                add_vertex!(G,Dict(:x=>x,:y=>y))
            end
        end
    end
    kdtree = KDTree(hcat(pts...))
    # create edges of 4-connected grid
    for i in vertices(G)
        for j in inrange(kdtree,pts[i],norm([dx;dy]))
            if i != j && !(has_edge(G,i,j))
                if abs(pts[i][1]-pts[j][1]) <= dx && pts[i][2] == pts[j][2]
                    add_edge!(G,i,j)
                elseif abs(pts[i][2]-pts[j][2]) <= dy && pts[i][1] == pts[j][1]
                    add_edge!(G,i,j)
                end
            end
        end
    end
    return G
end

"""
    Returns a grid graph that represents a 2D environment with regularly spaced
    rectangular obstacles
"""
function initialize_regular_grid_graph(;
    n_obstacles_x=2,
    n_obstacles_y=2,
    obs_width = [2;2],
    obs_offset = [1;1],
    env_pad = [1;1],
    env_offset = [1.0,1.0],
    env_scale = 2.0 # this is essentially the robot diameter
    )
    # generate occupancy grid representing the environment
    o = ones(Int,obs_width[1],obs_width[2]) # obstacle region
    op = pad_matrix(o,(obs_offset[1],obs_offset[2]),0) # padded obstacles region
    A = repeat(op,n_obstacles_x,n_obstacles_y)
    Ap = pad_matrix(A,(env_pad[1],env_pad[2]),0) # padded occupancy grid
    K = zeros(Int,size(Ap))
    G = MetaGraph()

    k = 0
    for i in 1:size(Ap,1)
        for j in 1:size(Ap,2)
            if Ap[i,j] == 0
                k += 1
                add_vertex!(G,
                    Dict(:x=>env_offset[1] + env_scale*(i-1),
                    :y=>env_offset[2] + env_scale*(j-1))
                    )
                add_edge!(G,nv(G),nv(G))
                K[i,j] = k
            end
        end
    end
    for i in 1:size(Ap,1)
        for j in 1:size(Ap,2)
            if Ap[i,j] == 0
                if j < size(Ap,2)
                    add_edge!(G,K[i,j],K[i,j+1])
                end
                if j > 1
                    add_edge!(G,K[i,j],K[i,j-1])
                end
                if i < size(Ap,1)
                    add_edge!(G,K[i,j],K[i+1,j])
                end
                if i > 1
                    add_edge!(G,K[i,j],K[i-1,j])
                end
            end
        end
    end
    G
end

include("a_star.jl")

end # module
