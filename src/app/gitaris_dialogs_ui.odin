package app

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

import font_core "../font"
import "../ui"
import "../workspace"

// While a dialog is open: the first of its elements in the last frame, so
// Tab cycles inside the dialog only. -1 when no dialog is open.
gitaris_modal_first_box := -1

GITARIS_SUMMARY_LIMIT :: 72
GITARIS_SUMMARY_IDEAL :: 50
GITARIS_BODY_WRAP :: 72

@(private = "file")
gitaris_set_owned :: proc(field: ^string, value: string) {
	delete(field^)
	field^ = strings.clone(value)
}

@(private = "file")
gitaris_dialog_field_id :: proc(field: string) -> ui.UiId {
	return ui.make_id(field, ui.make_id("dialog-card"))
}

// Keyboard focus goes to a field of the dialog drawn this frame.
@(private = "file")
gitaris_dialog_focus :: proc(ctx: ^ui.UiContext, field: string, caret: int) {
	ctx.focus_id = gitaris_dialog_field_id(field)
	ctx.caret = caret
	// The key that opened the dialog must not also act inside it.
	ctx.input.key_pressed[.RETURN] = false
	ctx.input.key_pressed[.SPACE] = false
}

// Pushes one tag (or all of them, with an empty name) in the background.
gitaris_tag_push :: proc(state: ^Gitaris, name: string) {
	state.force_armed = false
	gitaris_notice(state, "")
	gitaris_error(state, workspace.remote_tag_start(&state.remote, &state.model, name, strings.to_string(state.passphrase)))
}

// The full message from the editor's fields: summary, a blank line, body.
gitaris_commit_editor_message :: proc(state: ^Gitaris) -> string {
	summary := strings.trim_space(strings.to_string(state.commit_summary))
	body := strings.trim_right_space(strings.trim_left(strings.to_string(state.commit_body), "\r\n"))
	if strings.trim_space(body) == "" do return summary
	return strings.concatenate({summary, "\n\n", body}, context.temp_allocator)
}

// Opens the commit editor with the inline draft: its first line becomes the
// summary and the rest (after blank lines) the description.
gitaris_open_commit_editor :: proc(ctx: ^ui.UiContext, state: ^Gitaris) {
	text := strings.to_string(state.commit_message)
	summary, body := text, ""
	if newline := strings.index_byte(text, '\n'); newline >= 0 {
		summary, body = text[:newline], strings.trim_left(text[newline + 1:], "\r\n")
	}
	gitaris_set_field(&state.commit_summary, strings.trim_space(summary))
	gitaris_set_field(&state.commit_body, body)
	gitaris_set_owned(&state.dialog_error, "")
	state.dialog = .COMMIT
	gitaris_dialog_focus(ctx, "commit-summary", len(state.commit_summary.buf))
}

// New branch (kind .BRANCH) or tag (.TAG) at `revision` (empty for HEAD).
gitaris_open_ref_dialog :: proc(ctx: ^ui.UiContext, state: ^Gitaris, kind: Gitaris_Dialog, revision, target: string) {
	strings.builder_reset(&state.dialog_name)
	strings.builder_reset(&state.dialog_message)
	gitaris_set_owned(&state.dialog_revision, revision)
	gitaris_set_owned(&state.dialog_target, target)
	gitaris_set_owned(&state.dialog_error, "")
	state.dialog_checkout = true
	state.dialog_push = false
	state.dialog = kind
	gitaris_dialog_focus(ctx, "dialog-name", 0)
}

// The starting point of a new branch or tag at HEAD, described.
gitaris_head_target :: proc(state: ^Gitaris) -> string {
	model := &state.model
	branch := model.sync.branch != "" ? model.sync.branch : "detached HEAD"
	for commit in model.commits {
		if strings.contains(commit.refs, "HEAD →") {
			return fmt.tprintf("HEAD · %s · %s  %s", branch, commit.hash[:min(8, len(commit.hash))], commit.message)
		}
	}
	return fmt.tprintf("HEAD · %s", branch)
}

gitaris_commit_target :: proc(commit: workspace.Commit) -> string {
	return fmt.tprintf("%s  %s", commit.hash[:min(8, len(commit.hash))], commit.message)
}

gitaris_close_dialog :: proc(ctx: ^ui.UiContext, state: ^Gitaris) {
	if state.dialog == .COMMIT {
		// The draft returns to the inline box, ready for the next visit.
		gitaris_set_field(&state.commit_message, gitaris_commit_editor_message(state))
	}
	state.dialog = .NONE
	gitaris_set_owned(&state.dialog_error, "")
	ctx.focus_id = 0
}

// Commits the staged files with `message`. Returns true when the model was
// replaced (successfully or not), so callers stop drawing stale rows.
gitaris_commit :: proc(ctx: ^ui.UiContext, state: ^Gitaris, message: string) -> (replaced: bool, err: string) {
	if workspace.remote_busy(&state.remote) do return false, "Wait for the running network operation to finish before committing."
	target := gitaris_repo_label(state)
	err = workspace.commit_staged(&state.model, message)
	if err != "" do return true, err
	summary := strings.trim_space(message)
	if newline := strings.index_byte(summary, '\n'); newline >= 0 do summary = strings.trim_space(summary[:newline])
	gitaris_notice(state, fmt.tprintf("Committed to %s: %s", target, summary))
	strings.builder_reset(&state.commit_message)
	strings.builder_reset(&state.commit_summary)
	strings.builder_reset(&state.commit_body)
	ctx.caret = 0
	return true, ""
}

gitaris_dialog_ui :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face, state: ^Gitaris, w, h, scale: f32) {
	gitaris_modal_first_box = ctx.n_boxes
	{
		// The scrim takes every click and scroll meant for the view below.
		ui.begin_window(ctx, template_rect({0, 0, w, h}, scale), "dialog-scrim")
		template_box(ctx, {0, 0, w, h}, {0.09, 0.09, 0.08, 0.36}, 0, scale)
	}
	switch state.dialog {
	case .COMMIT: gitaris_commit_editor_ui(ctx, face, title, mono, state, w, h, scale)
	case .BRANCH, .TAG: gitaris_ref_dialog_ui(ctx, face, title, mono, state, w, h, scale)
	case .NONE:
	}
}

@(private = "file")
gitaris_long_lines :: proc(text: string) -> int {
	count := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) do if utf8.rune_count(line) > GITARIS_BODY_WRAP do count += 1
	return count
}

gitaris_commit_editor_ui :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face, state: ^Gitaris, w, h, scale: f32) {
	model := &state.model
	pw, ph := min(w - 48, 960), min(h - 48, 660)
	px, py := (w - pw) * 0.5, (h - ph) * 0.5
	x, iw := px + 26, pw - 52
	side_w: f32 = pw >= 760 ? 260 : 0
	ew := side_w > 0 ? iw - side_w - 22 : iw
	footer := py + ph - 64
	staged, unstaged := 0, 0
	for file in model.changes.files {
		if file.staged do staged += 1
		if file.unstaged && !file.staged do unstaged += 1
	}
	commit_now, close := false, false
	{
		ui.begin_window(ctx, template_rect({px, py, pw, ph}, scale), "dialog-card")
		template_panel(ctx, {px, py, pw, ph}, TEMPLATE_CARD, 18, scale)
		template_label(ctx, title, "Commit", {x, py + 20, 100, 30}, 21, TEMPLATE_TEXT, scale)
		branch := model.sync.branch != "" ? model.sync.branch : "detached HEAD"
		heading := fmt.tprintf("into %s  ·  on %s", gitaris_repo_label(state), branch)
		if len(state.parents) > 0 do heading = fmt.tprintf("%s  ·  submodule of %s", heading, gitaris_parent_label(state))
		template_label(ctx, face, heading, {x + 92, py + 20, ew - 92, 30}, 13, TEMPLATE_MUTED, scale)

		// Ctrl+Enter commits from anywhere; keep it out of the description.
		if ctx.input.key_down[.CTRL] && ctx.input.key_pressed[.RETURN] {
			ctx.input.key_pressed[.RETURN] = false
			commit_now = true
		}
		y := py + 66
		count := utf8.rune_count(state.commit_summary.buf[:])
		count_color := TEMPLATE_MUTED
		if count > GITARIS_SUMMARY_IDEAL do count_color = TEMPLATE_TEXT
		if count > GITARIS_SUMMARY_LIMIT do count_color = TEMPLATE_WARNING
		gitaris_section(ctx, face, "SUMMARY", x, y, ew - 90, scale)
		template_label(ctx, face, fmt.tprintf("%d / %d", count, GITARIS_SUMMARY_LIMIT), {x + ew - 90, y, 90, 16}, 10, count_color, scale, {.RIGHT})
		if gitaris_field(ctx, face, "commit-summary", "", "One line: what this commit does, e.g. Add tag support to the history view",
			&state.commit_summary, {x, y + 20, ew, 40}, scale) == .SUBMIT {
			// Enter continues in the description, like a mail subject.
			gitaris_dialog_focus(ctx, "commit-body", len(state.commit_body.buf))
		}
		hint := "Imperative mood reads best in logs: Fix, Add, Remove…"
		if count > GITARIS_SUMMARY_IDEAL do hint = "Over 50 characters: fine, but short summaries read best in one-line logs."
		if count > GITARIS_SUMMARY_LIMIT do hint = "Over 72 characters: Git tools will cut this line off. Move details to the description."
		template_label(ctx, face, hint, {x, y + 64, ew, 16}, 10, count_color, scale)

		y += 94
		body := strings.to_string(state.commit_body)
		long := gitaris_long_lines(body)
		gitaris_section(ctx, face, "DESCRIPTION  ·  optional", x, y, ew - 200, scale)
		wrap := long > 0 ? fmt.tprintf("%d line%s over %d characters", long, long == 1 ? "" : "s", GITARIS_BODY_WRAP) : fmt.tprintf("wrap at %d characters", GITARIS_BODY_WRAP)
		template_label(ctx, face, wrap, {x + ew - 200, y, 200, 16}, 10, long > 0 ? TEMPLATE_WARNING : TEMPLATE_MUTED, scale, {.RIGHT})
		body_rect := ui.Rect2d{x, y + 20, ew, footer - y - 34}
		style := gitaris_field_style(mono, scale)
		style.font_size = 13 * scale
		style.padding = 12 * scale
		ui.style_push(ctx, style)
		ui.textbox(ctx, "commit-body", &state.commit_body, template_rect(body_rect, scale))
		ui.style_pop(ctx)
		if len(state.commit_body.buf) == 0 {
			placeholder := [?]string{
				"Why is this change needed? What does it change, and how?",
				"",
				"Mention anything a reviewer should know: trade-offs,",
				"follow-ups, or how it was tested.",
			}
			for line, i in placeholder {
				template_label(ctx, mono, line, {body_rect.x + 12, body_rect.y + 10 + f32(i) * 18, ew - 24, 18}, 12, TEMPLATE_MUTED, scale)
			}
		}

		template_box(ctx, {px, footer, pw, 1}, TEMPLATE_LINE, 0, scale)
		status_w := iw - 240
		if state.dialog_error != "" {
			gitaris_message(ctx, face, state.dialog_error, {x, footer + 10, status_w, 44}, scale)
		} else {
			target := staged > 0 ? fmt.tprintf("Commits %d staged file%s as %s <%s>.", staged, staged == 1 ? "" : "s", model.config.username, model.config.email) : "Nothing is staged yet: stage files in the working tree first."
			template_label(ctx, face, target, {x, footer + 12, status_w, 18}, 12, staged > 0 ? TEMPLATE_TEXT : TEMPLATE_WARNING, scale)
			template_label(ctx, face, "Ctrl+Enter commits  ·  Esc closes and keeps the draft", {x, footer + 32, status_w, 16}, 10, TEMPLATE_MUTED, scale)
		}
		if gitaris_button(ctx, face, "Cancel", {x + iw - 226, footer + 14, 100, 36}, scale, id = "commit-editor-cancel") do close = true
		if gitaris_button(ctx, face, "Commit", {x + iw - 118, footer + 14, 118, 36}, scale, true, id = "commit-editor-commit") do commit_now = true
		if ctx.input.key_pressed[.ESCAPE] do close = true
	}
	if side_w > 0 {
		// What will be committed, so nothing comes as a surprise.
		sx, sy := x + iw - side_w, py + 66
		sh := footer - sy - 14
		ui.begin_window(ctx, template_rect({sx, sy, side_w, sh}, scale), "dialog-staged")
		template_box(ctx, {sx, sy, side_w, sh}, TEMPLATE_SURFACE, 12, scale)
		template_label(ctx, title, "Staged", {sx + 14, sy + 10, side_w - 70, 22}, 13, TEMPLATE_TEXT, scale)
		template_label(ctx, face, fmt.tprintf("%d", staged), {sx + side_w - 54, sy + 10, 40, 22}, 11, TEMPLATE_MUTED, scale, {.RIGHT})
		note_h: f32 = unstaged > 0 ? 44 : 0
		files := make([dynamic]int, context.temp_allocator)
		for file, i in model.changes.files do if file.staged do append(&files, i)
		viewport := ui.Rect2d{sx + 6, sy + 38, side_w - 12, sh - 44 - note_h}
		first, last, offset := gitaris_scroll_begin(ctx, viewport, len(files), 38, scale)
		for i in first..<last {
			file := model.changes.files[files[i]]
			ry := viewport.y + f32(i) * 38 - offset
			badge, _, color := gitaris_file_status(file)
			template_label(ctx, mono, badge, {viewport.x + 8, ry + 2, 16, 20}, 12, color, scale)
			template_label(ctx, face, filepath.base(file.path), {viewport.x + 26, ry + 2, viewport.width - 34, 18}, 12, TEMPLATE_TEXT, scale)
			template_label(ctx, face, file.path, {viewport.x + 26, ry + 19, viewport.width - 34, 14}, 10, TEMPLATE_MUTED, scale)
		}
		if len(files) == 0 {
			template_label(ctx, face, "No staged files.", {viewport.x + 8, viewport.y + 6, viewport.width - 16, 18}, 12, TEMPLATE_MUTED, scale)
		}
		gitaris_scroll_end(ctx, viewport, scale)
		if unstaged > 0 {
			note := fmt.tprintf("%d other changed file%s %s not staged and will not be committed.", unstaged, unstaged == 1 ? "" : "s", unstaged == 1 ? "is" : "are")
			gitaris_message(ctx, face, note, {sx + 14, sy + sh - note_h, side_w - 28, note_h - 4}, scale, TEMPLATE_MUTED)
		}
	}
	if commit_now {
		_, err := gitaris_commit(ctx, state, gitaris_commit_editor_message(state))
		gitaris_set_owned(&state.dialog_error, err)
		if err == "" {
			state.dialog = .NONE
			ctx.focus_id = 0
			gitaris_reset_windows(ctx, "commit-files", "commit-diff")
		}
	} else if close {
		gitaris_close_dialog(ctx, state)
	}
}

gitaris_ref_dialog_ui :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face, state: ^Gitaris, w, h, scale: f32) {
	model := &state.model
	tag := state.dialog == .TAG
	kind := tag ? "tag" : "branch"
	pw := min(w - 48, 560)
	ph: f32 = tag ? 470 : 340
	px, py := (w - pw) * 0.5, (h - ph) * 0.5
	x, iw := px + 26, pw - 52
	create, close := false, false
	ui.begin_window(ctx, template_rect({px, py, pw, ph}, scale), "dialog-card")
	template_panel(ctx, {px, py, pw, ph}, TEMPLATE_CARD, 18, scale)
	template_label(ctx, title, tag ? "New tag" : "New branch", {x, py + 20, iw, 30}, 21, TEMPLATE_TEXT, scale)
	if ctx.input.key_down[.CTRL] && ctx.input.key_pressed[.RETURN] {
		ctx.input.key_pressed[.RETURN] = false
		create = true
	}

	y := py + 64
	gitaris_section(ctx, face, "STARTS AT", x, y, iw, scale)
	template_box(ctx, {x, y + 20, iw, 32}, TEMPLATE_SURFACE, 10, scale)
	template_label(ctx, mono, state.dialog_target, {x + 12, y + 20, iw - 24, 32}, 12, TEMPLATE_TEXT, scale)

	y += 68
	gitaris_section(ctx, face, "NAME", x, y, iw, scale)
	placeholder := tag ? "e.g. v1.4.0" : "e.g. feature/new-report"
	if gitaris_field(ctx, face, "dialog-name", "", placeholder, &state.dialog_name, {x, y + 20, iw, 40}, scale) == .SUBMIT do create = true
	// Name problems show while typing, before anything is created.
	name := strings.trim_space(strings.to_string(state.dialog_name))
	problem := name != "" ? workspace.check_ref_name(kind, name) : ""
	if problem == "" && name != "" {
		if tag && workspace.tag_index(model^, name) >= 0 do problem = fmt.tprintf("A tag named %s already exists.", name)
		for branch in model.branches {
			if !tag && !branch.remote && branch.name == name do problem = fmt.tprintf("A branch named %s already exists.", name)
		}
	}
	if problem != "" do template_label(ctx, face, problem, {x, y + 64, iw, 16}, 10, TEMPLATE_WARNING, scale)

	y += 92
	remote := model.sync.remote != "" ? model.sync.remote : "origin"
	if tag {
		gitaris_section(ctx, face, "MESSAGE  ·  optional", x, y, iw, scale)
		ui.style_push(ctx, gitaris_field_style(face, scale))
		ui.textbox(ctx, "dialog-message", &state.dialog_message, template_rect({x, y + 20, iw, 96}, scale))
		ui.style_pop(ctx)
		if len(state.dialog_message.buf) == 0 {
			template_label(ctx, face, "Release notes or why this commit matters", {x + 11, y + 24, iw - 22, 24}, 13, TEMPLATE_MUTED, scale)
		}
		annotated := strings.trim_space(strings.to_string(state.dialog_message)) != ""
		kind_hint := "Without a message this is a lightweight tag: just a name for the commit."
		if annotated do kind_hint = fmt.tprintf("Annotated tag, tagged by %s <%s> with this message.", model.config.username, model.config.email)
		template_label(ctx, face, kind_hint, {x, y + 120, iw, 16}, 10, TEMPLATE_MUTED, scale)
		y += 150
		gitaris_check(ctx, face, "dialog-push", &state.dialog_push, {x, y, 22, 22}, scale)
		template_label(ctx, face, fmt.tprintf("Push the tag to %s after creating it", remote), {x + 32, y, iw - 32, 22}, 13, TEMPLATE_TEXT, scale)
	} else {
		gitaris_check(ctx, face, "dialog-checkout", &state.dialog_checkout, {x, y, 22, 22}, scale)
		template_label(ctx, face, "Check out the new branch", {x + 32, y, iw - 32, 22}, 13, TEMPLATE_TEXT, scale)
		detail := state.dialog_checkout ? "Your uncommitted changes come along; the switch stops if they would be overwritten." : "The branch is created without touching your working files."
		template_label(ctx, face, detail, {x + 32, y + 22, iw - 32, 16}, 10, TEMPLATE_MUTED, scale)
	}

	footer := py + ph - 64
	template_box(ctx, {px, footer, pw, 1}, TEMPLATE_LINE, 0, scale)
	if state.dialog_error != "" do gitaris_message(ctx, face, state.dialog_error, {x, footer + 10, iw - 250, 46}, scale)
	if gitaris_button(ctx, face, "Cancel", {x + iw - 240, footer + 14, 100, 36}, scale, id = "ref-dialog-cancel") do close = true
	if gitaris_button(ctx, face, tag ? "Create tag" : "Create branch", {x + iw - 132, footer + 14, 132, 36}, scale, true, id = "ref-dialog-create") do create = true
	if ctx.input.key_pressed[.ESCAPE] do close = true

	if create {
		if workspace.remote_busy(&state.remote) {
			gitaris_set_owned(&state.dialog_error, "Wait for the running network operation to finish first.")
			return
		}
		revision := strings.clone(state.dialog_revision, context.temp_allocator)
		short := len(revision) >= 8 ? revision[:8] : "HEAD"
		if tag {
			message := strings.to_string(state.dialog_message)
			if err := workspace.create_tag(model, name, revision, message); err != "" {
				gitaris_set_owned(&state.dialog_error, err)
				return
			}
			gitaris_notice(state, fmt.tprintf("Created tag %s at %s.", name, short))
			gitaris_error(state, "")
			push := state.dialog_push
			gitaris_close_dialog(ctx, state)
			if push do gitaris_tag_push(state, name)
		} else {
			created, err := workspace.create_branch(model, name, revision, state.dialog_checkout)
			if !created {
				gitaris_set_owned(&state.dialog_error, err)
				return
			}
			checked_out := state.dialog_checkout && err == ""
			gitaris_notice(state, fmt.tprintf(checked_out ? "Created and checked out %s at %s." : "Created branch %s at %s.", name, short))
			gitaris_error(state, err)
			gitaris_close_dialog(ctx, state)
		}
		gitaris_reset_windows(ctx, "history", "branches", "commit-files", "commit-diff")
	} else if close {
		gitaris_close_dialog(ctx, state)
	}
}
