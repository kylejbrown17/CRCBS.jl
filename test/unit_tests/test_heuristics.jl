module heuristicsTests

using Parameters
using CRCBS

@with_kw struct State
    v::Int = -1
end
@with_kw struct Action
    v::Int = -1
end
struct GraphEnv <: AbstractLowLevelEnv{State,Action,TravelTime}
    G
end
get_heuristic_cost(env::GraphEnv,s::State) = get_heuristic_cost()

end #module

let
    PerfectHeuristic()
    SoftConflictHeuristic()
end
let
    G = initialize_regular_grid_graph(;n_obstacles_x=1,n_obstacles_y=1)
    start_times = [0,-2,2]
    starts = [1,2,3]
    goals = [4,5,6]
    let
        h = PerfectHeuristic(G,starts,goals)
        @test get_heuristic_cost(h,goals[1],starts[1]) == gdistances(G,starts[1])[goals[1]]
    end
    let
        h = SoftConflictHeuristic(G,start_times,starts,goals)
        @test get_heuristic_cost(h,starts[1],1) >= 1.0
    end
    let
        h1 = PerfectHeuristic(G,starts,goals)
        h2 = SoftConflictHeuristic(G,start_times,starts,goals)
    end
    let
        h = construct_composite_heuristic(
            NullHeuristic(),
            PerfectHeuristic(G,starts,goals)
        )
        cost = get_heuristic_cost(h,goals[1],starts[1])
        @test cost[1] == 0.0
        @test cost[2] ==  gdistances(G,starts[1])[goals[1]]
    end
end
# DeadlineHeuristic
# let
#     G = Graph(3)
#     for v in 1:nv(G)-1
#         add_edge!(G,v,v+1)
#     end
#     starts = [1]
#     goals = [nv(G)]
#     h1 = PerfectHeuristic(G,starts,goals)
#     h = DeadlineHeuristic(t_max=ne(G)+1.0, h=h1)
#     @test get_heuristic_cost(h, 0.0, goals[1], starts[1]) == 0.0
#     @test get_heuristic_cost(h, 1.0, goals[1], starts[1]) == 0.0
#     @test get_heuristic_cost(h, 2.0, goals[1], starts[1]) == 1.0
# end
# HardConflictHeuristic
let
    G = Graph(5)
    for v in 1:nv(G)-1
        add_edge!(G,v,v+1)
    end
    T = 10
    num_agents = 2
    h = HardConflictHeuristic(G,T,num_agents)
    set_path!(h,num_agents,[1,2],2)
    # Agent 1 has a cost of 1 whenever it conflicts with agent 2's path
    @test get_heuristic_cost(h,1,1,2) == 1.0
    @test get_heuristic_cost(h,1,2,3) == 1.0
    @test get_heuristic_cost(h,1,2,1) == 0.0
    @test get_heuristic_cost(h,1,3,4) == 0.0
    # Agent 2 should have zero cost even when it conflicts with its own path
    @test get_heuristic_cost(h,2,1,2) == 0.0
    # Now that agent 2's path has been updated, the cost should be zero for a
    # vtx no longer on the path
    set_path!(h,num_agents,[1,2],3)
    @test get_heuristic_cost(h,1,1,2) == 0.0
end
# Full CompositeCost and CompositeHeuristic for TaskGraphs route planner
let
    G = Graph(3)
    for v in 1:nv(G)-1
        add_edge!(G,v,v+1)
    end
    start_times = [0]
    starts = [1]
    goals = [nv(G)]
    deadline = 10
    num_agents = 1
    cost_model = construct_composite_cost_model(
        FullDeadlineCost(DeadlineCost(deadline)),
        FullCostModel(sum,NullCost()),
        SumOfTravelTime()
    )
    heuristic_model = construct_composite_heuristic(
        PerfectHeuristic(G,starts,goals),
        HardConflictHeuristic(G,ne(G),num_agents),
        PerfectHeuristic(G,starts,goals),
    )
end