package workspace

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import git "../git"

test_folder :: proc(t: ^testing.T) -> string {
	path, err := os.make_directory_temp("", "gitaris-test-*", context.allocator)
	testing.expect(t, err == nil)
	return path
}

@(test)
config_first_run_and_round_trip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	path := fmt.tprintf("%s/gitaris.json", root)
	empty_inputs := [?]string{"", " \r\n\t", "{}", "{\"username\":\"Ada\"}"}
	missing, err := config_load(path)
	defer config_destroy(&missing)
	testing.expect(t, err == "" && !config_complete(missing))
	for text in empty_inputs {
		testing.expect(t, os.write_entire_file(path, text) == nil)
		config, message := config_load(path)
		testing.expect(t, message == "" && !config_complete(config))
		config_destroy(&config)
	}
	invalid_inputs := [?]string{"{oops", "null", "[]", "{\"email\":42}"}
	for text in invalid_inputs {
		testing.expect(t, os.write_entire_file(path, text) == nil)
		config, message := config_load(path)
		testing.expect(t, message != "" && !config_complete(config))
		config_destroy(&config)
	}
	want := Config{"C:\\Users\\Ada\\.ssh", "C:\\Projects\\étoile", "Ada \"Lovelace\"", "ada@example.com"}
	testing.expect(t, config_save(want, path) == "")
	actual, message := config_load(path)
	defer config_destroy(&actual)
	testing.expect(t, message == "" && actual == want)
	// Saving twice exercises replacement of an existing file on Windows too.
	want.username = "Grace Hopper"
	testing.expect(t, config_save(want, path) == "")
	reloaded, reload_error := config_load(path)
	defer config_destroy(&reloaded)
	testing.expect(t, reload_error == "" && reloaded == want)
	testing.expect(t, config_save(want, fmt.tprintf("%s/missing/gitaris.json", root)) != "")
	testing.expect(t, normalize_path(fmt.tprintf(" \"%s\" ", root)) == root)
}

test_ok :: proc(t: ^testing.T, code: c.int) -> bool {
	return testing.expectf(t, code == git.OK, "%d: %s", code, git.last_error_message())
}

test_commit :: proc(t: ^testing.T, repo: ^git.Repository, message: string) -> git.Oid {
	options: git.Commit_Create_Options
	_ = test_ok(t, git.commit_create_options_init(&options, git.COMMIT_CREATE_OPTIONS_VERSION))
	options.flags.allow_empty_commit = true
	id, result := git.commit(repo, cstring_temp(message), &options)
	_ = test_ok(t, result)
	return id
}

test_ref :: proc(t: ^testing.T, repo: ^git.Repository, name: string, id: ^git.Oid) {
	ref: ^git.Reference
	_ = test_ok(t, git.reference_create(&ref, repo, cstring_temp(name), id, 0, nil))
	git.reference_free(ref)
}

@(test)
repository_history_selection_pagination_and_restart :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	repo: ^git.Repository
	if !test_ok(t, git.repository_init(&repo, cstring_temp(root), 0)) do return
	defer git.repository_free(repo)
	if !test_ok(t, git.repository_set_head(repo, "refs/heads/main")) do return
	config := Config{root, root, "History reader", "reader@example.com"}
	model: Model
	defer destroy(&model)
	if !testing.expect(t, open(&model, config) == "") do return
	testing.expect(t, len(model.branches) == 1 && model.branches[0].unborn)
	testing.expect(t, model.branches[0].name == "main" && len(model.commits) == 0 && !model.has_more)
	testing.expect(t, string(model.identity.name) == config.username && string(model.identity.email) == config.email)
	settings: ^git.Config
	if !test_ok(t, git.repository_config(&settings, repo)) do return
	_ = test_ok(t, git.config_set_string(settings, "user.name", "Fixture author"))
	_ = test_ok(t, git.config_set_string(settings, "user.email", "fixture@example.com"))
	git.config_free(settings)
	first := test_commit(t, repo, "Initial commit")
	test_ref(t, repo, "refs/heads/feature", &first)
	test_ref(t, repo, "refs/remotes/origin/feature", &first)
	for i in 0..<PAGE_SIZE + 4 do _ = test_commit(t, repo, fmt.tprintf("Commit %03d", i))
	if !testing.expect(t, refresh(&model) == "") do return
	testing.expect(t, len(model.branches) == 3 && model.branches[model.selected].name == "main")
	testing.expect(t, len(model.commits) == PAGE_SIZE && model.has_more)
	testing.expect(t, model.commits[0].message == "Commit 103" && model.commits[0].author == "Fixture author")
	testing.expect(t, load_more(&model) == "")
	testing.expect(t, len(model.commits) == PAGE_SIZE + 5 && !model.has_more)
	testing.expect(t, model.commits[len(model.commits) - 1].message == "Initial commit")
	for branch, i in model.branches {
		if branch.name == "feature" || branch.name == "origin/feature" {
			testing.expect(t, select_branch(&model, i) == "")
			testing.expect(t, len(model.commits) == 1 && model.commits[0].message == "Initial commit")
			testing.expect(t, branch.remote == (branch.name == "origin/feature"))
		}
	}
	head: ^git.Reference
	if !test_ok(t, git.repository_head(&head, repo)) do return
	testing.expect(t, string(git.reference_name(head)) == "refs/heads/main")
	git.reference_free(head)
	selected := strings.clone(model.branches[model.selected].ref_name, context.temp_allocator)
	testing.expect(t, refresh(&model) == "")
	testing.expect(t, model.branches[model.selected].ref_name == selected)
	// An invalid project must not discard the open repository or its history.
	invalid := config
	invalid.project_path = fmt.tprintf("%s/does-not-exist", root)
	testing.expect(t, open(&model, invalid) != "" && model.config == config)
	path := fmt.tprintf("%s/gitaris.json", root)
	testing.expect(t, config_save(config, path) == "")
	saved, message := config_load(path)
	defer config_destroy(&saved)
	testing.expect(t, message == "")
	restarted: Model
	defer destroy(&restarted)
	testing.expect(t, open(&restarted, saved) == "")
	testing.expect(t, restarted.branches[restarted.selected].name == "main" && len(restarted.commits) == PAGE_SIZE)
	// A direct HEAD is selectable even though it is not returned by branch iteration.
	ref: ^git.Reference
	if !test_ok(t, git.reference_create(&ref, repo, "HEAD", &first, 1, nil)) do return
	git.reference_free(ref)
	testing.expect(t, open(&restarted, saved) == "")
	testing.expect(t, restarted.branches[restarted.selected].name == "Detached HEAD")
	testing.expect(t, restarted.all_branches && len(restarted.commits) == PAGE_SIZE)
	testing.expect(t, select_branch(&restarted, restarted.selected) == "")
	testing.expect(t, len(restarted.commits) == 1)
}
