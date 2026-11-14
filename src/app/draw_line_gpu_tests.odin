package app

import "core:testing"
import "core:sync"
import vk "vendor:vulkan"

import "../gpu"

// Opt in with the existing -define:TEXT_GPU_TESTS=true rendering checks.
when #config(TEXT_GPU_TESTS, false) {
	@(test)
	line_shader_renders_antialiased_caps_and_nodes_in_one_draw :: proc(t: ^testing.T) {
		sync.mutex_lock(&text_gpu_test_mutex)
		defer sync.mutex_unlock(&text_gpu_test_mutex)
		validation := #config(TEXT_GPU_VALIDATION, true)
		device, result := gpu.init({validation = validation, synchronization_validation = validation, buffer_device_address = true})
		if !testing.expect(t, result == .NONE) do return
		defer testing.expect(t, gpu.shutdown(&device) == gpu.Result.NONE)
		batch := init_text_batch(device, .R8G8B8A8_UNORM)
		defer testing.expect(t, destroy_text_batch(device, &batch) == gpu.Result.NONE)
		target: gpu.Texture
		if !testing.expect(t, gpu.create_texture(device, {
			width = 64, height = 64, format = .R8G8B8A8_UNORM,
			usage = {.COLOR_ATTACHMENT, .TRANSFER_SRC},
		}, &target) == gpu.Result.NONE) {
			return
		}
		defer gpu.destroy_texture(device, &target)
		readback: gpu.Buffer
		if !testing.expect(t, gpu.create_buffer(device, {
			size = 64 * 64 * 4, usage = {.TRANSFER_DST}, memory = .READBACK,
		}, &readback) == gpu.Result.NONE) {
			return
		}
		defer gpu.destroy_buffer(device, &readback)
		command, command_result := gpu.create_command(device)
		if !testing.expect(t, command_result == .NONE) do return
		defer gpu.destroy_command(&command)

		// Mix an atlas-backed rectangle with analytic lines in the same batch.
		testing.expect(t, draw_rect(&batch, {0, 0, 2, 2}, {1, 1, 1, 1}, {1, 1, 1, 1}))
		testing.expect(t, draw_line(&batch, {8, 8}, {48, 40}, 4, {1, 1, 1, 1}))
		testing.expect(t, draw_line(&batch, {52, 12}, {52, 12}, 8, {1, 0, 0, 1}))
		batch.clip_enabled = true
		batch.clip_min, batch.clip_max = {20, 48}, {42, 60}
		testing.expect(t, draw_line(&batch, {8, 54}, {56, 54}, 4, {1, 1, 1, 1}))
		if !testing.expect(t, text_prepare_render(&batch) == gpu.Result.NONE) do return
		testing.expect(t, batch.prepared_vertex_count == 24)
		if !testing.expect(t, gpu.begin_command(command) == gpu.Result.NONE) do return
		if !testing.expect(t, gpu.begin_render(command, {
			area = {extent = {64, 64}}, colors = []gpu.Attachment{{texture = &target, load = .CLEAR, store = .STORE}},
		}) == gpu.Result.NONE) {
			return
		}
		if !testing.expect(t, text_render(&batch, command, {64, 64}) == gpu.Result.NONE) do return
		if !testing.expect(t, gpu.end_render(command) == gpu.Result.NONE) do return
		if !testing.expect(t, gpu.transition_texture(command, &target, .TRANSFER_SRC_OPTIMAL, {.TRANSFER}, {.TRANSFER_READ}) == gpu.Result.NONE) do return
		region := vk.BufferImageCopy{imageSubresource = {{.COLOR}, 0, 0, 1}, imageExtent = {64, 64, 1}}
		vk.CmdCopyImageToBuffer(gpu.native_command(command), target.image, .TRANSFER_SRC_OPTIMAL, readback.buffer, 1, &region)
		barrier := vk.BufferMemoryBarrier2{
			sType = .BUFFER_MEMORY_BARRIER_2,
			srcStageMask = {.TRANSFER}, srcAccessMask = {.TRANSFER_WRITE},
			dstStageMask = {.HOST}, dstAccessMask = {.HOST_READ},
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED, dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			buffer = readback.buffer, size = readback.size,
		}
		dependency := vk.DependencyInfo{sType = .DEPENDENCY_INFO, bufferMemoryBarrierCount = 1, pBufferMemoryBarriers = &barrier}
		vk.CmdPipelineBarrier2(gpu.native_command(command), &dependency)
		if !testing.expect(t, gpu.submit_command(command) == gpu.Result.NONE) do return
		if !testing.expect(t, gpu.wait_command(command) == gpu.Result.NONE) do return
		pixels := ([^][4]u8)(readback.mapped)[:64 * 64]
		testing.expect(t, pixels[24 * 64 + 28].a == 255 && pixels[14 * 64 + 28].a == 0)
		testing.expect(t, pixels[12 * 64 + 52] == [4]u8{255, 0, 0, 255})
		testing.expect(t, pixels[8 * 64 + 48].a == 0)
		testing.expect(t, pixels[54 * 64 + 20].a == 255 && pixels[54 * 64 + 41].a == 255)
		testing.expect(t, pixels[54 * 64 + 19].a == 0 && pixels[54 * 64 + 42].a == 0)
		partial := 0
		for pixel in pixels do if pixel.a > 0 && pixel.a < 255 do partial += 1
		testing.expect(t, partial > 20)
		testing.expect(t, gpu.stats(device).draw_calls == 1 && gpu.stats(device).validation_errors == 0)
	}
}
