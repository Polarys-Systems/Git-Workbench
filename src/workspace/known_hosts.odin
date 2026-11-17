package workspace

import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/base64"
import "core:os"
import "core:strings"

// OpenSSH known_hosts lookups. libgit2 checks only the Windows
// %USERPROFILE%\.ssh\known_hosts; a repository inside WSL is usually used
// from WSL, where the hosts were trusted in the Linux ~/.ssh/known_hosts.

Known_Host_Result :: enum { UNKNOWN, MATCH, REVOKED }

// Whether known_hosts text lists key (an SSH wire-format public key) for
// host. Plain, [host]:port and hashed (|1|salt|hash) names are recognized;
// wildcard patterns are not. A matching @revoked line wins over any match.
known_hosts_check :: proc(text, host: string, key: []u8) -> Known_Host_Result {
	if host == "" || len(key) == 0 do return .UNKNOWN
	host_lower := strings.to_lower(host, context.temp_allocator)
	result := Known_Host_Result.UNKNOWN
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.fields(strings.trim_space(line), context.temp_allocator)
		if len(fields) == 0 || strings.has_prefix(fields[0], "#") do continue
		revoked := false
		if strings.has_prefix(fields[0], "@") {
			// @cert-authority lines hold CA keys, not host keys.
			if fields[0] != "@revoked" do continue
			revoked = true
			fields = fields[1:]
		}
		if len(fields) < 3 || !known_hosts_names_match(fields[0], host_lower) do continue
		blob, err := base64.decode(fields[2], allocator = context.temp_allocator)
		if err != nil || string(blob) != string(key) do continue
		if revoked do return .REVOKED
		result = .MATCH
	}
	return result
}

@(private)
known_hosts_names_match :: proc(names, host: string) -> bool {
	if strings.has_prefix(names, "|1|") do return known_hosts_hashed_match(names, host)
	matched := false
	for pattern in strings.split(names, ",", context.temp_allocator) {
		name := strings.to_lower(pattern, context.temp_allocator)
		negated := strings.has_prefix(name, "!")
		if negated do name = name[1:]
		// [host]:port; the certificate callback is not told the port.
		if strings.has_prefix(name, "[") {
			if end := strings.index(name, "]"); end > 0 do name = name[1:end]
		}
		if name != host do continue
		if negated do return false
		matched = true
	}
	return matched
}

// |1|base64(salt)|base64(HMAC-SHA1(salt, host)), as ssh-keygen -H writes.
@(private)
known_hosts_hashed_match :: proc(names, host: string) -> bool {
	parts := strings.split(names[3:], "|", context.temp_allocator)
	if len(parts) != 2 do return false
	salt, salt_err := base64.decode(parts[0], allocator = context.temp_allocator)
	expected, hash_err := base64.decode(parts[1], allocator = context.temp_allocator)
	if salt_err != nil || hash_err != nil || len(expected) != 20 do return false
	// Hosts on a non-standard port are hashed as [host]:port, which the
	// certificate callback cannot reconstruct; those stay unknown.
	digest: [20]u8
	hmac.sum(hash.Algorithm.Insecure_SHA1, digest[:], transmute([]u8)host, salt)
	return string(digest[:]) == string(expected)
}

// Checks every readable known_hosts file under the given .ssh folders.
known_hosts_check_files :: proc(ssh_dirs: []string, host: string, key: []u8) -> Known_Host_Result {
	result := Known_Host_Result.UNKNOWN
	for dir in ssh_dirs {
		for name in ([?]string{"known_hosts", "known_hosts2"}) {
			path := strings.concatenate({dir, `\`, name}, context.temp_allocator)
			data, err := os.read_entire_file(path, context.temp_allocator)
			if err != nil || len(data) > 16 << 20 do continue
			switch known_hosts_check(string(data), host, key) {
			case .REVOKED: return .REVOKED
			case .MATCH: result = .MATCH
			case .UNKNOWN:
			}
		}
	}
	return result
}
