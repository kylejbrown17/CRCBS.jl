export
    LowLevelSearchHeuristic,
    NullHeuristic,
    PerfectHeuristic,
    MultiStagePerfectHeuristic,
    SoftConflictTable,
    CompositeHeuristic,
        construct_composite_heuristic

abstract type LowLevelSearchHeuristic{C} <: AbstractCostModel{C} end
################################################################################
############################### PerfectHeuristic ###############################
################################################################################
"""
    `NullHeuristic`
"""
struct NullHeuristic <: LowLevelSearchHeuristic{Float64} end
get_heuristic_cost(h::NullHeuristic,args...) = 0.0
get_heuristic_cost(env::E,h::NullHeuristic,args...) where {E<:AbstractLowLevelEnv} = get_heuristic_cost(h,args...)

################################################################################
############################### PerfectHeuristic ###############################
################################################################################
"""
    `PerfectHeuristic`

    The Perfect Heuristic stores the exact distance between any vertex in a
    graph to all goal vertices specified during construction. The distances are
    stored in `dists`, a dictionary which maps a goal vertex `v` to a vector of
    distances from any other vertex in `1:nv(G)` to `v`.

    An example of how to access the distance from vertex `v1` to goal `v2`:
    `get_heuristic_cost(h,v1,v2) = h.dists[v2][v1]`
"""
@with_kw struct PerfectHeuristic <: LowLevelSearchHeuristic{Float64}
    dists::Dict{Int,Vector{Float64}} = Dict{Int,Vector{Float64}}()
end
get_heuristic_cost(h::PerfectHeuristic,goal_vtx::Int,vtx::Int) = h.dists[goal_vtx][vtx]
function PerfectHeuristic(graph,starts::Vector{Int},goals::Vector{Int})
    dists = Dict(v => gdistances(graph,v) for v in goals)
    PerfectHeuristic(dists)
end

"""
    `MultiStagePerfectHeuristic`

    Stores multiple lookup tables corresponding to different stages of a Path-
    Finding search. Each stage has a different goal. The heuristic value at a
    particular stage must reflect not just the distance to the next goal but the
    length of the path through all remaining goals.
"""
@with_kw struct MultiStagePerfectHeuristic <: LowLevelSearchHeuristic{Float64}
    dists::Dict{Int,Vector{Vector{Float64}}} = Dict{Int,Vector{Vector{Float64}}}()
end
get_heuristic_cost(h::MultiStagePerfectHeuristic,agent_idx::Int,stage::Int,vtx::Int) = h.dists[agent_idx][stage][vtx]
function construct_multi_stage_distance_array(G,goals)
    if length(goals) > 0
        vtxs = copy(goals)
        dists = Vector{Vector{Float64}}()
        d = 0
        g = vtxs[end]
        while length(vtxs) > 0
            v = pop!(vtxs)
            d = gdistances(G,g)[v] + d
            push!(dists, gdistances(G,v).+ d)
            g = v
        end
        return reverse(dists)
    end
    return Vector{Vector{Float64}}()
end
function MultiStagePerfectHeuristic(graph,goals::Vector{Vector{Int}})
    dists = Dict(idx => construct_multi_stage_distance_array(graph,g) for (idx,g) in enumerate(goals))
    MultiStagePerfectHeuristic(dists)
end

################################################################################
############################### SoftConflictTable ##############################
################################################################################
"""
    `SoftConflictTable`

    The `SoftConflictTable` is a tie-breaker heuristic in A* search  within the
    CBS paradigm.
"""
@with_kw struct SoftConflictTable <: LowLevelSearchHeuristic{Float64}
    CAT::Matrix{Float64} = zeros(2,2) # global table
end
get_heuristic_cost(h::SoftConflictTable,vtx::Int,t::Int) = h.CAT[vtx,t]
"""
    `get_fat_path(G,D,start_vtx,goal_vtx)`

    returns a fat path through `G` from `start_vtx` to `goal_vtx`. Each set
    of vertices in the fat path contains all vertices with distance d1 from
    start_vtx and distance d2 to goal_vtx, where d1+d2 == the length of the
    shortest path(s) from `start_vtx` to `goal_vtx`

    G is a graph, D is the distance matrix
"""
function get_fat_path(G,D,start_vtx::Int,goal_vtx::Int)
    fat_path = Vector{Set{Int}}([Set{Int}(start_vtx)])
    for i in 1:D[start_vtx,goal_vtx]
        next_set = Set{Int}()
        for src_vtx in fat_path[end]
            for dst_vtx in outneighbors(G,src_vtx)
                if D[dst_vtx,goal_vtx] <= D[src_vtx,goal_vtx] - 1
                    push!(next_set, dst_vtx)
                end
            end
        end
        push!(fat_path, next_set)
    end
    fat_path
end
"""
    `construct_soft_conflict_lookup_table(G,T::Int)`

    Returns a soft lookup table to encode possible paths for each agent through
    a graph G. The table is to be used a a tie-breaker heuristic in A* search
    within the CBS paradigm.
"""
function construct_soft_conflict_lookup_table(G,T::Int)
    CAT = zeros(nv(G),T)
end
"""
    `add_fat_path_to_table(CAT,fat_path)`
"""
function add_fat_path_to_table!(CAT,t0,fat_path)
    for t in 1:length(fat_path)
        idxs = collect(fat_path[t])
        if t+t0 > 0
            CAT[idxs,t+t0] .+= 1.0/length(idxs)
        end
    end
end
"""
    `populate_soft_lookup_table!(CAT,start_times,start_vtxs,goal_vtxs)`
"""
function populate_soft_lookup_table!(CAT,G,D,start_times,start_vtxs,goal_vtxs)
    path_list = [t=>get_fat_path(G,D,s,g) for (s,t,g) in zip(start_vtxs,start_times,goal_vtxs)]
    for (t0,fat_path) in path_list
        add_fat_path_to_table!(CAT,t0,fat_path)
    end
    CAT
end
"""
    `construct_soft_conflict_lookup_table(graph,T::Int)`

    Returns a soft lookup table to encode possible paths for each agent through
    `graph`. The argument `T` defines the time horizon of the lookup table.
"""
function SoftConflictTable(graph,T::Int)
    SoftConflictTable(construct_soft_conflict_lookup_table(graph,T))
end
"""
    `construct_and_populate_soft_lookup_table!`
"""
function SoftConflictTable(graph,start_times::Vector{Int},start_vtxs::Vector{Int},goal_vtxs::Vector{Int};
        T = Int(round(maximum(start_times) + nv(graph))))
    CAT = construct_soft_conflict_lookup_table(graph,T)
    D = get_dist_matrix(graph)
    populate_soft_lookup_table!(CAT,graph,D,start_times,start_vtxs,goal_vtxs)
    SoftConflictTable(CAT)
end

################################################################################
################################################################################
################################################################################
struct CompositeHeuristic{M<:Tuple,T<:Tuple} <: LowLevelSearchHeuristic{T}
    cost_models::M
end
function construct_composite_heuristic(args...)
    models = Tuple(args)
    for m in models
        @assert typeof(m) <: LowLevelSearchHeuristic
    end
    cost_types = map(m->get_cost_type(m),models)
    CompositeHeuristic{typeof(models),Tuple{cost_types...}}(models)
end
# get_cost_type(h::H) where {T,M,H<:CompositeHeuristic{T,M}} = T
function get_heuristic_cost(model::H,args...) where {T,M,H<:CompositeHeuristic{M,T}}
    T(map(h->get_heuristic_cost(h,args...), model.cost_models))
end
function get_heuristic_cost(env::E,model::H,args...) where {E<:AbstractLowLevelEnv,T,M,H<:CompositeHeuristic{M,T}}
    T(map(m->get_heuristic_cost(env,m,args...), model.cost_models))
end

# ################################################################################
# ############################# TieBreakerHeuristic ##############################
# ################################################################################
# """
#     TieBreakerCost
# """
# @with_kw struct TieBreakerCost
#     c1::Float64 = 0.0
#     c2::Float64 = 0.0
# end
# function TieBreakerCost(c::R where {R <: Real})
#     TieBreakerCost(c1=c)
# end
# Base.isless(cost1::TieBreakerCost,cost2::TieBreakerCost) = [cost1.c1,cost1.c2] < [cost2.c1,cost2.c2]
# Base.:+(c1::TieBreakerCost, c2::TieBreakerCost) = TieBreakerCost(c1.c1+c2.c1,c1.c2+c2.c2)
# """
#     TieBreakerHeuristic{H1,H2}
# """
# @with_kw struct TieBreakerHeuristic <: LowLevelSearchHeuristic{TieBreakerCost}
#     h1::PerfectHeuristic = PerfectHeuristic()
#     h2::SoftConflictTable = SoftConflictTable()
# end
# function TieBreakerHeuristic(graph,start_times::Vector{Int},starts::Vector{Int},goals::Vector{Int})
#     TieBreakerHeuristic(
#         PerfectHeuristic(graph,starts,goals),
#         SoftConflictTable(graph,start_times,starts,goals)
#     )
# end
# function get_heuristic_cost(h::TieBreakerHeuristic,goal_vtx::Int,vtx::Int,t::Int)
#     TieBreakerCost(
#         get_heuristic_cost(h.h1, goal_vtx, vtx),
#         get_heuristic_cost(h.h2, vtx, t)
#         )
# end
