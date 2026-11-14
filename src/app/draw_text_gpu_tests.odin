package app

import "core:mem"
import "core:sync"
import "core:testing"
import vk "vendor:vulkan"

import "../font"
import "../gpu"

// Opt in with -define:TEXT_GPU_TESTS=true. Requires Vulkan 1.3; validation can
// be disabled with -define:TEXT_GPU_VALIDATION=false when layers are unavailable.
when #config(TEXT_GPU_TESTS, false) {
	// The Vulkan binding stores device function pointers globally. Serialize
	// device lifetimes even when the CPU test runner uses multiple threads.
	text_gpu_test_mutex: sync.Mutex

	@(test)
	text_prepare_uploads_rectangles_and_vertices :: proc(t: ^testing.T) {
		sync.mutex_lock(&text_gpu_test_mutex)
		defer sync.mutex_unlock(&text_gpu_test_mutex)
		face, loaded := text_test_face(t)
		if !loaded do return
		defer font.face_destroy(&face)
		validation := #config(TEXT_GPU_VALIDATION, true)
		device, result := gpu.init({validation = validation, synchronization_validation = validation})
		testing.expect(t, result == .NONE)
		if result != .NONE do return
		defer {
			shutdown_result := gpu.shutdown(&device)
			testing.expect(t, shutdown_result == .NONE)
		}
		batch := text_test_batch(512, 512)
		defer {
			destroy_result := destroy_text_batch(device, &batch)
			testing.expect(t, destroy_result == .NONE)
		}
		result = gpu.create_buffer(
			device, {MAX_TEXT_VERTEX_BYTES, {.STORAGE_BUFFER, .TRANSFER_DST, .TRANSFER_SRC}, .DEVICE}, &batch.vertex_buffer,
		)
		testing.expect(t, result == .NONE)
		if result != .NONE do return
		result = gpu.create_texture(device, {
			width = 512, height = 512, format = .R8_UNORM,
			usage = {.SAMPLED, .TRANSFER_DST, .TRANSFER_SRC},
		}, &batch.atlas_texture)
		testing.expect(t, result == .NONE)
		if result != .NONE do return
		batch.upload_batch, result = gpu.create_upload_batch(device, MAX_TEXT_VERTEX_BYTES + 512 * 512 + 4 * gpu.MAX_UPLOADS)
		testing.expect(t, result == .NONE)
		if result != .NONE do return

		// More than one bounded upload batch must be submitted without dropping
		// rectangles. Two sizes of printable ASCII produce over 128 glyphs.
		sizes := [?]u32{8 * 64, 10 * 64}
		for size in sizes {
			for r := rune('!'); r <= rune('~'); r += 1 {
				idx, found := font.glyph_index(&face, r)
				if !found do continue
				_, cached := get_or_cache_glyph(&batch, &face, size, idx)
				testing.expect(t, cached)
			}
		}
		testing.expect(t, draw_text(&batch, &face, "AB", {}, {1, 1, 1, 1}, 16))
		data_size, upload_count, vertex_count := len(batch.pending_pixels), len(batch.pending_glyph_uploads), len(batch.vertices)
		testing.expect(t, upload_count > gpu.MAX_UPLOADS)

		// An upload error must preserve both queues and cancel recording so the
		// same batch can be retried rather than leaving false successful hits.
		batch.atlas_texture.usage -= {.TRANSFER_DST}
		testing.expect(t, text_prepare_render(&batch) == gpu.Result.ERROR_INVALID_ARGUMENT)
		testing.expect(t, len(batch.pending_pixels) == data_size && len(batch.pending_glyph_uploads) == upload_count)
		testing.expect(t, len(batch.vertices) == vertex_count && batch.prepared_vertex_count == 0)
		batch.atlas_texture.usage += {.TRANSFER_DST}

		expected_data := make([]byte, data_size)
		defer delete(expected_data)
		copy(expected_data, batch.pending_pixels[:])
		expected_uploads := make([]Pending_Glyph_Upload, upload_count)
		defer delete(expected_uploads)
		copy(expected_uploads, batch.pending_glyph_uploads[:])
		expected_vertices := make([]byte, len(batch.vertices) * size_of(Text_Vertex))
		defer delete(expected_vertices)
		copy(expected_vertices, mem.slice_to_bytes(batch.vertices[:]))
		result = text_prepare_render(&batch)
		testing.expect(t, result == .NONE)
		if result != .NONE do return
		testing.expect(t, batch.prepared_vertex_count == u32(vertex_count))
		testing.expect(t, len(batch.pending_pixels) == 0 && len(batch.pending_glyph_uploads) == 0 && len(batch.vertices) == 0)
		testing.expect(t, gpu.stats(device).upload_submissions == 2)
		testing.expect(t, gpu.stats(device).uploaded_bytes == u64(len(expected_data) + len(expected_vertices)))

		// Read back actual GPU contents, not just staging records.
		readback: gpu.Buffer
		result = gpu.create_buffer(device, {
			size = vk.DeviceSize(len(expected_vertices) + 512 * 512),
			usage = {.TRANSFER_DST}, memory = .READBACK,
		}, &readback)
		testing.expect(t, result == .NONE)
		if result != .NONE do return
		defer gpu.destroy_buffer(device, &readback)
		command, command_result := gpu.create_command(device)
		testing.expect(t, command_result == .NONE)
		if command_result != .NONE do return
		defer gpu.destroy_command(&command)
		result = gpu.begin_command(command)
		if result == .NONE do result = gpu.copy_buffer(command, &batch.vertex_buffer, 0, &readback, 0, vk.DeviceSize(len(expected_vertices)))
		if result == .NONE do result = gpu.transition_texture(command, &batch.atlas_texture, .TRANSFER_SRC_OPTIMAL, {.TRANSFER}, {.TRANSFER_READ})
		testing.expect(t, result == .NONE)
		if result != .NONE do return
		region := vk.BufferImageCopy{
			bufferOffset = vk.DeviceSize(len(expected_vertices)),
			imageSubresource = {{.COLOR}, 0, 0, 1},
			imageExtent = {512, 512, 1},
		}
		vk.CmdCopyImageToBuffer(gpu.native_command(command), batch.atlas_texture.image, .TRANSFER_SRC_OPTIMAL, readback.buffer, 1, &region)
		barrier := vk.BufferMemoryBarrier2{
			sType = .BUFFER_MEMORY_BARRIER_2,
			srcStageMask = {.TRANSFER}, srcAccessMask = {.TRANSFER_WRITE},
			dstStageMask = {.HOST}, dstAccessMask = {.HOST_READ},
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			buffer = readback.buffer, size = readback.size,
		}
		dependency := vk.DependencyInfo{
			sType = .DEPENDENCY_INFO, bufferMemoryBarrierCount = 1, pBufferMemoryBarriers = &barrier,
		}
		vk.CmdPipelineBarrier2(gpu.native_command(command), &dependency)
		result = gpu.transition_texture(command, &batch.atlas_texture, .SHADER_READ_ONLY_OPTIMAL, {.FRAGMENT_SHADER}, {.SHADER_SAMPLED_READ})
		if result == .NONE do result = gpu.submit_command(command)
		if result == .NONE do result = gpu.wait_command(command)
		testing.expect(t, result == .NONE)
		if result != .NONE do return
		mapped := ([^]byte)(readback.mapped)[:int(readback.size)]
		for value, i in expected_vertices do testing.expect(t, mapped[i] == value)
		for upload in expected_uploads {
			width, height := int(upload.rect.extent.width), int(upload.rect.extent.height)
			for y in 0..<height {
				for x in 0..<width {
					src := upload.data_offset + y * width + x
					dst := len(expected_vertices) + (int(upload.rect.offset.y) + y) * 512 + int(upload.rect.offset.x) + x
					testing.expect(t, mapped[dst] == expected_data[src])
				}
			}
		}

		// Cache hits on the next frame upload vertices only.
		testing.expect(t, draw_text(&batch, &face, "AB", {}, {1, 1, 1, 1}, 16))
		testing.expect(t, len(batch.pending_glyph_uploads) == 0 && len(batch.pending_pixels) == 0)
		result = text_prepare_render(&batch)
		testing.expect(t, result == .NONE && batch.prepared_vertex_count == 12)
		testing.expect(t, gpu.stats(device).upload_submissions == 3)
		testing.expect(t, gpu.wait_uploads(batch.upload_batch) == gpu.Result.NONE)
		testing.expect(t, gpu.stats(device).validation_errors == 0)
	}
}
