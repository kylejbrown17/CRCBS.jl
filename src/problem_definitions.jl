export
    MAPF,
    MultiMAPF,
    num_agents,
    num_goals

abstract type AbstractMAPF end

"""
    A MAPF is an instance of a Multi Agent Path Finding problem. It consists of
    a graph `G` whose edges have unit length, as well as a list of start and
    goal vertices on that graph. Note that this is the _labeled_ case, where
    each agent has a specific assigned destination.
"""
struct MAPF{S,G} <: AbstractMAPF# Multi Agent Path Finding Problem
    graph::G # <: AbstractGraph
    starts::Vector{S}   # Vector of initial agent states
    goals::Vector{S}    # Vector of goal states
end
num_agents(mapf::AbstractMAPF) = length(mapf.starts)
num_goals(mapf::AbstractMAPF) = length(mapf.goals)

"""
    MultiMAPF{S,G}

    A multi-stage MAPF, where agents have a sequence of assigned goals
"""
struct MultiMAPF{S,G} <: AbstractMAPF
    graph::G # <: AbstractGraph
    starts::Vector{S}   # Vector of initial agent states
    goals::Vector{Vector{S}}    # Vector of goal states
end