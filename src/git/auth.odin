package git

// Credential callbacks for libgit2: username/password and SSH keys.

import "core:c"

// For HTTPS authentication; password may be a personal access token.
// Strings must remain valid until the synchronous fetch/push/pull returns.
// Use a separate instance per operation, or reset attempted before retrying.
Userpass_Auth :: struct {
	username, password: cstring,
	attempted: bool,
}

// Set Remote_Callbacks.credentials to this function and payload to ^Userpass_Auth.
// At most one password attempt is made, avoiding an infinite authentication
// loop on invalid credentials. This does not invoke Git Credential Manager.
userpass_credentials :: proc "c" (out: ^^Credential, url, username_from_url: cstring, allowed_types: c.uint, payload: rawptr) -> c.int {
	if payload == nil do return EAUTH
	auth := (^Userpass_Auth)(payload)
	if auth.username == nil || auth.password == nil do return EAUTH
	if allowed_types & CREDENTIAL_USERPASS_PLAINTEXT != 0 {
		if auth.attempted do return EAUTH
		auth.attempted = true
		return credential_userpass_plaintext_new(out, auth.username, auth.password)
	}
	if allowed_types & CREDENTIAL_USERNAME != 0 {
		return credential_username_new(out, auth.username)
	}
	return PASSTHROUGH
}

// SSH key-file authentication, including encrypted private keys. Supply the
// passphrase at runtime; nil/empty is suitable only for an unencrypted key.
// Use a fresh instance per operation. All strings must outlive the operation.
SSH_Key_Auth :: struct {
	username: cstring,
	private_key: cstring,
	public_key: cstring, // Optional with this build's OpenSSL/libssh2 backend.
	passphrase: cstring,
	attempted, username_attempted: bool,
}

// Assign to Remote_Callbacks.credentials, with ^SSH_Key_Auth as payload.
// This never prompts or logs secrets: the caller supplies a passphrase obtained
// from its CLI/UI. Bound the attempts so a wrong passphrase cannot loop forever.
ssh_key_credentials :: proc "c" (out: ^^Credential, url, username_from_url: cstring, allowed_types: c.uint, payload: rawptr) -> c.int {
	if out == nil || payload == nil do return EAUTH
	auth := (^SSH_Key_Auth)(payload)
	username := username_from_url
	if username == nil do username = auth.username
	if username == nil do return EAUTH
	if allowed_types & CREDENTIAL_SSH_KEY != 0 {
		if auth.attempted || auth.private_key == nil do return EAUTH
		auth.attempted = true
		return credential_ssh_key_new(out, username, auth.public_key, auth.private_key, auth.passphrase)
	}
	if allowed_types & CREDENTIAL_USERNAME != 0 {
		if auth.username_attempted do return EAUTH
		auth.username_attempted = true
		return credential_username_new(out, username)
	}
	return PASSTHROUGH
}
