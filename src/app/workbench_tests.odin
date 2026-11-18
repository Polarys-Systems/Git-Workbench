package app

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import font_core "../font"
import "../git"
import "../ui"
import "../workspace"

@(test)
welcome_precedes_workspace_and_validates_submission :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ctx := ui.init()
	defer ui.destroy(ctx)
	body, title, welcome, icons: font_core.Face
	state := Workbench{ssh = strings.builder_make(), project = strings.builder_make(),
		username = strings.builder_make(), email = strings.builder_make(), search = strings.builder_make()}
	defer workbench_destroy(&state)
	scales := [?]f32{1, 2}
	for scale in scales {
		workbench_ui(ctx, &body, &title, &welcome, &icons, &state, nil, 1000 * scale, 720 * scale, scale)
		found, field_count := false, 0
		for box in ui.elements(ctx) {
			if strings.to_string(box.text) == "Welcome." {
				found = true
				testing.expect(t, box.style.font_id == ui.UiFont(uintptr(&welcome)))
				testing.expect(t, box.style.font_size == 74 * scale)
			}
			if .EDITABLE in box.actions do field_count += 1
			testing.expect(t, strings.to_string(box.text) != "Commit history")
		}
		testing.expect(t, found && field_count == 4)
		// Submit through the actual form button, then check inline validation.
		ui.input_mouse_move(ctx, 700 * scale, 615 * scale)
		ui.input_mouse_button(ctx, .LEFT, true)
		workbench_ui(ctx, &body, &title, &welcome, &icons, &state, nil, 1000 * scale, 720 * scale, scale)
		ui.input_mouse_button(ctx, .LEFT, false)
		workbench_ui(ctx, &body, &title, &welcome, &icons, &state, nil, 1000 * scale, 720 * scale, scale)
		testing.expect(t, !state.ready && state.error != "")
	}
}

@(test)
branch_buttons_load_the_selected_history :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root, err := os.make_directory_temp("", "workbench-branch-ui-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer delete(root)
	defer _ = os.remove_all(root)
	repo: ^git.Repository
	if !testing.expect(t, git.repository_init(&repo, workspace.cstring_temp(root), 0) == git.OK) do return
	defer git.repository_free(repo)
	testing.expect(t, git.repository_set_head(repo, "refs/heads/main") == git.OK)
	identity: ^git.Signature
	testing.expect(t, git.signature_now(&identity, "UI test", "test@example.invalid") == git.OK)
	defer git.signature_free(identity)
	options: git.Commit_Create_Options
	testing.expect(t, git.commit_create_options_init(&options, git.COMMIT_CREATE_OPTIONS_VERSION) == git.OK)
	options.flags.allow_empty_commit = true
	options.author, options.committer = identity, identity
	first, result := git.commit(repo, "Shared root", &options)
	if !testing.expect(t, result == git.OK) do return
	branch: ^git.Reference
	testing.expect(t, git.reference_create(&branch, repo, "refs/heads/feature", &first, 0, nil) == git.OK)
	git.reference_free(branch)
	_, result = git.commit(repo, "Main only", &options)
	if !testing.expect(t, result == git.OK) do return
	state := Workbench{ready = true, search = strings.builder_make()}
	defer workbench_destroy(&state)
	if !testing.expect(t, workspace.open(&state.model, {root, root, "UI test", "test@example.invalid"}) == "") do return
	ctx := ui.init()
	defer ui.destroy(ctx)
	body, title, welcome, icons: font_core.Face
	workbench_ui(ctx, &body, &title, &welcome, &icons, &state, nil, 1000, 720, 1)
	testing.expect(t, len(state.model.commits) == 2 && state.model.branches[state.model.selected].name == "main")
	// The first branch row ("feature", sorted before "main") in the sidebar.
	ui.input_mouse_move(ctx, 140, MENU_HEIGHT + 138)
	ui.input_mouse_button(ctx, .LEFT, true)
	workbench_ui(ctx, &body, &title, &welcome, &icons, &state, nil, 1000, 720, 1)
	ui.input_mouse_button(ctx, .LEFT, false)
	workbench_ui(ctx, &body, &title, &welcome, &icons, &state, nil, 1000, 720, 1)
	testing.expect(t, state.model.branches[state.model.selected].name == "feature")
	testing.expect(t, len(state.model.commits) == 1 && state.model.commits[0].message == "Shared root")
	testing.expect(t, state.error == "")
	// Saving preferences retains the branch being browsed, not just HEAD.
	workbench_open_menu(&state, .PREFERENCES)
	workbench_set_field(&state.username, "Updated reader")
	workbench_start(&state, fmt.tprintf("%s/gitaris.json", root))
	testing.expect(t, state.error == "" && state.menu == .NONE)
	testing.expect(t, state.model.config.username == "Updated reader")
	testing.expect(t, state.model.branches[state.model.selected].name == "feature")
}

@(test)
history_virtualization_and_filtering :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ctx := ui.init()
	defer ui.destroy(ctx)
	body, title, welcome, icons: font_core.Face
	state := Workbench{ready = true, search = strings.builder_make()}
	// Synthetic ownership stays in this fixture; no repository handles are needed.
	defer strings.builder_destroy(&state.search)
	state.model.config = {"keys", "project", "Ada", "ada@example.com"}
	for i in 0..<5000 {
		append(&state.model.branches, workspace.Branch{name = fmt.tprintf("branch-%d", i), ref_name = fmt.tprintf("refs/heads/branch-%d", i)})
		append(&state.model.commits, workspace.Commit{message = fmt.tprintf("Commit %04d", i), hash = "abc0123456789", author = "Ada", date = "2026-10-23"})
	}
	defer delete(state.model.branches)
	defer delete(state.model.commits)
	scales := [?]f32{1, 2}
	for scale in scales {
		strings.builder_reset(&state.search)
		workbench_ui(ctx, &body, &title, &welcome, &icons, &state, nil, 1000 * scale, 720 * scale, scale)
		testing.expect(t, ctx.n_boxes < 200)
		ui.input_mouse_move(ctx, 650 * scale, 450 * scale)
		ui.input_scroll(ctx, 0, -5000)
		workbench_ui(ctx, &body, &title, &welcome, &icons, &state, nil, 1000 * scale, 720 * scale, scale)
		testing.expect(t, ctx.windows[2].scroll_offset.y > 0)
		testing.expect(t, ctx.windows[1].scroll_offset.y == 0)
		ui.input_mouse_move(ctx, 600 * scale, (MENU_HEIGHT + 74) * scale) // Search field.
		ui.input_mouse_button(ctx, .LEFT, true)
		ui.input_text(ctx, "COMMIT 0003")
		workbench_ui(ctx, &body, &title, &welcome, &icons, &state, nil, 1000 * scale, 720 * scale, scale)
		ui.input_mouse_button(ctx, .LEFT, false)
		testing.expect(t, ctx.windows[2].scroll_offset.y == 0)
		found := false
		for box in ui.elements(ctx) {
			if strings.to_string(box.text) == "Commit 0003" {
				found = true
				testing.expect(t, box.boundary_rect.height > 0)
			}
			testing.expect(t, strings.to_string(box.text) != "Commit 0000")
		}
		testing.expect(t, found)
	}
}

workbench_test_frame :: proc(ctx: ^ui.UiContext, state: ^Workbench, scale: f32) {
	workbench_ui(ctx, nil, nil, nil, nil, state, nil, 1000 * scale, 720 * scale, scale)
}

workbench_test_click :: proc(t: ^testing.T, ctx: ^ui.UiContext, state: ^Workbench, text: string, scale: f32) {
	workbench_test_frame(ctx, state, scale)
	for box in ui.elements(ctx) {
		if .CLICKABLE not_in box.actions || strings.to_string(box.text) != text do continue
		ui.input_mouse_move(ctx, box.rect.x + box.rect.width * 0.5, box.rect.y + box.rect.height * 0.5)
		ui.input_mouse_button(ctx, .LEFT, true)
		workbench_test_frame(ctx, state, scale)
		ui.input_mouse_button(ctx, .LEFT, false)
		workbench_test_frame(ctx, state, scale)
		workbench_test_frame(ctx, state, scale)
		return
	}
	testing.expectf(t, false, "Button not found: %s", text)
}

@(test)
workspace_menu_edits_validate_cancel_and_persist :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root, err := os.make_directory_temp("", "workbench-menu-ui-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer delete(root)
	defer _ = os.remove_all(root)
	repo: ^git.Repository
	if !testing.expect(t, git.repository_init(&repo, workspace.cstring_temp(root), 0) == git.OK) do return
	defer git.repository_free(repo)
	state := Workbench{ready = true, search = strings.builder_make()}
	defer workbench_destroy(&state)
	if !testing.expect(t, workspace.open(&state.model, {root, root, "Menu test", "menu@example.invalid"}) == "") do return
	ctx := ui.init()
	defer ui.destroy(ctx)
	scales := [?]f32{1, 2}
	for scale in scales {
		workbench_test_click(t, ctx, &state, "Preferences", scale)
		testing.expect(t, state.menu == .PREFERENCES)
		testing.expect(t, strings.to_string(state.username) == "Menu test")
		testing.expect(t, strings.to_string(state.email) == "menu@example.invalid")
		testing.expect(t, strings.to_string(state.ssh) == root)
		fields := 0
		for box in ui.elements(ctx) {
			if .EDITABLE in box.actions {
				fields += 1
				testing.expect(t, box.boundary_rect.height == box.rect.height)
			}
		}
		testing.expect(t, fields == 3)
		workbench_set_field(&state.username, "Unsaved reader")
		workbench_set_field(&state.email, "invalid")
		workbench_test_click(t, ctx, &state, "Save", scale)
		testing.expect(t, state.menu == .PREFERENCES && state.error != "")
		testing.expect(t, state.ready && state.model.config.username == "Menu test")
		workbench_test_click(t, ctx, &state, "Cancel", scale)
		testing.expect(t, state.menu == .NONE && state.error == "")
		testing.expect(t, strings.to_string(state.username) == "Menu test")

		workbench_test_click(t, ctx, &state, "Project", scale)
		testing.expect(t, state.menu == .PROJECT)
		testing.expect(t, strings.to_string(state.project) == root)
		workbench_set_field(&state.project, fmt.tprintf("%s/missing", root))
		workbench_test_click(t, ctx, &state, "Open", scale)
		testing.expect(t, state.menu == .PROJECT && state.error != "")
		testing.expect(t, state.ready && state.model.config.project_path == root)
		workbench_test_click(t, ctx, &state, "Cancel", scale)
		testing.expect(t, state.menu == .NONE && strings.to_string(state.project) == root)
	}

	path := fmt.tprintf("%s/gitaris.json", root)
	keys := workspace.normalize_path(fmt.tprintf("%s/keys", root))
	if !testing.expect(t, os.make_directory(keys) == nil) do return
	workbench_open_menu(&state, .PREFERENCES)
	workbench_set_field(&state.username, "Saved reader")
	workbench_set_field(&state.email, "saved@example.invalid")
	workbench_set_field(&state.ssh, keys)
	workbench_set_field(&state.search, "keep my filter")
	workbench_start(&state, path)
	testing.expect(t, state.menu == .NONE && state.error == "")
	testing.expect(t, string(state.model.identity.name) == "Saved reader")
	testing.expect(t, string(state.model.identity.email) == "saved@example.invalid")
	testing.expect(t, state.model.config.ssh_key_path == keys)
	testing.expect(t, strings.to_string(state.search) == "keep my filter")
	saved, message := workspace.config_load(path)
	defer workspace.config_destroy(&saved)
	testing.expect(t, message == "" && saved == state.model.config)

	// A failed disk write must not apply the edited identity or close the page.
	workbench_open_menu(&state, .PREFERENCES)
	workbench_set_field(&state.username, "Cannot save")
	workbench_start(&state, fmt.tprintf("%s/missing/gitaris.json", root))
	testing.expect(t, state.menu == .PREFERENCES && state.error != "")
	testing.expect(t, state.model.config == saved)

	other := workspace.normalize_path(fmt.tprintf("%s/another-project", root))
	other_repo: ^git.Repository
	if !testing.expect(t, git.repository_init(&other_repo, workspace.cstring_temp(other), 0) == git.OK) do return
	defer git.repository_free(other_repo)
	workbench_open_menu(&state, .PROJECT)
	workbench_set_field(&state.project, other)
	workbench_start(&state, path)
	testing.expect(t, state.menu == .NONE && state.error == "")
	testing.expect(t, state.model.config.project_path == other)
	testing.expect(t, state.model.config.username == saved.username && strings.to_string(state.search) == "")
	reloaded, reload_error := workspace.config_load(path)
	defer workspace.config_destroy(&reloaded)
	testing.expect(t, reload_error == "" && reloaded == state.model.config)
}
