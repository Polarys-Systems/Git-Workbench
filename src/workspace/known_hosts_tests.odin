package workspace

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:testing"

// github.com's published ed25519 host key, and the same line hashed by ssh-keygen -H.
@(private = "file")
GITHUB_KEY :: "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
@(private = "file")
GITHUB_HASHED :: "|1|Z2Cl9QpW7PvqlrRmnJhQl8RM+tI=|eyCITuBzO+YrGfEhUgkksNsBZG0= ssh-ed25519 " + GITHUB_KEY

@(test)
known_hosts_match_plain_bracketed_and_hashed_names :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	key, _ := base64.decode(GITHUB_KEY, allocator = context.temp_allocator)
	other := key[:len(key) - 1]
	PLAIN :: "# comment\n\ngitlab.com ssh-ed25519 AAAA\ngithub.com,140.82.121.4 ssh-ed25519 " + GITHUB_KEY + " comment\n"
	testing.expect(t, known_hosts_check(PLAIN, "github.com", key) == .MATCH)
	testing.expect(t, known_hosts_check(PLAIN, "GitHub.com", key) == .MATCH)
	testing.expect(t, known_hosts_check(PLAIN, "140.82.121.4", key) == .MATCH)
	testing.expect(t, known_hosts_check(PLAIN, "gitlab.com", key) == .UNKNOWN)
	testing.expect(t, known_hosts_check(PLAIN, "github.com", other) == .UNKNOWN)
	testing.expect(t, known_hosts_check("[github.com]:2222 ssh-ed25519 " + GITHUB_KEY, "github.com", key) == .MATCH)
	testing.expect(t, known_hosts_check(GITHUB_HASHED, "github.com", key) == .MATCH)
	testing.expect(t, known_hosts_check(GITHUB_HASHED, "gitlab.com", key) == .UNKNOWN)
	// Negated names, CA keys and revocations.
	testing.expect(t, known_hosts_check("*.com,!github.com,github.com ssh-ed25519 " + GITHUB_KEY, "github.com", key) == .UNKNOWN)
	testing.expect(t, known_hosts_check("@cert-authority github.com ssh-ed25519 " + GITHUB_KEY, "github.com", key) == .UNKNOWN)
	REVOKED :: PLAIN + "@revoked * ssh-ed25519 " + GITHUB_KEY + "\n@revoked github.com ssh-ed25519 " + GITHUB_KEY + "\n"
	testing.expect(t, known_hosts_check(REVOKED, "github.com", key) == .REVOKED)
	testing.expect(t, known_hosts_check("garbage\n|1|bad|bad ssh-ed25519 " + GITHUB_KEY, "github.com", key) == .UNKNOWN)
}

@(test)
known_hosts_files_are_read_from_each_ssh_folder :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	key, _ := base64.decode(GITHUB_KEY, allocator = context.temp_allocator)
	empty := fmt.tprintf(`%s\empty`, root)
	trusted := fmt.tprintf(`%s\trusted`, root)
	testing.expect(t, os.make_directory_all(empty) == nil && os.make_directory_all(trusted) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf(`%s\known_hosts`, trusted), transmute([]u8)string(GITHUB_HASHED)) == nil)
	testing.expect(t, known_hosts_check_files({empty}, "github.com", key) == .UNKNOWN)
	testing.expect(t, known_hosts_check_files({empty, trusted}, "github.com", key) == .MATCH)
	// Outside WSL there are no Linux .ssh folders to consult.
	testing.expect(t, len(wsl_ssh_dirs(`C:\devel\project`)) == 0)
	testing.expect(t, len(wsl_ssh_dirs(`\\wsl.localhost\NoSuchDistribution-workbench\home\ada\project`)) == 0)
}
