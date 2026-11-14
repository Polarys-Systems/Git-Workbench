package git

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
git_abi_layout :: proc(t: ^testing.T) {
	// Reference layouts for the vendored libgit2 2.0.0-rc.1 headers.
	when ODIN_ARCH == .amd64 {
		testing.expect(t, size_of(Oid) == 33 && align_of(Oid) == 1)
		testing.expect(t, size_of(Time) == 16 && size_of(Signature) == 32)
		testing.expect(t, size_of(Buffer) == 24 && size_of(Strarray) == 16)
		testing.expect(t, size_of(Indexer_Progress) == 32 && size_of(Push_Update) == 88)
		testing.expect(t, size_of(Remote_Head) == 88 && offset_of(Remote_Head, name) == 72)
		testing.expect(t, size_of(Remote_Callbacks) == 128 && size_of(Proxy_Options) == 40)
		testing.expect(t, size_of(Fetch_Options) == 216 && size_of(Push_Options) == 216)
		testing.expect(t, size_of(Commit_Create_Options) == 64 && size_of(Merge_Options) == 48)
		testing.expect(t, size_of(Checkout_Options) == 144)
		testing.expect(t, size_of(Rebase_Options) == 240 && offset_of(Rebase_Options, merge_options) == 24)
		testing.expect(t, offset_of(Rebase_Options, checkout_options) == 72 && offset_of(Rebase_Options, payload) == 232)
		testing.expect(t, size_of(Rebase_Operation) == 48 && offset_of(Rebase_Operation, exec) == 40)
		testing.expect(t, size_of(Diff_File) == 64 && offset_of(Diff_File, path) == 40)
		testing.expect(t, size_of(Diff_Delta) == 144 && offset_of(Diff_Delta, old_file) == 16)
		testing.expect(t, size_of(Diff_Options) == 96 && offset_of(Diff_Options, max_size) == 72)
		testing.expect(t, size_of(Diff_Find_Options) == 32)
		testing.expect(t, size_of(Diff_Hunk) == 152 && offset_of(Diff_Hunk, header) == 24)
		testing.expect(t, size_of(Diff_Line) == 40 && offset_of(Diff_Line, content) == 32)
		testing.expect(t, offset_of(Remote_Callbacks, credentials) == 24)
		testing.expect(t, offset_of(Remote_Callbacks, payload) == 104)
		testing.expect(t, offset_of(Remote_Callbacks, update_refs) == 120)
		testing.expect(t, offset_of(Fetch_Options, callbacks) == 8)
		testing.expect(t, offset_of(Fetch_Options, proxy_opts) == 152)
		testing.expect(t, offset_of(Fetch_Options, custom_headers) == 200)
		testing.expect(t, offset_of(Push_Options, callbacks) == 8)
		testing.expect(t, offset_of(Push_Options, remote_push_options) == 200)
		testing.expect(t, offset_of(Commit_Create_Options, author) == 8)
		testing.expect(t, offset_of(Commit_Create_Options, payload) == 56)
		testing.expect(t, offset_of(Checkout_Options, notify_cb) == 32)
		testing.expect(t, offset_of(Checkout_Options, paths) == 64)
		testing.expect(t, offset_of(Checkout_Options, perfdata_payload) == 136)
	}
}

@(private)
test_ok :: proc(t: ^testing.T, result: c.int) -> bool {
	return testing.expectf(t, result == OK, "libgit2 returned %d: %s", result, last_error_message())
}

@(private)
test_cstring :: proc(value: string) -> cstring {
	return strings.clone_to_cstring(value, context.temp_allocator)
}

@(private)
test_repository :: proc(t: ^testing.T, path: string, bare := false) -> ^Repository {
	repo: ^Repository
	if !test_ok(t, repository_init(&repo, test_cstring(path), c.uint(1 if bare else 0))) do return nil
	if !test_ok(t, repository_set_head(repo, "refs/heads/main")) {
		repository_free(repo)
		return nil
	}
	config: ^Config
	if !test_ok(t, repository_config(&config, repo)) {
		repository_free(repo)
		return nil
	}
	defer config_free(config)
	_ = test_ok(t, config_set_string(config, "user.name", "Odin libgit2 tests"))
	_ = test_ok(t, config_set_string(config, "user.email", "odin-test@example.invalid"))
	_ = test_ok(t, config_set_string(config, "core.autocrlf", "false"))
	_ = test_ok(t, config_set_string(config, "core.eol", "lf"))
	return repo
}

@(private)
test_remote :: proc(t: ^testing.T, repo: ^Repository, url: string) -> bool {
	remote: ^Remote
	if !test_ok(t, remote_create(&remote, repo, "origin", test_cstring(url))) do return false
	remote_free(remote)
	return true
}

@(private)
test_write :: proc(t: ^testing.T, root, name, content: string) -> bool {
	return testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", root, name), content) == nil)
}

@(test)
git_staging_and_commits :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, libgit2_init() > 0) do return
	defer _ = libgit2_shutdown()
	major, minor, revision: c.int
	libgit2_version(&major, &minor, &revision)
	if !testing.expect(t, major == 2 && minor == 0) do return
	root, err := os.make_directory_temp("", "odin-libgit2-commit-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer delete(root)
	defer _ = os.remove_all(root)
	repo := test_repository(t, root)
	if repo == nil do return
	defer repository_free(repo)

	if !test_write(t, root, ".gitignore", "ignored.txt\n") do return
	if !test_write(t, root, "ignored.txt", "not staged\n") do return
	if !test_write(t, root, "tracked.txt", "initial\n") do return
	if !test_ok(t, stage_all(repo)) do return
	index: ^Index
	if !test_ok(t, repository_index(&index, repo)) do return
	testing.expect(t, index_entrycount(index) == 2)
	index_free(index)
	first, result := commit(repo, "Initial commit")
	if !test_ok(t, result) do return
	testing.expect(t, first.type == u8(OID_SHA1))
	lookup: ^Commit
	if !test_ok(t, commit_lookup(&lookup, repo, &first)) do return
	testing.expect(t, commit_parentcount(lookup) == 0)
	testing.expect(t, string(commit_message(lookup)) == "Initial commit")
	commit_free(lookup)

	// No implicit staging, and ignored files remain ignored.
	if !test_write(t, root, "untracked.txt", "not staged yet\n") do return
	_, result = commit(repo, "Should not commit working files")
	testing.expect(t, result == EUNCHANGED)
	if !testing.expect(t, os.remove(fmt.tprintf("%s/tracked.txt", root)) == nil) do return
	if !test_ok(t, stage_all(repo)) do return
	if !test_ok(t, repository_index(&index, repo)) do return
	testing.expect(t, index_entrycount(index) == 2)
	index_free(index)
	second: Oid
	second, result = commit(repo, "Add and delete files")
	if !test_ok(t, result) do return
	if !test_ok(t, commit_lookup(&lookup, repo, &second)) do return
	testing.expect(t, commit_parentcount(lookup) == 1)
	commit_free(lookup)
	if !test_ok(t, stage_all(repo)) do return
	_, result = commit(repo, "Still no changes")
	testing.expect(t, result == EUNCHANGED)

	opts: Commit_Create_Options
	if !test_ok(t, commit_create_options_init(&opts, COMMIT_CREATE_OPTIONS_VERSION)) do return
	opts.flags.allow_empty_commit = true
	_, result = commit(repo, "Explicit empty commit", &opts)
	_ = test_ok(t, result)
	testing.expect(t, push(repo, nil) == EINVALIDSPEC)
	testing.expect(t, reject_failed_push("refs/heads/main", nil, nil) == OK)
	testing.expect(t, reject_failed_push("refs/heads/main", "test rejection", nil) == EUSER)
}

@(test)
git_history_and_reference_iteration :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, libgit2_init() > 0) do return
	defer _ = libgit2_shutdown()
	root, err := os.make_directory_temp("", "odin-libgit2-history-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer delete(root)
	defer _ = os.remove_all(root)
	repo := test_repository(t, root)
	if repo == nil do return
	defer repository_free(repo)
	index: ^Index
	if !test_ok(t, repository_index(&index, repo)) do return
	defer index_free(index)
	tree_id: Oid
	if !test_ok(t, index_write_tree(&tree_id, index)) do return
	tree: ^Tree
	if !test_ok(t, tree_lookup(&tree, repo, &tree_id)) do return
	defer tree_free(tree)

	// A diamond with dates deliberately opposed to ancestry, beyond 32-bit
	// Unix time. This exercises actual DLL calls, parent order and time ABI.
	messages := [4]cstring{"Root\n\nBody\n", "Feature", "Main", "Merge"}
	times := [4]i64{2_200_000_400, 2_200_000_200, 2_200_000_300, 2_200_000_100}
	parents := [4][]int{nil, {0}, {0}, {2, 1}}
	author := Signature{name = "History author", email = "author@example.invalid", when_ = {time = 2_200_000_000}}
	committer := Signature{name = "History committer", email = "committer@example.invalid", when_ = {offset = -90, sign = '-'}}
	ids: [4]Oid
	nodes: [4]^Commit
	defer for node in nodes do commit_free(node)
	for i in 0..<len(nodes) {
		parent_nodes: [2]^Commit
		for p, j in parents[i] do parent_nodes[j] = nodes[p]
		committer.when_.time = times[i]
		if !test_ok(t, commit_create(&ids[i], repo, nil, &author, &committer, nil,
			messages[i], tree, c.size_t(len(parents[i])), raw_data(parent_nodes[:]))) {
			return
		}
		if !test_ok(t, commit_lookup(&nodes[i], repo, &ids[i])) do return
		testing.expect(t, commit_time(nodes[i]) == times[i] && commit_time_offset(nodes[i]) == -90)
		testing.expect(t, commit_parentcount(nodes[i]) == c.uint(len(parents[i])))
		for p, j in parents[i] {
			parent_id := commit_parent_id(nodes[i], c.uint(j))
			if !testing.expect(t, parent_id != nil) do return
			testing.expect(t, oid_equal(parent_id, &ids[p]) == 1)
		}
	}
	summary := commit_summary(nodes[0])
	if !testing.expect(t, summary != nil) do return
	testing.expect(t, string(summary) == "Root")
	loaded_author, loaded_committer := commit_author(nodes[3]), commit_committer(nodes[3])
	if !testing.expect(t, loaded_author != nil && loaded_committer != nil) do return
	testing.expect(t, string(loaded_author.name) == "History author" && loaded_author.when_.time == author.when_.time)
	testing.expect(t, string(loaded_committer.email) == "committer@example.invalid" && loaded_committer.when_.time == times[3])
	parent: ^Commit
	if !test_ok(t, commit_parent(&parent, nodes[3], 1)) do return
	testing.expect(t, oid_equal(commit_id(parent), &ids[1]) == 1)
	commit_free(parent)

	names := [4]cstring{"refs/heads/main", "refs/heads/feature", "refs/remotes/origin/main", "refs/tags/v1"}
	tips := [4]int{3, 1, 2, 0}
	for name, i in names {
		ref: ^Reference
		if !test_ok(t, reference_create(&ref, repo, name, &ids[tips[i]], 0, nil)) do return
		reference_free(ref)
	}
	walk: ^Revwalk
	if !test_ok(t, revwalk_new(&walk, repo)) do return
	defer revwalk_free(walk)
	if !test_ok(t, revwalk_sorting(walk, SORT_TOPOLOGICAL | SORT_TIME)) do return
	if !test_ok(t, revwalk_push_glob(walk, "refs/heads/*")) do return
	if !test_ok(t, revwalk_push_glob(walk, "refs/remotes/*")) do return
	id: Oid
	positions := [4]int{-1, -1, -1, -1}
	for row in 0..<len(nodes) {
		if !test_ok(t, revwalk_next(&id, walk)) do return
		found := false
		for i in 0..<len(ids) {
			if oid_equal(&id, &ids[i]) == 0 do continue
			testing.expect(t, positions[i] == -1, "each commit must be visited only once")
			positions[i] = row
			found = true
		}
		testing.expect(t, found)
	}
	testing.expect(t, revwalk_next(&id, walk) == ITEROVER)
	for ps, i in parents {
		testing.expect(t, positions[i] >= 0)
		for p in ps do testing.expect(t, positions[i] < positions[p], "children must precede their parents")
	}
	if !test_ok(t, revwalk_reset(walk)) do return
	if !test_ok(t, revwalk_push_head(walk)) do return
	if !test_ok(t, revwalk_hide(walk, &ids[2])) do return
	if !test_ok(t, revwalk_hide_ref(walk, "refs/heads/feature")) do return
	if !test_ok(t, revwalk_next(&id, walk)) do return
	testing.expect(t, oid_equal(&id, &ids[3]) == 1)
	testing.expect(t, revwalk_next(&id, walk) == ITEROVER)

	head, resolved: ^Reference
	if !test_ok(t, reference_lookup(&head, repo, "HEAD")) do return
	defer reference_free(head)
	testing.expect(t, reference_type(head) == REFERENCE_SYMBOLIC && reference_target(head) == nil)
	testing.expect(t, string(reference_symbolic_target(head)) == "refs/heads/main")
	if !test_ok(t, reference_resolve(&resolved, head)) do return
	defer reference_free(resolved)
	testing.expect(t, reference_type(resolved) == REFERENCE_DIRECT)
	testing.expect(t, oid_equal(reference_target(resolved), &ids[3]) == 1)

	refs: ^Reference_Iterator
	if !test_ok(t, reference_iterator_new(&refs, repo)) do return
	defer reference_iterator_free(refs)
	seen: [4]bool
	for {
		ref: ^Reference
		result := reference_next(&ref, refs)
		if result == ITEROVER do break
		if !test_ok(t, result) do return
		defer reference_free(ref)
		found := false
		for name, i in names {
			if string(reference_name(ref)) != string(name) do continue
			testing.expect(t, !seen[i])
			seen[i], found = true, true
			testing.expect(t, oid_equal(reference_target(ref), &ids[tips[i]]) == 1)
			testing.expect(t, reference_is_tag(ref) == c.int(1 if i == 3 else 0))
		}
		testing.expect(t, found)
	}
	for found in seen do testing.expect(t, found)
	filtered: ^Reference_Iterator
	if !test_ok(t, reference_iterator_glob_new(&filtered, repo, "refs/remotes/*")) do return
	defer reference_iterator_free(filtered)
	name: cstring
	if !test_ok(t, reference_next_name(&name, filtered)) do return
	testing.expect(t, string(name) == "refs/remotes/origin/main")
	testing.expect(t, reference_next_name(&name, filtered) == ITEROVER)
	branches: ^Branch_Iterator
	if !test_ok(t, branch_iterator_new(&branches, repo, BRANCH_ALL)) do return
	defer branch_iterator_free(branches)
	locals, remotes := 0, 0
	for {
		ref: ^Reference
		kind: c.int
		result := branch_next(&ref, &kind, branches)
		if result == ITEROVER do break
		if !test_ok(t, result) do return
		defer reference_free(ref)
		if !test_ok(t, branch_name(&name, ref)) do return
		testing.expect(t, string(name) == string(reference_shorthand(ref)))
		if kind == BRANCH_LOCAL {
			locals += 1
			testing.expect(t, reference_is_branch(ref) == 1)
		} else {
			remotes += 1
			testing.expect(t, kind == BRANCH_REMOTE && reference_is_remote(ref) == 1)
		}
	}
	testing.expect(t, locals == 2 && remotes == 1)
}

@(test)
git_local_fetch_push_and_pull :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, libgit2_init() > 0) do return
	defer _ = libgit2_shutdown()
	root, err := os.make_directory_temp("", "odin-libgit2-remote-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer delete(root)
	defer _ = os.remove_all(root)
	server_path := fmt.tprintf("%s/server", root)
	source_path := fmt.tprintf("%s/source", root)
	client_path := fmt.tprintf("%s/client", root)
	server := test_repository(t, server_path, true)
	if server == nil do return
	defer repository_free(server)
	source := test_repository(t, source_path)
	if source == nil do return
	defer repository_free(source)
	client := test_repository(t, client_path)
	if client == nil do return
	defer repository_free(client)
	if !test_remote(t, source, server_path) || !test_remote(t, client, server_path) do return
	if !test_write(t, source_path, "file.txt", "first\n") do return
	if !test_ok(t, stage_all(source)) do return
	first, result := commit(source, "Initial remote commit")
	if !test_ok(t, result) do return
	specs := [1]cstring{"refs/heads/main:refs/heads/main"}
	opts: Push_Options
	if !test_ok(t, push_options_init(&opts, PUSH_OPTIONS_VERSION)) do return
	if !test_ok(t, push(source, specs[:], options = &opts)) do return
	server_id: Oid
	if !test_ok(t, reference_name_to_id(&server_id, server, "refs/heads/main")) do return
	testing.expect(t, oid_equal(&server_id, &first) == 1)

	// Fetch changes remote-tracking refs but leaves an unborn local HEAD alone.
	fetch_opts: Fetch_Options
	if !test_ok(t, fetch_options_init(&fetch_opts, FETCH_OPTIONS_VERSION)) do return
	if !test_ok(t, fetch(client, options = &fetch_opts)) do return
	local: ^Reference
	testing.expect(t, repository_head(&local, client) == EUNBORNBRANCH)
	initial: ^Commit
	if !test_ok(t, commit_lookup(&initial, client, &first)) do return
	checkout: Checkout_Options
	if !test_ok(t, checkout_options_init(&checkout, CHECKOUT_OPTIONS_VERSION)) {
		commit_free(initial)
		return
	}
	if !test_ok(t, checkout_tree(client, (^Object)(initial), &checkout)) {
		commit_free(initial)
		return
	}
	commit_free(initial)
	if !test_ok(t, reference_create(&local, client, "refs/heads/main", &first, 0, "test initial checkout")) do return
	if !test_ok(t, branch_set_upstream(local, "origin/main")) {
		reference_free(local)
		return
	}
	reference_free(local)
	status: Pull_Result
	status, result = pull(client)
	if !test_ok(t, result) do return
	testing.expect(t, status == .UP_TO_DATE)
	_, result = pull(server)
	testing.expect(t, result == EBAREREPO)

	if !test_write(t, source_path, "file.txt", "second\n") do return
	if !test_write(t, source_path, "blocked.txt", "remote tracked content\n") do return
	if !test_ok(t, stage_all(source)) do return
	second: Oid
	second, result = commit(source, "Remote update")
	if !test_ok(t, result) do return
	if !test_ok(t, push(source, specs[:])) do return

	// Safe pull refuses to overwrite a conflicting local modification.
	if !test_write(t, client_path, "file.txt", "local uncommitted content\n") do return
	_, result = pull(client)
	testing.expect(t, result == ECONFLICT)
	client_id: Oid
	if !test_ok(t, reference_name_to_id(&client_id, client, "HEAD")) do return
	testing.expect(t, oid_equal(&client_id, &first) == 1)
	content, read_err := os.read_entire_file(fmt.tprintf("%s/file.txt", client_path), context.temp_allocator)
	testing.expect(t, read_err == nil && string(content) == "local uncommitted content\n")
	if !test_write(t, client_path, "file.txt", "first\n") do return
	// Ignored local files are protected too, even when the remote tracks one.
	if !test_write(t, client_path, ".git/info/exclude", "blocked.txt\n") do return
	if !test_write(t, client_path, "blocked.txt", "precious ignored content\n") do return
	_, result = pull(client)
	testing.expect(t, result == ECONFLICT)
	content, read_err = os.read_entire_file(fmt.tprintf("%s/blocked.txt", client_path), context.temp_allocator)
	testing.expect(t, read_err == nil && string(content) == "precious ignored content\n")
	if !testing.expect(t, os.remove(fmt.tprintf("%s/blocked.txt", client_path)) == nil) do return
	status, result = pull(client, &fetch_opts)
	if !test_ok(t, result) do return
	testing.expect(t, status == .FAST_FORWARDED)
	if !test_ok(t, reference_name_to_id(&client_id, client, "HEAD")) do return
	testing.expect(t, oid_equal(&client_id, &second) == 1)
	content, read_err = os.read_entire_file(fmt.tprintf("%s/file.txt", client_path), context.temp_allocator)
	testing.expect(t, read_err == nil && string(content) == "second\n")

	// Divergent histories must not be merged or force-pushed implicitly.
	if !test_write(t, client_path, "client-only.txt", "client\n") do return
	if !test_ok(t, stage_all(client)) do return
	client_commit: Oid
	client_commit, result = commit(client, "Local branch diverges")
	if !test_ok(t, result) do return
	if !test_write(t, source_path, "server-only.txt", "server\n") do return
	if !test_ok(t, stage_all(source)) do return
	_, result = commit(source, "Remote branch diverges")
	if !test_ok(t, result) do return
	if !test_ok(t, push(source, specs[:])) do return
	_, result = pull(client)
	testing.expect(t, result == ENONFASTFORWARD)
	if !test_ok(t, reference_name_to_id(&client_id, client, "HEAD")) do return
	testing.expect(t, oid_equal(&client_id, &client_commit) == 1)
	testing.expect(t, push(client, specs[:]) != OK)

	// Pull with rebase replays the local commit on top of the upstream tip.
	status, result = pull(client, rebase = true)
	if !test_ok(t, result) do return
	testing.expect(t, status == .REBASED)
	remote_tip: Oid
	if !test_ok(t, reference_name_to_id(&remote_tip, client, "refs/remotes/origin/main")) do return
	if !test_ok(t, reference_name_to_id(&client_id, client, "HEAD")) do return
	rebased: ^Commit
	if !test_ok(t, commit_lookup(&rebased, client, &client_id)) do return
	testing.expect(t, commit_parentcount(rebased) == 1 && oid_equal(commit_parent_id(rebased, 0), &remote_tip) == 1)
	testing.expect(t, string(commit_summary(rebased)) == "Local branch diverges")
	commit_free(rebased)
	testing.expect(t, os.exists(fmt.tprintf("%s/server-only.txt", client_path)) && os.exists(fmt.tprintf("%s/client-only.txt", client_path)))
	status, result = pull(client, rebase = true)
	testing.expect(t, result == OK && status == .UP_TO_DATE)
	if !test_ok(t, push(client, specs[:])) do return

	// --force-with-lease refuses to overwrite commits this clone has not seen.
	lease := Push_Lease{refname = "refs/heads/main"}
	if !test_ok(t, reference_name_to_id(&lease.expected, source, "refs/remotes/origin/main")) do return
	lease_opts: Push_Options
	if !test_ok(t, push_options_init(&lease_opts, PUSH_OPTIONS_VERSION)) do return
	lease_opts.callbacks.push_negotiation = lease_negotiation
	lease_opts.callbacks.payload = &lease
	force := [1]cstring{"+refs/heads/main:refs/heads/main"}
	testing.expect(t, push(source, force[:], options = &lease_opts) != OK && lease.rejected)
	if !test_ok(t, reference_name_to_id(&server_id, server, "refs/heads/main")) do return
	testing.expect(t, oid_equal(&server_id, &client_id) == 1)
	// Once the remote state is fetched, the lease matches and the force push wins.
	if !test_ok(t, fetch(source)) do return
	lease.rejected = false
	if !test_ok(t, reference_name_to_id(&lease.expected, source, "refs/remotes/origin/main")) do return
	if !test_ok(t, push(source, force[:], options = &lease_opts)) do return
	source_id: Oid
	if !test_ok(t, reference_name_to_id(&source_id, source, "HEAD")) do return
	if !test_ok(t, reference_name_to_id(&server_id, server, "refs/heads/main")) do return
	testing.expect(t, oid_equal(&server_id, &source_id) == 1)
}

@(test)
git_pull_rebase_conflict_changes_nothing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, libgit2_init() > 0) do return
	defer _ = libgit2_shutdown()
	root, err := os.make_directory_temp("", "odin-libgit2-rebase-*", context.allocator)
	if !testing.expect(t, err == nil) do return
	defer delete(root)
	defer _ = os.remove_all(root)
	server_path := fmt.tprintf("%s/server", root)
	source_path := fmt.tprintf("%s/source", root)
	client_path := fmt.tprintf("%s/client", root)
	server := test_repository(t, server_path, true)
	if server == nil do return
	defer repository_free(server)
	source := test_repository(t, source_path)
	if source == nil do return
	defer repository_free(source)
	if !test_remote(t, source, server_path) do return
	if !test_write(t, source_path, "file.txt", "base\n") do return
	if !test_ok(t, stage_all(source)) do return
	if _, result := commit(source, "Base"); !test_ok(t, result) do return
	specs := [1]cstring{"refs/heads/main:refs/heads/main"}
	if !test_ok(t, push(source, specs[:])) do return

	// Clone-equivalent: fetch, check out, track origin/main.
	client := test_repository(t, client_path)
	if client == nil do return
	defer repository_free(client)
	if !test_remote(t, client, server_path) || !test_ok(t, fetch(client)) do return
	base: Oid
	if !test_ok(t, reference_name_to_id(&base, client, "refs/remotes/origin/main")) do return
	local: ^Reference
	if !test_ok(t, reference_create(&local, client, "refs/heads/main", &base, 0, "test checkout")) do return
	_ = test_ok(t, branch_set_upstream(local, "origin/main"))
	reference_free(local)
	checkout: Checkout_Options
	_ = checkout_options_init(&checkout, CHECKOUT_OPTIONS_VERSION)
	checkout.checkout_strategy = CHECKOUT_FORCE
	if !test_ok(t, checkout_head(client, &checkout)) do return

	if !test_write(t, client_path, "file.txt", "client\n") do return
	if !test_ok(t, stage_all(client)) do return
	local_id, result := commit(client, "Client edit")
	if !test_ok(t, result) do return
	if !test_write(t, source_path, "file.txt", "server\n") do return
	if !test_ok(t, stage_all(source)) do return
	if _, result = commit(source, "Server edit"); !test_ok(t, result) do return
	if !test_ok(t, push(source, specs[:])) do return

	status: Pull_Result
	status, result = pull(client, rebase = true)
	testing.expect(t, result == EMERGECONFLICT && status == .FAILED)
	head_id: Oid
	if !test_ok(t, reference_name_to_id(&head_id, client, "HEAD")) do return
	testing.expect(t, oid_equal(&head_id, &local_id) == 1)
	testing.expect(t, repository_state(client) == 0)
	content, read_err := os.read_entire_file(fmt.tprintf("%s/file.txt", client_path), context.temp_allocator)
	testing.expect(t, read_err == nil && string(content) == "client\n")
}

@(test)
git_build_has_ssh_and_https :: proc(t: ^testing.T) {
	if !testing.expect(t, libgit2_init() > 0) do return
	defer _ = libgit2_shutdown()
	features := libgit2_features()
	testing.expect(t, features & FEATURE_SSH != 0, "rebuild libgit2 with -DUSE_SSH=libssh2")
	testing.expect(t, features & FEATURE_HTTPS != 0)
	testing.expect(t, libgit2_feature_backend(FEATURE_SSH) != nil)
	testing.expect(t, libgit2_feature_backend(FEATURE_HTTPS) != nil)
}

@(test)
git_credentials_and_option_defaults :: proc(t: ^testing.T) {
	if !testing.expect(t, libgit2_init() > 0) do return
	defer _ = libgit2_shutdown()
	callbacks: Remote_Callbacks
	if !test_ok(t, remote_init_callbacks(&callbacks, REMOTE_CALLBACKS_VERSION)) do return
	testing.expect(t, callbacks.version == REMOTE_CALLBACKS_VERSION)
	proxy: Proxy_Options
	if !test_ok(t, proxy_options_init(&proxy, PROXY_OPTIONS_VERSION)) do return
	testing.expect(t, proxy.type == PROXY_NONE)
	merge_opts: Merge_Options
	if !test_ok(t, merge_options_init(&merge_opts, MERGE_OPTIONS_VERSION)) do return
	testing.expect(t, merge_opts.flags & MERGE_FIND_RENAMES != 0)
	auth := Userpass_Auth{username = "example-user", password = "test-token-not-a-real-secret"}
	credential: ^Credential
	if !test_ok(t, userpass_credentials(&credential, "https://example.invalid/repo", nil, CREDENTIAL_USERPASS_PLAINTEXT, &auth)) do return
	testing.expect(t, credential != nil && auth.attempted)
	credential_free(credential)
	testing.expect(t, userpass_credentials(&credential, nil, nil, CREDENTIAL_USERPASS_PLAINTEXT, &auth) == EAUTH)
	auth.attempted = false
	if !test_ok(t, userpass_credentials(&credential, nil, nil, CREDENTIAL_USERNAME, &auth)) do return
	credential_free(credential)
	testing.expect(t, !auth.attempted)
	testing.expect(t, userpass_credentials(&credential, nil, nil, CREDENTIAL_SSH_KEY, &auth) == PASSTHROUGH)
}

@(test)
git_ssh_key_callback :: proc(t: ^testing.T) {
	if !testing.expect(t, libgit2_init() > 0) do return
	defer _ = libgit2_shutdown()
	// The constructor copies credential data, but does not open/decrypt the
	// key until connection time. No real user keys are read in this unit test.
	auth := SSH_Key_Auth{
		username = "fallback-user", private_key = "test-key-not-on-disk",
		passphrase = "synthetic test passphrase with spaces",
	}
	credential: ^Credential
	if !test_ok(t, ssh_key_credentials(&credential, nil, nil, CREDENTIAL_USERNAME, &auth)) do return
	testing.expect(t, string(credential_get_username(credential)) == "fallback-user")
	credential_free(credential)
	testing.expect(t, auth.username_attempted && !auth.attempted)
	testing.expect(t, ssh_key_credentials(&credential, nil, nil, CREDENTIAL_USERNAME, &auth) == EAUTH)
	if !test_ok(t, ssh_key_credentials(&credential, nil, "url-user", CREDENTIAL_SSH_KEY, &auth)) do return
	testing.expect(t, string(credential_get_username(credential)) == "url-user")
	credential_free(credential)
	testing.expect(t, auth.attempted)
	testing.expect(t, ssh_key_credentials(&credential, nil, nil, CREDENTIAL_SSH_KEY, &auth) == EAUTH)
	testing.expect(t, ssh_key_credentials(&credential, nil, nil, CREDENTIAL_USERPASS_PLAINTEXT, &auth) == PASSTHROUGH)
	testing.expect(t, ssh_key_credentials(&credential, nil, nil, CREDENTIAL_SSH_KEY, nil) == EAUTH)
	missing := SSH_Key_Auth{username = "git"}
	testing.expect(t, ssh_key_credentials(&credential, nil, nil, CREDENTIAL_SSH_KEY, &missing) == EAUTH)
	auth = SSH_Key_Auth{private_key = "test-key-not-on-disk"}
	testing.expect(t, ssh_key_credentials(&credential, nil, nil, CREDENTIAL_SSH_KEY, &auth) == EAUTH)
}
