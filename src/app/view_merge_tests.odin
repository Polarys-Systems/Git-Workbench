package app

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "../git"
import "../ui"
import "../workspace"

@(test)
merge_editor_menu_choices_manual_edit_and_save :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root, err := os.make_directory_temp("", "gitaris-merge-ui-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer delete(root)
	defer _ = os.remove_all(root)
	repo: ^git.Repository
	if !testing.expect(t, git.repository_init(&repo, workspace.cstring_temp(root), 0) == git.OK) do return
	defer git.repository_free(repo)
	index: ^git.Index
	if !testing.expect(t, git.repository_index(&index, repo) == git.OK) do return
	defer git.index_free(index)
	settings: ^git.Config
	if !testing.expect(t, git.repository_config(&settings, repo) == git.OK) do return
	testing.expect(t, git.config_set_string(settings, "core.autocrlf", "false") == git.OK)
	git.config_free(settings)
	path := fmt.tprintf("%s/conflict.txt", root)
	content := "prefix\n<<<<<<< HEAD\ncurrent\n=======\nincoming\n>>>>>>> feature\nsuffix\n"
	widths := [?]f32{1000, 1600}
	scales := [?]f32{1, 2}
	for w in widths {
		for scale in scales {
			testing.expect(t, os.write_entire_file(path, content) == nil)
			if !testing.expect(t, git.index_add_bypath(index, "conflict.txt") == git.OK) do return
			entry := git.index_get_bypath(index, "conflict.txt", 0)^
			entry.path = "conflict.txt"
			if !testing.expect(t, git.index_conflict_add(index, &entry, &entry, &entry) == git.OK) do return
			if !testing.expect(t, git.index_write(index) == git.OK) do return
			state := Gitaris{ready = true, search = strings.builder_make()}
			defer gitaris_destroy(&state)
			if !testing.expect(t, workspace.open(&state.model, {root, root, "Resolver", "resolver@example.invalid"}) == "") do return
			ctx := ui.init()
			defer ui.destroy(ctx)
			gitaris_changes_test_click(t, ctx, &state, nil, "Merge editor", w, scale)
			if !testing.expect(t, state.menu == .MERGE && state.error == "" && len(state.model.merge.files) == 1) do return
			gitaris_changes_test_click(t, ctx, &state, nil, "Use incoming", w, scale)
			file := &state.model.merge.files[0]
			testing.expect(t, strings.to_string(file.result) == "prefix\nincoming\nsuffix\n")
			gitaris_changes_test_click(t, ctx, &state, nil, "← History", w, scale)
			gitaris_changes_test_click(t, ctx, &state, nil, "Merge editor", w, scale)
			testing.expect(t, strings.to_string(file.result) == "prefix\nincoming\nsuffix\n")
			gitaris_changes_test_click(t, ctx, &state, nil, "Reset result", w, scale)
			testing.expect(t, strings.to_string(file.result) == content)
			gitaris_changes_test_click(t, ctx, &state, nil, "Incoming + current", w, scale)
			testing.expect(t, strings.to_string(file.result) == "prefix\nincoming\ncurrent\nsuffix\n")
			// The editor takes focus at the replaced block, ready for typing.
			testing.expect(t, ctx.focus_id == gitaris_merge_result_id(file.path) && ctx.caret == len("prefix\n"))
			gitaris_changes_test_click(t, ctx, &state, nil, "Reset result", w, scale)
			testing.expect(t, strings.to_string(file.result) == content)
			gitaris_changes_test_click(t, ctx, &state, nil, "Current + incoming", w, scale)
			gitaris_changes_test_click(t, ctx, &state, nil, "prefix\ncurrent\nincoming\nsuffix\n", w, scale)
			ui.input_text(ctx, "manual ending")
			gitaris_changes_test_frame(ctx, &state, nil, w, scale)
			testing.expect(t, strings.has_suffix(strings.to_string(file.result), "manual ending"))
			for box in ui.elements(ctx) {
				if box.boundary_rect.height <= 0 do continue
				testing.expect(t, box.boundary_rect.x >= 0 && box.boundary_rect.x + box.boundary_rect.width <= w * scale)
			}
			gitaris_changes_test_click(t, ctx, &state, nil, "Save and stage", w, scale)
			if !testing.expect(t, file.staged && state.error == "") do return
			actual, read_err := os.read_entire_file(path, context.temp_allocator)
			testing.expect(t, read_err == nil && string(actual) == "prefix\ncurrent\nincoming\nsuffix\nmanual ending")
			testing.expect(t, git.index_read(index, 1) == git.OK && git.index_has_conflicts(index) == 0)
			gitaris_changes_test_click(t, ctx, &state, nil, "Reload conflicts", w, scale)
			testing.expect(t, len(state.model.merge.files) == 0 && state.error == "")
		}
	}
}
