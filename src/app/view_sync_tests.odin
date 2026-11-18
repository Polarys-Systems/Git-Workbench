package app

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import font_core "../font"
import "../git"
import "../ui"
import "../workspace"

workbench_sync_test_visible :: proc(ctx: ^ui.UiContext, text: string) -> bool {
	for box in ui.elements(ctx) {
		if box.boundary_rect.height > 0 && strings.contains(strings.to_string(box.text), text) do return true
	}
	return false
}

@(test)
working_tree_diff_and_sync_panel_push_and_pull_strategy :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root, err := os.make_directory_temp("", "workbench-sync-ui-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer delete(root)
	defer _ = os.remove_all(root)
	server_path, client_path := fmt.tprintf("%s/server", root), fmt.tprintf("%s/client", root)
	server, client: ^git.Repository
	if !testing.expect(t, git.repository_init(&server, workspace.cstring_temp(server_path), 1) == git.OK) do return
	defer git.repository_free(server)
	if !testing.expect(t, git.repository_init(&client, workspace.cstring_temp(client_path), 0) == git.OK) do return
	defer git.repository_free(client)
	testing.expect(t, git.repository_set_head(client, "refs/heads/main") == git.OK)
	remote: ^git.Remote
	if !testing.expect(t, git.remote_create(&remote, client, "origin", workspace.cstring_temp(server_path)) == git.OK) do return
	git.remote_free(remote)
	identity: ^git.Signature
	if !testing.expect(t, git.signature_now(&identity, "Sync UI test", "sync-ui@example.invalid") == git.OK) do return
	defer git.signature_free(identity)
	options: git.Commit_Create_Options
	testing.expect(t, git.commit_create_options_init(&options, git.COMMIT_CREATE_OPTIONS_VERSION) == git.OK)
	options.author, options.committer = identity, identity
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/notes.txt", client_path), "first line\n") == nil)
	testing.expect(t, git.stage_all(client) == git.OK)
	_, result := git.commit(client, "Initial notes", &options)
	if !testing.expect(t, result == git.OK) do return
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/notes.txt", client_path), "first line\nsecond line\n") == nil)

	state := Workbench{ready = true, search = strings.builder_make()}
	defer workbench_destroy(&state)
	if !testing.expect(t, workspace.open(&state.model, {root, client_path, "Reader", "reader@example.invalid"}) == "") do return
	ctx := ui.init()
	defer ui.destroy(ctx)
	mono: font_core.Face
	w, scale: f32 = 1000, 1

	// The working tree diff shows uncommitted edits against HEAD.
	workbench_changes_test_click(t, ctx, &state, &mono, "Working tree", w, scale)
	if !testing.expect(t, state.model.changes.working && state.error == "") do return
	testing.expect(t, workbench_sync_test_visible(ctx, "Uncommitted changes") && workbench_sync_test_visible(ctx, "second line"))
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/notes.txt", client_path), "first line\n") == nil)
	workbench_changes_test_click(t, ctx, &state, &mono, "Reload", w, scale)
	testing.expect(t, len(state.model.changes.files) == 0 && workbench_sync_test_visible(ctx, "No uncommitted changes"))
	workbench_changes_test_click(t, ctx, &state, &mono, "← History", w, scale)
	testing.expect(t, !workspace.changes_open(state.model.changes))

	// Sync: the pull strategy toggles pull.rebase in the repository config.
	workbench_changes_test_click(t, ctx, &state, &mono, "Sync", w, scale)
	if !testing.expect(t, state.menu == .SYNC) do return
	testing.expect(t, workbench_sync_test_visible(ctx, "no upstream"))
	workbench_changes_test_click(t, ctx, &state, &mono, "Rebase local commits", w, scale)
	testing.expect(t, state.model.sync.rebase && workspace.pull_rebase_enabled(client, "main"))
	workbench_changes_test_click(t, ctx, &state, &mono, "Fast-forward only", w, scale)
	testing.expect(t, !state.model.sync.rebase && !workspace.pull_rebase_enabled(client, "main"))

	// Pull needs an upstream; Push publishes the branch in the background.
	workbench_changes_test_click(t, ctx, &state, &mono, "Pull", w, scale)
	testing.expect(t, strings.contains(state.error, "no upstream"))
	workbench_changes_test_click(t, ctx, &state, &mono, "Push", w, scale)
	workspace.remote_await(&state.remote)
	workbench_changes_test_frame(ctx, &state, &mono, w, scale)
	testing.expectf(t, state.error == "" && state.notice == "Pushed main to origin/main.", "%s / %s", state.error, state.notice)
	testing.expect(t, state.model.sync.upstream == "origin/main" && workbench_sync_test_visible(ctx, "main  →  origin/main"))
	testing.expect(t, workbench_sync_test_visible(ctx, "Pushed main to origin/main."))

	// Force push needs a confirming click and can be cancelled.
	workbench_changes_test_click(t, ctx, &state, &mono, "Force push (lease)", w, scale)
	testing.expect(t, state.force_armed && workbench_sync_test_visible(ctx, "--force-with-lease"))
	testing.expect(t, !workspace.remote_busy(&state.remote))
	workbench_changes_test_click(t, ctx, &state, &mono, "Cancel", w, scale)
	testing.expect(t, !state.force_armed && !workbench_sync_test_visible(ctx, "--force-with-lease"))
	testing.expect(t, !workbench_sync_test_visible(ctx, "Confirm force push") && !workspace.remote_busy(&state.remote))
	workbench_changes_test_click(t, ctx, &state, &mono, "Force push (lease)", w, scale)
	workbench_changes_test_click(t, ctx, &state, &mono, "Confirm force push", w, scale)
	workspace.remote_await(&state.remote)
	workbench_changes_test_frame(ctx, &state, &mono, w, scale)
	testing.expectf(t, state.error == "" && strings.has_prefix(state.notice, "Force-pushed (with lease)"), "%s / %s", state.error, state.notice)

	workbench_changes_test_click(t, ctx, &state, &mono, "Done", w, scale)
	testing.expect(t, state.menu == .NONE && workbench_sync_test_visible(ctx, "Force-pushed (with lease)"))
}
