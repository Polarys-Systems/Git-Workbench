package gpu

import "core:mem"
import vk "vendor:vulkan"

// Reusable, bounded staging storage. Source bytes are copied while staging;
// destinations must remain alive until completion or cancellation.
create_upload_batch :: proc(device: ^Device, capacity: vk.DeviceSize) -> (^Upload_Batch, Result) {
	if device == nil do return nil, .NO_DEVICE
	if capacity == 0 || capacity > vk.DeviceSize(max(int)) do return nil, .ERROR_INVALID_ARGUMENT
	batch, err := new(Upload_Batch, device.allocator)
	if err != nil do return nil, .NO_MEMORY
	batch.device = device
	result := create_buffer(device, {capacity, {.TRANSFER_SRC}, .UPLOAD}, &batch.staging)
	if result == .NONE do batch.command, result = create_command(device)
	if result !=
	   .NONE {destroy_buffer(device, &batch.staging); free(batch, device.allocator); return nil, result}
	device.live_objects += 1
	return batch, .NONE
}
poll_uploads :: proc(batch: ^Upload_Batch) -> Result {return(
		batch != nil ? poll_command(batch.command) : .ERROR_INVALID_ARGUMENT \
	)}
wait_uploads :: proc(batch: ^Upload_Batch) -> Result {return(
		batch != nil ? wait_command(batch.command) : .ERROR_INVALID_ARGUMENT \
	)}
begin_uploads :: proc(batch: ^Upload_Batch) -> Result {
	if batch == nil do return .ERROR_INVALID_ARGUMENT
	if batch.recording do return .ERROR_STATE
	result := poll_command(batch.command)
	if result == .NONE && batch.command.phase != .IDLE do result = .ERROR_STATE
	if result == .NONE {batch.recording, batch.used, batch.count = true, 0, 0}
	return result
}
@(private = "file")
staging_offset :: proc(
	batch: ^Upload_Batch,
	size: int,
	alignment: u32,
) -> (
	vk.DeviceSize,
	Result,
) {
	if !batch.recording do return 0, .ERROR_STATE
	if batch.count == MAX_UPLOADS do return 0, .CAPACITY
	align := vk.DeviceSize(alignment)
	padding := (align - batch.used % align) % align
	if batch.used > batch.staging.size || padding > batch.staging.size - batch.used || vk.DeviceSize(size) > batch.staging.size - batch.used - padding do return 0, .OUT_OF_RANGE
	return batch.used + padding, .NONE
}
upload_buffer :: proc(
	batch: ^Upload_Batch,
	buffer: ^Buffer,
	offset: vk.DeviceSize,
	data: []byte,
	consumer_stages: vk.PipelineStageFlags2,
	consumer_access: vk.AccessFlags2,
) -> Result {
	if batch == nil ||
	   buffer == nil ||
	   len(data) == 0 ||
	   consumer_stages == {} ||
	   buffer.owner != batch.device.device ||
	   buffer.buffer == 0 ||
	   buffer == &batch.staging ||
	   .TRANSFER_DST not_in buffer.usage {return .ERROR_INVALID_ARGUMENT}
	if offset > buffer.size || vk.DeviceSize(len(data)) > buffer.size - offset do return .OUT_OF_RANGE
	staging, result := staging_offset(batch, len(data), 4)
	if result == .NONE {
		mem.copy(
			mem.ptr_offset(([^]byte)(batch.staging.mapped), int(staging)),
			raw_data(data),
			len(data),
		)
		batch.records[batch.count] = {
			buffer         = buffer,
			staging_offset = staging,
			offset         = offset,
			size           = len(data),
			stages         = consumer_stages,
			access         = consumer_access,
		}
		batch.count += 1
		batch.used = staging + vk.DeviceSize(len(data))
	}
	return result
}
upload_texture :: proc(
	batch: ^Upload_Batch,
	texture: ^Texture,
	region: ^Texture_Upload,
	data: []byte,
) -> Result {
	if batch == nil || texture == nil || raw_data(data) == nil || texture.owner != batch.device.device || texture.image == 0 || texture.aspects != {.COLOR} || .TRANSFER_DST not_in texture.usage do return .ERROR_INVALID_ARGUMENT
	upload := Texture_Upload {
		final_layout    = .SHADER_READ_ONLY_OPTIMAL,
		consumer_stages = {.VERTEX_SHADER, .FRAGMENT_SHADER},
		consumer_access = {.SHADER_SAMPLED_READ},
	}
	if region != nil do upload = region^
	if upload.mip_level >= texture.mip_levels ||
	   upload.offset.x < 0 ||
	   upload.offset.y < 0 ||
	   upload.consumer_stages == {} ||
	   (upload.final_layout != .GENERAL && upload.final_layout != .SHADER_READ_ONLY_OPTIMAL) ||
	   (upload.final_layout == .SHADER_READ_ONLY_OPTIMAL &&
			   .SAMPLED not_in texture.usage) {return .ERROR_INVALID_ARGUMENT}
	width, height :=
		max(texture.extent.width >> upload.mip_level, 1),
		max(texture.extent.height >> upload.mip_level, 1)
	if upload.extent.width == 0 && upload.extent.height == 0 do upload.extent = {width, height}
	if u32(upload.offset.x) > width ||
	   upload.extent.width > width - u32(upload.offset.x) ||
	   u32(upload.offset.y) > height ||
	   upload.extent.height > height - u32(upload.offset.y) ||
	   upload.extent.width == 0 ||
	   upload.extent.height == 0 {return .OUT_OF_RANGE}
	bytes := format_bytes(texture.format)
	if bytes == 0 do return .UNSUPPORTED
	if u64(upload.extent.width) > u64(max(int)) / u64(bytes) ||
	   u64(upload.extent.height) > u64(max(int)) / (u64(upload.extent.width) * u64(bytes)) ||
	   u64(len(data)) !=
		   u64(upload.extent.width) *
			   u64(upload.extent.height) *
			   u64(bytes) {return .ERROR_INVALID_ARGUMENT}
	for record in batch.records[:batch.count] {if record.texture == texture && record.region.final_layout != upload.final_layout do return .ERROR_INVALID_ARGUMENT}
	staging, result := staging_offset(batch, len(data), max(bytes, 4))
	if result == .NONE {
		mem.copy(
			mem.ptr_offset(([^]byte)(batch.staging.mapped), int(staging)),
			raw_data(data),
			len(data),
		)
		batch.records[batch.count] = {
			texture        = texture,
			staging_offset = staging,
			size           = len(data),
			region         = upload,
			stages         = upload.consumer_stages,
			access         = upload.consumer_access,
		}
		batch.count += 1
		batch.used = staging + vk.DeviceSize(len(data))
	}
	return result
}
@(private = "file")
overlaps :: proc(a, b: ^Upload_Record) -> bool {
	if a.buffer != nil && a.buffer == b.buffer do return a.offset < b.offset + vk.DeviceSize(b.size) && b.offset < a.offset + vk.DeviceSize(a.size)
	if a.texture != nil && a.texture == b.texture && a.region.mip_level == b.region.mip_level {
		return(
			u32(a.region.offset.x) < u32(b.region.offset.x) + b.region.extent.width &&
			u32(b.region.offset.x) < u32(a.region.offset.x) + a.region.extent.width &&
			u32(a.region.offset.y) < u32(b.region.offset.y) + b.region.extent.height &&
			u32(b.region.offset.y) < u32(a.region.offset.y) + a.region.extent.height \
		)
	}
	return false
}
// Group barriers and submit asynchronously on the graphics queue. Wait/poll
// before reusing staging; rotate batches when polling returns BUSY.
submit_uploads :: proc(batch: ^Upload_Batch) -> Result {
	if batch == nil do return .ERROR_INVALID_ARGUMENT
	if !batch.recording || batch.count == 0 do return .ERROR_STATE
	command := batch.command
	result := begin_command(command)
	if result != .NONE do return result
	when GRAPHICS_BENCHMARK {
		if batch.profile_queries != 0 {
			vk.CmdResetQueryPool(command.command, batch.profile_queries, 0, 2)
			vk.CmdWriteTimestamp2(command.command, {.ALL_COMMANDS}, batch.profile_queries, 0)
		}
	}
	result = begin_gpu_timing(command, .UPLOAD_TOTAL)
	if result != .NONE do return result
	buffers, images := batch.buffer_barriers[:], batch.image_barriers[:]
	textures: [MAX_UPLOADS]^Texture
	final_layouts: [MAX_UPLOADS]vk.ImageLayout
	image_stages: [MAX_UPLOADS]vk.PipelineStageFlags2
	image_access: [MAX_UPLOADS]vk.AccessFlags2
	heads: [MAX_UPLOADS * 2]u32
	previous, image_index: [MAX_UPLOADS]u32
	buffer_count, image_count: u32
	for &record, i in batch.records[:batch.count] {
		key := uintptr(record.buffer != nil ? rawptr(record.buffer) : rawptr(record.texture))
		slot := u32((key >> 4) ~ (key >> 12)) % (MAX_UPLOADS * 2)
		// Only same-resource records need overlap checks: expected linear work.
		for {
			head := heads[slot]
			if head == 0 || (batch.records[head - 1].buffer == record.buffer && batch.records[head - 1].texture == record.texture) do break
			slot = (slot + 1) % (MAX_UPLOADS * 2)
		}
		previous[i], heads[slot] = heads[slot], u32(i + 1)
		if record.buffer != nil {
			buffers[buffer_count] = {
				sType               = .BUFFER_MEMORY_BARRIER_2,
				srcStageMask        = {.ALL_COMMANDS},
				srcAccessMask       = {.MEMORY_READ, .MEMORY_WRITE},
				dstStageMask        = {.TRANSFER},
				dstAccessMask       = {.TRANSFER_WRITE},
				srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
				dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
				buffer              = record.buffer.buffer,
				offset              = record.offset,
				size                = vk.DeviceSize(record.size),
			}
			buffer_count += 1
		} else {
			index := previous[i] != 0 ? image_index[previous[i] - 1] : image_count
			image_index[i] = index
			if index == image_count {
				texture := record.texture
				textures[index], final_layouts[index] = texture, record.region.final_layout
				images[index] = {
					sType               = .IMAGE_MEMORY_BARRIER_2,
					srcStageMask        = texture.layout == .UNDEFINED ? {} : {.ALL_COMMANDS},
					srcAccessMask       = texture.layout == .UNDEFINED ? {} : {.MEMORY_READ, .MEMORY_WRITE},
					dstStageMask        = {.TRANSFER},
					dstAccessMask       = {.TRANSFER_WRITE},
					oldLayout           = texture.layout,
					newLayout           = .TRANSFER_DST_OPTIMAL,
					srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
					dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
					image               = texture.image,
					subresourceRange    = {{.COLOR}, 0, texture.mip_levels, 0, 1},
				}
				image_count += 1
			}
			image_stages[index] |= record.stages
			image_access[index] |= record.access
		}
	}
	dependency := vk.DependencyInfo {
		sType                    = .DEPENDENCY_INFO,
		bufferMemoryBarrierCount = buffer_count,
		pBufferMemoryBarriers    = raw_data(buffers),
		imageMemoryBarrierCount  = image_count,
		pImageMemoryBarriers     = raw_data(images),
	}
	vk.CmdPipelineBarrier2(command.command, &dependency)
	batch.device.stats.upload_barrier_calls += 1
	result = begin_gpu_timing(command, .UPLOAD_COPIES)
	if result != .NONE do return result
	bytes: u64
	for &record, i in batch.records[:batch.count] {
		hazard := false
		for j := previous[i]; j != 0 && !hazard; j = previous[j - 1] do hazard = overlaps(&record, &batch.records[j - 1])
		if hazard {
			barrier := vk.MemoryBarrier2 {
				sType         = .MEMORY_BARRIER_2,
				srcStageMask  = {.TRANSFER},
				srcAccessMask = {.TRANSFER_WRITE},
				dstStageMask  = {.TRANSFER},
				dstAccessMask = {.TRANSFER_WRITE},
			}
			ordered := vk.DependencyInfo {
				sType              = .DEPENDENCY_INFO,
				memoryBarrierCount = 1,
				pMemoryBarriers    = &barrier,
			}
			vk.CmdPipelineBarrier2(command.command, &ordered)
			batch.device.stats.upload_barrier_calls += 1
		}
		if record.buffer != nil {
			copy := vk.BufferCopy{record.staging_offset, record.offset, vk.DeviceSize(record.size)}
			vk.CmdCopyBuffer(command.command, batch.staging.buffer, record.buffer.buffer, 1, &copy)
		} else {
			copy := vk.BufferImageCopy {
				bufferOffset     = record.staging_offset,
				imageSubresource = {{.COLOR}, record.region.mip_level, 0, 1},
				imageOffset      = {record.region.offset.x, record.region.offset.y, 0},
				imageExtent      = {record.region.extent.width, record.region.extent.height, 1},
			}
			vk.CmdCopyBufferToImage(
				command.command,
				batch.staging.buffer,
				record.texture.image,
				.TRANSFER_DST_OPTIMAL,
				1,
				&copy,
			)
		}
		bytes += u64(record.size)
	}
	result = end_gpu_timing(command, .UPLOAD_COPIES)
	if result != .NONE do return result
	buffer_index := 0
	for record in batch.records[:batch.count] {
		if record.buffer != nil {
			buffers[buffer_index].srcStageMask, buffers[buffer_index].srcAccessMask =
				{.TRANSFER}, {.TRANSFER_WRITE}
			buffers[buffer_index].dstStageMask, buffers[buffer_index].dstAccessMask =
				record.stages, record.access
			buffer_index += 1
		}
	}
	for i: u32 = 0; i < image_count; i += 1 {
		images[i].srcStageMask, images[i].srcAccessMask = {.TRANSFER}, {.TRANSFER_WRITE}
		images[i].dstStageMask, images[i].dstAccessMask = image_stages[i], image_access[i]
		images[i].oldLayout, images[i].newLayout = .TRANSFER_DST_OPTIMAL, final_layouts[i]
		result = track_image(command, textures[i], final_layouts[i])
		if result != .NONE do break
	}
	if result == .NONE {
		vk.CmdPipelineBarrier2(command.command, &dependency)
		batch.device.stats.upload_barrier_calls += 1
		when GRAPHICS_BENCHMARK {if batch.profile_queries != 0 do vk.CmdWriteTimestamp2(command.command, {.ALL_COMMANDS}, batch.profile_queries, 1)}
		result = end_gpu_timing(command, .UPLOAD_TOTAL)
		if result == .NONE do result = submit_command(command)
	}
	batch.recording = false
	if result ==
	   .NONE {batch.device.stats.upload_submissions += 1; batch.device.stats.uploaded_bytes += bytes}
	return result
}
cancel_uploads :: proc(batch: ^Upload_Batch) -> Result {
	if batch == nil do return .ERROR_INVALID_ARGUMENT
	result := cancel_command(batch.command)
	if result == .NONE do batch.recording, batch.used, batch.count = false, 0, 0
	return result
}
destroy_upload_batch :: proc(batch: ^^Upload_Batch) -> Result {
	if batch == nil do return .ERROR_INVALID_ARGUMENT
	if batch^ == nil do return .NONE
	result := destroy_command(&batch^.command)
	if result == .NONE || result == .DEVICE_LOST {
		device := batch^.device
		destroy_buffer(device, &batch^.staging)
		device.live_objects -= 1
		free(batch^, device.allocator)
		batch^ = nil
	}
	return result
}
upload_texture_wait :: proc(device: ^Device, texture: ^Texture, data: []byte) -> Result {
	batch, result := create_upload_batch(device, vk.DeviceSize(len(data)))
	if result == .NONE do result = begin_uploads(batch)
	if result == .NONE do result = upload_texture(batch, texture, nil, data)
	if result == .NONE do result = submit_uploads(batch)
	cleanup := destroy_upload_batch(&batch)
	return result != .NONE ? result : cleanup
}
