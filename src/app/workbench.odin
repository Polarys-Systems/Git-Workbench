package app

// Application state (the Workbench struct) and the actions views call on it:
// opening repositories and submodules, error/notice messages, network tasks,
// settings, and the native file/folder pickers.

import "core:c"
import "core:fmt"
import "core:mem"
import "core:path/filepath"
import "core:strings"

import "../ui"
import "../workspace"
import SDL "vendor:sdl3"

Workbench_Menu :: enum { NONE, PROJECT, PREFERENCES, MERGE, SYNC, SUBMODULES }

// Modal windows drawn over the current view.
Workbench_Dialog :: enum { NONE, COMMIT, BRANCH, TAG }

// The spreadsheet viewer's position in the open workbook diff.
Workbench_Grid :: struct {
	key: string, // The file it belongs to; a new file resets the rest.
	sheet, first_tab: int,
	row, col: int, // Selected cell: index into the sheet's rows, 1-based column; row -1 for none.
	text: bool, // Show the row-by-row text diff instead.
	changes_only: bool,
}

Workbench :: struct {
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
	// Looks inside submodules for changes in the background (slow on Windows).
	scan: workspace.Submodule_Scan,
	force_armed: bool, // Force push needs a second, confirming click.
	ready: bool,
	menu: Workbench_Menu,
	picker_event: u32,
	picker_pending: bool,
	view_id: ui.UiId,
	view_enter: ui.UI_Anim_Float,
	// Submodule navigation. parents holds the project paths above the open
	// repository (outermost first); trail holds, for each level entered, the
	// submodule's path inside its parent. Both are empty at the saved project.
	parents, trail: [dynamic]string,
	submodule_focus: int, // Row highlighted in the Submodules view; -1 for none.
	window_title: string,
	// Commit editor, New branch and New tag windows.
	dialog: Workbench_Dialog,
	commit_summary, commit_body: strings.Builder, // The commit editor's draft.
	dialog_name, dialog_message: strings.Builder,  // Branch/tag name, tag message.
	dialog_revision: string, // Commit the branch or tag starts at; empty for HEAD.
	dialog_target: string,   // That commit, described for the window.
	dialog_checkout, dialog_push: bool,
	dialog_error: string,
	// A delete awaiting its confirming click: "branch:<ref>" or "tag:<name>".
	delete_armed: string,
	sidebar_tags: bool, // The sidebar lists tags instead of branches.
	grid: Workbench_Grid,
}

// The saved project: the outermost repository, even inside a submodule.
workbench_root_path :: proc(state: ^Workbench) -> string {
	return len(state.parents) > 0 ? state.parents[0] : state.model.config.project_path
}

// Repository names from the saved project down to the open one.
workbench_crumbs :: proc(state: ^Workbench) -> [dynamic]string {
	crumbs := make([dynamic]string, context.temp_allocator)
	append(&crumbs, filepath.base(workbench_root_path(state)))
	for path in state.trail do append(&crumbs, path)
	return crumbs
}

// The open repository's display name: the project's folder, or the
// submodule's path inside its parent.
workbench_repo_label :: proc(state: ^Workbench) -> string {
	crumbs := workbench_crumbs(state)
	return crumbs[len(crumbs) - 1]
}

workbench_parent_label :: proc(state: ^Workbench) -> string {
	crumbs := workbench_crumbs(state)
	return len(crumbs) > 1 ? crumbs[len(crumbs) - 2] : ""
}

@(private = "file")
workbench_clear_trail :: proc(state: ^Workbench) {
	for path in state.parents do delete(path)
	for path in state.trail do delete(path)
	clear(&state.parents)
	clear(&state.trail)
}

// Opens another repository with the same identity and SSH keys, without
// saving it as the project. Keeps the current workspace when opening fails.
@(private = "file")
workbench_switch_repository :: proc(state: ^Workbench, path: string) -> bool {
	if workspace.remote_busy(&state.remote) {
		workbench_error(state, "Wait for the running network operation to finish before switching repositories.")
		return false
	}
	config := state.model.config
	config.project_path = path
	next: workspace.Model
	if err := workspace.open(&next, config); err != "" {
		workbench_error(state, err)
		return false
	}
	workspace.destroy(&state.model)
	state.model = next
	strings.builder_reset(&state.search)
	state.menu = .NONE
	state.force_armed = false
	state.submodule_focus = -1
	workbench_error(state, "")
	return true
}

// Opens a checked-out submodule as the workspace. History, working tree,
// staging, commits and sync then apply to the submodule; the breadcrumb
// shows the way back to its parent.
workbench_enter_submodule :: proc(state: ^Workbench, index: int) -> bool {
	path, err := workspace.submodule_location(state.model, index)
	if err != "" {
		workbench_error(state, err)
		return false
	}
	parent := strings.clone(state.model.config.project_path)
	child := strings.clone(state.model.submodules[index].path)
	if !workbench_switch_repository(state, path) {
		delete(parent)
		delete(child)
		return false
	}
	append(&state.parents, parent)
	append(&state.trail, child)
	workbench_notice(state, fmt.tprintf("Opened submodule %s: history, commits and sync now apply to it.", child))
	return true
}

// Returns to an enclosing repository; level 0 is the saved project.
workbench_leave_to :: proc(state: ^Workbench, level: int) -> bool {
	if level < 0 || level >= len(state.parents) do return false
	if !workbench_switch_repository(state, state.parents[level]) do return false
	left := strings.clone(state.trail[level], context.temp_allocator)
	for i in level..<len(state.parents) {
		delete(state.parents[i])
		delete(state.trail[i])
	}
	resize(&state.parents, level)
	resize(&state.trail, level)
	// Point at the submodule just left, so its new status is easy to find.
	for info, i in state.model.submodules do if info.path == left do state.submodule_focus = i
	workbench_notice(state, fmt.tprintf("Back in %s.", workbench_repo_label(state)))
	return true
}

workbench_error :: proc(state: ^Workbench, message: string) {
	delete(state.error)
	state.error = strings.clone(message)
}

workbench_notice :: proc(state: ^Workbench, message: string) {
	delete(state.notice)
	state.notice = strings.clone(message)
}

workbench_remote_start :: proc(state: ^Workbench, action: workspace.Remote_Action) {
	state.force_armed = false
	workbench_notice(state, "")
	workbench_error(state, workspace.remote_start(&state.remote, &state.model, action, strings.to_string(state.passphrase)))
}

// name selects one submodule; empty updates all of them (recursively).
workbench_submodule_update :: proc(state: ^Workbench, name := "") {
	state.force_armed = false
	workbench_notice(state, "")
	workbench_error(state, workspace.remote_submodule_start(&state.remote, &state.model, name, strings.to_string(state.passphrase)))
}

workbench_forget_passphrase :: proc(state: ^Workbench) {
	mem.zero_slice(state.passphrase.buf[:])
	strings.builder_reset(&state.passphrase)
}

// Called every frame. Once a push/pull finishes, reload history and branch
// status (the merge editor's drafts and an open working-tree view are kept).
workbench_remote_poll :: proc(state: ^Workbench) {
	if !workspace.remote_poll(&state.remote) do return
	task := &state.remote
	message := workspace.remote_message(task)
	if task.failed {
		workbench_error(state, message)
		workbench_notice(state, "")
		if task.passphrase_rejected do workbench_forget_passphrase(state)
	} else {
		workbench_notice(state, message)
		workbench_error(state, "")
	}
	if !state.ready do return
	working := state.model.changes.working
	merge := state.model.merge
	state.model.merge = {}
	if err := workspace.refresh(&state.model); err != "" {
		state.model.merge = merge
		workbench_error(state, err)
		return
	}
	workspace.clear_merge(&state.model.merge)
	state.model.merge = merge
	if working do workbench_error(state, workspace.select_working_changes(&state.model))
}

// Called every frame: applies a finished submodule scan, and starts one for
// a freshly loaded repository. Stale results (the repository was reloaded
// meanwhile) are dropped, and the next frame scans again.
workbench_scan_poll :: proc(state: ^Workbench) {
	if !state.ready do return
	_ = workspace.submodule_scan_poll(&state.scan, &state.model)
	if !workspace.submodule_scan_busy(&state.scan) do _ = workspace.submodule_scan_start(&state.scan, &state.model)
}

// True while some submodule's inside has not been looked at yet.
workbench_scanning :: proc(state: ^Workbench) -> bool {
	return workspace.submodule_scan_needed(state.model)
}

workbench_set_field :: proc(field: ^strings.Builder, value: string) {
	strings.builder_reset(field)
	strings.write_string(field, value)
}

workbench_open_menu :: proc(state: ^Workbench, menu: Workbench_Menu) {
	if state.picker_pending do return
	config := state.model.config
	workbench_set_field(&state.ssh, config.ssh_key_path)
	workbench_set_field(&state.project, workbench_root_path(state))
	workbench_set_field(&state.username, config.username)
	workbench_set_field(&state.email, config.email)
	workbench_error(state, "")
	state.menu = menu
	state.force_armed = false
	if menu == .MERGE && !state.model.merge.loaded {
		workbench_error(state, workspace.load_merge(&state.model))
	}
}

workbench_init :: proc(state: ^Workbench) {
	state.ssh = strings.builder_make()
	state.project = strings.builder_make()
	state.username = strings.builder_make()
	state.email = strings.builder_make()
	state.search = strings.builder_make()
	state.passphrase = strings.builder_make()
	state.commit_message = strings.builder_make()
	state.commit_summary = strings.builder_make()
	state.commit_body = strings.builder_make()
	state.dialog_name = strings.builder_make()
	state.dialog_message = strings.builder_make()
	state.submodule_focus = -1
	state.grid.row = -1
	config, err := workspace.config_load()
	defer workspace.config_destroy(&config)
	workbench_set_field(&state.ssh, config.ssh_key_path)
	workbench_set_field(&state.project, config.project_path)
	workbench_set_field(&state.username, config.username)
	workbench_set_field(&state.email, config.email)
	if err != "" {
		workbench_error(state, err)
	} else if workspace.config_complete(config) {
		err = workspace.open(&state.model, config)
		state.ready = err == ""
		workbench_error(state, err)
	}
}

workbench_destroy :: proc(state: ^Workbench) {
	// Let a running push/pull finish before its repository is released.
	workspace.remote_destroy(&state.remote)
	workspace.submodule_scan_destroy(&state.scan)
	delete(state.notice)
	workspace.destroy(&state.model)
	strings.builder_destroy(&state.ssh)
	strings.builder_destroy(&state.project)
	strings.builder_destroy(&state.username)
	strings.builder_destroy(&state.email)
	strings.builder_destroy(&state.search)
	workbench_forget_passphrase(state)
	strings.builder_destroy(&state.passphrase)
	strings.builder_destroy(&state.commit_message)
	strings.builder_destroy(&state.commit_summary)
	strings.builder_destroy(&state.commit_body)
	strings.builder_destroy(&state.dialog_name)
	strings.builder_destroy(&state.dialog_message)
	delete(state.dialog_revision)
	delete(state.dialog_target)
	delete(state.dialog_error)
	delete(state.delete_armed)
	delete(state.grid.key)
	delete(state.error)
	workbench_clear_trail(state)
	delete(state.parents)
	delete(state.trail)
	delete(state.window_title)
}

workbench_start :: proc(state: ^Workbench, config_path := workspace.CONFIG_FILE) {
	config := workspace.Config{
		ssh_key_path = workspace.normalize_path(strings.to_string(state.ssh)),
		project_path = workspace.normalize_path(strings.to_string(state.project)),
		username = strings.trim_space(strings.to_string(state.username)),
		email = strings.trim_space(strings.to_string(state.email)),
	}
	if workspace.remote_busy(&state.remote) {
		workbench_error(state, "Wait for the push or pull to finish before changing the project or preferences.")
		return
	}
	// Saving Preferences inside a submodule keeps it open; the saved project
	// remains the outermost repository. Opening a project leaves submodules.
	keep_trail := state.menu == .PREFERENCES && len(state.parents) > 0 &&
		config.project_path == workspace.normalize_path(state.parents[0])
	opened := config
	if keep_trail do opened.project_path = state.model.config.project_path
	next: workspace.Model
	if err := workspace.open(&next, opened); err != "" {
		workbench_error(state, err)
		return
	}
	same_project := state.ready && state.model.config.project_path == opened.project_path
	if same_project {
		selected := state.model.branches[state.model.selected].ref_name
		for branch, i in next.branches {
			if branch.ref_name == selected && (i != next.selected || state.model.all_branches != next.all_branches) {
				if err := workspace.select_history(&next, i, state.model.all_branches); err != "" {
					workspace.destroy(&next)
					workbench_error(state, err)
					return
				}
				break
			}
		}
	}
	if err := workspace.config_save(config, config_path); err != "" {
		workspace.destroy(&next)
		workbench_error(state, err)
		return
	}
	if state.model.config.ssh_key_path != config.ssh_key_path do workbench_forget_passphrase(state)
	workspace.destroy(&state.model)
	state.model = next
	if !keep_trail do workbench_clear_trail(state)
	if !same_project do strings.builder_reset(&state.search)
	workbench_error(state, "")
	state.ready = true
	state.menu = .NONE
}

// Dialog callbacks may run on another thread. Transfer SDL-owned text through
// the event queue; never mutate the UI's builders or borrow callback strings.
workbench_picked :: proc "c" (userdata: rawptr, files: [^]cstring, filter: c.int) {
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

workbench_pick :: proc(state: ^Workbench, window: ^SDL.Window, project, file: bool) {
	if state.picker_pending do return
	if state.picker_event == 0 || state.picker_event == 0xffffffff {
		workbench_error(state, "The file picker is unavailable. You can enter a path directly.")
		return
	}
	state.picker_pending = true
	field := project ? uintptr(2) : uintptr(1)
	userdata := rawptr((uintptr(state.picker_event) << 8) | field)
	if file {
		SDL.ShowOpenFileDialog(workbench_picked, userdata, window, nil, 0, nil, false)
	} else {
		SDL.ShowOpenFolderDialog(workbench_picked, userdata, window, nil, false)
	}
}

workbench_picker_event :: proc(state: ^Workbench, event: ^SDL.Event) {
	state.picker_pending = false
	defer SDL.free(event.user.data1)
	if event.user.data1 == nil do return // Cancelled.
	text := string(cstring(event.user.data1))
	switch event.user.code {
	case 1: workbench_set_field(&state.ssh, text)
	case 2: workbench_set_field(&state.project, text)
	case: workbench_error(state, text)
	}
}
