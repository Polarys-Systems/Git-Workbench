package app

import "core:fmt"

import font_core "../font"
import "../ui"
import "../workspace"

gitaris_remote_progress :: proc(state: ^Gitaris) -> string {
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

gitaris_sync_summary :: proc(status: workspace.Sync_Status) -> (heading, detail: string) {
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
gitaris_section :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, text: string, x, y, w, scale: f32) {
	template_label(ctx, face, text, {x, y, w, 16}, 10, TEMPLATE_MUTED, scale)
}

gitaris_sync_ui :: proc(ctx: ^ui.UiContext, face, title: ^font_core.Face, state: ^Gitaris, w, h, scale: f32) {
	ui.begin_window(ctx, template_rect({0, GITARIS_MENU_HEIGHT, w, h - GITARIS_MENU_HEIGHT}, scale), "workspace-sync")
	model := &state.model
	status := model.sync
	busy := workspace.remote_busy(&state.remote)
	pw := min(w - 2 * GITARIS_GAP, 600)
	ph: f32 = 510
	px := (w - pw) * 0.5
	py := GITARIS_MENU_HEIGHT + max(GITARIS_GAP, (h - GITARIS_MENU_HEIGHT - ph) * 0.4) + (1 - state.view_enter.value) * 10
	template_panel(ctx, {px, py, pw, ph}, TEMPLATE_CARD, 18, scale)
	x, fw := px + 24, pw - 48
	template_label(ctx, title, "Sync", {x, py + 20, 80, 30}, 20, TEMPLATE_TEXT, scale)
	// Inside a submodule, pushes and pulls go to the submodule's own remote.
	repo := gitaris_repo_label(state)
	if len(state.parents) > 0 {
		tag := template_tag(ctx, face, "SUBMODULE", x + 66, py + 26, TEMPLATE_HIGHLIGHT, TEMPLATE_DARK, scale)
		template_label(ctx, face, repo, {x + 74 + tag, py + 20, fw - 80 - tag, 30}, 13, TEMPLATE_TEXT, scale)
	} else {
		template_label(ctx, face, repo, {x + 66, py + 20, fw - 66, 30}, 13, TEMPLATE_MUTED, scale)
	}

	heading, detail := gitaris_sync_summary(status)
	gitaris_section(ctx, face, "BRANCH", x, py + 62, fw, scale)
	template_label(ctx, title, heading, {x, py + 80, fw, 24}, 16, TEMPLATE_TEXT, scale)
	template_label(ctx, face, detail, {x, py + 104, fw, 18}, 12, TEMPLATE_MUTED, scale)
	template_box(ctx, {x, py + 132, fw, 1}, TEMPLATE_LINE, 0, scale)

	// pull.rebase lives in the repository's Git config, shared with the Git CLI.
	gitaris_section(ctx, face, "PULL STRATEGY", x, py + 144, fw, scale)
	half := (fw - 6) * 0.5
	if gitaris_button(ctx, face, "Fast-forward only", {x, py + 164, half, 32}, scale, !status.rebase, id = "pull-ff") &&
		status.rebase && !busy {
		gitaris_error(state, workspace.set_pull_rebase(model, false))
	}
	if gitaris_button(ctx, face, "Rebase local commits", {x + half + 6, py + 164, half, 32}, scale, status.rebase, id = "pull-rebase") &&
		!status.rebase && !busy {
		gitaris_error(state, workspace.set_pull_rebase(model, true))
	}
	explanation := "Pull only fast-forwards. If your branch has diverged, pull stops and nothing changes."
	if status.rebase {
		explanation = "Pull replays your local commits on top of the upstream (git pull --rebase). If one conflicts, nothing changes."
	}
	template_label(ctx, face, explanation, {x, py + 202, fw, 18}, 11, TEMPLATE_TEXT, scale)
	template_label(ctx, face, "Saved as pull.rebase in this repository's .git/config, so Git pulls the same way.", {x, py + 220, fw, 16}, 10, TEMPLATE_MUTED, scale)
	template_box(ctx, {x, py + 246, fw, 1}, TEMPLATE_LINE, 0, scale)

	gitaris_section(ctx, face, "REMOTE", x, py + 258, fw, scale)
	if gitaris_button(ctx, face, "Pull", {x, py + 278, 96, 34}, scale, id = "sync-pull") && !busy {
		gitaris_remote_start(state, .PULL)
	}
	if gitaris_button(ctx, face, "Push", {x + 102, py + 278, 96, 34}, scale, true, id = "sync-push") && !busy {
		gitaris_remote_start(state, .PUSH)
	}
	force_label := state.force_armed ? "Confirm force push" : "Force push (lease)"
	if gitaris_button(ctx, face, force_label, {x + 204, py + 278, 170, 34}, scale, id = "sync-force") && !busy {
		if state.force_armed {
			gitaris_remote_start(state, .FORCE_PUSH_WITH_LEASE)
		} else {
			// The confirmation warning replaces the previous result.
			state.force_armed = true
			gitaris_error(state, "")
			gitaris_notice(state, "")
		}
	}
	// Tags are never pushed with the branch; this sends every local tag.
	if !state.force_armed && len(model.tags) > 0 &&
		gitaris_button(ctx, face, fmt.tprintf("Push tags (%d)", len(model.tags)), {x + fw - 130, py + 278, 130, 34}, scale, id = "sync-tags") && !busy {
		gitaris_tag_push(state, "")
	}
	if state.force_armed {
		if gitaris_button(ctx, face, "Cancel", {x + 380, py + 278, 84, 34}, scale, id = "sync-force-cancel") {
			state.force_armed = false
		}
		target := status.upstream != "" ? status.upstream : fmt.tprintf("%s/%s", status.remote, status.branch)
		warning := fmt.tprintf("Replaces %s with your %s. Refused if %s has commits you have not fetched (--force-with-lease).", target, status.branch, target)
		gitaris_message(ctx, face, warning, {x, py + 318, fw, 34}, scale)
	}

	if busy {
		template_label(ctx, face, gitaris_remote_progress(state), {x, py + 356, fw, 18}, 12, TEMPLATE_ACCENT, scale)
	} else if state.error != "" {
		gitaris_message(ctx, face, state.error, {x, py + 356, fw, 36}, scale)
	} else if state.notice != "" {
		gitaris_message(ctx, face, state.notice, {x, py + 356, fw, 36}, scale, GITARIS_ADD_TEXT)
	}

	// Only offered to encrypted key files, after unencrypted keys and ssh-agent.
	gitaris_section(ctx, face, "SSH KEY PASSPHRASE", x, py + 398, fw, scale)
	has_passphrase := len(state.passphrase.buf) > 0
	field_w := has_passphrase ? fw - 90 : fw
	_ = gitaris_field(ctx, face, "ssh-passphrase", "", "Only needed if your key has one", &state.passphrase,
		{x, py + 418, field_w, 36}, scale, secret = true)
	if has_passphrase && gitaris_button(ctx, face, "Forget", {x + fw - 84, py + 418, 84, 36}, scale, id = "ssh-passphrase-forget") {
		gitaris_forget_passphrase(state)
	}
	template_label(ctx, face, "SSH: keys from Preferences, ssh-agent, then encrypted keys. The passphrase is never saved.", {x, py + ph - 34, fw - 110, 28}, 10, TEMPLATE_MUTED, scale)
	if gitaris_button(ctx, face, "Done", {x + fw - 96, py + ph - 38, 96, 30}, scale) || ctx.input.key_pressed[.ESCAPE] {
		gitaris_open_menu(state, .NONE)
	}
}
