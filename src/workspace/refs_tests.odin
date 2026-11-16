package workspace

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import git "../git"

@(private = "file")
test_branch_index :: proc(model: ^Model, name: string) -> int {
	for branch, i in model.branches do if branch.name == name do return i
	return -1
}

@(private = "file")
test_head_name :: proc(model: ^Model) -> string {
	for branch in model.branches do if branch.head do return branch.name
	return ""
}

@(private = "file")
test_read :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(data) : "<unreadable>"
}

@(test)
branches_create_check_out_and_delete :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	repo, ok := test_workbook_repo(t, root)
	if !ok do return
	defer git.repository_free(repo)
	// Checked-out files must match byte for byte, whatever the global setting.
	settings: ^git.Config
	if test_ok(t, git.repository_config(&settings, repo)) {
		_ = test_ok(t, git.config_set_string(settings, "core.autocrlf", "false"))
		git.config_free(settings)
	}
	file := fmt.tprintf("%s/a.txt", root)
	test_commit_file(t, repo, file, transmute([]u8)string("one\n"), "One")
	test_commit_file(t, repo, file, transmute([]u8)string("two\n"), "Two")

	model: Model
	defer destroy(&model)
	if !testing.expect(t, open(&model, {root, root, "Brancher", "branch@example.invalid"}) == "") do return
	if !testing.expect(t, len(model.commits) == 2) do return
	first := strings.clone(model.commits[1].hash, context.temp_allocator)

	// Names are checked before anything is created.
	_, err := create_branch(&model, "bad name", "", false)
	testing.expectf(t, strings.contains(err, "spaces"), "got %s", err)
	_, err = create_branch(&model, "a..b", "", false)
	testing.expectf(t, strings.contains(err, "not a valid branch name"), "got %s", err)
	_, err = create_branch(&model, "main", "", false)
	testing.expectf(t, err == "A branch named main already exists.", "got %s", err)

	// At HEAD without checking out: HEAD stays on main.
	created: bool
	created, err = create_branch(&model, "feature/x", "", false)
	testing.expectf(t, created && err == "", "got %s", err)
	testing.expect(t, test_branch_index(&model, "feature/x") >= 0)
	testing.expect(t, test_head_name(&model) == "main")

	// At an older commit, checked out: the files follow and the view moves there.
	created, err = create_branch(&model, "old", first, true)
	testing.expectf(t, created && err == "", "got %s", err)
	testing.expect(t, test_head_name(&model) == "old")
	// The all-branches view stays, with the new branch selected.
	testing.expect(t, model.branches[model.selected].name == "old" && model.all_branches)
	testing.expect(t, test_read(file) == "one\n")

	notice: string
	notice, err = checkout_branch(&model, test_branch_index(&model, "main"))
	testing.expectf(t, err == "" && notice == "Checked out main.", "got %s / %s", notice, err)
	testing.expect(t, test_head_name(&model) == "main" && test_read(file) == "two\n")

	// Uncommitted edits that the switch would overwrite stop it untouched.
	testing.expect(t, os.write_entire_file(file, "mine\n") == nil)
	notice, err = checkout_branch(&model, test_branch_index(&model, "old"))
	testing.expectf(t, strings.contains(err, "uncommitted changes would be overwritten"), "got %s", err)
	testing.expect(t, test_head_name(&model) == "main" && test_read(file) == "mine\n")
	testing.expect(t, os.write_entire_file(file, "two\n") == nil)

	// The checked-out branch cannot be deleted; another one can.
	_, err = delete_branch(&model, test_branch_index(&model, "main"))
	testing.expect(t, strings.contains(err, "cannot be deleted"))
	notice, err = delete_branch(&model, test_branch_index(&model, "old"))
	testing.expectf(t, err == "" && notice == fmt.tprintf("Deleted branch old (was %s).", first[:8]), "got %s / %s", notice, err)
	testing.expect(t, test_branch_index(&model, "old") < 0 && test_branch_index(&model, "feature/x") >= 0)

	// A remote-tracking branch checks out as a new local branch tracking it.
	tip: git.Oid
	_ = test_ok(t, git.reference_name_to_id(&tip, repo, "refs/heads/main"))
	origin: ^git.Remote
	_ = test_ok(t, git.remote_create(&origin, repo, "origin", "https://example.invalid/repo.git"))
	git.remote_free(origin)
	test_ref(t, repo, "refs/remotes/origin/topic", &tip)
	testing.expect(t, refresh(&model) == "")
	notice, err = checkout_branch(&model, test_branch_index(&model, "origin/topic"))
	testing.expectf(t, err == "" && notice == "Checked out topic, a new local branch tracking origin/topic.", "got %s / %s", notice, err)
	testing.expect(t, test_head_name(&model) == "topic" && model.sync.upstream == "origin/topic")
}

@(test)
tags_create_label_scope_and_delete :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	repo, ok := test_workbook_repo(t, root)
	if !ok do return
	defer git.repository_free(repo)
	file := fmt.tprintf("%s/a.txt", root)
	test_commit_file(t, repo, file, transmute([]u8)string("one\n"), "One")
	test_commit_file(t, repo, file, transmute([]u8)string("two\n"), "Two")

	model: Model
	defer destroy(&model)
	if !testing.expect(t, open(&model, {root, root, "Tagger", "tag@example.invalid"}) == "") do return
	first := strings.clone(model.commits[1].hash, context.temp_allocator)

	// Lightweight on an older commit; annotated (with a message) at HEAD.
	testing.expect(t, create_tag(&model, "v1.9", first, "  ") == "")
	testing.expect(t, create_tag(&model, "v1.10", "", "Release ten\n\nNotes") == "")
	testing.expect(t, create_tag(&model, "v1.9", "", "") == "A tag named v1.9 already exists.")
	testing.expect(t, strings.contains(create_tag(&model, "bad~name", "", ""), "not a valid tag name"))
	if !testing.expect(t, len(model.tags) == 2) do return
	// Newest versions first: 10 sorts after 9.
	testing.expect(t, model.tags[0].name == "v1.10" && model.tags[0].annotated && model.tags[0].message == "Release ten")
	testing.expect(t, model.tags[1].name == "v1.9" && !model.tags[1].annotated)
	testing.expect(t, model.commits[0].tags == "v1.10" && model.commits[1].tags == "v1.9")

	// The annotated tag records the identity and the full message.
	ref: ^git.Reference
	if test_ok(t, git.reference_lookup(&ref, repo, "refs/tags/v1.10")) {
		annotation: ^git.Tag
		if test_ok(t, git.tag_lookup(&annotation, repo, git.reference_target(ref))) {
			testing.expect(t, string(git.tag_message(annotation)) == "Release ten\n\nNotes\n")
			testing.expect(t, string(git.tag_tagger(annotation).name) == "Tagger")
			git.tag_free(annotation)
		}
		git.reference_free(ref)
	}

	// A tag scopes the history like a branch, and survives a refresh.
	testing.expect(t, select_tag(&model, tag_index(model, "v1.9")) == "")
	testing.expect(t, model.scoped_tag == "v1.9" && len(model.commits) == 1 && model.commits[0].hash == first)
	testing.expect(t, refresh(&model) == "")
	testing.expect(t, model.scoped_tag == "v1.9" && len(model.commits) == 1)
	// Choosing a branch leaves the tag's scope.
	testing.expect(t, select_branch(&model, model.selected) == "")
	testing.expect(t, model.scoped_tag == "" && len(model.commits) == 2)

	testing.expect(t, select_tag(&model, tag_index(model, "v1.9")) == "")
	testing.expect(t, delete_tag(&model, "v1.9") == "")
	testing.expect(t, len(model.tags) == 1 && model.scoped_tag == "" && len(model.commits) == 2)
	testing.expect(t, model.commits[1].tags == "")
}

@(test)
natural_order_compares_numbers_by_value :: proc(t: ^testing.T) {
	testing.expect(t, natural_less("v1.9", "v1.10"))
	testing.expect(t, !natural_less("v1.10", "v1.9"))
	testing.expect(t, natural_less("v1.2", "v1.2.1"))
	testing.expect(t, natural_less("alpha", "beta"))
	testing.expect(t, natural_less("v2", "v010"))
	testing.expect(t, !natural_less("v1", "v1"))
}

@(test)
remote_task_pushes_one_tag_or_all_tags :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	server_path := fmt.tprintf("%s/server", root)
	client_path := fmt.tprintf("%s/client", root)
	server := test_repo(t, server_path, true)
	if server == nil do return
	defer git.repository_free(server)
	client := test_repo(t, client_path)
	if client == nil do return
	defer git.repository_free(client)
	remote: ^git.Remote
	if !test_ok(t, git.remote_create(&remote, client, "origin", cstring_temp(server_path))) do return
	git.remote_free(remote)
	test_write_file(t, client_path, "file.txt", "base\n")
	if !test_ok(t, git.stage_all(client)) do return
	_ = test_commit(t, client, "Base")

	model: Model
	defer destroy(&model)
	task: Remote_Task
	defer remote_destroy(&task)
	if !testing.expect(t, open(&model, Config{root, client_path, "Tag user", "tag-user@example.invalid"}) == "") do return
	testing.expect(t, remote_tag_start(&task, &model, "") == "This repository has no tags to push.")
	testing.expect(t, create_tag(&model, "v1", "", "") == "")
	testing.expect(t, create_tag(&model, "v2", "", "Second") == "")

	// One tag: only it reaches the server.
	if !testing.expect(t, remote_tag_start(&task, &model, "v1") == "") do return
	testing.expect(t, remote_wait(&task))
	testing.expectf(t, !task.failed && remote_message(&task) == "Pushed tag v1 to origin.", "%s", remote_message(&task))
	id: git.Oid
	testing.expect(t, git.reference_name_to_id(&id, server, "refs/tags/v1") == git.OK)
	testing.expect(t, git.reference_name_to_id(&id, server, "refs/tags/v2") != git.OK)

	// All tags; then a server tag pointing elsewhere is not replaced.
	if !testing.expect(t, remote_tag_start(&task, &model, "") == "") do return
	testing.expect(t, remote_wait(&task))
	testing.expectf(t, !task.failed && remote_message(&task) == "Pushed 2 tags to origin.", "%s", remote_message(&task))
	testing.expect(t, git.reference_name_to_id(&id, server, "refs/tags/v2") == git.OK)
	before: git.Oid
	testing.expect(t, git.reference_name_to_id(&before, server, "refs/tags/v1") == git.OK)
	defer {
		after: git.Oid
		testing.expect(t, git.reference_name_to_id(&after, server, "refs/tags/v1") == git.OK && git.oid_equal(&before, &after) != 0)
	}
	test_write_file(t, client_path, "file.txt", "next\n")
	if !test_ok(t, git.stage_all(client)) do return
	_ = test_commit(t, client, "Next")
	testing.expect(t, refresh(&model) == "" && delete_tag(&model, "v1") == "" && create_tag(&model, "v1", "", "") == "")
	if !testing.expect(t, remote_tag_start(&task, &model, "v1") == "") do return
	testing.expect(t, remote_wait(&task))
	testing.expectf(t, task.failed, "moving a pushed tag must fail: %s", remote_message(&task))
}
