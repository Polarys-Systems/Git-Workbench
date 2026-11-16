package workspace

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import git "../git"

PAGE_SIZE :: 100

Branch :: struct {
	name, ref_name: string,
	remote, head, unborn: bool,
	tip: git.Oid,
}

Commit :: struct {
	message, hash, author, date: string,
	refs: string,
	graph: Graph_Row,
}

Model :: struct {
	config: Config,
	repo: ^git.Repository,
	identity: ^git.Signature,
	branches: [dynamic]Branch,
	commits: [dynamic]Commit,
	selected: int,
	walk: ^git.Revwalk,
	has_more: bool,
	all_branches: bool,
	graph: Commit_Graph,
	changes: Commit_Changes,
	merge: Merge_Editor,
	sync: Sync_Status,
	submodules: [dynamic]Submodule_Info,
	submodule_error: string, // Listing failed (e.g. a malformed .gitmodules).
	submodule_generation: u64, // Identifies this load for Submodule_Scan.
	// Inside WSL (\\wsl.localhost\...): holds a wsl_trust_begin until destroyed.
	wsl: bool,
}

cstring_temp :: proc(text: string) -> cstring {
	return strings.clone_to_cstring(text, context.temp_allocator)
}

git_error :: proc(action: string) -> string {
	return fmt.tprintf("%s: %s", action, git.last_error_message())
}

clear_history :: proc(model: ^Model) {
	clear_changes(&model.changes)
	git.revwalk_free(model.walk)
	model.walk = nil
	model.has_more = false
	for commit in model.commits {
		delete(commit.message)
		delete(commit.hash)
		delete(commit.author)
		delete(commit.date)
		delete(commit.refs)
		delete(commit.graph.edges)
	}
	clear(&model.commits)
	delete(model.graph.lanes)
	model.graph = {}
}

destroy :: proc(model: ^Model) {
	clear_merge(&model.merge)
	clear_sync(&model.sync)
	clear_submodules(model)
	clear_history(model)
	delete(model.commits)
	for branch in model.branches {
		delete(branch.name)
		delete(branch.ref_name)
	}
	delete(model.branches)
	git.signature_free(model.identity)
	git.repository_free(model.repo)
	config_destroy(&model.config)
	if model.wsl do wsl_trust_end()
	model^ = {}
}

// Open into a temporary model so validation failures preserve the active workspace.
open :: proc(model: ^Model, config: Config) -> string {
	if !config_complete(config) do return "Please choose your SSH keys and project, and enter your commit name and email."
	values := [?]string{config.ssh_key_path, config.project_path, config.username, config.email}
	for value in values {
		if strings.contains(value, "\x00") || strings.contains(value, "\n") || strings.contains(value, "\r") {
			return "Paths and commit identity must each be a single line."
		}
	}
	if !os.exists(config.ssh_key_path) do return "The SSH key location does not exist. Choose a key file or the folder containing your keys."
	if !os.is_dir(config.project_path) do return "The project folder does not exist. Choose a local Git repository."
	if !strings.contains(config.email, "@") || strings.has_prefix(config.email, "@") ||
		strings.has_suffix(config.email, "@") || strings.contains_any(config.email, " \t<>") {
		return "Please enter a valid commit email, such as you@example.com."
	}
	next: Model
	if result := open_repository(&next.repo, config.project_path); result != git.OK {
		if result == git.EOWNER do return ownership_message(config.project_path)
		return git_error("Could not open this Git project")
	}
	succeeded := false
	defer if !succeeded do destroy(&next)
	// libgit2 opens a WSL repository's submodules internally too.
	if is_wsl_path(config.project_path) {
		next.wsl = true
		wsl_trust_begin()
	}
	if git.signature_now(&next.identity, cstring_temp(config.username), cstring_temp(config.email)) != git.OK {
		return git_error("Could not use this commit identity")
	}
	next.config = config_clone(config)
	if err := load_branches(&next); err != "" do return err
	load_sync(&next)
	load_submodules(&next)
	if err := select_history(&next, next.selected, true); err != "" do return err
	destroy(model)
	model^ = next
	succeeded = true
	return ""
}

load_branches :: proc(model: ^Model) -> string {
	head: ^git.Reference
	result := git.repository_head(&head, model.repo)
	head_name: string
	unborn, detached: bool
	if result == git.OK {
		head_name = strings.clone(string(git.reference_name(head)), context.temp_allocator)
		detached = git.reference_is_branch(head) == 0
		git.reference_free(head)
	} else if result == git.EUNBORNBRANCH || result == git.ENOTFOUND {
		unborn = true
		if git.reference_lookup(&head, model.repo, "HEAD") == git.OK {
			head_name = strings.clone(string(git.reference_symbolic_target(head)), context.temp_allocator)
			git.reference_free(head)
		}
	} else {
		return git_error("Could not read HEAD")
	}
	iter: ^git.Branch_Iterator
	if git.branch_iterator_new(&iter, model.repo, git.BRANCH_ALL) != git.OK do return git_error("Could not list branches")
	defer git.branch_iterator_free(iter)
	for {
		ref: ^git.Reference
		kind: c.int
		result = git.branch_next(&ref, &kind, iter)
		if result == git.ITEROVER do break
		if result != git.OK do return git_error("Could not read a branch")
		defer git.reference_free(ref)
		// Remote HEAD aliases are not branches.
		if git.reference_type(ref) == git.REFERENCE_SYMBOLIC do continue
		name := string(git.reference_name(ref))
		is_head := name == head_name
		if is_head do model.selected = len(model.branches)
		append(&model.branches, Branch{
			name = strings.clone(string(git.reference_shorthand(ref))),
			ref_name = strings.clone(name), remote = kind == git.BRANCH_REMOTE, head = is_head,
			tip = git.reference_target(ref)^,
		})
	}
	if detached || unborn {
		model.selected = len(model.branches)
		name := detached ? "Detached HEAD" : strings.trim_prefix(head_name, "refs/heads/")
		if name == "" do name = "HEAD"
		tip: git.Oid
		if detached && git.reference_name_to_id(&tip, model.repo, "HEAD") != git.OK do return git_error("Could not read detached HEAD")
		append(&model.branches, Branch{name = strings.clone(name), ref_name = strings.clone("HEAD"), head = true, unborn = unborn, tip = tip})
	}
	return ""
}

// Selection only changes the viewed ancestry. It does not check out working files.
select_branch :: proc(model: ^Model, index: int) -> string {
	return select_history(model, index, false)
}

select_history :: proc(model: ^Model, index: int, all_branches: bool) -> string {
	if index < 0 || index >= len(model.branches) do return "This branch is no longer available. Refresh the project."
	branch := model.branches[index]
	walk: ^git.Revwalk
	if all_branches || !branch.unborn {
		if git.revwalk_new(&walk, model.repo) != git.OK do return git_error("Could not open commit history")
		if git.revwalk_sorting(walk, git.SORT_TOPOLOGICAL | git.SORT_TIME) != git.OK {
			err := git_error("Could not read branch history")
			git.revwalk_free(walk)
			return err
		}
		// Walking all tips together reveals unmerged branches too. libgit2
		// deduplicates shared ancestry and keeps every parent after its children.
		for &candidate, i in model.branches {
			if candidate.unborn || (!all_branches && i != index) do continue
			if git.revwalk_push(walk, &candidate.tip) != git.OK {
				err := git_error("Could not read branch history")
				git.revwalk_free(walk)
				return err
			}
		}
	}
	clear_history(model)
	model.selected = index
	model.all_branches = all_branches
	model.walk = walk
	model.has_more = walk != nil
	return load_more(model)
}

load_more :: proc(model: ^Model) -> string {
	if !model.has_more do return ""
	for _ in 0..<PAGE_SIZE {
		id: git.Oid
		result := git.revwalk_next(&id, model.walk)
		if result == git.ITEROVER {
			git.revwalk_free(model.walk)
			model.walk = nil
			model.has_more = false
			return ""
		}
		if result != git.OK do return git_error("Could not load more commits")
		node: ^git.Commit
		if git.commit_lookup(&node, model.repo, &id) != git.OK do return git_error("Could not read a commit")
		defer git.commit_free(node)
		hash: [65]u8
		_ = git.oid_tostr(raw_data(hash[:]), c.size_t(len(hash)), &id)
		date: [32]u8
		stamp := time.unix(git.commit_time(node) + i64(git.commit_time_offset(node)) * 60, 0)
		author := git.commit_author(node)
		parents := make([]git.Oid, int(git.commit_parentcount(node)), context.temp_allocator)
		for &parent, i in parents do parent = git.commit_parent_id(node, c.uint(i))^
		refs := strings.builder_make(context.temp_allocator)
		for &branch in model.branches {
			if branch.unborn || git.oid_equal(&branch.tip, &id) == 0 do continue
			if len(refs.buf) > 0 do strings.write_string(&refs, ", ")
			if branch.head do strings.write_string(&refs, "HEAD → ")
			strings.write_string(&refs, branch.name)
		}
		append(&model.commits, Commit{
			message = strings.clone(string(git.commit_summary(node))),
			hash = strings.clone(string(cstring(raw_data(hash[:])))),
			author = strings.clone(author != nil ? string(author.name) : "Unknown author"),
			date = strings.clone(time.to_string_yyyy_mm_dd(stamp, date[:])),
			refs = strings.clone(strings.to_string(refs)),
			graph = graph_append(&model.graph, id, parents),
		})
	}
	return ""
}

refresh :: proc(model: ^Model) -> string {
	selected := strings.clone(model.branches[model.selected].ref_name, context.temp_allocator)
	next: Model
	if err := open(&next, model.config); err != "" do return err
	for branch, i in next.branches {
		if branch.ref_name == selected && (i != next.selected || model.all_branches != next.all_branches) {
			if err := select_history(&next, i, model.all_branches); err != "" {
				destroy(&next)
				return err
			}
			break
		}
	}
	destroy(model)
	model^ = next
	return ""
}
