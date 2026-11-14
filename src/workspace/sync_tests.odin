package workspace

import "core:c"
import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import git "../git"

test_repo :: proc(t: ^testing.T, path: string, bare := false) -> ^git.Repository {
	repo: ^git.Repository
	if !test_ok(t, git.repository_init(&repo, cstring_temp(path), u32(bare ? 1 : 0))) do return nil
	_ = test_ok(t, git.repository_set_head(repo, "refs/heads/main"))
	settings: ^git.Config
	if test_ok(t, git.repository_config(&settings, repo)) {
		_ = test_ok(t, git.config_set_string(settings, "user.name", "Sync fixture"))
		_ = test_ok(t, git.config_set_string(settings, "user.email", "sync@example.invalid"))
		_ = test_ok(t, git.config_set_string(settings, "core.autocrlf", "false"))
		git.config_free(settings)
	}
	return repo
}

test_write_file :: proc(t: ^testing.T, root, name, content: string) {
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", root, name), content) == nil)
}

test_find_file :: proc(model: ^Model, path: string) -> (Changed_File, int) {
	for file, i in model.changes.files do if file.path == path do return file, i
	return {}, -1
}

@(test)
working_changes_compare_head_with_index_and_worktree :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	repo := test_repo(t, root)
	if repo == nil do return
	defer git.repository_free(repo)
	model: Model
	defer destroy(&model)
	config := Config{root, root, "Working reader", "working@example.invalid"}

	// Before the first commit, everything is compared with an empty tree.
	test_write_file(t, root, "draft.txt", "first draft\n")
	if !testing.expect(t, open(&model, config) == "") do return
	if !testing.expect(t, select_working_changes(&model) == "") do return
	testing.expect(t, changes_open(model.changes) && model.changes.working && model.changes.hash == "")
	draft, _ := test_find_file(&model, "draft.txt")
	testing.expect(t, draft.status == git.DELTA_UNTRACKED)
	test_change_line(t, model.changes.file, .ADDITION, "first draft", 0, 1)

	test_write_file(t, root, "tracked.txt", "one\ntwo\n")
	test_write_file(t, root, "staged.txt", "before\n")
	test_write_file(t, root, "removed.txt", "bye\n")
	if !test_ok(t, git.stage_all(repo)) do return
	head := test_commit(t, repo, "Base")
	if !testing.expect(t, refresh(&model) == "") do return
	testing.expect(t, !changes_open(model.changes))
	if !testing.expect(t, select_working_changes(&model) == "") do return
	testing.expect(t, len(model.changes.files) == 0 && model.changes.hash != "")

	// Unstaged edit, staged edit, deletion and a new untracked file.
	test_write_file(t, root, "tracked.txt", "one\nTWO\n")
	test_write_file(t, root, "staged.txt", "after\n")
	index: ^git.Index
	if !test_ok(t, git.repository_index(&index, repo)) do return
	_ = test_ok(t, git.index_add_bypath(index, "staged.txt"))
	_ = test_ok(t, git.index_write(index))
	git.index_free(index)
	testing.expect(t, os.remove(fmt.tprintf("%s/removed.txt", root)) == nil)
	testing.expect(t, os.make_directory(fmt.tprintf("%s/notes", root)) == nil)
	test_write_file(t, root, "notes/new.md", "hello\n")
	if !testing.expect(t, select_working_changes(&model) == "") do return
	hash: [65]u8
	_ = git.oid_tostr(raw_data(hash[:]), len(hash), &head)
	testing.expect(t, model.changes.hash == string(cstring(raw_data(hash[:]))))
	testing.expect(t, len(model.changes.files) == 4)
	tracked, tracked_index := test_find_file(&model, "tracked.txt")
	staged, _ := test_find_file(&model, "staged.txt")
	removed, _ := test_find_file(&model, "removed.txt")
	added, _ := test_find_file(&model, "notes/new.md")
	testing.expect(t, tracked.status == git.DELTA_MODIFIED && staged.status == git.DELTA_MODIFIED)
	testing.expect(t, removed.status == git.DELTA_DELETED && added.status == git.DELTA_UNTRACKED)
	if !testing.expect(t, select_file(&model, tracked_index) == "") do return
	test_change_line(t, model.changes.file, .DELETION, "two", 2, 0)
	test_change_line(t, model.changes.file, .ADDITION, "TWO", 0, 2)
	testing.expect(t, model.changes.file.additions == 1 && model.changes.file.deletions == 1)

	// Reloading keeps the selected file; nothing was staged by viewing.
	test_write_file(t, root, "tracked.txt", "one\nTwo\n")
	if !testing.expect(t, select_working_changes(&model) == "") do return
	testing.expect(t, model.changes.files[model.changes.file.index].path == "tracked.txt")
	test_change_line(t, model.changes.file, .ADDITION, "Two", 0, 2)
	if !test_ok(t, git.repository_index(&index, repo)) do return
	testing.expect(t, git.index_get_bypath(index, "notes/new.md", 0) == nil)
	git.index_free(index)
	clear_changes(&model.changes)
	testing.expect(t, !changes_open(model.changes))
}

@(test)
pull_rebase_setting_is_stored_in_repository_config :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	repo := test_repo(t, root)
	if repo == nil do return
	defer git.repository_free(repo)
	_ = test_commit(t, repo, "Base")
	model: Model
	defer destroy(&model)
	if !testing.expect(t, open(&model, Config{root, root, "Rebase", "rebase@example.invalid"}) == "") do return
	testing.expect(t, model.sync.branch == "main" && model.sync.upstream == "" && model.sync.remote == "")
	testing.expect(t, set_pull_rebase(&model, true) == "" && model.sync.rebase)
	text, err := os.read_entire_file(fmt.tprintf("%s/.git/config", root), context.temp_allocator)
	testing.expect(t, err == nil && strings.contains(string(text), "rebase = true"))
	testing.expect(t, refresh(&model) == "" && model.sync.rebase)
	testing.expect(t, set_pull_rebase(&model, false) == "" && !model.sync.rebase)

	// A branch-level override wins in Git, so the toggle updates it as well.
	settings: ^git.Config
	if !test_ok(t, git.repository_config(&settings, repo)) do return
	_ = test_ok(t, git.config_set_string(settings, "branch.main.rebase", "merges"))
	git.config_free(settings)
	testing.expect(t, pull_rebase_enabled(model.repo, "main"))
	testing.expect(t, set_pull_rebase(&model, false) == "" && !model.sync.rebase)
	testing.expect(t, !pull_rebase_enabled(model.repo, "main"))
}

@(test)
remote_task_pushes_pulls_and_honors_the_lease :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	server_path := fmt.tprintf("%s/server", root)
	client_path := fmt.tprintf("%s/client", root)
	other_path := fmt.tprintf("%s/other", root)
	server := test_repo(t, server_path, true)
	if server == nil do return
	defer git.repository_free(server)
	client := test_repo(t, client_path)
	if client == nil do return
	defer git.repository_free(client)
	remote: ^git.Remote
	if !test_ok(t, git.remote_create(&remote, client, "origin", cstring_temp(server_path))) do return
	git.remote_free(remote)
	test_write_file(t, client_path, "file.txt", "base\n")
	if !test_ok(t, git.stage_all(client)) do return
	_ = test_commit(t, client, "Base")

	model: Model
	defer destroy(&model)
	task: Remote_Task
	defer remote_destroy(&task)
	if !testing.expect(t, open(&model, Config{root, client_path, "Sync user", "sync-user@example.invalid"}) == "") do return
	testing.expect(t, model.sync.remote == "origin" && model.sync.upstream == "")
	testing.expect(t, remote_start(&task, &model, .PULL) != "" && !remote_busy(&task))

	// The first push publishes the branch and records its upstream.
	if !testing.expect(t, remote_start(&task, &model, .PUSH) == "") do return
	testing.expect(t, remote_start(&task, &model, .PUSH) != "")
	testing.expect(t, remote_wait(&task) && !remote_busy(&task))
	testing.expectf(t, !task.failed, "push failed: %s", remote_message(&task))
	testing.expect(t, refresh(&model) == "" && model.sync.upstream == "origin/main")
	testing.expect(t, model.sync.ahead == 0 && model.sync.behind == 0)

	// A second clone advances the server.
	other := test_repo(t, other_path)
	if other == nil do return
	defer git.repository_free(other)
	if !test_ok(t, git.remote_create(&remote, other, "origin", cstring_temp(server_path))) do return
	git.remote_free(remote)
	if !test_ok(t, git.fetch(other)) do return
	base: git.Oid
	if !test_ok(t, git.reference_name_to_id(&base, other, "refs/remotes/origin/main")) do return
	test_ref(t, other, "refs/heads/main", &base)
	checkout: git.Checkout_Options
	_ = git.checkout_options_init(&checkout, git.CHECKOUT_OPTIONS_VERSION)
	checkout.checkout_strategy = git.CHECKOUT_FORCE
	if !test_ok(t, git.checkout_head(other, &checkout)) do return
	test_write_file(t, other_path, "other.txt", "from the other clone\n")
	if !test_ok(t, git.stage_all(other)) do return
	_ = test_commit(t, other, "Other clone")
	specs := [1]cstring{"refs/heads/main:refs/heads/main"}
	if !test_ok(t, git.push(other, specs[:])) do return

	// Diverge locally: a plain push is rejected, and so is a lease that has
	// not seen the other clone's commit.
	test_write_file(t, client_path, "mine.txt", "local work\n")
	if !test_ok(t, git.stage_all(client)) do return
	local := test_commit(t, client, "Local work")
	if !testing.expect(t, refresh(&model) == "" && model.sync.ahead == 1) do return
	testing.expect(t, remote_start(&task, &model, .PUSH) == "" && remote_wait(&task))
	testing.expect(t, task.failed && strings.contains(remote_message(&task), "Pull first"))
	testing.expect(t, remote_start(&task, &model, .FORCE_PUSH_WITH_LEASE) == "" && remote_wait(&task))
	testing.expect(t, task.failed && strings.contains(remote_message(&task), "Force push refused"))
	server_tip: git.Oid
	_ = test_ok(t, git.reference_name_to_id(&server_tip, server, "refs/heads/main"))
	testing.expect(t, git.oid_equal(&server_tip, &local) == 0)

	// Fast-forward-only pulls refuse divergence; with rebase the pull replays it.
	// Set it explicitly: a global pull.rebase would otherwise apply.
	testing.expect(t, set_pull_rebase(&model, false) == "" && !model.sync.rebase)
	testing.expect(t, remote_start(&task, &model, .PULL) == "" && remote_wait(&task))
	testing.expectf(t, task.failed && strings.contains(remote_message(&task), "diverged"), "pull: %v %s", task.failed, remote_message(&task))
	testing.expect(t, set_pull_rebase(&model, true) == "")
	testing.expect(t, remote_start(&task, &model, .PULL) == "" && remote_wait(&task))
	testing.expectf(t, !task.failed, "pull failed: %s", remote_message(&task))
	testing.expect(t, os.exists(fmt.tprintf("%s/other.txt", client_path)) && os.exists(fmt.tprintf("%s/mine.txt", client_path)))
	testing.expect(t, refresh(&model) == "" && model.sync.ahead == 1 && model.sync.behind == 0)
	testing.expect(t, model.commits[0].message == "Local work" && model.commits[0].author == "Sync fixture")

	// Rewrite the pushed commit, then replace it on the server with the lease.
	testing.expect(t, remote_start(&task, &model, .PUSH) == "" && remote_wait(&task) && !task.failed)
	options: git.Commit_Create_Options
	_ = git.commit_create_options_init(&options, git.COMMIT_CREATE_OPTIONS_VERSION)
	head_ref: ^git.Reference
	if !test_ok(t, git.repository_head(&head_ref, client)) do return
	rebased := git.reference_target(head_ref)^
	git.reference_free(head_ref)
	node: ^git.Commit
	if !test_ok(t, git.commit_lookup(&node, client, &rebased)) do return
	parent: ^git.Commit
	_ = test_ok(t, git.commit_parent(&parent, node, 0))
	tree: ^git.Tree
	_ = test_ok(t, git.tree_lookup(&tree, client, git.commit_tree_id(node)))
	amended: git.Oid
	parents := [1]^git.Commit{parent}
	_ = test_ok(t, git.commit_create(&amended, client, nil, model.identity, model.identity, nil, "Local work, amended", tree, 1, raw_data(parents[:])))
	git.tree_free(tree)
	git.commit_free(parent)
	git.commit_free(node)
	test_ref_force(t, client, "refs/heads/main", &amended)
	if !testing.expect(t, refresh(&model) == "") do return
	testing.expect(t, remote_start(&task, &model, .FORCE_PUSH_WITH_LEASE) == "" && remote_wait(&task))
	testing.expectf(t, !task.failed, "force push failed: %s", remote_message(&task))
	_ = test_ok(t, git.reference_name_to_id(&server_tip, server, "refs/heads/main"))
	testing.expect(t, git.oid_equal(&server_tip, &amended) == 1)
}

test_ref_force :: proc(t: ^testing.T, repo: ^git.Repository, name: string, id: ^git.Oid) {
	ref: ^git.Reference
	_ = test_ok(t, git.reference_create(&ref, repo, cstring_temp(name), id, 1, nil))
	git.reference_free(ref)
}

@(test)
ssh_key_candidates_accept_files_and_key_folders :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	test_write_file(t, root, "id_rsa", "rsa")
	test_write_file(t, root, "id_ed25519", "ed")
	test_write_file(t, root, "id_ed25519.pub", "public")
	keys := ssh_key_candidates(root)
	testing.expect(t, len(keys) == 2 && strings.has_suffix(keys[0], "id_ed25519") && strings.has_suffix(keys[1], "id_rsa"))
	single := ssh_key_candidates(fmt.tprintf("%s/id_rsa", root))
	testing.expect(t, len(single) == 1)
	testing.expect(t, len(ssh_key_candidates(fmt.tprintf("%s/missing", root))) == 0)
}

@(private)
test_openssh_key :: proc(cipher: string) -> string {
	blob := make([dynamic]u8, context.temp_allocator)
	append(&blob, "openssh-key-v1\x00")
	n := len(cipher)
	append(&blob, u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n))
	append(&blob, cipher)
	append(&blob, "\x00\x00\x00\x04none") // The rest of the key is irrelevant.
	encoded, _ := base64.encode(blob[:], allocator = context.temp_allocator)
	return fmt.tprintf("-----BEGIN OPENSSH PRIVATE KEY-----\n%s\n%s\n-----END OPENSSH PRIVATE KEY-----\n",
		encoded[:min(len(encoded), 20)], encoded[min(len(encoded), 20):])
}

@(test)
ssh_key_encrypted_recognizes_key_formats :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	cases := [?]struct{name, text: string, encrypted: bool}{
		{"openssh_plain", test_openssh_key("none"), false},
		{"openssh_locked", test_openssh_key("aes256-ctr"), true},
		{"pem_plain", "-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----\n", false},
		{"pem_locked", "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,00\n\nMIIE\n-----END RSA PRIVATE KEY-----\n", true},
		{"pkcs8_locked", "-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIE\n-----END ENCRYPTED PRIVATE KEY-----\n", true},
		{"putty_plain", "PuTTY-User-Key-File-3: ssh-ed25519\r\nEncryption: none\r\n", false},
		{"putty_locked", "PuTTY-User-Key-File-3: ssh-ed25519\r\nEncryption: aes256-cbc\r\n", true},
		{"garbage", "not a key", false},
	}
	for test_case in cases {
		test_write_file(t, root, test_case.name, test_case.text)
		path := fmt.tprintf("%s/%s", root, test_case.name)
		testing.expectf(t, ssh_key_encrypted(path) == test_case.encrypted, "%s: expected encrypted=%v", test_case.name, test_case.encrypted)
	}
	testing.expect(t, !ssh_key_encrypted(fmt.tprintf("%s/missing", root)))
}

// Encrypted keys must never be offered without a passphrase: libssh2 would
// abort the whole operation instead of moving on to the next credential.
@(test)
remote_credentials_offer_encrypted_keys_last_and_only_with_a_passphrase :: proc(t: ^testing.T) {
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	offer :: proc(payload: ^Remote_Payload) -> (code: c.int, key: cstring) {
		credential: ^git.Credential
		code = remote_credentials(&credential, "ssh://git@example.invalid/repo", "git", git.CREDENTIAL_SSH_KEY, payload)
		if code == git.OK {
			// Only key-file credentials record a key; the agent's has none.
			key = payload.last_key >= 0 ? payload.keys[payload.last_key] : nil
			git.credential_free(credential)
		}
		return
	}
	payload := Remote_Payload{last_key = -1, key_count = 2}
	payload.keys[0], payload.keys[1] = "locked", "plain"
	payload.encrypted[0] = true
	code, key := offer(&payload)
	testing.expect(t, code == git.OK && key == "plain")
	code, key = offer(&payload)
	testing.expect(t, code == git.OK && key == nil && payload.agent_tried)
	code, _ = offer(&payload)
	testing.expect(t, code == git.EAUTH && payload.locked_skipped && remote_needs_passphrase(&payload))
	testing.expect(t, strings.contains(remote_auth_hint(git.EAUTH, &payload), "locked is protected by a passphrase"))

	payload = Remote_Payload{last_key = -1, key_count = 2, passphrase = "correct horse"}
	payload.keys[0], payload.keys[1] = "locked", "plain"
	payload.encrypted[0] = true
	_, _ = offer(&payload)
	_, _ = offer(&payload)
	code, key = offer(&payload)
	testing.expect(t, code == git.OK && key == "locked" && !payload.locked_skipped)
	code, _ = offer(&payload)
	testing.expect(t, code == git.EAUTH && !remote_needs_passphrase(&payload))
}

@(test)
remote_task_zeroes_and_frees_the_passphrase :: proc(t: ^testing.T) {
	task: Remote_Task
	task.passphrase = strings.clone_to_cstring("secret")
	remote_reset(&task)
	testing.expect(t, task.passphrase == nil)
}
