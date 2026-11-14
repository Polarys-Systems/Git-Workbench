package workspace

import "core:c"
import "core:fmt"
import "core:os"
import "core:testing"

import git "../git"

test_changed_file :: proc(t: ^testing.T, model: ^Model, path: string) -> bool {
	for file, i in model.changes.files {
		if file.path == path do return testing.expect(t, select_file(model, i) == "")
	}
	return testing.expectf(t, false, "Changed file not found: %s", path)
}

test_change_line :: proc(t: ^testing.T, file: File_Changes, kind: Change_Kind, text: string,
	old_line, new_line: int) {
	for line in file.lines {
		if line.kind == kind && line.text == text {
			testing.expect(t, line.old_line == old_line && line.new_line == new_line)
			return
		}
	}
	testing.expectf(t, false, "Diff line not found: %v %s", kind, text)
}

@(test)
commit_changes_roots_files_renames_binary_and_lifecycle :: proc(t: ^testing.T) {
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
	settings: ^git.Config
	if !test_ok(t, git.repository_config(&settings, repo)) do return
	_ = test_ok(t, git.config_set_string(settings, "user.name", "Changes fixture"))
	_ = test_ok(t, git.config_set_string(settings, "user.email", "changes@example.invalid"))
	_ = test_ok(t, git.config_set_string(settings, "core.autocrlf", "false"))
	git.config_free(settings)
	names := [?]string{"alpha.txt", "deleted.txt", "rename-me.txt", "empty.txt", "binary.dat", "no-newline.txt"}
	contents := [?]string{"keep\nremove\n", "gone\n", "rename only\nstays identical\n", "", "\x00old\n", "old ending"}
	for name, i in names do testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", root, name), contents[i]) == nil)
	if !test_ok(t, git.stage_all(repo)) do return
	first := test_commit(t, repo, "Initial files")
	test_ref(t, repo, "refs/heads/root-only", &first)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/alpha.txt", root), "keep\n\tadded\n") == nil)
	testing.expect(t, os.remove(fmt.tprintf("%s/deleted.txt", root)) == nil)
	testing.expect(t, os.rename(fmt.tprintf("%s/rename-me.txt", root), fmt.tprintf("%s/renamed.txt", root)) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/added.txt", root), "brand new\n") == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/binary.dat", root), "\x00new\n") == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/no-newline.txt", root), "new ending") == nil)
	if !test_ok(t, git.stage_all(repo)) do return
	_ = test_commit(t, repo, "Edit files")
	_ = test_commit(t, repo, "Empty commit")
	// Worktree and index changes must never leak into the historical diff.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/alpha.txt", root), "not committed\n") == nil)
	if !test_ok(t, git.stage_all(repo)) do return
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/alpha.txt", root), "not staged either\n") == nil)
	model: Model
	defer destroy(&model)
	if !testing.expect(t, open(&model, {root, root, "Reader", "reader@example.invalid"}) == "") do return
	testing.expect(t, model.changes.hash == "")
	if !testing.expect(t, select_commit(&model, 0) == "") do return
	testing.expect(t, model.changes.hash == model.commits[0].hash && len(model.changes.files) == 0)
	if !testing.expect(t, select_commit(&model, 1) == "") do return
	testing.expect(t, len(model.changes.files) == 6 && model.changes.file.index == 0)
	if test_changed_file(t, &model, "alpha.txt") {
		testing.expect(t, model.changes.file.additions == 1 && model.changes.file.deletions == 1)
		test_change_line(t, model.changes.file, .CONTEXT, "keep", 1, 1)
		test_change_line(t, model.changes.file, .DELETION, "remove", 2, 0)
		test_change_line(t, model.changes.file, .ADDITION, "    added", 0, 2)
		testing.expect(t, model.changes.file.lines[0].kind == .HUNK)
	}
	if test_changed_file(t, &model, "added.txt") {
		testing.expect(t, model.changes.files[model.changes.file.index].status == git.DELTA_ADDED)
		test_change_line(t, model.changes.file, .ADDITION, "brand new", 0, 1)
	}
	if test_changed_file(t, &model, "deleted.txt") {
		testing.expect(t, model.changes.files[model.changes.file.index].status == git.DELTA_DELETED)
		test_change_line(t, model.changes.file, .DELETION, "gone", 1, 0)
	}
	if test_changed_file(t, &model, "renamed.txt") {
		file := model.changes.files[model.changes.file.index]
		testing.expect(t, file.status == git.DELTA_RENAMED && file.old_path == "rename-me.txt")
		testing.expect(t, len(model.changes.file.lines) == 0 && !model.changes.file.binary)
	}
	if test_changed_file(t, &model, "binary.dat") {
		testing.expect(t, model.changes.file.binary && len(model.changes.file.lines) == 0)
	}
	if test_changed_file(t, &model, "no-newline.txt") {
		test_change_line(t, model.changes.file, .DELETION, "old ending", 1, 0)
		test_change_line(t, model.changes.file, .ADDITION, "new ending", 0, 1)
		notes := 0
		for line in model.changes.file.lines do if line.kind == .NOTE do notes += 1
		testing.expect(t, notes > 0 && model.changes.file.additions == 1 && model.changes.file.deletions == 1)
	}
	// Invalid selections preserve the current view, rather than showing stale data
	// for another file or releasing the still-displayed diff.
	hash, selected := model.changes.hash, model.changes.file.index
	testing.expect(t, select_commit(&model, -1) != "" && model.changes.hash == hash)
	testing.expect(t, select_commit(&model, len(model.commits)) != "" && model.changes.hash == hash)
	testing.expect(t, select_file(&model, -1) != "" && model.changes.file.index == selected)
	testing.expect(t, select_file(&model, len(model.changes.files)) != "" && model.changes.file.index == selected)
	if !testing.expect(t, select_commit(&model, 2) == "") do return
	testing.expect(t, len(model.changes.files) == len(names))
	for file in model.changes.files do testing.expect(t, file.status == git.DELTA_ADDED)
	if test_changed_file(t, &model, "alpha.txt") {
		testing.expect(t, model.changes.file.deletions == 0 && model.changes.file.additions == 2)
		test_change_line(t, model.changes.file, .ADDITION, "remove", 0, 2)
	}
	if test_changed_file(t, &model, "empty.txt") {
		testing.expect(t, !model.changes.file.binary && len(model.changes.file.lines) == 0)
	}
	for branch, i in model.branches {
		if branch.name == "root-only" {
			testing.expect(t, select_branch(&model, i) == "")
			testing.expect(t, model.changes.hash == "" && model.changes.diff == nil && len(model.changes.files) == 0)
		}
	}
	testing.expect(t, select_commit(&model, 0) == "")
	testing.expect(t, refresh(&model) == "" && model.changes.hash == "")
	actual, read_error := os.read_entire_file(fmt.tprintf("%s/alpha.txt", root), context.allocator)
	defer delete(actual)
	testing.expect(t, read_error == nil && string(actual) == "not staged either\n")
	head: ^git.Reference
	if test_ok(t, git.repository_head(&head, repo)) {
		testing.expect(t, string(git.reference_name(head)) == "refs/heads/main")
		git.reference_free(head)
	}
}

@(test)
change_text_preserves_whitespace_and_tab_stops :: proc(t: ^testing.T) {
	text, columns := change_text("a\tb\t é  \r\n")
	defer delete(text)
	testing.expect(t, text == "a   b    é  " && columns == 12)
}

@(test)
merge_changes_compare_against_first_parent :: proc(t: ^testing.T) {
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
	model: Model
	defer destroy(&model)
	if !testing.expect(t, open(&model, {root, root, "Merge author", "merge@example.invalid"}) == "") do return
	identity := model.identity
	messages := [4]cstring{"Root", "Feature", "Main", "Merge"}
	contents := [4]string{"root\n", "feature\n", "main\n", "merged\n"}
	parent_indices := [4][]int{nil, {0}, {0}, {2, 1}}
	nodes: [4]^git.Commit
	defer for node in nodes do git.commit_free(node)
	for i in 0..<4 {
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/file.txt", root), contents[i]) == nil)
		if !test_ok(t, git.stage_all(repo)) do return
		index: ^git.Index
		if !test_ok(t, git.repository_index(&index, repo)) do return
		defer git.index_free(index)
		tree_id, commit_id: git.Oid
		if !test_ok(t, git.index_write_tree(&tree_id, index)) do return
		tree: ^git.Tree
		if !test_ok(t, git.tree_lookup(&tree, repo, &tree_id)) do return
		defer git.tree_free(tree)
		parents: [2]^git.Commit
		for p, j in parent_indices[i] do parents[j] = nodes[p]
		ref: cstring = i == 1 ? "refs/heads/feature" : "refs/heads/main"
		if !test_ok(t, git.commit_create(&commit_id, repo, ref, identity, identity, nil, messages[i],
			tree, c.size_t(len(parent_indices[i])), raw_data(parents[:]))) {
			return
		}
		if !test_ok(t, git.commit_lookup(&nodes[i], repo, &commit_id)) do return
	}
	if !testing.expect(t, refresh(&model) == "") do return
	if !testing.expect(t, select_commit(&model, 0) == "") do return
	testing.expect(t, model.commits[0].message == "Merge" && len(model.changes.files) == 1)
	test_change_line(t, model.changes.file, .DELETION, "main", 1, 0)
	test_change_line(t, model.changes.file, .ADDITION, "merged", 0, 1)
}
