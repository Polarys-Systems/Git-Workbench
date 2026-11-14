package app

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import font_core "../font"
import "../git"
import "../ui"
import "../workspace"

gitaris_changes_test_frame :: proc(ctx: ^ui.UiContext, state: ^Gitaris, mono: ^font_core.Face, w, scale: f32) {
	h: f32 = w >= 1600 ? 900 : 720
	gitaris_ui(ctx, nil, nil, nil, nil, state, nil, w * scale, h * scale, scale, mono)
}

gitaris_changes_test_click :: proc(t: ^testing.T, ctx: ^ui.UiContext, state: ^Gitaris,
	mono: ^font_core.Face, text: string, w, scale: f32) {
	gitaris_changes_test_frame(ctx, state, mono, w, scale)
	for box in ui.elements(ctx) {
		if strings.to_string(box.text) != text || box.boundary_rect.height <= 0 do continue
		rect := box.boundary_rect
		ui.input_mouse_move(ctx, rect.x + rect.width * 0.5, rect.y + rect.height * 0.5)
		ui.input_mouse_button(ctx, .LEFT, true)
		gitaris_changes_test_frame(ctx, state, mono, w, scale)
		ui.input_mouse_button(ctx, .LEFT, false)
		gitaris_changes_test_frame(ctx, state, mono, w, scale)
		gitaris_changes_test_frame(ctx, state, mono, w, scale)
		return
	}
	testing.expectf(t, false, "Visible text not found: %s", text)
}

@(test)
commit_and_file_clicks_show_colored_virtualized_diffs :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root, err := os.make_directory_temp("", "gitaris-changes-ui-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer delete(root)
	defer _ = os.remove_all(root)
	repo: ^git.Repository
	if !testing.expect(t, git.repository_init(&repo, workspace.cstring_temp(root), 0) == git.OK) do return
	defer git.repository_free(repo)
	testing.expect(t, git.repository_set_head(repo, "refs/heads/main") == git.OK)
	identity: ^git.Signature
	if !testing.expect(t, git.signature_now(&identity, "Diff UI test", "diff@example.invalid") == git.OK) do return
	defer git.signature_free(identity)
	options: git.Commit_Create_Options
	testing.expect(t, git.commit_create_options_init(&options, git.COMMIT_CREATE_OPTIONS_VERSION) == git.OK)
	options.author, options.committer = identity, identity
	options.flags.allow_empty_commit = true
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/a-code.odin", root), "keep\nold value\n") == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/b-notes.txt", root), "before\n") == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/c-picture.bin", root), "\x00before") == nil)
	testing.expect(t, git.stage_all(repo) == git.OK)
	_, result := git.commit(repo, "Initial files", &options)
	if !testing.expect(t, result == git.OK) do return
	content := strings.builder_make(context.temp_allocator)
	strings.write_string(&content, "keep\nnew value\n")
	for _ in 0..<260 do strings.write_byte(&content, 'x')
	strings.write_byte(&content, '\n')
	for i in 0..<2000 do fmt.sbprintf(&content, "added line %d\n", i)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/a-code.odin", root), strings.to_string(content)) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/b-notes.txt", root), "after\n") == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/c-picture.bin", root), "\x00after") == nil)
	testing.expect(t, git.stage_all(repo) == git.OK)
	_, result = git.commit(repo, "Edit files", &options)
	if !testing.expect(t, result == git.OK) do return
	_, result = git.commit(repo, "Empty commit", &options)
	if !testing.expect(t, result == git.OK) do return
	state := Gitaris{ready = true, search = strings.builder_make()}
	defer gitaris_destroy(&state)
	if !testing.expect(t, workspace.open(&state.model, {root, root, "Reader", "reader@example.invalid"}) == "") do return
	ctx := ui.init()
	defer ui.destroy(ctx)
	mono: font_core.Face
	scales := [?]f32{1, 2}
	widths := [?]f32{1000, 1600}
	for w in widths {
		for scale in scales {
			gitaris_changes_test_click(t, ctx, &state, &mono, "Edit files", w, scale)
			if !testing.expect(t, state.model.changes.hash == state.model.commits[1].hash && state.error == "") do return
			testing.expect(t, state.model.changes.files[state.model.changes.file.index].path == "a-code.odin")
			red, green, old_text, new_text := false, false, false, false
			for box in ui.elements(ctx) {
				if box.boundary_rect.height <= 0 do continue
				red = red || (box.draw_background && box.style.color_top == GITARIS_DELETION)
				green = green || (box.draw_background && box.style.color_top == GITARIS_ADDITION)
				text := strings.to_string(box.text)
				if text == "old value" || text == "new value" {
					testing.expect(t, box.style.font_id == ui.UiFont(uintptr(&mono)) && box.style.font_size == 13 * scale)
				}
				old_text = old_text || text == "old value"
				new_text = new_text || text == "new value"
				testing.expect(t, box.boundary_rect.x >= 0 && box.boundary_rect.x + box.boundary_rect.width <= w * scale)
			}
			testing.expect(t, red && green && old_text && new_text)
			testing.expect(t, ctx.n_boxes < 300)
			gitaris_changes_test_click(t, ctx, &state, &mono, "→", w, scale)
			testing.expect(t, ctx.windows[4].scroll_offset.x > 0)
			ui.input_mouse_move(ctx, (w - 200) * scale, 480 * scale)
			ui.input_scroll(ctx, 0, -1000)
			gitaris_changes_test_frame(ctx, &state, &mono, w, scale)
			testing.expect(t, ctx.windows[4].scroll_offset.y > 0 && ctx.windows[3].scroll_offset.y == 0)
			testing.expect(t, ctx.n_boxes < 300)
			gitaris_changes_test_click(t, ctx, &state, &mono, "b-notes.txt", w, scale)
			testing.expect(t, state.model.changes.files[state.model.changes.file.index].path == "b-notes.txt")
			testing.expect(t, ctx.windows[4].scroll_offset == [2]f32{})
			before, after := false, false
			for box in ui.elements(ctx) {
				text := strings.to_string(box.text)
				before = before || text == "before"
				after = after || text == "after"
				testing.expect(t, text != "old value" && text != "new value")
			}
			testing.expect(t, before && after)
			gitaris_changes_test_click(t, ctx, &state, &mono, "c-picture.bin", w, scale)
			testing.expect(t, state.model.changes.file.binary)
			binary_message := false
			for box in ui.elements(ctx) do binary_message = binary_message || strings.contains(strings.to_string(box.text), "Binary file changed")
			testing.expect(t, binary_message)
			gitaris_changes_test_click(t, ctx, &state, &mono, "← History", w, scale)
			testing.expect(t, state.model.changes.hash == "")
			gitaris_changes_test_click(t, ctx, &state, &mono, "Empty commit", w, scale)
			empty_message := false
			for box in ui.elements(ctx) do empty_message = empty_message || strings.to_string(box.text) == "This commit has no file changes."
			testing.expect(t, empty_message && len(state.model.changes.files) == 0)
			gitaris_changes_test_click(t, ctx, &state, &mono, "← History", w, scale)
		}
	}
}
