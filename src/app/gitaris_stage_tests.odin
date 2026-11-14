package app

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import font_core "../font"
import "../git"
import "../ui"
import "../workspace"

// Clicks the checkbox at the start of a working file's row (left of its name).
gitaris_stage_test_check :: proc(t: ^testing.T, ctx: ^ui.UiContext, state: ^Gitaris,
	mono: ^font_core.Face, name: string, w, scale: f32) {
	gitaris_changes_test_frame(ctx, state, mono, w, scale)
	for box in ui.elements(ctx) {
		if strings.to_string(box.text) != name || box.boundary_rect.height <= 0 do continue
		ui.input_mouse_move(ctx, box.rect.x - 37 * scale, box.rect.y + 22 * scale)
		ui.input_mouse_button(ctx, .LEFT, true)
		gitaris_changes_test_frame(ctx, state, mono, w, scale)
		ui.input_mouse_button(ctx, .LEFT, false)
		gitaris_changes_test_frame(ctx, state, mono, w, scale)
		// The hint above the list reflects the new check on the following frame.
		gitaris_changes_test_frame(ctx, state, mono, w, scale)
		return
	}
	testing.expectf(t, false, "File row not found: %s", name)
}

@(test)
working_tree_checks_stage_unstage_and_commit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root, err := os.make_directory_temp("", "gitaris-stage-ui-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer delete(root)
	defer _ = os.remove_all(root)
	repo: ^git.Repository
	if !testing.expect(t, git.repository_init(&repo, workspace.cstring_temp(root), 0) == git.OK) do return
	defer git.repository_free(repo)
	testing.expect(t, git.repository_set_head(repo, "refs/heads/main") == git.OK)
	identity: ^git.Signature
	if !testing.expect(t, git.signature_now(&identity, "Stage UI test", "stage-ui@example.invalid") == git.OK) do return
	defer git.signature_free(identity)
	options: git.Commit_Create_Options
	testing.expect(t, git.commit_create_options_init(&options, git.COMMIT_CREATE_OPTIONS_VERSION) == git.OK)
	options.author, options.committer = identity, identity
	names := [?]string{"first.txt", "second.txt", "third.txt"}
	for name in names do testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", root, name), "v1\n") == nil)
	testing.expect(t, git.stage_all(repo) == git.OK)
	_, result := git.commit(repo, "Initial", &options)
	if !testing.expect(t, result == git.OK) do return
	for name in names do testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", root, name), "v2\n") == nil)

	state := Gitaris{ready = true, search = strings.builder_make()}
	defer gitaris_destroy(&state)
	if !testing.expect(t, workspace.open(&state.model, {root, root, "Committer", "committer@example.invalid"}) == "") do return
	ctx := ui.init()
	defer ui.destroy(ctx)
	mono: font_core.Face
	w, scale: f32 = 1000, 2
	changes := &state.model.changes

	gitaris_changes_test_click(t, ctx, &state, &mono, "Working tree", w, scale)
	if !testing.expect(t, changes.working && len(changes.files) == 3) do return
	testing.expect(t, gitaris_sync_test_visible(ctx, "Nothing staged yet"))
	testing.expect(t, gitaris_sync_test_visible(ctx, "Applies to the viewed file"))

	// Without checks, Stage acts on the viewed file only.
	gitaris_changes_test_click(t, ctx, &state, &mono, "Stage", w, scale)
	testing.expect(t, state.error == "" && changes.files[0].staged && !changes.files[1].staged)
	gitaris_changes_test_click(t, ctx, &state, &mono, "Unstage", w, scale)
	testing.expect(t, state.error == "" && !changes.files[0].staged)

	// Checking rows never changes the viewed file; Stage acts on the checked files.
	gitaris_stage_test_check(t, ctx, &state, &mono, "second.txt", w, scale)
	gitaris_stage_test_check(t, ctx, &state, &mono, "third.txt", w, scale)
	testing.expect(t, changes.file.index == 0 && !changes.files[0].selected && changes.files[1].selected && changes.files[2].selected)
	testing.expect(t, gitaris_sync_test_visible(ctx, "Applies to 2 checked files"))
	gitaris_changes_test_click(t, ctx, &state, &mono, "Stage", w, scale)
	testing.expect(t, state.error == "" && !changes.files[0].staged && changes.files[1].staged && changes.files[2].staged)
	testing.expect(t, gitaris_sync_test_visible(ctx, "2 staged files"))

	// An empty message is refused; a typed one commits only the staged files.
	gitaris_changes_test_click(t, ctx, &state, &mono, "Commit", w, scale)
	testing.expect(t, state.error == "Enter a commit message.")
	gitaris_changes_test_click(t, ctx, &state, &mono, "Commit message · the first line is the summary", w, scale)
	ui.input_text(ctx, "Update second and third")
	gitaris_changes_test_frame(ctx, &state, &mono, w, scale)
	testing.expect(t, strings.to_string(state.commit_message) == "Update second and third")
	gitaris_changes_test_click(t, ctx, &state, &mono, "Commit", w, scale)
	testing.expect(t, state.error == "" && state.notice == "Committed: Update second and third")
	testing.expect(t, len(state.commit_message.buf) == 0)
	if !testing.expect(t, changes.working && len(changes.files) == 1) do return
	testing.expect(t, changes.files[0].path == "first.txt" && !changes.files[0].staged)
	if !testing.expect(t, len(state.model.commits) == 2) do return
	testing.expect(t, state.model.commits[0].message == "Update second and third" && state.model.commits[0].author == "Committer")
	for box in ui.elements(ctx) {
		if box.boundary_rect.height <= 0 do continue
		testing.expect(t, box.boundary_rect.x >= 0 && box.boundary_rect.x + box.boundary_rect.width <= w * scale)
	}
}
