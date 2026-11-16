package workspace

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import git "../git"

// The most important condition of a submodule; Submodule_Info keeps the raw
// libgit2 flags for everything else.
Submodule_State :: enum {
	CURRENT,         // Checked out at the recorded commit, nothing changed inside.
	// Recorded by the parent but not checked out here: never cloned, or its
	// folder is empty or gone. Update fixes all of these the same way.
	NOT_INITIALIZED,
	ADDED,          // Staged as a new submodule; not committed yet.
	REMOVED,         // Staged for removal.
	OTHER_COMMIT,    // Its checked-out commit differs from the one the parent records.
	POINTER_STAGED,  // The parent's index records a new commit, not committed yet.
	MODIFIED,        // Uncommitted changes inside the submodule.
	UNTRACKED,       // Only untracked files inside the submodule.
}

Submodule_Info :: struct {
	name, path, url, branch: string,
	// Commits recorded in the parent's HEAD tree and index, and checked out in
	// the submodule's working directory. Empty when absent from that place.
	head, index, workdir: string,
	status: c.uint,
	state: Submodule_State,
	// Uncommitted or untracked changes inside, in addition to state.
	dirty: bool,
	// The submodule has its own checked-out repository that can be opened.
	checked_out: bool,
}

clear_submodules :: proc(model: ^Model) {
	for info in model.submodules {
		delete(info.name)
		delete(info.path)
		delete(info.url)
		delete(info.branch)
		delete(info.head)
		delete(info.index)
		delete(info.workdir)
	}
	delete(model.submodules)
	model.submodules = nil
	delete(model.submodule_error)
	model.submodule_error = ""
}

@(private)
Submodule_Names :: struct {
	names: ^[dynamic]string,
	ctx: runtime.Context,
}

@(private)
collect_submodule_name :: proc "c" (submodule: ^git.Submodule, name: cstring, payload: rawptr) -> c.int {
	collected := (^Submodule_Names)(payload)
	context = collected.ctx
	append(collected.names, strings.clone(string(name), context.temp_allocator))
	return 0
}

// Names of the repository's submodules (from .gitmodules, the index and HEAD).
submodule_names :: proc(repo: ^git.Repository) -> ([dynamic]string, c.int) {
	names := make([dynamic]string, context.temp_allocator)
	payload := Submodule_Names{&names, context}
	result := git.submodule_foreach(repo, collect_submodule_name, &payload)
	return names, result
}

@(private)
short_oid :: proc(id: ^git.Oid) -> string {
	if id == nil do return ""
	text: [65]u8
	_ = git.oid_tostr(raw_data(text[:]), c.size_t(len(text)), id)
	full := string(cstring(raw_data(text[:])))
	return strings.clone(full[:min(len(full), 8)])
}

@(private)
classify_submodule :: proc(status: c.uint) -> Submodule_State {
	switch {
	case status & git.SUBMODULE_STATUS_INDEX_DELETED != 0: return .REMOVED
	case status & git.SUBMODULE_STATUS_INDEX_ADDED != 0: return .ADDED
	case status & (git.SUBMODULE_STATUS_WD_UNINITIALIZED | git.SUBMODULE_STATUS_WD_DELETED) != 0: return .NOT_INITIALIZED
	case status & git.SUBMODULE_STATUS_IN_WD == 0: return .NOT_INITIALIZED
	case status & git.SUBMODULE_STATUS_WD_MODIFIED != 0: return .OTHER_COMMIT
	case status & git.SUBMODULE_STATUS_INDEX_MODIFIED != 0: return .POINTER_STAGED
	case status & (git.SUBMODULE_STATUS_WD_INDEX_MODIFIED | git.SUBMODULE_STATUS_WD_WD_MODIFIED) != 0: return .MODIFIED
	case status & git.SUBMODULE_STATUS_WD_UNTRACKED != 0: return .UNTRACKED
	}
	return .CURRENT
}

// Reads every submodule's recorded/checked-out commits and status. Missing or
// broken submodules are reported in their state, and a failure to list them
// in model.submodule_error, so neither keeps the parent project from opening.
load_submodules :: proc(model: ^Model) {
	clear_submodules(model)
	if model.repo == nil || git.repository_is_bare(model.repo) != 0 do return
	names, result := submodule_names(model.repo)
	if result != git.OK {
		model.submodule_error = strings.clone(git_error("Could not list the submodules (check .gitmodules)"))
		return
	}
	workdir := string(git.repository_workdir(model.repo))
	for name in names {
		submodule: ^git.Submodule
		if git.submodule_lookup(&submodule, model.repo, cstring_temp(name)) != git.OK do continue
		defer git.submodule_free(submodule)
		info := Submodule_Info{
			name = strings.clone(name),
			path = strings.clone(string(git.submodule_path(submodule))),
			url = strings.clone(string(git.submodule_url(submodule))),
			branch = strings.clone(string(git.submodule_branch(submodule))),
			head = short_oid(git.submodule_head_id(submodule)),
			index = short_oid(git.submodule_index_id(submodule)),
			workdir = short_oid(git.submodule_wd_id(submodule)),
		}
		// Honor each submodule's own ignore setting (e.g. ignore = untracked).
		if git.submodule_status(&info.status, model.repo, cstring_temp(name), git.SUBMODULE_IGNORE_UNSPECIFIED) != git.OK {
			info.status = git.SUBMODULE_STATUS_WD_UNINITIALIZED
		}
		info.state = classify_submodule(info.status)
		info.dirty = info.status & (git.SUBMODULE_STATUS_WD_INDEX_MODIFIED | git.SUBMODULE_STATUS_WD_WD_MODIFIED | git.SUBMODULE_STATUS_WD_UNTRACKED) != 0
		full, _ := filepath.join({workdir, info.path}, context.temp_allocator)
		dot_git, _ := filepath.join({full, ".git"}, context.temp_allocator)
		info.checked_out = info.workdir != "" && os.exists(dot_git)
		append(&model.submodules, info)
	}
}

// The commit the parent's next commit would record (the index), else HEAD's.
submodule_recorded :: proc(info: Submodule_Info) -> string {
	return info.index != "" ? info.index : info.head
}

// Whether the submodule needs the user's attention (everything except a
// clean checkout at the recorded commit, or only untracked files inside).
submodule_attention :: proc(info: Submodule_Info) -> bool {
	return info.state != .CURRENT && info.state != .UNTRACKED
}

submodule_attention_count :: proc(model: Model) -> int {
	count := 0
	for info in model.submodules do if submodule_attention(info) do count += 1
	return count
}

// A short label and a one-line explanation naming the commits involved.
// parent is the display name of the repository that contains the submodule.
submodule_describe :: proc(info: Submodule_Info, parent: string) -> (label, detail: string) {
	recorded := submodule_recorded(info)
	switch info.state {
	case .NOT_INITIALIZED:
		return "Not checked out", fmt.tprintf("Not cloned here yet. Update clones it and checks out %s.", recorded != "" ? recorded : "the recorded commit")
	case .ADDED:
		return "Added", fmt.tprintf("Staged as a new submodule at %s; commit %s to record it.", recorded, parent)
	case .REMOVED:
		return "Removed", fmt.tprintf("Staged for removal; commit %s to drop it.", parent)
	case .OTHER_COMMIT:
		return "Other commit", fmt.tprintf("Checked out %s, but %s records %s. Update checks out %s; staging it in %s records %s instead.",
			info.workdir, parent, recorded, recorded, parent, info.workdir)
	case .POINTER_STAGED:
		return "New commit staged", fmt.tprintf("%s's next commit records %s (was %s).", parent, info.index, info.head != "" ? info.head : "absent")
	case .MODIFIED:
		return "Uncommitted changes", fmt.tprintf("At %s with uncommitted changes inside. Open it to stage and commit them there.", info.workdir)
	case .UNTRACKED:
		return "Untracked files", fmt.tprintf("At %s, the recorded commit; it contains untracked files.", info.workdir)
	case .CURRENT:
	}
	return "Up to date", fmt.tprintf("Checked out at %s, the commit %s records.", info.workdir, parent)
}

// The submodule's folder, for opening it as its own workspace.
submodule_location :: proc(model: Model, index: int) -> (string, string) {
	if index < 0 || index >= len(model.submodules) do return "", "This submodule is no longer listed. Refresh the project."
	info := model.submodules[index]
	if !info.checked_out {
		return "", fmt.tprintf("%s is not checked out yet. Update it first, then open it.", info.path)
	}
	path, _ := filepath.join({model.config.project_path, info.path}, context.temp_allocator)
	return path, ""
}

// The submodule whose gitlink a changed file is, if any (-1 otherwise).
submodule_for_path :: proc(model: Model, path: string) -> int {
	for info, i in model.submodules do if info.path == path do return i
	return -1
}

// Nested submodules deeper than this are left for Git.
SUBMODULE_MAX_DEPTH :: 8

// Worker side of remote_submodule_start (runs on the remote task's thread).
@(private)
remote_submodules_update :: proc(repo: ^git.Repository, task: ^Remote_Task, payload: ^Remote_Payload) -> (string, bool) {
	names, result := submodule_names(repo)
	if result != git.OK do return git_error("Could not list the submodules (check .gitmodules)"), true
	updated := 0
	first := ""
	for name in names {
		if task.submodule != "" && name != task.submodule do continue
		path, err := submodule_update_one(repo, name, task, payload, 0, &updated)
		if err != "" do return err, true
		if first == "" do first = path
	}
	switch {
	case first == "" && task.submodule != "": return fmt.tprintf("Submodule %s is no longer listed. Refresh the project.", task.submodule_path), true
	case first == "": return "There are no submodules to update.", false
	case updated == 1: return fmt.tprintf("Updated submodule %s: checked out its recorded commit.", first), false
	case task.submodule != "": return fmt.tprintf("Updated submodule %s and %d nested submodules.", first, updated - 1), false
	}
	return fmt.tprintf("Updated %d submodules to the commits their parents record.", updated), false
}

@(private)
submodule_update_one :: proc(repo: ^git.Repository, name: string, task: ^Remote_Task, payload: ^Remote_Payload,
	depth: int, updated: ^int) -> (path, err: string) {
	submodule: ^git.Submodule
	if git.submodule_lookup(&submodule, repo, cstring_temp(name)) != git.OK {
		return name, git_error(fmt.tprintf("Could not find submodule %s", name))
	}
	defer git.submodule_free(submodule)
	path = strings.clone(string(git.submodule_path(submodule)), context.temp_allocator)
	// A deleted submodule folder makes libgit2 fail; Git recreates it.
	folder, _ := filepath.join({string(git.repository_workdir(repo)), path}, context.temp_allocator)
	if !os.exists(folder) && os.make_directory_all(folder) != nil {
		return path, fmt.tprintf("Could not create the folder for submodule %s.", path)
	}
	options: git.Submodule_Update_Options
	if git.submodule_update_options_init(&options, git.SUBMODULE_UPDATE_OPTIONS_VERSION) != git.OK {
		return path, git_error("Could not prepare the submodule update")
	}
	// Each submodule may live on another server: offer every key afresh.
	payload^ = remote_payload(task)
	options.fetch_opts.callbacks.credentials = remote_credentials
	options.fetch_opts.callbacks.payload = payload
	// The default SAFE checkout refuses to overwrite local changes.
	result := git.submodule_update(submodule, 1, &options)
	if result != git.OK {
		if result == git.ECONFLICT || strings.contains(git.last_error_message(), "conflict") {
			return path, fmt.tprintf("Could not update %s: it has local changes that the recorded commit would overwrite. Commit or stash them inside the submodule first; nothing was changed.", path)
		}
		return path, fmt.tprintf("%s.%s", git_error(fmt.tprintf("Could not update %s", path)), remote_auth_hint(result, payload))
	}
	updated^ += 1
	if depth >= SUBMODULE_MAX_DEPTH do return path, ""
	nested: ^git.Repository
	if git.submodule_open(&nested, submodule) != git.OK do return path, ""
	defer git.repository_free(nested)
	inner, code := submodule_names(nested)
	if code != git.OK do return path, git_error(fmt.tprintf("Could not list the submodules inside %s", path))
	for inner_name in inner {
		inner_path, inner_err := submodule_update_one(nested, inner_name, task, payload, depth + 1, updated)
		if inner_err != "" do return path, fmt.tprintf("%s (in %s/%s)", inner_err, path, inner_path)
	}
	return path, ""
}
