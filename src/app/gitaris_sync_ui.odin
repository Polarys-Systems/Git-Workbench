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

gitaris_sync_ui :: proc(ctx: ^ui.UiContext, face, title: ^font_core.Face, state: ^Gitaris, w, h, scale: f32) {
	ui.begin_window(ctx, template_rect({0, GITARIS_MENU_HEIGHT, w, h - GITARIS_MENU_HEIGHT}, scale), "workspace-sync")
	model := &state.model
	status := model.sync
	busy := workspace.remote_busy(&state.remote)
	pw := min(w - 64, 640)
	ph: f32 = 640
	px := (w - pw) * 0.5
	py := GITARIS_MENU_HEIGHT + max(24, (h - GITARIS_MENU_HEIGHT - ph) * 0.5) + (1 - state.view_enter.value) * 12
	template_panel(ctx, {px, py, pw, ph}, TEMPLATE_SURFACE, 22, scale)
	x, fw := px + 32, pw - 64
	template_label(ctx, title, "Sync", {x, py + 24, fw, 38}, 26, TEMPLATE_TEXT, scale)

	heading, detail := gitaris_sync_summary(status)
	template_label(ctx, face, "BRANCH", {x, py + 76, fw, 20}, 11, TEMPLATE_MUTED, scale)
	template_label(ctx, title, heading, {x, py + 98, fw, 28}, 18, TEMPLATE_TEXT, scale)
	template_label(ctx, face, detail, {x, py + 128, fw, 22}, 13, TEMPLATE_MUTED, scale)
	template_box(ctx, {x, py + 164, fw, 1}, TEMPLATE_LINE, 0, scale)

	// pull.rebase lives in the repository's Git config, shared with the Git CLI.
	template_label(ctx, face, "PULL STRATEGY", {x, py + 180, fw, 20}, 11, TEMPLATE_MUTED, scale)
	half := (fw - 8) * 0.5
	if gitaris_button(ctx, face, "Fast-forward only", {x, py + 204, half, 36}, scale, !status.rebase, id = "pull-ff") &&
		status.rebase && !busy {
		gitaris_error(state, workspace.set_pull_rebase(model, false))
	}
	if gitaris_button(ctx, face, "Rebase local commits", {x + half + 8, py + 204, half, 36}, scale, status.rebase, id = "pull-rebase") &&
		!status.rebase && !busy {
		gitaris_error(state, workspace.set_pull_rebase(model, true))
	}
	explanation := "Pull only fast-forwards. If your branch has diverged, pull stops and nothing changes."
	if status.rebase {
		explanation = "Pull replays your local commits on top of the upstream (git pull --rebase). If one conflicts, nothing changes."
	}
	template_label(ctx, face, explanation, {x, py + 248, fw, 20}, 12, TEMPLATE_TEXT, scale)
	template_label(ctx, face, "Saved as pull.rebase in this repository's .git/config, so Git pulls the same way.", {x, py + 270, fw, 20}, 11, TEMPLATE_MUTED, scale)
	template_box(ctx, {x, py + 304, fw, 1}, TEMPLATE_LINE, 0, scale)

	template_label(ctx, face, "REMOTE", {x, py + 320, fw, 20}, 11, TEMPLATE_MUTED, scale)
	if gitaris_button(ctx, face, "Pull", {x, py + 344, 112, 40}, scale, id = "sync-pull") && !busy {
		gitaris_remote_start(state, .PULL)
	}
	if gitaris_button(ctx, face, "Push", {x + 120, py + 344, 112, 40}, scale, true, id = "sync-push") && !busy {
		gitaris_remote_start(state, .PUSH)
	}
	force_label := state.force_armed ? "Confirm force push" : "Force push (lease)"
	if gitaris_button(ctx, face, force_label, {x + 240, py + 344, 184, 40}, scale, id = "sync-force") && !busy {
		if state.force_armed {
			gitaris_remote_start(state, .FORCE_PUSH_WITH_LEASE)
		} else {
			// The confirmation warning replaces the previous result.
			state.force_armed = true
			gitaris_error(state, "")
			gitaris_notice(state, "")
		}
	}
	if state.force_armed {
		if gitaris_button(ctx, face, "Cancel", {x + 432, py + 344, 88, 40}, scale, id = "sync-force-cancel") {
			state.force_armed = false
		}
		target := status.upstream != "" ? status.upstream : fmt.tprintf("%s/%s", status.remote, status.branch)
		warning := fmt.tprintf("Replaces %s with your %s. Refused if %s has commits you have not fetched (--force-with-lease).", target, status.branch, target)
		gitaris_message(ctx, face, warning, {x, py + 394, fw, 36}, scale)
	}

	if busy {
		template_label(ctx, face, gitaris_remote_progress(state), {x, py + 434, fw, 22}, 13, TEMPLATE_ACCENT, scale)
	} else if state.error != "" {
		gitaris_message(ctx, face, state.error, {x, py + 434, fw, 52}, scale)
	} else if state.notice != "" {
		gitaris_message(ctx, face, state.notice, {x, py + 434, fw, 52}, scale, GITARIS_ADD_TEXT)
	}

	// Only offered to encrypted key files, after unencrypted keys and ssh-agent.
	template_label(ctx, face, "SSH KEY PASSPHRASE", {x, py + 494, fw, 20}, 11, TEMPLATE_MUTED, scale)
	has_passphrase := len(state.passphrase.buf) > 0
	field_w := has_passphrase ? fw - 96 : fw
	_ = gitaris_field(ctx, face, "ssh-passphrase", "", "Only needed if your key has one", &state.passphrase,
		{x, py + 518, field_w, 40}, scale, secret = true)
	if has_passphrase && gitaris_button(ctx, face, "Forget", {x + fw - 88, py + 518, 88, 40}, scale, id = "ssh-passphrase-forget") {
		gitaris_forget_passphrase(state)
	}

	if gitaris_button(ctx, face, "Done", {x + fw - 112, py + ph - 72, 112, 40}, scale) || ctx.input.key_pressed[.ESCAPE] {
		gitaris_open_menu(state, .NONE)
	}
	template_label(ctx, face, "SSH: keys from Preferences, ssh-agent, then encrypted keys. The passphrase is never saved.", {x, py + ph - 26, fw, 20}, 11, TEMPLATE_MUTED, scale)
}
