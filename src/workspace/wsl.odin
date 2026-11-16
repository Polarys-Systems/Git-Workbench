package workspace

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

import git "../git"

// Windows Subsystem for Linux. Windows reaches a distribution's files through
// \\wsl.localhost\<distribution>\... (or the older \\wsl$\<distribution>\...).
// Those files belong to the Linux user, which Windows reports as another
// account, so libgit2's ownership check ("not owned by current user") rejects
// every repository there. These are the user's own files, and this app runs no
// hooks or configured programs (the risks that check guards against), so the
// check is relaxed for WSL repositories only. Git's global settings are never
// changed: the Git CLI still needs its own safe.directory entry.

WSL_PREFIXES :: [?]string{`\\wsl.localhost\`, `\\wsl$\`}

// The path with backslashes, and its WSL prefix length (0 if not a WSL path).
@(private)
wsl_split :: proc(path: string) -> (string, int) {
	normalized, _ := strings.replace_all(path, "/", `\`, context.temp_allocator)
	lower := strings.to_lower(normalized, context.temp_allocator)
	for prefix in WSL_PREFIXES do if strings.has_prefix(lower, prefix) do return normalized, len(prefix)
	return normalized, 0
}

is_wsl_path :: proc(path: string) -> bool {
	_, prefix := wsl_split(path)
	return prefix > 0
}

// The distribution a WSL path belongs to, e.g. "Ubuntu"; empty otherwise.
wsl_distribution :: proc(path: string) -> string {
	normalized, prefix := wsl_split(path)
	if prefix == 0 do return ""
	rest := normalized[prefix:]
	if end := strings.index_byte(rest, '\\'); end >= 0 do rest = rest[:end]
	return rest
}

// Maps a Linux path, as typed or pasted from a WSL terminal, to its Windows
// path: /mnt/c/... is the Windows drive C:, anything else lives inside a
// distribution. The first distribution (the default) where the path exists
// wins; if it exists in none, the default's path is returned so the error
// names it. Returns empty when no distribution is installed.
wsl_translate :: proc(path: string, distributions: []string) -> string {
	if !strings.has_prefix(path, "/") || strings.has_prefix(path, "//") do return ""
	parts := strings.split(strings.trim_right(path, "/"), "/", context.temp_allocator)
	// parts[0] is empty (the leading slash).
	if len(parts) >= 3 && parts[1] == "mnt" && len(parts[2]) == 1 && (parts[2][0] | 0x20) >= 'a' && (parts[2][0] | 0x20) <= 'z' {
		drive := strings.to_upper(parts[2], context.temp_allocator)
		rest := strings.join(parts[3:], `\`, context.temp_allocator)
		return fmt.tprintf(`%s:\%s`, drive, rest)
	}
	inside := strings.join(parts[1:], `\`, context.temp_allocator)
	for distribution in distributions {
		for prefix in WSL_PREFIXES {
			candidate := fmt.tprintf(`%s%s\%s`, prefix, distribution, inside)
			if os.exists(candidate) do return candidate
		}
	}
	if len(distributions) == 0 do return ""
	return fmt.tprintf(`%s%s\%s`, WSL_PREFIXES[0], distributions[0], inside)
}

@(private)
Ownership :: struct {
	mutex: sync.Mutex,
	relaxed: int, // Open WSL repositories and running WSL operations.
}

@(private)
ownership: Ownership

@(private)
apply_owner_validation :: proc(enabled: bool) {
	_ = git.libgit2_opts(git.OPT_SET_OWNER_VALIDATION, c.int(enabled ? 1 : 0))
}

owner_validation_enabled :: proc() -> bool {
	sync.mutex_lock(&ownership.mutex)
	defer sync.mutex_unlock(&ownership.mutex)
	value: c.int = 1
	_ = git.libgit2_opts(git.OPT_GET_OWNER_VALIDATION, &value)
	return value != 0
}

// While a WSL repository is open (or a background operation on one runs),
// libgit2 also opens repositories internally, e.g. submodules for their
// status. Keep the check relaxed for that time; pair with wsl_trust_end.
wsl_trust_begin :: proc() {
	sync.mutex_lock(&ownership.mutex)
	defer sync.mutex_unlock(&ownership.mutex)
	ownership.relaxed += 1
	apply_owner_validation(false)
}

wsl_trust_end :: proc() {
	sync.mutex_lock(&ownership.mutex)
	defer sync.mutex_unlock(&ownership.mutex)
	ownership.relaxed = max(0, ownership.relaxed - 1)
	apply_owner_validation(ownership.relaxed == 0)
}

// Every repository this app opens by path goes through here: WSL paths open
// without the ownership check, all others with it, even while a WSL
// repository is open.
open_repository :: proc(out: ^^git.Repository, path: string) -> c.int {
	sync.mutex_lock(&ownership.mutex)
	defer sync.mutex_unlock(&ownership.mutex)
	apply_owner_validation(!is_wsl_path(path))
	result := git.repository_open(out, cstring_temp(path))
	apply_owner_validation(ownership.relaxed == 0)
	return result
}

// What to do when a (non-WSL) repository belongs to another Windows user.
ownership_message :: proc(path: string) -> string {
	slashed, _ := strings.replace_all(path, `\`, "/", context.temp_allocator)
	return fmt.tprintf("Git does not trust this folder because it belongs to another Windows user. If it is yours, trust it with: git config --global --add safe.directory \"%s\"", slashed)
}
