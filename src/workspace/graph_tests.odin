package workspace

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import git "../git"

test_graph_id :: proc(value: u8) -> git.Oid {
	id := git.Oid{type = u8(git.OID_SHA1)}
	id.id[0] = value
	return id
}

@(test)
graph_lanes_split_join_and_reuse_without_moving :: proc(t: ^testing.T) {
	graph: Commit_Graph
	defer delete(graph.lanes)
	// An octopus merge opens three histories, which all meet at the same root.
	merge := graph_append(&graph, test_graph_id(5), []git.Oid{test_graph_id(4), test_graph_id(3), test_graph_id(2)})
	defer delete(merge.edges)
	testing.expect(t, graph.width == 3 && merge.lane == 0 && len(merge.edges) == 3)
	for edge, i in merge.edges {
		testing.expect(t, edge.from == [2]f32{0, 0.5} && edge.to == [2]f32{f32(i), 1})
	}
	main := graph_append(&graph, test_graph_id(4), []git.Oid{test_graph_id(1)})
	defer delete(main.edges)
	testing.expect(t, main.lane == 0 && main.color == merge.color)
	side := graph_append(&graph, test_graph_id(3), []git.Oid{test_graph_id(1)})
	defer delete(side.edges)
	testing.expect(t, side.lane == 1 && side.color != main.color)
	testing.expect(t, side.edges[len(side.edges) - 1].to == [2]f32{0, 1})
	other := graph_append(&graph, test_graph_id(2), []git.Oid{test_graph_id(1)})
	defer delete(other.edges)
	testing.expect(t, other.lane == 2 && other.edges[len(other.edges) - 1].to == [2]f32{0, 1})
	root := graph_append(&graph, test_graph_id(1), nil)
	defer delete(root.edges)
	testing.expect(t, root.lane == 0 && len(root.edges) == 1 && root.edges[0].to.y == 0.5)
	for lane in graph.lanes do testing.expect(t, lane.target.type == 0)
	disconnected := graph_append(&graph, test_graph_id(9), nil)
	defer delete(disconnected.edges)
	testing.expect(t, disconnected.lane == 0 && len(disconnected.edges) == 0 && disconnected.color != root.color)
}

test_graph_commit :: proc(t: ^testing.T, repo: ^git.Repository, tree: ^git.Tree,
	identity: ^git.Signature, refname, message: cstring, parents: []^git.Commit) -> ^git.Commit {
	id: git.Oid
	if !test_ok(t, git.commit_create(&id, repo, refname, identity, identity, nil, message,
		tree, c.size_t(len(parents)), raw_data(parents))) {
		return nil
	}
	commit: ^git.Commit
	_ = test_ok(t, git.commit_lookup(&commit, repo, &id))
	return commit
}

@(test)
history_graph_all_branches_labels_topology_and_pagination :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	repo: ^git.Repository
	if !test_ok(t, git.repository_init(&repo, cstring_temp(root), 0)) do return
	defer git.repository_free(repo)
	_ = test_ok(t, git.repository_set_head(repo, "refs/heads/main"))
	index: ^git.Index
	if !test_ok(t, git.repository_index(&index, repo)) do return
	defer git.index_free(index)
	tree_id: git.Oid
	if !test_ok(t, git.index_write_tree(&tree_id, index)) do return
	tree: ^git.Tree
	if !test_ok(t, git.tree_lookup(&tree, repo, &tree_id)) do return
	defer git.tree_free(tree)
	identity: ^git.Signature
	if !test_ok(t, git.signature_now(&identity, "Graph fixture", "graph@example.invalid")) do return
	defer git.signature_free(identity)
	nodes := make([dynamic]^git.Commit)
	defer {
		for node in nodes do git.commit_free(node)
		delete(nodes)
	}
	identity.when_.time = 100
	append(&nodes, test_graph_commit(t, repo, tree, identity, "refs/heads/main", "Root", nil))
	identity.when_.time = 200
	append(&nodes, test_graph_commit(t, repo, tree, identity, "refs/heads/main", "Main", []^git.Commit{nodes[0]}))
	identity.when_.time = 300
	append(&nodes, test_graph_commit(t, repo, tree, identity, "refs/heads/feature", "Feature", []^git.Commit{nodes[0]}))
	// Deliberately skew the merge's clock: topology, not time, determines edges.
	identity.when_.time = 50
	append(&nodes, test_graph_commit(t, repo, tree, identity, "refs/heads/main", "Merge", []^git.Commit{nodes[1], nodes[2]}))
	identity.when_.time = 400
	append(&nodes, test_graph_commit(t, repo, tree, identity, "refs/remotes/origin/topic", "Unmerged remote", []^git.Commit{nodes[0]}))
	parent := nodes[3]
	for i in 0..<PAGE_SIZE {
		identity.when_.time = 500 + i64(i)
		parent = test_graph_commit(t, repo, tree, identity, "refs/heads/main", cstring_temp(fmt.tprintf("Later %d", i)), []^git.Commit{parent})
		append(&nodes, parent)
	}
	for node in nodes do if !testing.expect(t, node != nil) do return
	model: Model
	defer destroy(&model)
	if !testing.expect(t, open(&model, {root, root, "Reader", "reader@example.invalid"}) == "") do return
	testing.expect(t, model.all_branches && len(model.commits) == PAGE_SIZE && model.has_more)
	testing.expect(t, strings.contains(model.commits[0].refs, "HEAD → main"))
	first := model.commits[0].graph
	if !testing.expect(t, load_more(&model) == "") do return
	testing.expect(t, len(model.commits) == PAGE_SIZE + 5 && !model.has_more && model.graph.width >= 2)
	testing.expect(t, model.commits[0].graph.lane == first.lane && model.commits[0].graph.color == first.color)
	positions := make(map[string]int)
	defer delete(positions)
	for commit, i in model.commits do positions[commit.hash] = i
	testing.expect(t, len(positions) == len(model.commits))
	for commit, i in model.commits {
		id: git.Oid
		if !test_ok(t, git.oid_from_string(&id, cstring_temp(commit.hash), git.OID_SHA1)) do return
		node: ^git.Commit
		if !test_ok(t, git.commit_lookup(&node, repo, &id)) do return
		defer git.commit_free(node)
		for p in 0..<git.commit_parentcount(node) {
			hash: [65]u8
			_ = git.oid_tostr(raw_data(hash[:]), 65, git.commit_parent_id(node, p))
			parent_row, found := positions[string(cstring(raw_data(hash[:])))]
			testing.expect(t, found && parent_row > i)
		}
		if commit.message == "Unmerged remote" do testing.expect(t, commit.refs == "origin/topic")
		if commit.message == "Merge" {
			outgoing, diagonal := 0, false
			for edge in commit.graph.edges {
				if edge.from.y == 0.5 do outgoing += 1
				diagonal = diagonal || edge.from.x != edge.to.x
			}
			testing.expect(t, outgoing == 2 && diagonal)
		}
	}
	for branch, i in model.branches {
		if branch.name == "feature" {
			testing.expect(t, select_branch(&model, i) == "" && !model.all_branches)
			testing.expect(t, len(model.commits) == 2 && model.graph.width == 1)
			break
		}
	}
	testing.expect(t, refresh(&model) == "" && !model.all_branches && len(model.commits) == 2)
	testing.expect(t, select_history(&model, model.selected, true) == "")
	testing.expect(t, refresh(&model) == "" && model.all_branches)
}
