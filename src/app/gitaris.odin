package app

import "core:c"
import "core:mem"
import "core:strings"

import "../ui"
import "../workspace"
import SDL "vendor:sdl3"

GITARIS_WELCOME_FONT :: #load("../../assets/fonts/Gambarino_Complete/Fonts/OTF/Gambarino-Regular.otf")

Gitaris_Menu :: enum { NONE, PROJECT, PREFERENCES, MERGE, SYNC }

Gitaris :: struct {
	model: workspace.Model,
	ssh, project, username, email, search: strings.Builder,
	// Unlocks an encrypted SSH key for push/pull. Kept in memory for this
	// session only, never saved; cleared when the key location changes.
	passphrase: strings.Builder,
	// Draft for the next commit in the working tree view; cleared once committed.
	commit_message: strings.Builder,
	error: string,
	notice: string, // Last successful push/pull/commit, shown in the menu bar and Sync.
	remote: workspace.Remote_Task,
	force_armed: bool, // Force push needs a second, confirming click.
	ready: bool,
	menu: Gitaris_Menu,
	picker_event: u32,
	picker_pending: bool,
	view_id: ui.UiId,
	view_enter: ui.UI_Anim_Float,
}

gitaris_error :: proc(state: ^Gitaris, message: string) {
	delete(state.error)
	state.error = strings.clone(message)
}

gitaris_notice :: proc(state: ^Gitaris, message: string) {
	delete(state.notice)
	state.notice = strings.clone(message)
}

gitaris_remote_start :: proc(state: ^Gitaris, action: workspace.Remote_Action) {
	state.force_armed = false
	gitaris_notice(state, "")
	gitaris_error(state, workspace.remote_start(&state.remote, &state.model, action, strings.to_string(state.passphrase)))
}

gitaris_forget_passphrase :: proc(state: ^Gitaris) {
	mem.zero_slice(state.passphrase.buf[:])
	strings.builder_reset(&state.passphrase)
}

// Called every frame. Once a push/pull finishes, reload history and branch
// status (the merge editor's drafts and an open working-tree view are kept).
gitaris_remote_poll :: proc(state: ^Gitaris) {
	if !workspace.remote_poll(&state.remote) do return
	task := &state.remote
	message := workspace.remote_message(task)
	if task.failed {
		gitaris_error(state, message)
		gitaris_notice(state, "")
		if task.passphrase_rejected do gitaris_forget_passphrase(state)
	} else {
		gitaris_notice(state, message)
		gitaris_error(state, "")
	}
	if !state.ready do return
	working := state.model.changes.working
	merge := state.model.merge
	state.model.merge = {}
	if err := workspace.refresh(&state.model); err != "" {
		state.model.merge = merge
		gitaris_error(state, err)
		return
	}
	workspace.clear_merge(&state.model.merge)
	state.model.merge = merge
	if working do gitaris_error(state, workspace.select_working_changes(&state.model))
}

gitaris_set_field :: proc(field: ^strings.Builder, value: string) {
	strings.builder_reset(field)
	strings.write_string(field, value)
}

gitaris_open_menu :: proc(state: ^Gitaris, menu: Gitaris_Menu) {
	if state.picker_pending do return
	config := state.model.config
	gitaris_set_field(&state.ssh, config.ssh_key_path)
	gitaris_set_field(&state.project, config.project_path)
	gitaris_set_field(&state.username, config.username)
	gitaris_set_field(&state.email, config.email)
	gitaris_error(state, "")
	state.menu = menu
	state.force_armed = false
	if menu == .MERGE && !state.model.merge.loaded {
		gitaris_error(state, workspace.load_merge(&state.model))
	}
}

gitaris_init :: proc(state: ^Gitaris) {
	state.ssh = strings.builder_make()
	state.project = strings.builder_make()
	state.username = strings.builder_make()
	state.email = strings.builder_make()
	state.search = strings.builder_make()
	state.passphrase = strings.builder_make()
	state.commit_message = strings.builder_make()
	config, err := workspace.config_load()
	defer workspace.config_destroy(&config)
	gitaris_set_field(&state.ssh, config.ssh_key_path)
	gitaris_set_field(&state.project, config.project_path)
	gitaris_set_field(&state.username, config.username)
	gitaris_set_field(&state.email, config.email)
	if err != "" {
		gitaris_error(state, err)
	} else if workspace.config_complete(config) {
		err = workspace.open(&state.model, config)
		state.ready = err == ""
		gitaris_error(state, err)
	}
}

gitaris_destroy :: proc(state: ^Gitaris) {
	// Let a running push/pull finish before its repository is released.
	workspace.remote_destroy(&state.remote)
	delete(state.notice)
	workspace.destroy(&state.model)
	strings.builder_destroy(&state.ssh)
	strings.builder_destroy(&state.project)
	strings.builder_destroy(&state.username)
	strings.builder_destroy(&state.email)
	strings.builder_destroy(&state.search)
	gitaris_forget_passphrase(state)
	strings.builder_destroy(&state.passphrase)
	strings.builder_destroy(&state.commit_message)
	delete(state.error)
}

gitaris_start :: proc(state: ^Gitaris, config_path := workspace.CONFIG_FILE) {
	config := workspace.Config{
		ssh_key_path = workspace.normalize_path(strings.to_string(state.ssh)),
		project_path = workspace.normalize_path(strings.to_string(state.project)),
		username = strings.trim_space(strings.to_string(state.username)),
		email = strings.trim_space(strings.to_string(state.email)),
	}
	if workspace.remote_busy(&state.remote) {
		gitaris_error(state, "Wait for the push or pull to finish before changing the project or preferences.")
		return
	}
	next: workspace.Model
	if err := workspace.open(&next, config); err != "" {
		gitaris_error(state, err)
		return
	}
	same_project := state.ready && state.model.config.project_path == config.project_path
	if same_project {
		selected := state.model.branches[state.model.selected].ref_name
		for branch, i in next.branches {
			if branch.ref_name == selected && (i != next.selected || state.model.all_branches != next.all_branches) {
				if err := workspace.select_history(&next, i, state.model.all_branches); err != "" {
					workspace.destroy(&next)
					gitaris_error(state, err)
					return
				}
				break
			}
		}
	}
	if err := workspace.config_save(config, config_path); err != "" {
		workspace.destroy(&next)
		gitaris_error(state, err)
		return
	}
	if state.model.config.ssh_key_path != config.ssh_key_path do gitaris_forget_passphrase(state)
	workspace.destroy(&state.model)
	state.model = next
	if !same_project do strings.builder_reset(&state.search)
	gitaris_error(state, "")
	state.ready = true
	state.menu = .NONE
}

// Dialog callbacks may run on another thread. Transfer SDL-owned text through
// the event queue; never mutate the UI's builders or borrow callback strings.
gitaris_picked :: proc "c" (userdata: rawptr, files: [^]cstring, filter: c.int) {
	packed := uintptr(userdata)
	event: SDL.Event
	event.type = SDL.EventType(u32(packed >> 8))
	event.user.code = i32(packed & 0xff)
	if files == nil {
		event.user.code = -1
		event.user.data1 = SDL.strdup(SDL.GetError())
	} else if files[0] != nil {
		event.user.data1 = SDL.strdup(files[0])
	}
	if !SDL.PushEvent(&event) do SDL.free(event.user.data1)
}

gitaris_pick :: proc(state: ^Gitaris, window: ^SDL.Window, project, file: bool) {
	if state.picker_pending do return
	if state.picker_event == 0 || state.picker_event == 0xffffffff {
		gitaris_error(state, "The file picker is unavailable. You can enter a path directly.")
		return
	}
	state.picker_pending = true
	field := project ? uintptr(2) : uintptr(1)
	userdata := rawptr((uintptr(state.picker_event) << 8) | field)
	if file {
		SDL.ShowOpenFileDialog(gitaris_picked, userdata, window, nil, 0, nil, false)
	} else {
		SDL.ShowOpenFolderDialog(gitaris_picked, userdata, window, nil, false)
	}
}

gitaris_picker_event :: proc(state: ^Gitaris, event: ^SDL.Event) {
	state.picker_pending = false
	defer SDL.free(event.user.data1)
	if event.user.data1 == nil do return // Cancelled.
	text := string(cstring(event.user.data1))
	switch event.user.code {
	case 1: gitaris_set_field(&state.ssh, text)
	case 2: gitaris_set_field(&state.project, text)
	case: gitaris_error(state, text)
	}
}
