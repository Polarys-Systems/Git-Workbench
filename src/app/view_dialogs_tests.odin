package app

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import font_core "../font"
import "../git"
import "../ui"
import "../workspace"
import xlsx "../xlsx"

// A one-sheet workbook ("Budget") from comma-separated rows of inline strings.
@(private = "file")
dialogs_test_workbook :: proc(rows: []string) -> []u8 {
	sheet := strings.builder_make(context.temp_allocator)
	strings.write_string(&sheet, `<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>`)
	for row, i in rows {
		fmt.sbprintf(&sheet, `<row r="%d">`, i + 1)
		cells := row
		for cell in strings.split_iterator(&cells, ",") do fmt.sbprintf(&sheet, `<c t="inlineStr"><is><t>%s</t></is></c>`, cell)
		strings.write_string(&sheet, "</row>")
	}
	strings.write_string(&sheet, "</sheetData></worksheet>")
	parts := [?]xlsx.Zip_Part{
		{"xl/workbook.xml", `<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Budget" sheetId="1" r:id="rId1"/></sheets></workbook>`},
		{"xl/_rels/workbook.xml.rels", `<Relationships><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>`},
		{"xl/worksheets/sheet1.xml", strings.to_string(sheet)},
	}
	return xlsx.zip_write_stored(parts[:], allocator = context.temp_allocator)
}

// Clicks the topmost element showing `text` (dialogs sit above the view).
@(private = "file")
dialogs_test_click :: proc(t: ^testing.T, ctx: ^ui.UiContext, state: ^Gitaris, mono: ^font_core.Face, text: string, w, scale: f32, loc := #caller_location) {
	gitaris_changes_test_frame(ctx, state, mono, w, scale)
	boxes := ui.elements(ctx)
	#reverse for box in boxes {
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
	testing.expectf(t, false, "Visible text not found: %s", text, loc = loc)
}

@(private = "file")
dialogs_test_type :: proc(ctx: ^ui.UiContext, state: ^Gitaris, mono: ^font_core.Face, text: string, w, scale: f32) {
	ui.input_text(ctx, text)
	gitaris_changes_test_frame(ctx, state, mono, w, scale)
	// Labels drawn before the field show the text from the next frame.
	gitaris_changes_test_frame(ctx, state, mono, w, scale)
}

@(private = "file")
dialogs_test_key :: proc(ctx: ^ui.UiContext, state: ^Gitaris, mono: ^font_core.Face, key: ui.Key, w, scale: f32, ctrl := false) {
	if ctrl do ui.input_key(ctx, .CTRL, true)
	ui.input_key(ctx, key, true, true)
	gitaris_changes_test_frame(ctx, state, mono, w, scale)
	ui.input_key(ctx, key, false)
	if ctrl do ui.input_key(ctx, .CTRL, false)
	gitaris_changes_test_frame(ctx, state, mono, w, scale)
}

@(test)
workbook_grid_branch_tag_and_commit_editor :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root, err := os.make_directory_temp("", "gitaris-dialogs-ui-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer delete(root)
	defer _ = os.remove_all(root)
	repo: ^git.Repository
	if !testing.expect(t, git.repository_init(&repo, workspace.cstring_temp(root), 0) == git.OK) do return
	defer git.repository_free(repo)
	testing.expect(t, git.repository_set_head(repo, "refs/heads/main") == git.OK)
	settings: ^git.Config
	if testing.expect(t, git.repository_config(&settings, repo) == git.OK) {
		testing.expect(t, git.config_set_string(settings, "core.autocrlf", "false") == git.OK)
		git.config_free(settings)
	}
	identity: ^git.Signature
	if !testing.expect(t, git.signature_now(&identity, "Dialogs UI test", "dialogs@example.invalid") == git.OK) do return
	defer git.signature_free(identity)
	options: git.Commit_Create_Options
	testing.expect(t, git.commit_create_options_init(&options, git.COMMIT_CREATE_OPTIONS_VERSION) == git.OK)
	options.author, options.committer = identity, identity
	book := fmt.tprintf("%s/Budget.xlsx", root)
	testing.expect(t, os.write_entire_file(book, dialogs_test_workbook({"Item,Cost", "Rent,1000", "Food,300"})) == nil)
	testing.expect(t, git.stage_all(repo) == git.OK)
	_, result := git.commit(repo, "Budget", &options)
	testing.expect(t, os.write_entire_file(book, dialogs_test_workbook({"Item,Cost", "Travel,200", "Rent,1000", "Food,350"})) == nil)
	testing.expect(t, git.stage_all(repo) == git.OK)
	_, result = git.commit(repo, "Update budget", &options)
	if !testing.expect(t, result == git.OK) do return

	state := Gitaris{ready = true, search = strings.builder_make()}
	defer gitaris_destroy(&state)
	if !testing.expect(t, workspace.open(&state.model, {root, root, "Committer", "committer@example.invalid"}) == "") do return
	ctx := ui.init()
	defer ui.destroy(ctx)
	mono: font_core.Face
	w, scale: f32 = 1400, 1

	// A workbook opens as a grid: lettered columns, row numbers, sheet tab.
	dialogs_test_click(t, ctx, &state, &mono, "Update budget", w, scale)
	if !testing.expect(t, workspace.changes_open(state.model.changes) && len(state.model.changes.file.grid.sheets) == 1) do return
	for text in ([]string{"A", "B", "Budget", "Travel", "350", "Changed rows only", "+1  −0  ~1 rows"}) {
		testing.expectf(t, gitaris_sync_test_visible(ctx, text), "grid shows %s", text)
	}
	testing.expect(t, gitaris_sync_test_visible(ctx, "Select a cell"))
	// Step to the first change; the formula bar explains it.
	dialogs_test_click(t, ctx, &state, &mono, "↓", w, scale)
	testing.expect(t, state.grid.row == 1 && gitaris_sync_test_visible(ctx, "Row added in this version"))
	dialogs_test_click(t, ctx, &state, &mono, "↓", w, scale)
	testing.expect(t, state.grid.row == 3 && state.grid.col == 2 && gitaris_sync_test_visible(ctx, "Was:  300"))
	testing.expect(t, gitaris_sync_test_visible(ctx, "Change 2 of 2"))
	// Arrow keys continue from the selection.
	dialogs_test_key(ctx, &state, &mono, .LEFT, w, scale)
	testing.expect(t, state.grid.col == 1 && gitaris_sync_test_visible(ctx, "Unchanged cell in a changed row"))
	// The row-by-row text is one click away.
	dialogs_test_click(t, ctx, &state, &mono, "Text", w, scale)
	testing.expect(t, gitaris_sync_test_visible(ctx, "Food | 350"))
	dialogs_test_click(t, ctx, &state, &mono, "Grid", w, scale)
	testing.expect(t, !gitaris_sync_test_visible(ctx, "Food | 350"))

	// New branch at this commit, checked out.
	dialogs_test_click(t, ctx, &state, &mono, "Branch…", w, scale)
	if !testing.expect(t, state.dialog == .BRANCH && gitaris_sync_test_visible(ctx, "New branch")) do return
	dialogs_test_type(ctx, &state, &mono, "bad name", w, scale)
	testing.expect(t, gitaris_sync_test_visible(ctx, "cannot contain spaces"))
	strings.builder_reset(&state.dialog_name)
	dialogs_test_type(ctx, &state, &mono, "feature/grid", w, scale)
	dialogs_test_click(t, ctx, &state, &mono, "Create branch", w, scale)
	testing.expectf(t, state.dialog == .NONE && state.error == "", "dialog %v, error %s, dialog error %s", state.dialog, state.error, state.dialog_error)
	testing.expectf(t, strings.has_prefix(state.notice, "Created and checked out feature/grid at "), "notice: %s", state.notice)
	testing.expect(t, state.model.sync.branch == "feature/grid")

	// New tag from the sidebar (at HEAD), shown on the commit row.
	dialogs_test_click(t, ctx, &state, &mono, "Tags  0", w, scale)
	dialogs_test_click(t, ctx, &state, &mono, "+", w, scale)
	if !testing.expect(t, state.dialog == .TAG) do return
	dialogs_test_type(ctx, &state, &mono, "v1.0", w, scale)
	dialogs_test_key(ctx, &state, &mono, .RETURN, w, scale)
	testing.expectf(t, state.dialog == .NONE && len(state.model.tags) == 1, "dialog error: %s", state.dialog_error)
	testing.expect(t, state.model.commits[0].tags == "v1.0" && gitaris_sync_test_visible(ctx, "v1.0"))
	// Choosing the tag scopes the history; deleting asks twice.
	// The sidebar row (drawn before the chip on the commit row).
	gitaris_changes_test_click(t, ctx, &state, &mono, "v1.0", w, scale)
	testing.expect(t, state.model.scoped_tag == "v1.0")
	dialogs_test_click(t, ctx, &state, &mono, "Delete", w, scale)
	testing.expect(t, len(state.model.tags) == 1 && gitaris_sync_test_visible(ctx, "Confirm delete"))
	dialogs_test_click(t, ctx, &state, &mono, "Confirm delete", w, scale)
	testing.expect(t, len(state.model.tags) == 0 && state.model.scoped_tag == "")

	// The commit editor: summary, Enter to the description, staged files.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/notes.txt", root), "notes\n") == nil)
	dialogs_test_click(t, ctx, &state, &mono, "Working tree", w, scale)
	dialogs_test_click(t, ctx, &state, &mono, "Stage", w, scale)
	dialogs_test_click(t, ctx, &state, &mono, "Editor", w, scale)
	if !testing.expect(t, state.dialog == .COMMIT) do return
	testing.expect(t, gitaris_sync_test_visible(ctx, "Commits 1 staged file as Committer"))
	dialogs_test_type(ctx, &state, &mono, "Add notes", w, scale)
	testing.expect(t, gitaris_sync_test_visible(ctx, "9 / 72"))
	dialogs_test_key(ctx, &state, &mono, .RETURN, w, scale)
	dialogs_test_type(ctx, &state, &mono, "Why: keep track.", w, scale)
	// Esc keeps the draft in the inline box; reopening restores both parts.
	dialogs_test_key(ctx, &state, &mono, .ESCAPE, w, scale)
	testing.expect(t, state.dialog == .NONE && strings.to_string(state.commit_message) == "Add notes\n\nWhy: keep track.")
	dialogs_test_click(t, ctx, &state, &mono, "Editor", w, scale)
	testing.expect(t, strings.to_string(state.commit_summary) == "Add notes" && strings.to_string(state.commit_body) == "Why: keep track.")
	dialogs_test_key(ctx, &state, &mono, .RETURN, w, scale, ctrl = true)
	testing.expectf(t, state.dialog == .NONE && state.dialog_error == "", "dialog error: %s", state.dialog_error)
	testing.expect(t, strings.has_suffix(state.notice, ": Add notes") && len(state.commit_message.buf) == 0)
	head: git.Oid
	testing.expect(t, git.reference_name_to_id(&head, repo, "HEAD") == git.OK)
	node: ^git.Commit
	if testing.expect(t, git.commit_lookup(&node, repo, &head) == git.OK) {
		testing.expect(t, string(git.commit_message(node)) == "Add notes\n\nWhy: keep track.\n")
		git.commit_free(node)
	}
	for box in ui.elements(ctx) {
		if box.boundary_rect.height <= 0 do continue
		testing.expect(t, box.boundary_rect.x >= 0 && box.boundary_rect.x + box.boundary_rect.width <= w * scale + 0.5)
	}
}
