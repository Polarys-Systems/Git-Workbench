package workspace

import "core:os"
import "core:strings"

import git "../git"

// Marks each working change as staged (index differs from HEAD) and/or
// unstaged (working file differs from the index, including untracked files).
// Paths are matched on both sides so renames detected in the combined view
// still find their separate deletion and addition.
@(private)
load_stage_state :: proc(repo: ^git.Repository, head: ^git.Tree, changes: ^Commit_Changes) -> string {
	index: ^git.Index
	if git.repository_index(&index, repo) != git.OK do return git_error("Could not open the index")
	defer git.index_free(index)
	if git.index_read(index, 0) != git.OK do return git_error("Could not refresh the index")
	staged, unstaged: ^git.Diff
	if git.diff_tree_to_index(&staged, repo, head, index, nil) != git.OK do return git_error("Could not compare the index")
	defer git.diff_free(staged)
	options: git.Diff_Options
	if git.diff_options_init(&options, git.DIFF_OPTIONS_VERSION) != git.OK do return git_error("Could not initialize the comparison")
	options.flags = git.DIFF_INCLUDE_UNTRACKED | git.DIFF_RECURSE_UNTRACKED_DIRS | git.DIFF_INCLUDE_TYPECHANGE
	if git.diff_index_to_workdir(&unstaged, repo, index, &options) != git.OK do return git_error("Could not compare the working files")
	defer git.diff_free(unstaged)
	staged_paths, unstaged_paths := diff_paths(staged), diff_paths(unstaged)
	for &file in changes.files {
		file.staged = file.path in staged_paths || file.old_path in staged_paths
		file.unstaged = file.path in unstaged_paths || file.old_path in unstaged_paths
	}
	return ""
}

@(private)
diff_paths :: proc(diff: ^git.Diff) -> map[string]bool {
	paths := make(map[string]bool, context.temp_allocator)
	for i in 0..<git.diff_num_deltas(diff) {
		delta := git.diff_get_delta(diff, i)
		paths[strings.clone(string(delta.old_file.path), context.temp_allocator)] = true
		paths[strings.clone(string(delta.new_file.path), context.temp_allocator)] = true
	}
	return paths
}

// Indices of the checked working files, or the viewed file when none is checked.
stage_targets :: proc(changes: Commit_Changes) -> [dynamic]int {
	targets := make([dynamic]int, context.temp_allocator)
	if !changes.working do return targets
	for file, i in changes.files do if file.selected do append(&targets, i)
	if len(targets) == 0 && changes.file.index < len(changes.files) do append(&targets, changes.file.index)
	return targets
}

// Both paths of a working change: a rename stages its deletion and its addition together.
@(private)
change_paths :: proc(file: Changed_File) -> [dynamic]string {
	paths := make([dynamic]string, context.temp_allocator)
	append(&paths, file.path)
	if file.old_path != "" && file.old_path != file.path do append(&paths, file.old_path)
	return paths
}

@(private)
check_stage_targets :: proc(model: ^Model, targets: []int, action: string) -> string {
	if model.repo == nil || !model.changes.working do return "Open the working tree first."
	if len(targets) == 0 do return "Select files first."
	for i in targets {
		if i < 0 || i >= len(model.changes.files) do return "This file is no longer available. Reload the working tree."
		file := model.changes.files[i]
		if file.status == git.DELTA_CONFLICTED {
			return strings.concatenate({"Resolve ", file.path, " in the Merge editor before you ", action, " it."}, context.temp_allocator)
		}
	}
	return ""
}

// Like `git add -A -- <paths>` for the given working changes: new and modified
// files are added with Git's clean filters, deleted files are removed from the
// index. Other staged or unstaged work is left untouched. Reloads the view.
stage_files :: proc(model: ^Model, targets: []int) -> string {
	if err := check_stage_targets(model, targets, "stage"); err != "" do return err
	index: ^git.Index
	if git.repository_index(&index, model.repo) != git.OK do return git_error("Could not open the index")
	defer git.index_free(index)
	if git.index_read(index, 1) != git.OK do return git_error("Could not refresh the index")
	workdir := string(git.repository_workdir(model.repo))
	for i in targets {
		for path in change_paths(model.changes.files[i]) {
			full := strings.concatenate({workdir, path}, context.temp_allocator)
			_, stat_err := os.lstat(full, context.temp_allocator)
			exists := stat_err == nil
			result := exists ? git.index_add_bypath(index, cstring_temp(path)) : git.index_remove_bypath(index, cstring_temp(path))
			if result != git.OK do return git_error(strings.concatenate({"Could not stage ", path}, context.temp_allocator))
		}
	}
	// Nothing reaches disk unless every file was staged.
	if git.index_write(index) != git.OK do return git_error("Could not save the index")
	return select_working_changes(model)
}

// Like `git restore --staged -- <paths>`: the index entries return to their
// HEAD versions (or are removed when HEAD lacks them). Working files are kept.
unstage_files :: proc(model: ^Model, targets: []int) -> string {
	if err := check_stage_targets(model, targets, "unstage"); err != "" do return err
	head: ^git.Tree
	defer git.tree_free(head)
	head_id: git.Oid
	result := git.reference_name_to_id(&head_id, model.repo, "HEAD")
	if result == git.OK {
		node: ^git.Commit
		if git.commit_lookup(&node, model.repo, &head_id) != git.OK do return git_error("Could not read the last commit")
		defer git.commit_free(node)
		if git.tree_lookup(&head, model.repo, git.commit_tree_id(node)) != git.OK do return git_error("Could not read the last commit's files")
	} else if result != git.ENOTFOUND && result != git.EUNBORNBRANCH {
		return git_error("Could not read HEAD")
	}
	index: ^git.Index
	if git.repository_index(&index, model.repo) != git.OK do return git_error("Could not open the index")
	defer git.index_free(index)
	if git.index_read(index, 1) != git.OK do return git_error("Could not refresh the index")
	for i in targets {
		for path in change_paths(model.changes.files[i]) {
			entry: ^git.Tree_Entry
			found := false
			if head != nil {
				code := git.tree_entry_bypath(&entry, head, cstring_temp(path))
				if code != git.OK && code != git.ENOTFOUND do return git_error("Could not read the last commit's files")
				found = code == git.OK && git.tree_entry_filemode(entry) != git.FILEMODE_TREE
			}
			if found {
				restored := git.Index_Entry{mode = u32(git.tree_entry_filemode(entry)), id = git.tree_entry_id(entry)^, path = cstring_temp(path)}
				result = git.index_add(index, &restored)
			} else {
				result = git.index_remove_bypath(index, cstring_temp(path))
			}
			if entry != nil do git.tree_entry_free(entry)
			if result != git.OK do return git_error(strings.concatenate({"Could not unstage ", path}, context.temp_allocator))
		}
	}
	if git.index_write(index) != git.OK do return git_error("Could not save the index")
	return select_working_changes(model)
}

// Commits exactly what is staged, as the configured Gitaris identity (author
// and committer), and moves the current branch. A merge, revert or cherry-pick
// in progress is concluded the way `git commit` does (merge parents included,
// state files removed). Hooks are not run and nothing is signed.
// On success, history and the working tree view are reloaded.
commit_staged :: proc(model: ^Model, message: string) -> string {
	if model.repo == nil do return "Open a project first."
	text := strings.trim_space(message)
	if text == "" do return "Enter a commit message."
	if strings.contains(text, "\x00") do return "The commit message cannot contain NUL characters."
	state := git.repository_state(model.repo)
	switch state {
	case git.REPOSITORY_STATE_NONE, git.REPOSITORY_STATE_MERGE, git.REPOSITORY_STATE_REVERT, git.REPOSITORY_STATE_CHERRYPICK:
	case: return "A rebase or another multi-step operation is in progress. Finish it with Git before committing here."
	}
	{
		index: ^git.Index
		if git.repository_index(&index, model.repo) != git.OK do return git_error("Could not open the index")
		defer git.index_free(index)
		if git.index_read(index, 1) != git.OK do return git_error("Could not refresh the index")
		if git.index_has_conflicts(index) != 0 do return "Resolve and stage every conflict in the Merge editor before committing."
	}
	options: git.Commit_Create_Options
	if git.commit_create_options_init(&options, git.COMMIT_CREATE_OPTIONS_VERSION) != git.OK do return git_error("Could not prepare the commit")
	options.author, options.committer = model.identity, model.identity
	// Like `git commit`: surrounding blank lines trimmed, ending in one newline.
	full := strings.concatenate({text, "\n"}, context.temp_allocator)
	_, result := git.commit(model.repo, cstring_temp(full), &options)
	if result == git.EUNCHANGED do return "Nothing is staged. Stage files before committing."
	if result != git.OK do return git_error("Could not commit")
	if state != git.REPOSITORY_STATE_NONE && git.repository_state_cleanup(model.repo) != git.OK {
		return git_error("Committed, but could not clear the merge state")
	}
	working := model.changes.working
	if err := refresh(model); err != "" do return err
	if working do return select_working_changes(model)
	return ""
}
