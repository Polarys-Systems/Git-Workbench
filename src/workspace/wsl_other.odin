#+build !windows
package workspace

// WSL exists only on Windows.
wsl_distributions :: proc() -> [dynamic]string {
	return make([dynamic]string, context.temp_allocator)
}
