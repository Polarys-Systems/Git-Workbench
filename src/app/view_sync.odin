package app

// Sync panel: fetch, pull, push (and force push), pull strategy and the SSH passphrase.

import "core:fmt"

import font_core "../font"
import "../ui"
import "../workspace"

workbench_remote_progress :: proc(state: ^Workbench) -> string {
	branch := state.model.sync.branch
	switch state.remote.action {
	case .PULL: return state.remote.rebase ? fmt.tprintf("Pulling %s with rebase…", branch) : fmt.tprintf("Pulling %s…", branch)
	case .PUSH: return fmt.tprintf("Pushing %s…", branch)
	case .FORCE_PUSH_WITH_LEASE: return fmt.tprintf("Force pushing %s (with lease)…", branch)
	case .SUBMODULE_UPDATE:
		if state.remote.submodule_path != "" do return fmt.tprintf("Updating submodule %s…", state.remote.submodule_path)
		return "Updating submodules…"
	case .PUSH_TAGS:
		if state.remote.tag != "" do return fmt.tprintf("Pushing tag %s to %s…", state.remote.tag, state.remote.tag_remote)
		return fmt.tprintf("Pushing tags to %s…", state.remote.tag_remote)
	}
	return ""
}

workbench_sync_summary :: proc(status: workspace.Sync_Status) -> (heading, detail: string) {
	if status.branch == "" do return "Detached HEAD", "Check out a local branch to push or pull."
	if status.unborn do return status.branch, "No commits yet. Commit first, then push to publish the branch."
	if status.upstream == "" {
		if status.remote == "" do return status.branch, "No upstream and no remote named origin. Add one with git remote add origin <url>."
		return fmt.tprintf("%s  ·  no upstream", status.branch),
			fmt.tprintf("Push publishes it as %s/%s and tracks it from then on.", status.remote, status.branch)
	}
	heading = fmt.tprintf("%s  →  %s", status.branch, status.upstream)
	switch {
	case status.ahead == 0 && status.behind == 0: detail = "Up to date with the upstream as of the last fetch."
	case status.behind == 0: detail = fmt.tprintf("%d %s to push, as of the last fetch.", status.ahead, status.ahead == 1 ? "commit" : "commits")
	case status.ahead == 0: detail = fmt.tprintf("%d %s to pull, as of the last fetch.", status.behind, status.behind == 1 ? "commit" : "commits")
	case: detail = fmt.tprintf("Diverged: %d to push and %d to pull, as of the last fetch.", status.ahead, status.behind)
	}
	return
}

// A small section heading inside dialog panels.
workbench_section :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, text: string, x, y, w, scale: f32) {
	theme_label(ctx, face, text, {x, y, w, 16}, 10, THEME_MUTED, scale)
}

workbench_sync_ui :: proc(ctx: ^ui.UiContext, face, title: ^font_core.Face, state: ^Workbench, w, h, scale: f32) {
	ui.begin_window(ctx, theme_rect({0, MENU_HEIGHT, w, h - MENU_HEIGHT}, scale), "workspace-sync")
	model := &state.model
	status := model.sync
	busy := workspace.remote_busy(&state.remote)
	panel_w := min(w - 2 * PANEL_GAP, 600)
	panel_h: f32 = 510
	panel_x := (w - panel_w) * 0.5
	panel_y := MENU_HEIGHT + max(PANEL_GAP, (h - MENU_HEIGHT - panel_h) * 0.4) + (1 - state.view_enter.value) * 10
	theme_panel(ctx, {panel_x, panel_y, panel_w, panel_h}, THEME_CARD, 18, scale)
	x, inner_w := panel_x + 24, panel_w - 48
	theme_label(ctx, title, "Sync", {x, panel_y + 20, 80, 30}, 20, THEME_TEXT, scale)
	// Inside a submodule, pushes and pulls go to the submodule's own remote.
	repo := workbench_repo_label(state)
	if len(state.parents) > 0 {
		tag := theme_tag(ctx, face, "SUBMODULE", x + 66, panel_y + 26, THEME_HIGHLIGHT, THEME_DARK, scale)
		theme_label(ctx, face, repo, {x + 74 + tag, panel_y + 20, inner_w - 80 - tag, 30}, 13, THEME_TEXT, scale)
	} else {
		theme_label(ctx, face, repo, {x + 66, panel_y + 20, inner_w - 66, 30}, 13, THEME_MUTED, scale)
	}

	heading, detail := workbench_sync_summary(status)
	workbench_section(ctx, face, "BRANCH", x, panel_y + 62, inner_w, scale)
	theme_label(ctx, title, heading, {x, panel_y + 80, inner_w, 24}, 16, THEME_TEXT, scale)
	theme_label(ctx, face, detail, {x, panel_y + 104, inner_w, 18}, 12, THEME_MUTED, scale)
	theme_box(ctx, {x, panel_y + 132, inner_w, 1}, THEME_LINE, 0, scale)

	// pull.rebase lives in the repository's Git config, shared with the Git CLI.
	workbench_section(ctx, face, "PULL STRATEGY", x, panel_y + 144, inner_w, scale)
	half := (inner_w - 6) * 0.5
	if workbench_button(ctx, face, "Fast-forward only", {x, panel_y + 164, half, 32}, scale, !status.rebase, id = "pull-ff") &&
		status.rebase && !busy {
		workbench_error(state, workspace.set_pull_rebase(model, false))
	}
	if workbench_button(ctx, face, "Rebase local commits", {x + half + 6, panel_y + 164, half, 32}, scale, status.rebase, id = "pull-rebase") &&
		!status.rebase && !busy {
		workbench_error(state, workspace.set_pull_rebase(model, true))
	}
	explanation := "Pull only fast-forwards. If your branch has diverged, pull stops and nothing changes."
	if status.rebase {
		explanation = "Pull replays your local commits on top of the upstream (git pull --rebase). If one conflicts, nothing changes."
	}
	theme_label(ctx, face, explanation, {x, panel_y + 202, inner_w, 18}, 11, THEME_TEXT, scale)
	theme_label(ctx, face, "Saved as pull.rebase in this repository's .git/config, so Git pulls the same way.", {x, panel_y + 220, inner_w, 16}, 10, THEME_MUTED, scale)
	theme_box(ctx, {x, panel_y + 246, inner_w, 1}, THEME_LINE, 0, scale)

	workbench_section(ctx, face, "REMOTE", x, panel_y + 258, inner_w, scale)
	if workbench_button(ctx, face, "Pull", {x, panel_y + 278, 96, 34}, scale, id = "sync-pull") && !busy {
		workbench_remote_start(state, .PULL)
	}
	if workbench_button(ctx, face, "Push", {x + 102, panel_y + 278, 96, 34}, scale, true, id = "sync-push") && !busy {
		workbench_remote_start(state, .PUSH)
	}
	force_label := state.force_armed ? "Confirm force push" : "Force push (lease)"
	if workbench_button(ctx, face, force_label, {x + 204, panel_y + 278, 170, 34}, scale, id = "sync-force") && !busy {
		if state.force_armed {
			workbench_remote_start(state, .FORCE_PUSH_WITH_LEASE)
		} else {
			// The confirmation warning replaces the previous result.
			state.force_armed = true
			workbench_error(state, "")
			workbench_notice(state, "")
		}
	}
	// Tags are never pushed with the branch; this sends every local tag.
	if !state.force_armed && len(model.tags) > 0 &&
		workbench_button(ctx, face, fmt.tprintf("Push tags (%d)", len(model.tags)), {x + inner_w - 130, panel_y + 278, 130, 34}, scale, id = "sync-tags") && !busy {
		workbench_tag_push(state, "")
	}
	if state.force_armed {
		if workbench_button(ctx, face, "Cancel", {x + 380, panel_y + 278, 84, 34}, scale, id = "sync-force-cancel") {
			state.force_armed = false
		}
		target := status.upstream != "" ? status.upstream : fmt.tprintf("%s/%s", status.remote, status.branch)
		warning := fmt.tprintf("Replaces %s with your %s. Refused if %s has commits you have not fetched (--force-with-lease).", target, status.branch, target)
		workbench_message(ctx, face, warning, {x, panel_y + 318, inner_w, 34}, scale)
	}

	if busy {
		theme_label(ctx, face, workbench_remote_progress(state), {x, panel_y + 356, inner_w, 18}, 12, THEME_ACCENT, scale)
	} else if state.error != "" {
		workbench_message(ctx, face, state.error, {x, panel_y + 356, inner_w, 36}, scale)
	} else if state.notice != "" {
		workbench_message(ctx, face, state.notice, {x, panel_y + 356, inner_w, 36}, scale, THEME_ADDITION_TEXT)
	}

	// Only offered to encrypted key files, after unencrypted keys and ssh-agent.
	workbench_section(ctx, face, "SSH KEY PASSPHRASE", x, panel_y + 398, inner_w, scale)
	has_passphrase := len(state.passphrase.buf) > 0
	field_w := has_passphrase ? inner_w - 90 : inner_w
	_ = workbench_field(ctx, face, "ssh-passphrase", "", "Only needed if your key has one", &state.passphrase,
		{x, panel_y + 418, field_w, 36}, scale, secret = true)
	if has_passphrase && workbench_button(ctx, face, "Forget", {x + inner_w - 84, panel_y + 418, 84, 36}, scale, id = "ssh-passphrase-forget") {
		workbench_forget_passphrase(state)
	}
	theme_label(ctx, face, "SSH: keys from Preferences, ssh-agent, then encrypted keys. The passphrase is never saved.", {x, panel_y + panel_h - 34, inner_w - 110, 28}, 10, THEME_MUTED, scale)
	if workbench_button(ctx, face, "Done", {x + inner_w - 96, panel_y + panel_h - 38, 96, 30}, scale) || ctx.input.key_pressed[.ESCAPE] {
		workbench_open_menu(state, .NONE)
	}
}
