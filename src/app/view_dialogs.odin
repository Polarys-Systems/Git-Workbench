package app

// Modal windows: the commit editor and the New branch / New tag dialogs.

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

import font_core "../font"
import "../ui"
import "../workspace"

// While a dialog is open: the first of its elements in the last frame, so
// Tab cycles inside the dialog only. -1 when no dialog is open.
workbench_modal_first_box := -1

COMMIT_SUMMARY_LIMIT :: 72
COMMIT_SUMMARY_IDEAL :: 50
COMMIT_BODY_WRAP :: 72

@(private = "file")
workbench_set_owned :: proc(field: ^string, value: string) {
	delete(field^)
	field^ = strings.clone(value)
}

@(private = "file")
workbench_dialog_field_id :: proc(field: string) -> ui.UiId {
	return ui.make_id(field, ui.make_id("dialog-card"))
}

// Keyboard focus goes to a field of the dialog drawn this frame.
@(private = "file")
workbench_dialog_focus :: proc(ctx: ^ui.UiContext, field: string, caret: int) {
	ctx.focus_id = workbench_dialog_field_id(field)
	ctx.caret = caret
	// The key that opened the dialog must not also act inside it.
	ctx.input.key_pressed[.RETURN] = false
	ctx.input.key_pressed[.SPACE] = false
}

// Pushes one tag (or all of them, with an empty name) in the background.
workbench_tag_push :: proc(state: ^Workbench, name: string) {
	state.force_armed = false
	workbench_notice(state, "")
	workbench_error(state, workspace.remote_tag_start(&state.remote, &state.model, name, strings.to_string(state.passphrase)))
}

// The full message from the editor's fields: summary, a blank line, body.
workbench_commit_editor_message :: proc(state: ^Workbench) -> string {
	summary := strings.trim_space(strings.to_string(state.commit_summary))
	body := strings.trim_right_space(strings.trim_left(strings.to_string(state.commit_body), "\r\n"))
	if strings.trim_space(body) == "" do return summary
	return strings.concatenate({summary, "\n\n", body}, context.temp_allocator)
}

// Opens the commit editor with the inline draft: its first line becomes the
// summary and the rest (after blank lines) the description.
workbench_open_commit_editor :: proc(ctx: ^ui.UiContext, state: ^Workbench) {
	text := strings.to_string(state.commit_message)
	summary, body := text, ""
	if newline := strings.index_byte(text, '\n'); newline >= 0 {
		summary, body = text[:newline], strings.trim_left(text[newline + 1:], "\r\n")
	}
	workbench_set_field(&state.commit_summary, strings.trim_space(summary))
	workbench_set_field(&state.commit_body, body)
	workbench_set_owned(&state.dialog_error, "")
	state.dialog = .COMMIT
	workbench_dialog_focus(ctx, "commit-summary", len(state.commit_summary.buf))
}

// New branch (kind .BRANCH) or tag (.TAG) at `revision` (empty for HEAD).
workbench_open_ref_dialog :: proc(ctx: ^ui.UiContext, state: ^Workbench, kind: Workbench_Dialog, revision, target: string) {
	strings.builder_reset(&state.dialog_name)
	strings.builder_reset(&state.dialog_message)
	workbench_set_owned(&state.dialog_revision, revision)
	workbench_set_owned(&state.dialog_target, target)
	workbench_set_owned(&state.dialog_error, "")
	state.dialog_checkout = true
	state.dialog_push = false
	state.dialog = kind
	workbench_dialog_focus(ctx, "dialog-name", 0)
}

// The starting point of a new branch or tag at HEAD, described.
workbench_head_target :: proc(state: ^Workbench) -> string {
	model := &state.model
	branch := model.sync.branch != "" ? model.sync.branch : "detached HEAD"
	for commit in model.commits {
		if strings.contains(commit.refs, "HEAD →") {
			return fmt.tprintf("HEAD · %s · %s  %s", branch, commit.hash[:min(8, len(commit.hash))], commit.message)
		}
	}
	return fmt.tprintf("HEAD · %s", branch)
}

workbench_commit_target :: proc(commit: workspace.Commit) -> string {
	return fmt.tprintf("%s  %s", commit.hash[:min(8, len(commit.hash))], commit.message)
}

workbench_close_dialog :: proc(ctx: ^ui.UiContext, state: ^Workbench) {
	if state.dialog == .COMMIT {
		// The draft returns to the inline box, ready for the next visit.
		workbench_set_field(&state.commit_message, workbench_commit_editor_message(state))
	}
	state.dialog = .NONE
	workbench_set_owned(&state.dialog_error, "")
	ctx.focus_id = 0
}

// Commits the staged files with `message`. Returns true when the model was
// replaced (successfully or not), so callers stop drawing stale rows.
workbench_commit :: proc(ctx: ^ui.UiContext, state: ^Workbench, message: string) -> (replaced: bool, err: string) {
	if workspace.remote_busy(&state.remote) do return false, "Wait for the running network operation to finish before committing."
	target := workbench_repo_label(state)
	err = workspace.commit_staged(&state.model, message)
	if err != "" do return true, err
	summary := strings.trim_space(message)
	if newline := strings.index_byte(summary, '\n'); newline >= 0 do summary = strings.trim_space(summary[:newline])
	workbench_notice(state, fmt.tprintf("Committed to %s: %s", target, summary))
	strings.builder_reset(&state.commit_message)
	strings.builder_reset(&state.commit_summary)
	strings.builder_reset(&state.commit_body)
	ctx.caret = 0
	return true, ""
}

workbench_dialog_ui :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face, state: ^Workbench, w, h, scale: f32) {
	workbench_modal_first_box = ctx.n_boxes
	{
		// The scrim takes every click and scroll meant for the view below.
		ui.begin_window(ctx, theme_rect({0, 0, w, h}, scale), "dialog-scrim")
		theme_box(ctx, {0, 0, w, h}, {0.09, 0.09, 0.08, 0.36}, 0, scale)
	}
	switch state.dialog {
	case .COMMIT: workbench_commit_editor_ui(ctx, face, title, mono, state, w, h, scale)
	case .BRANCH, .TAG: workbench_ref_dialog_ui(ctx, face, title, mono, state, w, h, scale)
	case .NONE:
	}
}


// A dialog card centered in the window, and the content column inside it.
@(private = "file")
Dialog_Card :: struct {
	panel: ui.Rect2d,
	x, inner_w: f32, // Content column inside the card's padding.
	footer: f32, // Top of the footer with the buttons.
}

@(private = "file")
dialog_card :: proc(w, h, panel_w, panel_h: f32) -> Dialog_Card {
	panel := ui.Rect2d{(w - panel_w) * 0.5, (h - panel_h) * 0.5, panel_w, panel_h}
	return {panel = panel, x = panel.x + 26, inner_w = panel_w - 52, footer = panel.y + panel_h - 64}
}

// Ctrl+Enter confirms a dialog from any field. Consumes the key so a
// multi-line field does not also receive the newline.
@(private = "file")
ctrl_enter_pressed :: proc(ctx: ^ui.UiContext) -> bool {
	if !(ctx.input.key_down[.CTRL] && ctx.input.key_pressed[.RETURN]) do return false
	ctx.input.key_pressed[.RETURN] = false
	return true
}

@(private = "file")
plural :: proc(count: int) -> string {
	return count == 1 ? "" : "s"
}

// ---------------------------------------------------------------------------
// Commit editor

workbench_commit_editor_ui :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face, state: ^Workbench, w, h, scale: f32) {
	model := &state.model
	card := dialog_card(w, h, min(w - 48, 960), min(h - 48, 660))
	// The list of staged files only fits beside the fields on wide windows.
	side_w: f32 = card.panel.width >= 760 ? 260 : 0
	editor_w := side_w > 0 ? card.inner_w - side_w - 22 : card.inner_w
	staged, unstaged := 0, 0
	for file in model.changes.files {
		if file.staged do staged += 1
		if file.unstaged && !file.staged do unstaged += 1
	}

	commit_now, close := commit_editor_card(ctx, face, title, mono, state, card, editor_w, staged, scale)
	if side_w > 0 {
		side_y := card.panel.y + 66
		side := ui.Rect2d{card.x + card.inner_w - side_w, side_y, side_w, card.footer - side_y - 14}
		staged_files_list(ctx, face, title, mono, model, side, staged, unstaged, scale)
	}

	if commit_now {
		_, err := workbench_commit(ctx, state, workbench_commit_editor_message(state))
		workbench_set_owned(&state.dialog_error, err)
		if err == "" {
			state.dialog = .NONE
			ctx.focus_id = 0
			workbench_reset_windows(ctx, "commit-files", "commit-diff")
		}
	} else if close {
		workbench_close_dialog(ctx, state)
	}
}

// The card with the heading, summary, description and footer. Returns what
// the user asked for: commit, or close and keep the draft.
@(private = "file")
commit_editor_card :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face, state: ^Workbench,
	card: Dialog_Card, editor_w: f32, staged: int, scale: f32) -> (commit_now, close: bool) {
	model := &state.model
	panel, x := card.panel, card.x
	ui.begin_window(ctx, theme_rect(panel, scale), "dialog-card")
	theme_panel(ctx, panel, THEME_CARD, 18, scale)
	theme_label(ctx, title, "Commit", {x, panel.y + 20, 100, 30}, 21, THEME_TEXT, scale)
	branch := model.sync.branch != "" ? model.sync.branch : "detached HEAD"
	heading := fmt.tprintf("into %s  ·  on %s", workbench_repo_label(state), branch)
	if len(state.parents) > 0 do heading = fmt.tprintf("%s  ·  submodule of %s", heading, workbench_parent_label(state))
	theme_label(ctx, face, heading, {x + 92, panel.y + 20, editor_w - 92, 30}, 13, THEME_MUTED, scale)

	commit_now = ctrl_enter_pressed(ctx)
	summary_y := panel.y + 66
	commit_summary_field(ctx, face, state, x, summary_y, editor_w, scale)
	commit_description_field(ctx, face, mono, state, x, summary_y + 94, editor_w, card.footer, scale)

	// Footer: what will happen, and the buttons.
	theme_box(ctx, {panel.x, card.footer, panel.width, 1}, THEME_LINE, 0, scale)
	status_w := card.inner_w - 240
	if state.dialog_error != "" {
		workbench_message(ctx, face, state.dialog_error, {x, card.footer + 10, status_w, 44}, scale)
	} else {
		target := "Nothing is staged yet: stage files in the working tree first."
		if staged > 0 {
			target = fmt.tprintf("Commits %d staged file%s as %s <%s>.", staged, plural(staged), model.config.username, model.config.email)
		}
		theme_label(ctx, face, target, {x, card.footer + 12, status_w, 18}, 12, staged > 0 ? THEME_TEXT : THEME_WARNING, scale)
		theme_label(ctx, face, "Ctrl+Enter commits  ·  Esc closes and keeps the draft", {x, card.footer + 32, status_w, 16}, 10, THEME_MUTED, scale)
	}
	right := x + card.inner_w
	if workbench_button(ctx, face, "Cancel", {right - 226, card.footer + 14, 100, 36}, scale, id = "commit-editor-cancel") do close = true
	if workbench_button(ctx, face, "Commit", {right - 118, card.footer + 14, 118, 36}, scale, true, id = "commit-editor-commit") do commit_now = true
	if ctx.input.key_pressed[.ESCAPE] do close = true
	return
}

// The one-line summary, with a character count that warns as it grows long.
@(private = "file")
commit_summary_field :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, state: ^Workbench, x, y, width, scale: f32) {
	count := utf8.rune_count(state.commit_summary.buf[:])
	color := THEME_MUTED
	hint := "Imperative mood reads best in logs: Fix, Add, Remove…"
	if count > COMMIT_SUMMARY_IDEAL {
		color = THEME_TEXT
		hint = "Over 50 characters: fine, but short summaries read best in one-line logs."
	}
	if count > COMMIT_SUMMARY_LIMIT {
		color = THEME_WARNING
		hint = "Over 72 characters: Git tools will cut this line off. Move details to the description."
	}
	workbench_section(ctx, face, "SUMMARY", x, y, width - 90, scale)
	theme_label(ctx, face, fmt.tprintf("%d / %d", count, COMMIT_SUMMARY_LIMIT), {x + width - 90, y, 90, 16}, 10, color, scale, {.RIGHT})
	placeholder := "One line: what this commit does, e.g. Add tag support to the history view"
	if workbench_field(ctx, face, "commit-summary", "", placeholder, &state.commit_summary, {x, y + 20, width, 40}, scale) == .SUBMIT {
		// Enter continues in the description, like a mail subject.
		workbench_dialog_focus(ctx, "commit-body", len(state.commit_body.buf))
	}
	theme_label(ctx, face, hint, {x, y + 64, width, 16}, 10, color, scale)
}

// The optional, monospaced description, which counts lines that are too long.
@(private = "file")
commit_description_field :: proc(ctx: ^ui.UiContext, face, mono: ^font_core.Face, state: ^Workbench, x, y, width, bottom, scale: f32) {
	long := count_long_lines(strings.to_string(state.commit_body))
	workbench_section(ctx, face, "DESCRIPTION  ·  optional", x, y, width - 200, scale)
	wrap := fmt.tprintf("wrap at %d characters", COMMIT_BODY_WRAP)
	if long > 0 do wrap = fmt.tprintf("%d line%s over %d characters", long, plural(long), COMMIT_BODY_WRAP)
	theme_label(ctx, face, wrap, {x + width - 200, y, 200, 16}, 10, long > 0 ? THEME_WARNING : THEME_MUTED, scale, {.RIGHT})

	body_rect := ui.Rect2d{x, y + 20, width, bottom - y - 34}
	style := workbench_field_style(mono, scale)
	style.font_size = 13 * scale
	style.padding = 12 * scale
	ui.style_push(ctx, style)
	ui.textbox(ctx, "commit-body", &state.commit_body, theme_rect(body_rect, scale))
	ui.style_pop(ctx)
	if len(state.commit_body.buf) == 0 {
		placeholder := [?]string{
			"Why is this change needed? What does it change, and how?",
			"",
			"Mention anything a reviewer should know: trade-offs,",
			"follow-ups, or how it was tested.",
		}
		for line, i in placeholder {
			theme_label(ctx, mono, line, {body_rect.x + 12, body_rect.y + 10 + f32(i) * 18, width - 24, 18}, 12, THEME_MUTED, scale)
		}
	}
}

@(private = "file")
count_long_lines :: proc(text: string) -> int {
	count := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if utf8.rune_count(line) > COMMIT_BODY_WRAP do count += 1
	}
	return count
}

// Beside the fields: what will be committed, so nothing comes as a surprise.
@(private = "file")
staged_files_list :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face, model: ^workspace.Model,
	rect: ui.Rect2d, staged, unstaged: int, scale: f32) {
	ui.begin_window(ctx, theme_rect(rect, scale), "dialog-staged")
	theme_box(ctx, rect, THEME_SURFACE, 12, scale)
	theme_label(ctx, title, "Staged", {rect.x + 14, rect.y + 10, rect.width - 70, 22}, 13, THEME_TEXT, scale)
	theme_label(ctx, face, fmt.tprintf("%d", staged), {rect.x + rect.width - 54, rect.y + 10, 40, 22}, 11, THEME_MUTED, scale, {.RIGHT})

	note_h: f32 = unstaged > 0 ? 44 : 0
	staged_indices := make([dynamic]int, context.temp_allocator)
	for file, i in model.changes.files do if file.staged do append(&staged_indices, i)

	row_h :: 38
	viewport := ui.Rect2d{rect.x + 6, rect.y + 38, rect.width - 12, rect.height - 44 - note_h}
	first, last, offset := workbench_scroll_begin(ctx, viewport, len(staged_indices), row_h, scale)
	for i in first..<last {
		file := model.changes.files[staged_indices[i]]
		row_y := viewport.y + f32(i) * row_h - offset
		badge, _, color := workbench_file_status(file)
		theme_label(ctx, mono, badge, {viewport.x + 8, row_y + 2, 16, 20}, 12, color, scale)
		theme_label(ctx, face, filepath.base(file.path), {viewport.x + 26, row_y + 2, viewport.width - 34, 18}, 12, THEME_TEXT, scale)
		theme_label(ctx, face, file.path, {viewport.x + 26, row_y + 19, viewport.width - 34, 14}, 10, THEME_MUTED, scale)
	}
	if len(staged_indices) == 0 {
		theme_label(ctx, face, "No staged files.", {viewport.x + 8, viewport.y + 6, viewport.width - 16, 18}, 12, THEME_MUTED, scale)
	}
	workbench_scroll_end(ctx, viewport, scale)

	if unstaged > 0 {
		note := fmt.tprintf("%d other changed file%s %s not staged and will not be committed.", unstaged, plural(unstaged), unstaged == 1 ? "is" : "are")
		workbench_message(ctx, face, note, {rect.x + 14, rect.y + rect.height - note_h, rect.width - 28, note_h - 4}, scale, THEME_MUTED)
	}
}

// ---------------------------------------------------------------------------
// New branch / New tag

workbench_ref_dialog_ui :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face, state: ^Workbench, w, h, scale: f32) {
	model := &state.model
	tag := state.dialog == .TAG
	card := dialog_card(w, h, min(w - 48, 560), tag ? 470 : 340)
	panel, x, inner_w := card.panel, card.x, card.inner_w
	ui.begin_window(ctx, theme_rect(panel, scale), "dialog-card")
	theme_panel(ctx, panel, THEME_CARD, 18, scale)
	theme_label(ctx, title, tag ? "New tag" : "New branch", {x, panel.y + 20, inner_w, 30}, 21, THEME_TEXT, scale)
	create := ctrl_enter_pressed(ctx)
	close := false

	// Where it starts.
	y := panel.y + 64
	workbench_section(ctx, face, "STARTS AT", x, y, inner_w, scale)
	theme_box(ctx, {x, y + 20, inner_w, 32}, THEME_SURFACE, 10, scale)
	theme_label(ctx, mono, state.dialog_target, {x + 12, y + 20, inner_w - 24, 32}, 12, THEME_TEXT, scale)

	// Its name, checked while typing, before anything is created.
	y += 68
	workbench_section(ctx, face, "NAME", x, y, inner_w, scale)
	placeholder := tag ? "e.g. v1.4.0" : "e.g. feature/new-report"
	if workbench_field(ctx, face, "dialog-name", "", placeholder, &state.dialog_name, {x, y + 20, inner_w, 40}, scale) == .SUBMIT {
		create = true
	}
	name := strings.trim_space(strings.to_string(state.dialog_name))
	if problem := ref_name_problem(model^, tag, name); problem != "" {
		theme_label(ctx, face, problem, {x, y + 64, inner_w, 16}, 10, THEME_WARNING, scale)
	}

	// Options.
	y += 92
	if tag {
		tag_options(ctx, face, state, x, y, inner_w, scale)
	} else {
		workbench_check(ctx, face, "dialog-checkout", &state.dialog_checkout, {x, y, 22, 22}, scale)
		theme_label(ctx, face, "Check out the new branch", {x + 32, y, inner_w - 32, 22}, 13, THEME_TEXT, scale)
		detail := "The branch is created without touching your working files."
		if state.dialog_checkout do detail = "Your uncommitted changes come along; the switch stops if they would be overwritten."
		theme_label(ctx, face, detail, {x + 32, y + 22, inner_w - 32, 16}, 10, THEME_MUTED, scale)
	}

	// Footer.
	footer := card.footer
	theme_box(ctx, {panel.x, footer, panel.width, 1}, THEME_LINE, 0, scale)
	if state.dialog_error != "" do workbench_message(ctx, face, state.dialog_error, {x, footer + 10, inner_w - 250, 46}, scale)
	if workbench_button(ctx, face, "Cancel", {x + inner_w - 240, footer + 14, 100, 36}, scale, id = "ref-dialog-cancel") do close = true
	if workbench_button(ctx, face, tag ? "Create tag" : "Create branch", {x + inner_w - 132, footer + 14, 132, 36}, scale, true, id = "ref-dialog-create") do create = true
	if ctx.input.key_pressed[.ESCAPE] do close = true

	if create {
		ref_dialog_create(ctx, state, tag, name)
	} else if close {
		workbench_close_dialog(ctx, state)
	}
}

// Why `name` cannot be used for a new branch or tag; empty when it can (or is still empty).
@(private = "file")
ref_name_problem :: proc(model: workspace.Model, tag: bool, name: string) -> string {
	if name == "" do return ""
	if problem := workspace.check_ref_name(tag ? "tag" : "branch", name); problem != "" do return problem
	if tag {
		if workspace.tag_index(model, name) >= 0 do return fmt.tprintf("A tag named %s already exists.", name)
		return ""
	}
	for branch in model.branches {
		if !branch.remote && branch.name == name do return fmt.tprintf("A branch named %s already exists.", name)
	}
	return ""
}

// The tag message (which makes it an annotated tag) and the push option.
@(private = "file")
tag_options :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, state: ^Workbench, x, y, width, scale: f32) {
	config := state.model.config
	workbench_section(ctx, face, "MESSAGE  ·  optional", x, y, width, scale)
	ui.style_push(ctx, workbench_field_style(face, scale))
	ui.textbox(ctx, "dialog-message", &state.dialog_message, theme_rect({x, y + 20, width, 96}, scale))
	ui.style_pop(ctx)
	if len(state.dialog_message.buf) == 0 {
		theme_label(ctx, face, "Release notes or why this commit matters", {x + 11, y + 24, width - 22, 24}, 13, THEME_MUTED, scale)
	}
	annotated := strings.trim_space(strings.to_string(state.dialog_message)) != ""
	kind_hint := "Without a message this is a lightweight tag: just a name for the commit."
	if annotated do kind_hint = fmt.tprintf("Annotated tag, tagged by %s <%s> with this message.", config.username, config.email)
	theme_label(ctx, face, kind_hint, {x, y + 120, width, 16}, 10, THEME_MUTED, scale)

	push_y := y + 150
	remote := state.model.sync.remote != "" ? state.model.sync.remote : "origin"
	workbench_check(ctx, face, "dialog-push", &state.dialog_push, {x, push_y, 22, 22}, scale)
	theme_label(ctx, face, fmt.tprintf("Push the tag to %s after creating it", remote), {x + 32, push_y, width - 32, 22}, 13, THEME_TEXT, scale)
}

// Creates the branch or tag. On failure the dialog stays open with the error.
@(private = "file")
ref_dialog_create :: proc(ctx: ^ui.UiContext, state: ^Workbench, tag: bool, name: string) {
	model := &state.model
	if workspace.remote_busy(&state.remote) {
		workbench_set_owned(&state.dialog_error, "Wait for the running network operation to finish first.")
		return
	}
	// Closing the dialog frees dialog_revision, so keep a copy for the notice.
	revision := strings.clone(state.dialog_revision, context.temp_allocator)
	short := len(revision) >= 8 ? revision[:8] : "HEAD"
	if tag {
		if err := workspace.create_tag(model, name, revision, strings.to_string(state.dialog_message)); err != "" {
			workbench_set_owned(&state.dialog_error, err)
			return
		}
		workbench_notice(state, fmt.tprintf("Created tag %s at %s.", name, short))
		workbench_error(state, "")
		push := state.dialog_push
		workbench_close_dialog(ctx, state)
		if push do workbench_tag_push(state, name)
	} else {
		created, err := workspace.create_branch(model, name, revision, state.dialog_checkout)
		if !created {
			workbench_set_owned(&state.dialog_error, err)
			return
		}
		// Created but not checked out leaves `err` explaining why.
		checked_out := state.dialog_checkout && err == ""
		notice := checked_out ? "Created and checked out %s at %s." : "Created branch %s at %s."
		workbench_notice(state, fmt.tprintf(notice, name, short))
		workbench_error(state, err)
		workbench_close_dialog(ctx, state)
	}
	workbench_reset_windows(ctx, "history", "branches", "commit-files", "commit-diff")
}
