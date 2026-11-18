package workspace

// Commit graph layout: assigns each commit a lane and the edges to its parents.

import git "../git"

Graph_Edge :: struct {
	// X is a lane; Y is a fraction of a commit row (the node is at 0.5).
	from, to: [2]f32,
	color: int,
}

Graph_Row :: struct {
	lane, color: int,
	edges: [dynamic]Graph_Edge,
}

Graph_Lane :: struct {
	target: git.Oid, // A zero type marks a reusable lane.
	color: int,
}

Commit_Graph :: struct {
	lanes: [dynamic]Graph_Lane,
	width, next_color: int,
}

graph_find :: proc(graph: ^Commit_Graph, id: git.Oid) -> int {
	target := id
	for &lane, i in graph.lanes {
		if lane.target.type != 0 && git.oid_equal(&lane.target, &target) != 0 do return i
	}
	return -1
}

graph_reserve :: proc(graph: ^Commit_Graph) -> int {
	for lane, i in graph.lanes do if lane.target.type == 0 do return i
	append(&graph.lanes, Graph_Lane{})
	graph.width = max(graph.width, len(graph.lanes))
	return len(graph.lanes) - 1
}

// The topological revwalk visits children before parents. Keep pending parents
// in stable lanes rather than shifting columns whenever a branch ends; this
// also lets Load more continue the graph without moving already visible nodes.
graph_append :: proc(graph: ^Commit_Graph, id: git.Oid, parents: []git.Oid) -> Graph_Row {
	lane := graph_find(graph, id)
	incoming := lane >= 0
	if !incoming {
		lane = graph_reserve(graph)
		graph.lanes[lane] = {id, graph.next_color}
		graph.next_color += 1
	}
	row := Graph_Row{lane = lane, color = graph.lanes[lane].color}
	for pending, i in graph.lanes {
		if pending.target.type == 0 || (i == lane && !incoming) do continue
		append(&row.edges, Graph_Edge{{f32(i), 0}, {f32(i), i == lane ? 0.5 : 1}, pending.color})
	}
	graph.lanes[lane] = {}
	for parent, i in parents {
		parent_lane := graph_find(graph, parent)
		if parent_lane < 0 {
			// First-parent history keeps its color. Other parents start new lanes;
			// a parent already pending in another lane joins that existing line.
			parent_lane = i == 0 ? lane : graph_reserve(graph)
			color := i == 0 ? row.color : graph.next_color
			if i != 0 do graph.next_color += 1
			graph.lanes[parent_lane] = {parent, color}
		}
		append(&row.edges, Graph_Edge{{f32(lane), 0.5}, {f32(parent_lane), 1}, graph.lanes[parent_lane].color})
	}
	return row
}
