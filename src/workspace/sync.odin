package workspace

import "base:runtime"
import "core:c"
import "core:encoding/base64"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"

import git "../git"

// The checked-out branch and its upstream, as of the last fetch.
Sync_Status :: struct {
	branch: string,   // Short local branch name; empty for detached or unborn HEAD.
	upstream: string, // e.g. origin/main; empty when the branch has no upstream.
	remote: string,   // Push/pull remote: the upstream's, else origin when it exists.
	ahead, behind: int,
	unborn: bool,
	// Effective pull.rebase (or branch.<name>.rebase) for this repository.
	rebase: bool,
}

clear_sync :: proc(status: ^Sync_Status) {
	delete(status.branch)
	delete(status.upstream)
	delete(status.remote)
	status^ = {}
}

// Missing remotes or upstreams are normal states, never errors.
load_sync :: proc(model: ^Model) {
	clear_sync(&model.sync)
	status := &model.sync
	defer status.rebase = pull_rebase_enabled(model.repo, status.branch)
	head: ^git.Reference
	result := git.repository_head(&head, model.repo)
	if result == git.EUNBORNBRANCH {
		status.unborn = true
		if git.reference_lookup(&head, model.repo, "HEAD") == git.OK {
			status.branch = strings.clone(strings.trim_prefix(string(git.reference_symbolic_target(head)), "refs/heads/"))
			git.reference_free(head)
		}
	}
	if result != git.OK do return
	defer git.reference_free(head)
	if git.reference_is_branch(head) == 0 do return
	status.branch = strings.clone(string(git.reference_shorthand(head)))
	remote_name: git.Buffer
	defer git.buf_dispose(&remote_name)
	upstream: ^git.Reference
	if git.branch_upstream_remote(&remote_name, model.repo, git.reference_name(head)) == git.OK &&
		git.branch_upstream(&upstream, head) == git.OK {
		defer git.reference_free(upstream)
		status.upstream = strings.clone(string(git.reference_shorthand(upstream)))
		status.remote = strings.clone(string(remote_name.ptr))
		ahead, behind: c.size_t
		if git.graph_ahead_behind(&ahead, &behind, model.repo, git.reference_target(head), git.reference_target(upstream)) == git.OK {
			status.ahead, status.behind = int(ahead), int(behind)
		}
		return
	}
	origin: ^git.Remote
	if git.remote_lookup(&origin, model.repo, "origin") == git.OK {
		git.remote_free(origin)
		status.remote = strings.clone("origin")
	}
}

// git pull treats any non-false value ("merges", "interactive") as a rebase.
pull_rebase_enabled :: proc(repo: ^git.Repository, branch: string) -> bool {
	config: ^git.Config
	if repo == nil || git.repository_config(&config, repo) != git.OK do return false
	defer git.config_free(config)
	value: c.int
	if branch != "" {
		result := git.config_get_bool(&value, config, cstring_temp(fmt.tprintf("branch.%s.rebase", branch)))
		if result == git.OK do return value != 0
		if result != git.ENOTFOUND do return true
	}
	result := git.config_get_bool(&value, config, "pull.rebase")
	if result == git.OK do return value != 0
	return result != git.ENOTFOUND
}

// Stored as pull.rebase in the repository's own config, so the Git CLI and
// other tools pull the same way. A branch-level override is updated too, since
// it would otherwise win. Global Git settings are left unchanged.
set_pull_rebase :: proc(model: ^Model, enabled: bool) -> string {
	config: ^git.Config
	if git.repository_config(&config, model.repo) != git.OK do return git_error("Could not open the repository settings")
	defer git.config_free(config)
	if git.config_set_bool(config, "pull.rebase", c.int(enabled)) != git.OK do return git_error("Could not save pull.rebase")
	if model.sync.branch != "" {
		name := cstring_temp(fmt.tprintf("branch.%s.rebase", model.sync.branch))
		value: c.int
		if git.config_get_bool(&value, config, name) != git.ENOTFOUND {
			if git.config_set_bool(config, name, c.int(enabled)) != git.OK do return git_error("Could not save the branch's rebase setting")
		}
	}
	model.sync.rebase = pull_rebase_enabled(model.repo, model.sync.branch)
	return ""
}

// SUBMODULE_UPDATE is git submodule update --init --recursive, for one
// submodule (Remote_Task.submodule) or all of them.
// PUSH_TAGS pushes one tag (Remote_Task.tag) or every local tag.
Remote_Action :: enum { PULL, PUSH, FORCE_PUSH_WITH_LEASE, SUBMODULE_UPDATE, PUSH_TAGS }

// Network operations run on a worker thread with its own repository handle,
// so the window keeps rendering. Start at most one at a time, and do not
// mutate the repository from the UI while running.
Remote_Task :: struct {
	action: Remote_Action,
	worker: ^thread.Thread,
	done: bool, // Atomic; set by the worker when the result is ready.
	// Inputs, owned by the task; the worker only reads them.
	project_path, ssh_key_path, username, email: string,
	// Unlocks encrypted key files. Held only in memory, zeroed on reset.
	passphrase: cstring,
	rebase: bool,
	// SUBMODULE_UPDATE: the submodule's name and path, or empty for all.
	submodule, submodule_path: string,
	// PUSH_TAGS: the tag, or empty for all; and the remote to push to.
	tag, tag_remote: string,
	// Result, written by the worker in fixed storage (no cross-thread allocation).
	failed: bool,
	// Authentication failed and an encrypted key was skipped for lack of a
	// passphrase, or the supplied passphrase could not unlock a key.
	needs_passphrase, passphrase_rejected: bool,
	message_buf: [1024]u8,
	message_len: int,
}

remote_busy :: proc(task: ^Remote_Task) -> bool {
	return task.worker != nil
}

remote_message :: proc(task: ^Remote_Task) -> string {
	return string(task.message_buf[:task.message_len])
}

// passphrase is optional; it is tried only on encrypted key files.
remote_start :: proc(task: ^Remote_Task, model: ^Model, action: Remote_Action, passphrase := "") -> string {
	if remote_busy(task) do return "Another push or pull is still running."
	if model.repo == nil do return "Open a project first."
	if model.sync.branch == "" || model.sync.unborn {
		return model.sync.unborn ? "Create a first commit before pushing or pulling." : "Check out a local branch to push or pull (HEAD is detached)."
	}
	if action == .PULL && model.sync.upstream == "" {
		return fmt.tprintf("%s has no upstream branch yet. Push it first to publish it and set its upstream.", model.sync.branch)
	}
	if action != .PULL && model.sync.remote == "" {
		return "This repository has no remote named origin. Add one with git remote add origin <url>."
	}
	return remote_launch(task, model, action, passphrase)
}

// Updates one submodule (by name) or, with an empty name, every submodule:
// clones missing ones, fetches missing commits and checks out the commit the
// parent records (detached HEAD), then does the same for nested submodules.
// Local changes inside a submodule are never overwritten.
remote_submodule_start :: proc(task: ^Remote_Task, model: ^Model, name := "", passphrase := "") -> string {
	if remote_busy(task) do return "Another network operation is still running."
	if model.repo == nil do return "Open a project first."
	if len(model.submodules) == 0 do return "This repository has no submodules."
	path := ""
	if name != "" {
		for info in model.submodules do if info.name == name do path = info.path
		if path == "" do return "This submodule is no longer listed. Refresh the project."
	}
	return remote_launch(task, model, .SUBMODULE_UPDATE, passphrase, name, path)
}

// Pushes one tag (by name) or, with an empty name, every local tag to the
// branch's remote (origin when there is no upstream). Existing remote tags
// are never replaced: a tag that differs on the remote is rejected.
remote_tag_start :: proc(task: ^Remote_Task, model: ^Model, name := "", passphrase := "") -> string {
	if remote_busy(task) do return "Another network operation is still running."
	if model.repo == nil do return "Open a project first."
	if len(model.tags) == 0 do return "This repository has no tags to push."
	if name != "" && tag_index(model^, name) < 0 do return "This tag is no longer available. Refresh the project."
	remote := model.sync.remote
	if remote == "" {
		origin: ^git.Remote
		if git.remote_lookup(&origin, model.repo, "origin") != git.OK {
			git.error_clear()
			return "This repository has no remote named origin. Add one with git remote add origin <url>."
		}
		git.remote_free(origin)
		remote = "origin"
	}
	return remote_launch(task, model, .PUSH_TAGS, passphrase, tag = name, tag_remote = remote)
}

@(private)
remote_launch :: proc(task: ^Remote_Task, model: ^Model, action: Remote_Action, passphrase: string,
	submodule := "", submodule_path := "", tag := "", tag_remote := "") -> string {
	remote_reset(task)
	task.action = action
	task.submodule = strings.clone(submodule)
	task.submodule_path = strings.clone(submodule_path)
	task.tag = strings.clone(tag)
	task.tag_remote = strings.clone(tag_remote)
	task.project_path = strings.clone(model.config.project_path)
	task.ssh_key_path = strings.clone(model.config.ssh_key_path)
	task.username = strings.clone(model.config.username)
	task.email = strings.clone(model.config.email)
	if passphrase != "" do task.passphrase = strings.clone_to_cstring(passphrase)
	task.rebase = model.sync.rebase
	// The default context gives the worker its own heap and temp allocators.
	task.worker = thread.create_and_start_with_poly_data(task, remote_worker, init_context = runtime.default_context())
	if task.worker == nil {
		remote_reset(task)
		return "Could not start a background thread for the network operation."
	}
	return ""
}

// Non-blocking. Returns true once, when a running task has finished; read
// failed/remote_message afterwards, then refresh the model.
remote_poll :: proc(task: ^Remote_Task) -> bool {
	if task.worker == nil || !sync.atomic_load(&task.done) do return false
	remote_join(task)
	return true
}

// Block until the result is ready, but leave it for remote_poll (UI tests).
remote_await :: proc(task: ^Remote_Task) {
	if task.worker != nil do thread.join(task.worker)
}

// Block until the task finishes and collect it (shutdown and tests).
remote_wait :: proc(task: ^Remote_Task) -> bool {
	if task.worker == nil do return false
	remote_join(task)
	return true
}

remote_destroy :: proc(task: ^Remote_Task) {
	_ = remote_wait(task)
	remote_reset(task)
}

@(private)
remote_join :: proc(task: ^Remote_Task) {
	thread.join(task.worker)
	thread.destroy(task.worker)
	task.worker = nil
}

@(private)
remote_reset :: proc(task: ^Remote_Task) {
	delete(task.project_path)
	delete(task.ssh_key_path)
	delete(task.username)
	delete(task.email)
	delete(task.submodule)
	delete(task.submodule_path)
	delete(task.tag)
	delete(task.tag_remote)
	if task.passphrase != nil {
		mem.zero(rawptr(task.passphrase), len(task.passphrase))
		delete(task.passphrase)
	}
	task^ = {}
}

@(private)
remote_finish :: proc(task: ^Remote_Task, failed: bool, message: string) {
	task.failed = failed
	task.message_len = copy(task.message_buf[:], message)
}

// Credential payload shared by every callback of one operation.
@(private)
Remote_Payload :: struct {
	keys: [8]cstring,
	encrypted: [8]bool,
	key_count, next_key, next_locked: int,
	passphrase: cstring,
	last_key: int, // Index of the key file last offered; -1 for none or ssh-agent.
	locked_skipped: bool, // An encrypted key was not offered: no passphrase.
	agent_tried, username_tried: bool,
	lease: git.Push_Lease,
	use_lease: bool,
	keep_tags, tag_rejected: bool, // Tag pushes: refuse to move remote tags.
	// Repositories inside WSL: the Linux users' .ssh folders, whose keys and
	// known_hosts are used as well (read with the worker's context).
	wsl: bool,
	wsl_ssh_dirs: []string,
	ctx: runtime.Context,
	// Why a connection failed before authenticating: the server's host key
	// is not trusted (the host is named), or the remote asked for HTTPS
	// credentials.
	unknown_host_buf: [256]u8,
	unknown_host_len: int,
	host_revoked, https_asked: bool,
}

// Sets the credential and host key callbacks of one operation.
@(private)
remote_callbacks_set :: proc(callbacks: ^git.Remote_Callbacks, payload: ^Remote_Payload) {
	callbacks.credentials = remote_credentials
	callbacks.certificate_check = remote_certificate_check
	callbacks.payload = payload
}

// libgit2 has already checked the Windows known_hosts (valid). A WSL
// repository's hosts may be trusted only in the WSL known_hosts, which git
// in that distribution uses: accept a key listed there. Otherwise libgit2's
// verdict stands, and a rejected host is noted for the error message.
@(private)
remote_certificate_check :: proc "c" (cert: ^git.Certificate, valid: c.int, host: cstring, payload: rawptr) -> c.int {
	auth := (^Remote_Payload)(payload)
	context = auth.ctx
	if cert == nil || cert.cert_type != git.CERT_HOSTKEY_LIBSSH2 do return git.PASSTHROUGH
	hostkey := (^git.Cert_Hostkey)(cert)
	name := host != nil ? string(host) : ""
	if auth.wsl && hostkey.type & git.CERT_SSH_RAW != 0 && hostkey.hostkey != nil {
		switch known_hosts_check_files(auth.wsl_ssh_dirs, name, hostkey.hostkey[:hostkey.hostkey_len]) {
		case .MATCH:
			if valid == 0 do return git.OK
		case .REVOKED:
			auth.host_revoked = true
			auth.unknown_host_len = copy(auth.unknown_host_buf[:], name)
			return git.ECERTIFICATE
		case .UNKNOWN:
		}
	}
	if valid == 0 do auth.unknown_host_len = copy(auth.unknown_host_buf[:], name)
	return git.PASSTHROUGH
}

// Unencrypted key files first, then ssh-agent, then encrypted key files with
// the supplied passphrase. libssh2 aborts the whole operation (not just this
// credential) when it cannot load a key, so an encrypted key is never offered
// without a passphrase, and goes last so it cannot pre-empt ssh-agent. Each
// credential is attempted once so rejected ones cannot loop. HTTPS remotes are
// not handled (libgit2 does not use Git Credential Manager).
@(private)
remote_credentials :: proc "c" (out: ^^git.Credential, url, username_from_url: cstring, allowed_types: c.uint, payload: rawptr) -> c.int {
	auth := (^Remote_Payload)(payload)
	username := username_from_url != nil ? username_from_url : "git"
	if allowed_types & git.CREDENTIAL_SSH_KEY != 0 {
		for auth.next_key < auth.key_count {
			i := auth.next_key
			auth.next_key += 1
			if auth.encrypted[i] do continue
			auth.last_key = i
			return git.credential_ssh_key_new(out, username, nil, auth.keys[i], nil)
		}
		if !auth.agent_tried {
			auth.agent_tried = true
			auth.last_key = -1
			return git.credential_ssh_key_from_agent(out, username)
		}
		for auth.next_locked < auth.key_count {
			i := auth.next_locked
			auth.next_locked += 1
			if !auth.encrypted[i] do continue
			if auth.passphrase == nil {
				auth.locked_skipped = true
				continue
			}
			auth.last_key = i
			return git.credential_ssh_key_new(out, username, nil, auth.keys[i], auth.passphrase)
		}
		return git.EAUTH
	}
	if allowed_types & git.CREDENTIAL_USERPASS_PLAINTEXT != 0 do auth.https_asked = true
	if allowed_types & git.CREDENTIAL_USERNAME != 0 && !auth.username_tried {
		auth.username_tried = true
		return git.credential_username_new(out, username)
	}
	return git.PASSTHROUGH
}

@(private)
remote_negotiation :: proc "c" (updates: [^]^git.Push_Update, count: c.size_t, payload: rawptr) -> c.int {
	auth := (^Remote_Payload)(payload)
	if auth.keep_tags {
		// Like git push: an existing remote tag is never moved (libgit2 would).
		for i in 0..<int(count) {
			update := updates[i]
			if update == nil || update.dst_refname == nil do continue
			name := string(update.dst_refname)
			if len(name) <= 10 || name[:10] != "refs/tags/" || git.oid_is_zero(&update.src) || update.src.id == update.dst.id do continue
			auth.tag_rejected = true
			_ = git.error_set_str(git.ERROR_NET, "a tag with this name already exists on the remote at another commit")
			return git.EUSER
		}
	}
	if !auth.use_lease do return git.OK
	return git.check_push_lease(&auth.lease, updates, count)
}

// A key file, or the usual private keys inside a key folder.
ssh_key_candidates :: proc(location: string, allocator := context.temp_allocator) -> [dynamic]string {
	keys := make([dynamic]string, allocator)
	if location == "" do return keys
	if !os.is_dir(location) {
		if os.exists(location) do append(&keys, strings.clone(location, allocator))
		return keys
	}
	names := [?]string{"id_ed25519", "id_ecdsa", "id_ed25519_sk", "id_ecdsa_sk", "id_rsa"}
	for name in names {
		path, _ := filepath.join({location, name}, allocator)
		if os.exists(path) && !os.is_dir(path) do append(&keys, path)
	}
	return keys
}

// Whether a private key file needs a passphrase: OpenSSH (openssh-key-v1),
// PEM ("Proc-Type: 4,ENCRYPTED"), PKCS#8 and PuTTY formats are recognized.
// Unreadable or unknown files count as unencrypted, so libssh2 reports them.
ssh_key_encrypted :: proc(path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) > 1 << 20 do return false
	text := string(data)
	if strings.contains(text, "-----BEGIN ENCRYPTED PRIVATE KEY-----") do return true
	if strings.contains(text, "Proc-Type: 4,ENCRYPTED") do return true
	if strings.has_prefix(text, "PuTTY-User-Key-File-") {
		_, found, after := strings.partition(text, "Encryption:")
		if found == "" do return false
		line, _, _ := strings.partition(after, "\n")
		return strings.trim_space(line) != "none"
	}
	_, found, body := strings.partition(text, "-----BEGIN OPENSSH PRIVATE KEY-----")
	if found == "" do return false
	body, _, _ = strings.partition(body, "-----END")
	encoded := strings.builder_make(context.temp_allocator)
	for ch in body do if !strings.is_space(ch) do strings.write_rune(&encoded, ch)
	blob, decode_err := base64.decode(strings.to_string(encoded), allocator = context.temp_allocator)
	// Layout: "openssh-key-v1\0", then the cipher name as a big-endian
	// u32-length-prefixed string; "none" means unencrypted.
	MAGIC :: "openssh-key-v1\x00"
	if decode_err != nil || len(blob) < len(MAGIC) + 4 || string(blob[:len(MAGIC)]) != MAGIC do return false
	at := len(MAGIC)
	length := int(blob[at]) << 24 | int(blob[at + 1]) << 16 | int(blob[at + 2]) << 8 | int(blob[at + 3])
	at += 4
	if at + length > len(blob) do return false
	return string(blob[at:at + length]) != "none"
}

@(private)
remote_payload :: proc(task: ^Remote_Task) -> Remote_Payload {
	payload := Remote_Payload{last_key = -1, passphrase = task.passphrase, ctx = context}
	candidates := make([dynamic]string, context.temp_allocator)
	// Inside WSL, git uses the Linux user's keys: offer those first, like it.
	if is_wsl_path(task.project_path) {
		payload.wsl = true
		payload.wsl_ssh_dirs = wsl_ssh_dirs(task.project_path)[:]
		for dir in payload.wsl_ssh_dirs do append(&candidates, ..ssh_key_candidates(dir)[:])
	}
	append(&candidates, ..ssh_key_candidates(task.ssh_key_path)[:])
	outer: for key in candidates {
		if payload.key_count == len(payload.keys) do break
		for i in 0..<payload.key_count do if strings.equal_fold(string(payload.keys[i]), key) do continue outer
		payload.keys[payload.key_count] = cstring_temp(key)
		payload.encrypted[payload.key_count] = ssh_key_encrypted(key)
		payload.key_count += 1
	}
	return payload
}

@(private)
remote_worker :: proc(task: ^Remote_Task) {
	defer sync.atomic_store(&task.done, true)
	defer free_all(context.temp_allocator)
	// Nested submodule updates open WSL repositories inside libgit2.
	in_wsl := is_wsl_path(task.project_path)
	if in_wsl do wsl_trust_begin()
	defer if in_wsl do wsl_trust_end()
	repo: ^git.Repository
	if open_repository(&repo, task.project_path) != git.OK {
		remote_finish(task, true, git_error("Could not open the project"))
		return
	}
	defer git.repository_free(repo)
	identity: ^git.Signature
	if git.signature_now(&identity, cstring_temp(task.username), cstring_temp(task.email)) != git.OK {
		remote_finish(task, true, git_error("Could not use the commit identity"))
		return
	}
	defer git.signature_free(identity)
	payload := remote_payload(task)
	message: string
	failed: bool
	switch task.action {
	case .PULL: message, failed = remote_pull(repo, identity, task.rebase, &payload)
	case .PUSH: message, failed = remote_push(repo, false, &payload)
	case .FORCE_PUSH_WITH_LEASE: message, failed = remote_push(repo, true, &payload)
	case .SUBMODULE_UPDATE: message, failed = remote_submodules_update(repo, task, &payload)
	case .PUSH_TAGS: message, failed = remote_push_tags(repo, task.tag, task.tag_remote, &payload)
	}
	task.needs_passphrase = failed && remote_needs_passphrase(&payload)
	task.passphrase_rejected = failed && remote_passphrase_rejected(&payload)
	remote_finish(task, failed, message)
}

// libssh2 could not load the encrypted key last offered: in practice a wrong
// passphrase (its key-loading errors mention the private key or passphrase).
@(private)
remote_passphrase_rejected :: proc(payload: ^Remote_Payload) -> bool {
	if payload.last_key < 0 || !payload.encrypted[payload.last_key] do return false
	err := git.error_last()
	if err == nil || err.klass != git.ERROR_SSH do return false
	message := strings.to_lower(git.last_error_message(), context.temp_allocator)
	return strings.contains(message, "passphrase") || strings.contains(message, "private key")
}

@(private)
remote_needs_passphrase :: proc(payload: ^Remote_Payload) -> bool {
	return payload.locked_skipped && payload.passphrase == nil
}

@(private)
remote_key_name :: proc(payload: ^Remote_Payload, encrypted_only := false) -> string {
	if payload.last_key >= 0 && !encrypted_only do return filepath.base(string(payload.keys[payload.last_key]))
	for i in 0..<payload.key_count do if payload.encrypted[i] do return filepath.base(string(payload.keys[i]))
	return "your SSH key"
}

@(private)
remote_auth_hint :: proc(code: c.int, payload: ^Remote_Payload) -> string {
	if payload.unknown_host_len > 0 {
		host := string(payload.unknown_host_buf[:payload.unknown_host_len])
		if payload.host_revoked do return fmt.tprintf(" The SSH host key of %s is marked @revoked in known_hosts; nothing was sent.", host)
		where_ := payload.wsl ? "the Windows or WSL known_hosts" : "your known_hosts"
		return fmt.tprintf(" The SSH host key of %s is not in %s. Connect once with ssh -T git@%s to check and trust it, then try again.", host, where_, host)
	}
	// An HTTPS remote asks for a user name and password, never an SSH key.
	if payload.https_asked && payload.next_key == 0 && !payload.agent_tried {
		return " This remote uses HTTPS, which is not supported: switch it to SSH with git remote set-url origin git@<host>:<owner>/<repo>.git."
	}
	if remote_passphrase_rejected(payload) {
		return fmt.tprintf(" The passphrase did not unlock %s. Check it and try again.", remote_key_name(payload))
	}
	if remote_needs_passphrase(payload) {
		return fmt.tprintf(" %s is protected by a passphrase: enter it under SSH key passphrase and try again, or add the key to ssh-agent.", remote_key_name(payload, true))
	}
	// Every SSH credential was offered (or libgit2 reported an auth failure).
	if code == git.EAUTH || payload.agent_tried {
		if payload.wsl {
			// libssh2 reaches Pageant or the Windows OpenSSH agent only.
			return " No key was accepted (keys from Preferences and your WSL ~/.ssh were tried). An ssh-agent running inside WSL cannot be reached from Windows: add the key to the Windows ssh-agent or enter its passphrase under SSH key passphrase."
		}
		return " Check the SSH key location in Preferences (or ssh-agent); HTTPS remotes are not supported."
	}
	return ""
}

@(private)
remote_pull :: proc(repo: ^git.Repository, identity: ^git.Signature, rebase: bool, payload: ^Remote_Payload) -> (string, bool) {
	options: git.Fetch_Options
	if git.fetch_options_init(&options, git.FETCH_OPTIONS_VERSION) != git.OK do return git_error("Could not prepare the pull"), true
	remote_callbacks_set(&options.callbacks, payload)
	status, result := git.pull(repo, &options, rebase, identity)
	switch result {
	case git.OK:
	case git.ENONFASTFORWARD:
		return "Your branch and its upstream have diverged. Turn on Pull with rebase to replay your commits on top, or merge with Git.", true
	case git.ECONFLICT:
		return "Pull stopped: incoming changes would overwrite uncommitted or ignored files. Commit or stash them, then pull again.", true
	case git.EMERGECONFLICT:
		return "Pull with rebase stopped: one of your commits conflicts with the incoming changes. Nothing was changed; rebase in Git to resolve it.", true
	case:
		return fmt.tprintf("%s.%s", git_error("Pull failed"), remote_auth_hint(result, payload)), true
	}
	switch status {
	case .UP_TO_DATE: return "Already up to date.", false
	case .FAST_FORWARDED: return "Pulled: fast-forwarded to the upstream.", false
	case .REBASED: return "Pulled with rebase: your local commits now follow the upstream.", false
	case .FAILED:
	}
	return "Pull failed.", true
}

@(private)
remote_push :: proc(repo: ^git.Repository, force: bool, payload: ^Remote_Payload) -> (string, bool) {
	head: ^git.Reference
	if git.repository_head(&head, repo) != git.OK do return git_error("Could not read HEAD"), true
	defer git.reference_free(head)
	if git.reference_is_branch(head) == 0 do return "Check out a local branch to push (HEAD is detached).", true
	local := string(git.reference_name(head))
	short := string(git.reference_shorthand(head))
	remote_name, destination: string
	has_upstream := false
	remote_buf, merge_buf: git.Buffer
	defer git.buf_dispose(&remote_buf)
	defer git.buf_dispose(&merge_buf)
	if git.branch_upstream_remote(&remote_buf, repo, cstring_temp(local)) == git.OK && string(remote_buf.ptr) != "." &&
		git.branch_upstream_merge(&merge_buf, repo, cstring_temp(local)) == git.OK {
		remote_name = strings.clone(string(remote_buf.ptr), context.temp_allocator)
		destination = strings.clone(string(merge_buf.ptr), context.temp_allocator)
		has_upstream = true
	} else {
		// Like git push -u origin <branch>: publish under the same name.
		remote_name, destination = "origin", local
	}
	destination_short := strings.trim_prefix(destination, "refs/heads/")
	tracking := fmt.tprintf("refs/remotes/%s/%s", remote_name, destination_short)
	target := fmt.tprintf("%s/%s", remote_name, destination_short)
	if force {
		payload.use_lease = true
		payload.lease.refname = cstring_temp(destination)
		// No tracking ref means the branch must not exist on the remote yet.
		if git.reference_name_to_id(&payload.lease.expected, repo, cstring_temp(tracking)) != git.OK {
			payload.lease.expected = {}
		}
	}
	options: git.Push_Options
	if git.push_options_init(&options, git.PUSH_OPTIONS_VERSION) != git.OK do return git_error("Could not prepare the push"), true
	remote_callbacks_set(&options.callbacks, payload)
	options.callbacks.push_negotiation = remote_negotiation
	specs := [1]cstring{cstring_temp(fmt.tprintf("%s%s:%s", force ? "+" : "", local, destination))}
	result := git.push(repo, specs[:], cstring_temp(remote_name), &options)
	if result != git.OK {
		if payload.lease.rejected {
			return fmt.tprintf("Force push refused: %s changed since it was last fetched. Pull (or fetch) and review the new commits first; nothing was overwritten.", target), true
		}
		if result == git.ENONFASTFORWARD || strings.contains(git.last_error_message(), "fast") {
			return fmt.tprintf("%s has commits that %s does not. Pull first, or use Force push (lease) to replace them.", target, short), true
		}
		return fmt.tprintf("%s.%s", git_error("Push failed"), remote_auth_hint(result, payload)), true
	}
	if !has_upstream {
		// The push created the remote-tracking ref; failure to record it is not fatal.
		_ = git.branch_set_upstream(head, cstring_temp(target))
	}
	verb := force ? "Force-pushed (with lease)" : "Pushed"
	return fmt.tprintf("%s %s to %s.", verb, short, target), false
}

// Pushes refs/tags/<name>:refs/tags/<name> for one tag, or for every tag.
// A tag that already exists on the remote at another commit stops the push
// before anything is sent (checked during negotiation, like git push).
@(private)
remote_push_tags :: proc(repo: ^git.Repository, tag, remote_name: string, payload: ^Remote_Payload) -> (string, bool) {
	names := make([dynamic]string, context.temp_allocator)
	if tag != "" {
		append(&names, tag)
	} else {
		list: git.Strarray
		if git.tag_list(&list, repo) != git.OK do return git_error("Could not list tags"), true
		for i in 0..<int(list.count) do append(&names, strings.clone(string(list.strings[i]), context.temp_allocator))
		git.strarray_dispose(&list)
		if len(names) == 0 do return "There are no tags to push.", true
	}
	specs := make([dynamic]cstring, context.temp_allocator)
	for name in names do append(&specs, cstring_temp(fmt.tprintf("refs/tags/%s:refs/tags/%s", name, name)))
	options: git.Push_Options
	if git.push_options_init(&options, git.PUSH_OPTIONS_VERSION) != git.OK do return git_error("Could not prepare the push"), true
	remote_callbacks_set(&options.callbacks, payload)
	options.callbacks.push_negotiation = remote_negotiation
	payload.keep_tags = true
	result := git.push(repo, specs[:], cstring_temp(remote_name), &options)
	what := tag != "" ? fmt.tprintf("tag %s", tag) : fmt.tprintf("%d tag%s", len(names), len(names) == 1 ? "" : "s")
	if result != git.OK {
		message := git.last_error_message()
		if payload.tag_rejected || strings.contains(message, "already exists") {
			return fmt.tprintf("Could not push %s: a tag with the same name points elsewhere on %s. Rename or delete one of them.", what, remote_name), true
		}
		return fmt.tprintf("%s.%s", git_error(fmt.tprintf("Pushing %s failed", what)), remote_auth_hint(result, payload)), true
	}
	return fmt.tprintf("Pushed %s to %s.", what, remote_name), false
}
