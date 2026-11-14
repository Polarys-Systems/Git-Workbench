package workspace

import "core:fmt"
import "core:os"
import "core:testing"

import git "../git"

test_working_file :: proc(t: ^testing.T, model: ^Model, path: string) -> int {
	for file, i in model.changes.files do if file.path == path do return i
	testing.expectf(t, false, "Working change not found: %s", path)
	return -1
}

test_stage_state :: proc(t: ^testing.T, model: ^Model, path: string, staged, unstaged: bool) {
	i := test_working_file(t, model, path)
	if i < 0 do return
	file := model.changes.files[i]
	testing.expectf(t, file.staged == staged && file.unstaged == unstaged,
		"%s: staged %v (want %v), unstaged %v (want %v)", path, file.staged, staged, file.unstaged, unstaged)
}

@(test)
stage_unstage_and_commit_selected_files :: proc(t: ^testing.T) {
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
	_ = test_ok(t, git.config_set_string(settings, "core.autocrlf", "false"))
	git.config_free(settings)

	model: Model
	defer destroy(&model)
	if !testing.expect(t, open(&model, {root, root, "Stage author", "stage@example.invalid"}) == "") do return

	// Before the first commit: stage one of two new files, then commit it.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/a.txt", root), "a\n") == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/b.txt", root), "b\n") == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/gone.txt", root), "gone\n") == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/move-me.txt", root), "same content\nfor rename detection\n") == nil)
	if !testing.expect(t, select_working_changes(&model) == "") do return
	testing.expect(t, len(model.changes.files) == 4)
	test_stage_state(t, &model, "a.txt", false, true)
	testing.expect(t, commit_staged(&model, "Nothing yet") == "Nothing is staged. Stage files before committing.")
	testing.expect(t, commit_staged(&model, "  \n ") == "Enter a commit message.")

	a := test_working_file(t, &model, "a.txt")
	if a < 0 do return
	testing.expect(t, stage_files(&model, {a}) == "")
	test_stage_state(t, &model, "a.txt", true, false)
	test_stage_state(t, &model, "b.txt", false, true)
	// Unstaging before the first commit removes the entry from the index.
	a = test_working_file(t, &model, "a.txt")
	testing.expect(t, unstage_files(&model, {a}) == "")
	test_stage_state(t, &model, "a.txt", false, true)

	// Checked files are the targets; stage everything but b.txt and commit.
	for &file in model.changes.files do file.selected = file.path != "b.txt"
	targets := stage_targets(model.changes)
	testing.expect(t, len(targets) == 3)
	testing.expect(t, stage_files(&model, targets[:]) == "")
	for file in model.changes.files do testing.expect(t, file.selected == (file.path != "b.txt"))
	testing.expect(t, commit_staged(&model, "\n  Initial files\n\nBody line\n\n") == "")
	testing.expect(t, model.changes.working && len(model.changes.files) == 1)
	test_stage_state(t, &model, "b.txt", false, true)
	if !testing.expect(t, len(model.commits) == 1) do return
	testing.expect(t, model.commits[0].message == "Initial files" && model.commits[0].author == "Stage author")
	head: git.Oid
	_ = test_ok(t, git.reference_name_to_id(&head, model.repo, "HEAD"))
	node: ^git.Commit
	if !test_ok(t, git.commit_lookup(&node, model.repo, &head)) do return
	testing.expect(t, string(git.commit_message(node)) == "Initial files\n\nBody line\n")
	testing.expect(t, string(git.commit_committer(node).email) == "stage@example.invalid")
	git.commit_free(node)

	// Modify, delete and rename tracked files; partial staging keeps the rest unstaged.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/a.txt", root), "a\nstaged\n") == nil)
	testing.expect(t, os.remove(fmt.tprintf("%s/gone.txt", root)) == nil)
	testing.expect(t, os.rename(fmt.tprintf("%s/move-me.txt", root), fmt.tprintf("%s/moved.txt", root)) == nil)
	if !testing.expect(t, select_working_changes(&model) == "") do return
	moved := test_working_file(t, &model, "moved.txt")
	gone := test_working_file(t, &model, "gone.txt")
	if moved < 0 || gone < 0 do return
	testing.expect(t, model.changes.files[moved].status == git.DELTA_RENAMED)
	testing.expect(t, stage_files(&model, {moved, gone}) == "")
	test_stage_state(t, &model, "moved.txt", true, false)
	test_stage_state(t, &model, "gone.txt", true, false)
	test_stage_state(t, &model, "a.txt", false, true)
	a = test_working_file(t, &model, "a.txt")
	testing.expect(t, stage_files(&model, {a}) == "")
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/a.txt", root), "a\nstaged\nunstaged\n") == nil)
	if !testing.expect(t, select_working_changes(&model) == "") do return
	test_stage_state(t, &model, "a.txt", true, true)
	// Unstaging the rename restores both index entries from HEAD.
	moved = test_working_file(t, &model, "moved.txt")
	testing.expect(t, unstage_files(&model, {moved}) == "")
	test_stage_state(t, &model, "moved.txt", false, true)

	testing.expect(t, commit_staged(&model, "Partial") == "")
	if !testing.expect(t, len(model.commits) == 2) do return
	testing.expect(t, model.commits[0].message == "Partial")
	// Committed: the deletion and the staged half of a.txt. Still pending: the
	// unstaged line, the rename and the untracked file.
	test_stage_state(t, &model, "a.txt", false, true)
	test_stage_state(t, &model, "b.txt", false, true)
	test_stage_state(t, &model, "moved.txt", false, true)
	for file in model.changes.files do testing.expect(t, file.path != "gone.txt")
	testing.expect(t, stage_files(&model, {}) == "Select files first.")
}
