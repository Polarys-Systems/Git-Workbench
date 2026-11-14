package gpu

import "core:testing"

@(test)
gpu_timestamp_conversion_handles_period_and_wraparound :: proc(t: ^testing.T) {
	testing.expect(t, timestamp_elapsed_ms(100, 2100, 64, 2.5) == 0.005)
	// Only low timestampValidBits count; subtraction wraps in that domain.
	testing.expect(t, timestamp_elapsed_ms(0xffff_fff0, 0x10, 32, 1) == 0.000032)
	testing.expect(t, timestamp_elapsed_ms(~u64(0) - 15, 16, 64, 1) == 0.000032)
	testing.expect(t, timestamp_elapsed_ms(0x1234_fff0, 0x5678_0010, 16, 1) == 0.000032)
	// Absolute counters above f64's integer precision still give exact deltas.
	testing.expect(t, timestamp_elapsed_ms((u64(1) << 60) + 3, (u64(1) << 60) + 10, 64, 1) == 0.000007)
	testing.expect(t, timestamp_elapsed_ms(10, 10, 64, 1) == 0)
	testing.expect(t, timestamp_elapsed_ms(0, 10, 0, 1) == 0)
	testing.expect(t, timestamp_elapsed_ms(0, 10, 65, 1) == 0)
	testing.expect(t, timestamp_elapsed_ms(0, 10, 64, 0) == 0)
}

@(test)
gpu_timestamps_are_optional_and_validate_recording_state :: proc(t: ^testing.T) {
	testing.expect(t, !gpu_timestamps_supported(nil))
	device: Device
	testing.expect(t, !gpu_timestamps_supported(&device))
	device.enabled.gpu_timestamps = true
	device.timestamp_valid_bits = 36
	device.properties.limits.timestampPeriod = 1
	testing.expect(t, gpu_timestamps_supported(&device))
	device.timestamp_valid_bits = 0
	testing.expect(t, !gpu_timestamps_supported(&device))
	testing.expect(t, begin_gpu_timing(nil, .TEXT_DRAW) == .ERROR_INVALID_ARGUMENT)
	testing.expect(t, end_gpu_timing(nil, .TEXT_DRAW) == .ERROR_INVALID_ARGUMENT)
	command := Command{device = &device}
	testing.expect(t, begin_gpu_timing(&command, .TEXT_DRAW) == .ERROR_STATE)
	command.phase = .RECORDING
	testing.expect(t, begin_gpu_timing(&command, .TEXT_DRAW) == .NONE)
	testing.expect(t, end_gpu_timing(&command, .TEXT_DRAW) == .NONE)
	testing.expect(t, command.timing_used == {} && command.timing_open == {})
	testing.expect(t, begin_gpu_timing(&command, GPU_Timing_Section(99)) == .ERROR_INVALID_ARGUMENT)
}
