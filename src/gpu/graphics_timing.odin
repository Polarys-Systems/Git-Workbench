package gpu

import vk "vendor:vulkan"

@(private = "package")
GPU_TIMING_QUERY_COUNT :: 2 * len(GPU_Timing_Section)

gpu_timestamps_supported :: proc(device: ^Device) -> bool {
	return device != nil && device.enabled.gpu_timestamps &&
	       device.timestamp_valid_bits > 0 && device.timestamp_valid_bits <= 64 &&
	       device.properties.limits.timestampPeriod > 0
}

// Pools belong to individual commands, so in-flight frames never reset each
// other's queries. Reset all slots outside rendering, after the previous fence.
@(private = "package")
reset_gpu_timings :: proc(command: ^Command) {
	command.timing_used, command.timing_open = {}, {}
	if command.timing_queries != 0 {
		vk.CmdResetQueryPool(command.command, command.timing_queries, 0, GPU_TIMING_QUERY_COUNT)
	}
}

// TOP/BOTTOM timestamps bracket GPU execution, including dependencies and
// barriers in the interval. They do not measure an isolated command's cost:
// pipeline stages can overlap, and instrumentation itself has some overhead.
// Timings are optional no-ops on devices without enabled/supported timestamps.
begin_gpu_timing :: proc(command: ^Command, section: GPU_Timing_Section) -> Result {
	if command == nil || section < .FRAME || section > .UPLOAD_COPIES do return .ERROR_INVALID_ARGUMENT
	if !command_recording(command) do return .ERROR_STATE
	if command.timing_queries == 0 do return .NONE
	if section in command.timing_used do return .ERROR_STATE
	vk.CmdWriteTimestamp2(command.command, {.TOP_OF_PIPE}, command.timing_queries, 2 * u32(section))
	command.timing_used += {section}
	command.timing_open += {section}
	return .NONE
}

end_gpu_timing :: proc(command: ^Command, section: GPU_Timing_Section) -> Result {
	if command == nil || section < .FRAME || section > .UPLOAD_COPIES do return .ERROR_INVALID_ARGUMENT
	if !command_recording(command) do return .ERROR_STATE
	if command.timing_queries == 0 do return .NONE
	if section not_in command.timing_open do return .ERROR_STATE
	vk.CmdWriteTimestamp2(command.command, {.BOTTOM_OF_PIPE}, command.timing_queries, 2 * u32(section) + 1)
	command.timing_open -= {section}
	return .NONE
}

@(private = "package")
timestamp_elapsed_ms :: proc(start, end: u64, valid_bits: u32, period_ns: f64) -> f64 {
	if valid_bits == 0 || valid_bits > 64 || period_ns <= 0 do return 0
	mask := ~u64(0)
	if valid_bits < 64 do mask = (u64(1) << valid_bits) - 1
	// Subtract integers before conversion (large absolute counters lose f64
	// precision); mask the difference to handle the queue's timestamp wraparound.
	ticks := (end - start) & mask
	return f64(ticks) * period_ns / 1_000_000.0
}

// Only called after the submission's fence signals. No WAIT_BIT or device-idle
// wait is added for profiling. Read before resetting/reusing this command.
@(private = "package")
collect_gpu_timings :: proc(command: ^Command) -> Result {
	if command.timing_queries == 0 || command.timing_used == {} do return .NONE
	elapsed: [GPU_Timing_Section]f64
	for section in command.timing_used {
		ticks: [2]u64
		queried := vk.GetQueryPoolResults(
			command.device.device, command.timing_queries, 2 * u32(section), 2,
			size_of(ticks), &ticks, size_of(u64), {._64},
		)
		if queried == .NOT_READY do return .BUSY
		result := vk_result(command.device, queried, .ERROR_RESOURCE)
		if result != .NONE do return result
		elapsed[section] = timestamp_elapsed_ms(
			ticks[0], ticks[1], command.device.timestamp_valid_bits,
			f64(command.device.properties.limits.timestampPeriod),
		)
	}
	for section in command.timing_used {
		timing := &command.device.stats.gpu_timings[section]
		timing.milliseconds = elapsed[section]
		timing.total_milliseconds += elapsed[section]
		timing.samples += 1
	}
	command.timing_used = {}
	return .NONE
}
