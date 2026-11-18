package workspace

// Branches and tags: listing, creating, checking out and deleting them.

import "core:c"
import "core:fmt"
import "core:slice"
import "core:strings"

import git "../git"

// A tag that names a commit (tags of trees or blobs are not listed).
Tag :: struct {
	name: string,       // Short name, e.g. v1.2.0.
	target: git.Oid,    // The commit, after peeling an annotated tag.
	annotated: bool,
	message: string,    // Annotated tags: the message's first line.
}

clear_tags :: proc(model: ^Model) {
	for tag in model.tags {
		delete(tag.name)
		delete(tag.message)
	}
	delete(model.tags)
	model.tags = nil
}

// Lists refs/tags/*, newest-looking versions first (v1.10 before v1.9).
load_tags :: proc(model: ^Model) -> string {
	iter: ^git.Reference_Iterator
	if git.reference_iterator_glob_new(&iter, model.repo, "refs/tags/*") != git.OK do return git_error("Could not list tags")
	defer git.reference_iterator_free(iter)
	for {
		ref: ^git.Reference
		result := git.reference_next(&ref, iter)
		if result == git.ITEROVER do break
		if result != git.OK do return git_error("Could not read a tag")
		defer git.reference_free(ref)
		peeled: ^git.Object
		if git.reference_peel(&peeled, ref, git.OBJECT_COMMIT) != git.OK {
			git.error_clear()
			continue
		}
		tag := Tag{name = strings.clone(strings.trim_prefix(string(git.reference_name(ref)), "refs/tags/")), target = git.object_id(peeled)^}
		git.object_free(peeled)
		if direct := git.reference_target(ref); direct != nil {
			annotation: ^git.Tag
			if git.tag_lookup(&annotation, model.repo, direct) == git.OK {
				tag.annotated = true
				message := strings.trim_space(string(git.tag_message(annotation)))
				if newline := strings.index_byte(message, '\n'); newline >= 0 do message = strings.trim_space(message[:newline])
				tag.message = strings.clone(message)
				git.tag_free(annotation)
			} else {
				git.error_clear()
			}
		}
		append(&model.tags, tag)
	}
	slice.sort_by(model.tags[:], proc(a, b: Tag) -> bool { return natural_less(b.name, a.name) })
	return ""
}

// Compares runs of digits by value, so v1.10 sorts after v1.9.
natural_less :: proc(a, b: string) -> bool {
	i, j := 0, 0
	for i < len(a) && j < len(b) {
		da, db := a[i] >= '0' && a[i] <= '9', b[j] >= '0' && b[j] <= '9'
		if da && db {
			si, sj := i, j
			for i < len(a) && a[i] >= '0' && a[i] <= '9' do i += 1
			for j < len(b) && b[j] >= '0' && b[j] <= '9' do j += 1
			na, nb := strings.trim_left(a[si:i], "0"), strings.trim_left(b[sj:j], "0")
			if len(na) != len(nb) do return len(na) < len(nb)
			if na != nb do return na < nb
			continue
		}
		if a[i] != b[j] do return a[i] < b[j]
		i += 1
		j += 1
	}
	return len(a) - i < len(b) - j
}

// The tags naming `id`, joined with ", ".
@(private)
tags_at :: proc(model: ^Model, id: ^git.Oid) -> string {
	names := strings.builder_make(context.temp_allocator)
	for &tag in model.tags {
		if git.oid_equal(&tag.target, id) == 0 do continue
		if len(names.buf) > 0 do strings.write_string(&names, ", ")
		strings.write_string(&names, tag.name)
	}
	return strings.to_string(names)
}

// A commit by full hash, or HEAD's commit when `revision` is empty.
@(private)
lookup_revision :: proc(model: ^Model, revision: string) -> (^git.Commit, string) {
	id: git.Oid
	if revision == "" {
		result := git.reference_name_to_id(&id, model.repo, "HEAD")
		if result == git.ENOTFOUND || result == git.EUNBORNBRANCH do return nil, "Create a first commit before adding branches or tags."
		if result != git.OK do return nil, git_error("Could not read HEAD")
	} else {
		kind := len(revision) == 64 ? git.OID_SHA256 : git.OID_SHA1
		if git.oid_from_string(&id, cstring_temp(revision), kind) != git.OK do return nil, git_error("Could not read this revision")
	}
	node: ^git.Commit
	if git.commit_lookup(&node, model.repo, &id) != git.OK do return nil, git_error("Could not read this commit")
	return node, ""
}

// Why `name` cannot be used for a new branch or tag; empty when it can.
check_ref_name :: proc(kind, name: string) -> string {
	if name == "" do return fmt.tprintf("Enter a %s name.", kind)
	if strings.contains_any(name, " \t") do return fmt.tprintf("A %s name cannot contain spaces. Use - or / instead, e.g. feature/new-report.", kind)
	prefix := kind == "tag" ? "refs/tags/" : "refs/heads/"
	full_name := cstring_temp(strings.concatenate({prefix, name}, context.temp_allocator))
	valid: c.int
	git_accepts := git.reference_name_is_valid(&valid, full_name) == git.OK && valid != 0
	if !git_accepts || name == "HEAD" || strings.has_prefix(name, "-") {
		return fmt.tprintf("\"%s\" is not a valid %s name: avoid .., ~, ^, :, ?, *, [, \\, a trailing / or .lock, and starting with -.", name, kind)
	}
	return ""
}

@(private)
short_hash :: proc(id: ^git.Oid) -> string {
	hash: [65]u8
	_ = git.oid_tostr(raw_data(hash[:]), c.size_t(len(hash)), id)
	return strings.clone(string(cstring(raw_data(hash[:])))[:8], context.temp_allocator)
}

// Reloads the repository and shows the history of `ref_name` (when it is
// still a branch), keeping the all-branches view when it was on.
@(private)
refresh_to_branch :: proc(model: ^Model, ref_name: string) -> string {
	ref := strings.clone(ref_name, context.temp_allocator)
	all := model.all_branches
	if err := refresh(model); err != "" do return err
	for branch, i in model.branches {
		if branch.ref_name == ref do return select_history(model, i, all)
	}
	return ""
}

// Like `git switch <branch>`: a safe checkout of the branch's commit, then
// HEAD points at the branch. Uncommitted changes that the switch would
// overwrite stop it before anything is written; other changes carry over.
@(private)
switch_head :: proc(model: ^Model, ref_name: string) -> string {
	switch git.repository_state(model.repo) {
	case git.REPOSITORY_STATE_NONE:
	case: return "A merge, rebase or similar operation is in progress. Finish it before switching branches."
	}
	if git.repository_is_bare(model.repo) != 0 do return "This repository has no working tree to check out into."
	id: git.Oid
	if git.reference_name_to_id(&id, model.repo, cstring_temp(ref_name)) != git.OK do return git_error("Could not read the branch")
	node: ^git.Commit
	if git.commit_lookup(&node, model.repo, &id) != git.OK do return git_error("Could not read the branch's commit")
	defer git.commit_free(node)
	options: git.Checkout_Options
	if git.checkout_options_init(&options, git.CHECKOUT_OPTIONS_VERSION) != git.OK do return git_error("Could not prepare the checkout")
	options.checkout_strategy = git.CHECKOUT_SAFE | git.CHECKOUT_DONT_OVERWRITE_IGNORED
	short := strings.trim_prefix(ref_name, "refs/heads/")
	switch result := git.checkout_tree(model.repo, (^git.Object)(node), &options); result {
	case git.OK:
	case git.ECONFLICT:
		return fmt.tprintf("Could not switch to %s: uncommitted changes would be overwritten. Commit or stash them first; nothing was changed.", short)
	case:
		return git_error(fmt.tprintf("Could not check out %s", short))
	}
	if git.repository_set_head(model.repo, cstring_temp(ref_name)) != git.OK do return git_error("Checked out the files, but could not move HEAD")
	return ""
}

// Like `git branch <name> <revision>` (plus `git switch` when checkout is
// set). An empty revision means HEAD. The view moves to the new branch.
// `created` with an error means the branch exists but was not checked out.
create_branch :: proc(model: ^Model, branch_name, revision: string, checkout: bool) -> (created: bool, err: string) {
	if model.repo == nil do return false, "Open a project first."
	name := strings.trim_space(branch_name)
	if name_err := check_ref_name("branch", name); name_err != "" do return false, name_err
	node, lookup_err := lookup_revision(model, revision)
	if lookup_err != "" do return false, lookup_err
	defer git.commit_free(node)
	ref: ^git.Reference
	switch git.branch_create(&ref, model.repo, cstring_temp(name), node, 0) {
	case git.OK:
	case git.EEXISTS: return false, fmt.tprintf("A branch named %s already exists.", name)
	case: return false, git_error("Could not create the branch")
	}
	ref_name := strings.clone(string(git.reference_name(ref)), context.temp_allocator)
	git.reference_free(ref)
	switch_err := checkout ? switch_head(model, ref_name) : ""
	if refresh_err := refresh_to_branch(model, ref_name); refresh_err != "" do return true, refresh_err
	if switch_err != "" do return true, fmt.tprintf("Created %s, but did not check it out. %s", name, switch_err)
	return true, ""
}

// Checks out a branch from the list. A remote-tracking branch (origin/x)
// checks out the local branch x, creating it to track origin/x when missing.
checkout_branch :: proc(model: ^Model, index: int) -> (string, string) {
	if model.repo == nil || index < 0 || index >= len(model.branches) do return "", "This branch is no longer available. Refresh the project."
	branch := model.branches[index]
	if branch.head do return "", fmt.tprintf("%s is already checked out.", branch.name)
	if branch.ref_name == "HEAD" do return "", "Choose a branch to check out."
	ref_name := branch.ref_name
	created := false
	if branch.remote {
		slash := strings.index_byte(branch.name, '/')
		local := slash >= 0 ? branch.name[slash + 1:] : branch.name
		ref_name = strings.concatenate({"refs/heads/", local}, context.temp_allocator)
		existing: ^git.Reference
		if git.reference_lookup(&existing, model.repo, cstring_temp(ref_name)) == git.OK {
			git.reference_free(existing)
		} else {
			git.error_clear()
			node: ^git.Commit
			if git.commit_lookup(&node, model.repo, &model.branches[index].tip) != git.OK do return "", git_error("Could not read the branch's commit")
			defer git.commit_free(node)
			ref: ^git.Reference
			switch git.branch_create(&ref, model.repo, cstring_temp(local), node, 0) {
			case git.OK:
			case: return "", git_error(fmt.tprintf("Could not create the local branch %s", local))
			}
			defer git.reference_free(ref)
			if git.branch_set_upstream(ref, cstring_temp(branch.name)) != git.OK do git.error_clear()
			created = true
		}
	}
	short := strings.trim_prefix(ref_name, "refs/heads/")
	if err := switch_head(model, ref_name); err != "" {
		if refresh_err := refresh_to_branch(model, ref_name); refresh_err != "" do return "", refresh_err
		if created do return "", fmt.tprintf("Created %s to track %s, but did not check it out. %s", short, branch.name, err)
		return "", err
	}
	if err := refresh_to_branch(model, ref_name); err != "" do return "", err
	if created do return fmt.tprintf("Checked out %s, a new local branch tracking %s.", short, branch.name), ""
	return fmt.tprintf("Checked out %s.", short), ""
}

// Like `git branch -D`: removes a local branch other than the checked-out
// one. The notice names the old tip so the branch can be recreated.
delete_branch :: proc(model: ^Model, index: int) -> (string, string) {
	if model.repo == nil || index < 0 || index >= len(model.branches) do return "", "This branch is no longer available. Refresh the project."
	branch := model.branches[index]
	if branch.remote do return "", "Remote branches are deleted on the remote; use Git for that."
	if branch.head || branch.ref_name == "HEAD" do return "", "The checked-out branch cannot be deleted. Check out another branch first."
	ref: ^git.Reference
	if git.reference_lookup(&ref, model.repo, cstring_temp(branch.ref_name)) != git.OK do return "", git_error("Could not find the branch")
	defer git.reference_free(ref)
	tip := short_hash(&model.branches[index].tip)
	name := strings.clone(branch.name, context.temp_allocator)
	if git.branch_delete(ref) != git.OK do return "", git_error("Could not delete the branch")
	head := ""
	for b in model.branches do if b.head do head = b.ref_name
	if err := refresh_to_branch(model, strings.clone(head, context.temp_allocator)); err != "" do return "", err
	return fmt.tprintf("Deleted branch %s (was %s).", name, tip), ""
}

// Like `git tag <name> <revision>`, or `git tag -a -m <message>` when the
// message is not empty (tagged by the configured identity). Empty revision
// means HEAD. Tags stay local until pushed.
create_tag :: proc(model: ^Model, tag_name, revision, message: string) -> string {
	if model.repo == nil do return "Open a project first."
	name := strings.trim_space(tag_name)
	if err := check_ref_name("tag", name); err != "" do return err
	text := strings.trim_space(message)
	if strings.contains(text, "\x00") do return "The tag message cannot contain NUL characters."
	node, err := lookup_revision(model, revision)
	if err != "" do return err
	defer git.commit_free(node)
	id: git.Oid
	result: c.int
	if text == "" {
		result = git.tag_create_lightweight(&id, model.repo, cstring_temp(name), (^git.Object)(node), 0)
	} else {
		full := strings.concatenate({text, "\n"}, context.temp_allocator)
		result = git.tag_create(&id, model.repo, cstring_temp(name), (^git.Object)(node), model.identity, cstring_temp(full), 0)
	}
	if result == git.EEXISTS do return fmt.tprintf("A tag named %s already exists.", name)
	if result != git.OK do return git_error("Could not create the tag")
	return refresh(model)
}

// Like `git tag -d`. Only the local tag is removed.
delete_tag :: proc(model: ^Model, name: string) -> string {
	if model.repo == nil do return "Open a project first."
	if git.tag_delete(model.repo, cstring_temp(name)) != git.OK do return git_error("Could not delete the tag")
	return refresh(model)
}

// Shows the history leading to a tag (like a branch, without checking out).
select_tag :: proc(model: ^Model, index: int) -> string {
	if index < 0 || index >= len(model.tags) do return "This tag is no longer available. Refresh the project."
	return start_history(model, model.selected, false, model.tags[index].name, []git.Oid{model.tags[index].target})
}

tag_index :: proc(model: Model, name: string) -> int {
	for tag, i in model.tags do if tag.name == name do return i
	return -1
}
