package app

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import font_core "../font"
import "../git"
import "../ui"
import "../workspace"

@(private = "file")
submodule_test_commit :: proc(t: ^testing.T, repo: ^git.Repository, message: cstring) -> git.Oid {
	identity: ^git.Signature
	testing.expect(t, git.signature_now(&identity, "Submodule UI", "submodule-ui@example.invalid") == git.OK)
	defer git.signature_free(identity)
	options: git.Commit_Create_Options
	testing.expect(t, git.commit_create_options_init(&options, git.COMMIT_CREATE_OPTIONS_VERSION) == git.OK)
	options.author, options.committer = identity, identity
	id, result := git.commit(repo, message, &options)
	testing.expectf(t, result == git.OK, "commit: %s", git.last_error_message())
	return id
}

// A parent repository recording lib at vendor/lib, then updated so the
// submodule is checked out (as after git submodule update --init).
@(private = "file")
submodule_test_fixture :: proc(t: ^testing.T, root: string) -> (parent_path: string, ok: bool) {
	lib_path, _ := strings.replace_all(fmt.tprintf("%s/lib", root), "\\", "/", context.temp_allocator)
	parent_path = fmt.tprintf("%s/parent", root)
	lib, parent: ^git.Repository
	if !testing.expect(t, git.repository_init(&lib, workspace.cstring_temp(lib_path), 0) == git.OK) do return
	defer git.repository_free(lib)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/lib.txt", lib_path), "lib\n") == nil)
	testing.expect(t, git.stage_all(lib) == git.OK)
	recorded := submodule_test_commit(t, lib, "Library")
	if !testing.expect(t, git.repository_init(&parent, workspace.cstring_temp(parent_path), 0) == git.OK) do return
	defer git.repository_free(parent)
	testing.expect(t, git.repository_set_head(parent, "refs/heads/main") == git.OK)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/.gitmodules", parent_path),
		transmute([]u8)fmt.tprintf("[submodule \"lib\"]\n\tpath = vendor/lib\n\turl = %s\n", lib_path)) == nil)
	index: ^git.Index
	if !testing.expect(t, git.repository_index(&index, parent) == git.OK) do return
	testing.expect(t, git.index_add_bypath(index, ".gitmodules") == git.OK)
	entry := git.Index_Entry{mode = u32(git.FILEMODE_COMMIT), id = recorded, path = "vendor/lib"}
	testing.expect(t, git.index_add(index, &entry) == git.OK)
	testing.expect(t, git.index_write(index) == git.OK)
	git.index_free(index)
	_ = submodule_test_commit(t, parent, "Add lib")

	model: workspace.Model
	defer workspace.destroy(&model)
	task: workspace.Remote_Task
	defer workspace.remote_destroy(&task)
	if !testing.expect(t, workspace.open(&model, {root, parent_path, "Submodule UI", "submodule-ui@example.invalid"}) == "") do return
	if !testing.expect(t, workspace.remote_submodule_start(&task, &model) == "") do return
	testing.expect(t, workspace.remote_wait(&task))
	ok = testing.expectf(t, !task.failed, "update: %s", workspace.remote_message(&task))
	// Saved projects are normalized absolute paths.
	parent_path = workspace.normalize_path(parent_path)
	return
}

@(test)
submodule_navigation_keeps_the_open_repository_clear :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root, err := os.make_directory_temp("", "workbench-submodule-ui-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer delete(root)
	defer _ = os.remove_all(root)
	parent_path, ok := submodule_test_fixture(t, root)
	if !ok do return

	state := Workbench{ready = true, search = strings.builder_make(), submodule_focus = -1}
	defer workbench_destroy(&state)
	for field in ([]^strings.Builder{&state.ssh, &state.project, &state.username, &state.email}) do field^ = strings.builder_make()
	if !testing.expect(t, workspace.open(&state.model, {root, parent_path, "Submodule UI", "submodule-ui@example.invalid"}) == "") do return
	ctx := ui.init()
	defer ui.destroy(ctx)
	mono: font_core.Face
	w, scale: f32 = 1000, 1
	parent_name := filepath.base(parent_path)

	// The sidebar lists the submodule; clicking a checked-out one opens it.
	workbench_changes_test_frame(ctx, &state, &mono, w, scale)
	testing.expect(t, workbench_sync_test_visible(ctx, "vendor/lib") && workbench_sync_test_visible(ctx, "Up to date · open"))
	testing.expect(t, state.window_title == fmt.tprintf("%s — Git-Workbench", parent_name))
	workbench_changes_test_click(t, ctx, &state, &mono, "vendor/lib", w, scale)
	testing.expect(t, state.error == "" && len(state.parents) == 1 && state.trail[0] == "vendor/lib")
	opened, _ := strings.replace_all(state.model.config.project_path, "\\", "/", context.temp_allocator)
	testing.expect(t, strings.has_suffix(opened, "parent/vendor/lib"))
	testing.expect(t, len(state.model.commits) == 1 && state.model.commits[0].message == "Library")
	// Breadcrumb, tag, sidebar and title all name the submodule and its parent.
	testing.expect(t, workbench_repo_label(&state) == "vendor/lib" && workbench_parent_label(&state) == parent_name)
	testing.expect(t, workbench_sync_test_visible(ctx, "SUBMODULE") && workbench_sync_test_visible(ctx, fmt.tprintf("Back to %s", parent_name)))
	testing.expect(t, state.window_title == fmt.tprintf("%s › vendor/lib — Git-Workbench", parent_name))
	testing.expect(t, strings.contains(state.notice, "Opened submodule vendor/lib"))

	// Saving Preferences inside the submodule keeps it open and saves the parent.
	config_path := fmt.tprintf("%s/gitaris.json", root)
	workbench_open_menu(&state, .PREFERENCES)
	testing.expect(t, strings.to_string(state.project) == parent_path)
	workbench_set_field(&state.username, "Renamed")
	workbench_start(&state, config_path)
	testing.expect(t, state.error == "" && len(state.parents) == 1 && state.model.config.username == "Renamed")
	saved, load_error := workspace.config_load(config_path)
	defer workspace.config_destroy(&saved)
	testing.expect(t, load_error == "" && saved.project_path == parent_path && saved.username == "Renamed")

	// The parent crumb returns to the parent and points at the submodule.
	workbench_changes_test_click(t, ctx, &state, &mono, parent_name, w, scale)
	testing.expect(t, state.error == "" && len(state.parents) == 0 && len(state.trail) == 0)
	testing.expect(t, state.model.config.project_path == parent_path && state.submodule_focus == 0)
	testing.expect(t, state.window_title == fmt.tprintf("%s — Git-Workbench", parent_name))

	// The Submodules view opens it too; opening another project leaves it.
	workbench_open_menu(&state, .SUBMODULES)
	workbench_changes_test_frame(ctx, &state, &mono, w, scale)
	testing.expect(t, workbench_sync_test_visible(ctx, "Up to date") && workbench_sync_test_visible(ctx, "recorded "))
	workbench_changes_test_click(t, ctx, &state, &mono, "Open  →", w, scale)
	testing.expect(t, len(state.parents) == 1 && state.menu == .NONE)
	workbench_open_menu(&state, .PROJECT)
	workbench_start(&state, config_path)
	testing.expect(t, state.error == "" && len(state.parents) == 0 && state.model.config.project_path == parent_path)
}
