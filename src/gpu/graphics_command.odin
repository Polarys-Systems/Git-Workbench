package gpu

import "core:math"
import vk "vendor:vulkan"

@(private = "package")
command_recording :: proc(command: ^Command) -> bool {return(
		command != nil &&
		(command.phase == .RECORDING || command.phase == .RENDERING) \
	)}
// Independent contexts are reusable after completion or cancellation.
create_command :: proc(device: ^Device) -> (^Command, Result) {
	if device == nil do return nil, .NO_DEVICE
	command, err := new(Command, device.allocator)
	if err != nil do return nil, .NO_MEMORY
	command.device = device
	pool := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.TRANSIENT},
		queueFamilyIndex = device.queue_family,
	}
	result := vk_result(
		device,
		vk.CreateCommandPool(device.device, &pool, nil, &command.pool),
		.NO_COMMAND_BUFFER,
	)
	if result == .NONE {
		info := vk.CommandBufferAllocateInfo {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = command.pool,
			level              = .PRIMARY,
			commandBufferCount = 1,
		}
		result = vk_result(
			device,
			vk.AllocateCommandBuffers(device.device, &info, &command.command),
			.NO_COMMAND_BUFFER,
		)
	}
	if result == .NONE {
		info := vk.FenceCreateInfo {
			sType = .FENCE_CREATE_INFO,
		}
		result = vk_result(
			device,
			vk.CreateFence(device.device, &info, nil, &command.fence),
			.ERROR_FENCE,
		)
	}
	if result == .NONE && gpu_timestamps_supported(device) {
		info := vk.QueryPoolCreateInfo {
			sType = .QUERY_POOL_CREATE_INFO,
			queryType = .TIMESTAMP,
			queryCount = GPU_TIMING_QUERY_COUNT,
		}
		result = vk_result(device, vk.CreateQueryPool(device.device, &info, nil, &command.timing_queries), .ERROR_RESOURCE)
	}
	if result != .NONE {
		vk.DestroyQueryPool(device.device, command.timing_queries, nil)
		vk.DestroyFence(device.device, command.fence, nil)
		vk.DestroyCommandPool(device.device, command.pool, nil)
		free(command, device.allocator)
		return nil, result
	}
	device.live_objects += 1
	return command, .NONE
}
poll_command :: proc(command: ^Command) -> Result {
	if command == nil do return .ERROR_INVALID_ARGUMENT
	if command.device.lost do return .DEVICE_LOST
	if command.phase != .PENDING do return .NONE
	result := vk.GetFenceStatus(command.device.device, command.fence)
	if result == .NOT_READY do return .BUSY
	if result == .SUCCESS {
		timing_result := collect_gpu_timings(command)
		if timing_result != .NONE do return timing_result
		command.phase = .IDLE
	}
	return vk_result(command.device, result, .ERROR_FENCE)
}
wait_command :: proc(command: ^Command) -> Result {
	if command == nil do return .ERROR_INVALID_ARGUMENT
	if command.device.lost do return .DEVICE_LOST
	if command.phase != .PENDING do return .NONE
	result := vk_result(
		command.device,
		vk.WaitForFences(command.device.device, 1, &command.fence, true, ~u64(0)),
		.ERROR_FENCE,
	)
	if result == .NONE do result = collect_gpu_timings(command)
	if result == .NONE do command.phase = .IDLE
	return result
}
// Call after native pipeline/descriptor/index/dynamic-state changes; rebind and
// set state before further draws. Native callers must preserve rendering scopes.
invalidate_state :: proc(command: ^Command) {
	if command != nil {
		command.state_valid, command.pipeline, command.sets, command.index_bytes, command.index_stride =
			false, nil, {}, 0, 0
	}
}
@(private = "package")
command_reset :: proc(command: ^Command) -> Result {
	if command == nil do return .ERROR_INVALID_ARGUMENT
	if command.phase == .PENDING do return .BUSY
	result := vk_result(
		command.device,
		vk.ResetCommandPool(command.device.device, command.pool, {}),
		.NO_COMMAND_BUFFER,
	)
	command.phase = result == .NONE ? .IDLE : .FAILED
	command.image_count = 0
	command.timing_used, command.timing_open = {}, {}
	invalidate_state(command)
	return result
}
cancel_command :: proc(command: ^Command) -> Result {
	if command == nil || command.frame_owned do return .ERROR_INVALID_ARGUMENT
	return command_reset(command)
}
@(private = "package")
command_begin :: proc(command: ^Command) -> Result {
	if command == nil do return .ERROR_INVALID_ARGUMENT
	if command.device.lost do return .DEVICE_LOST
	result := poll_command(command)
	if result != .NONE do return result
	if command.phase != .IDLE do return .ERROR_STATE
	result = command_reset(command)
	if result == .NONE {
		info := vk.CommandBufferBeginInfo {
			sType = .COMMAND_BUFFER_BEGIN_INFO,
			flags = {.ONE_TIME_SUBMIT},
		}
		result = vk_result(
			command.device,
			vk.BeginCommandBuffer(command.command, &info),
			.NO_COMMAND_BUFFER,
		)
		when GRAPHICS_TESTING {if result == .NONE && test_failure(.BEGIN) do result = .NO_COMMAND_BUFFER}
		command.phase = result == .NONE ? .RECORDING : .FAILED
		if result == .NONE {
			reset_gpu_timings(command)
			if command.frame_owned do result = begin_gpu_timing(command, .FRAME)
		}
	}
	return result
}
begin_command :: proc(command: ^Command) -> Result {
	if command == nil || command.frame_owned do return .ERROR_INVALID_ARGUMENT
	return command_begin(command)
}
@(private = "package")
command_submit :: proc(command: ^Command, wait, signal: vk.Semaphore) -> Result {
	if command == nil do return .ERROR_INVALID_ARGUMENT
	if command.phase != .RECORDING do return .ERROR_STATE
	// FRAME covers the whole swapchain command, including its final transition
	// to PRESENT_SRC. Other sections must have been closed by their callers.
	if command.timing_open - {.FRAME} != {} do return .ERROR_STATE
	if .FRAME in command.timing_open {
		result := end_gpu_timing(command, .FRAME)
		if result != .NONE do return result
	}
	device := command.device
	result := vk_result(device, vk.EndCommandBuffer(command.command), .NO_COMMAND_BUFFER)
	if result == .NONE do result = vk_result(device, vk.ResetFences(device.device, 1, &command.fence), .ERROR_FENCE)
	if result == .NONE {
		wait_info := vk.SemaphoreSubmitInfo {
			sType     = .SEMAPHORE_SUBMIT_INFO,
			semaphore = wait,
			stageMask = {.ALL_COMMANDS},
		}
		signal_info := vk.SemaphoreSubmitInfo {
			sType     = .SEMAPHORE_SUBMIT_INFO,
			semaphore = signal,
			stageMask = {.ALL_COMMANDS},
		}
		buffer := vk.CommandBufferSubmitInfo {
			sType         = .COMMAND_BUFFER_SUBMIT_INFO,
			commandBuffer = command.command,
		}
		info := vk.SubmitInfo2 {
			sType                    = .SUBMIT_INFO_2,
			commandBufferInfoCount   = 1,
			pCommandBufferInfos      = &buffer,
			waitSemaphoreInfoCount   = wait != 0 ? 1 : 0,
			pWaitSemaphoreInfos      = &wait_info,
			signalSemaphoreInfoCount = signal != 0 ? 1 : 0,
			pSignalSemaphoreInfos    = &signal_info,
		}
		submitted: vk.Result
		when GRAPHICS_TESTING {submitted =
				test_failure(.SUBMIT) ? .ERROR_UNKNOWN : vk.QueueSubmit2(device.queue, 1, &info, command.fence)
		} else {submitted = vk.QueueSubmit2(device.queue, 1, &info, command.fence)}
		result = vk_result(device, submitted, .ERROR_QUEUE_SUBMIT)
	}
	command.phase = result == .NONE ? .PENDING : .FAILED
	if result ==
	   .NONE {for image in command.images[:command.image_count] do image.texture.layout = image.layout}
	return result
}
// Asynchronous submission. Rendering must be closed; layouts commit on success.
submit_command :: proc(command: ^Command) -> Result {
	if command == nil || command.frame_owned do return .ERROR_INVALID_ARGUMENT
	return command_submit(command, 0, 0)
}
destroy_command :: proc(command: ^^Command) -> Result {
	if command == nil do return .ERROR_INVALID_ARGUMENT
	if command^ == nil do return .NONE
	if command^.frame_owned do return .ERROR_STATE
	result := wait_command(command^)
	if result == .NONE || result == .DEVICE_LOST {
		device := command^.device
		vk.DestroyCommandPool(device.device, command^.pool, nil)
		vk.DestroyFence(device.device, command^.fence, nil)
		vk.DestroyQueryPool(device.device, command^.timing_queries, nil)
		device.live_objects -= 1
		free(command^, device.allocator)
		command^ = nil
	}
	return result
}
native_command :: proc(command: ^Command) -> vk.CommandBuffer {return(
		command_recording(command) ? command.command : nil \
	)}
@(private = "package")
command_image_layout :: proc(command: ^Command, texture: ^Texture) -> vk.ImageLayout {
	for state in command.images[:command.image_count] {if state.texture == texture do return state.layout}
	return texture.layout
}
@(private = "package")
track_image :: proc(command: ^Command, texture: ^Texture, layout: vk.ImageLayout) -> Result {
	index: u32
	for index < command.image_count && command.images[index].texture != texture do index += 1
	if index == MAX_UPLOADS do return .CAPACITY
	command.images[index] = {texture, layout}
	if index == command.image_count do command.image_count += 1
	return .NONE
}
@(private = "package")
image_barrier :: proc(
	command: vk.CommandBuffer,
	texture: ^Texture,
	old_layout, new_layout: vk.ImageLayout,
	stages: vk.PipelineStageFlags2,
	access: vk.AccessFlags2,
) {
	barrier := vk.ImageMemoryBarrier2 {
		sType               = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask        = old_layout == .UNDEFINED ? {} : {.ALL_COMMANDS},
		srcAccessMask       = old_layout == .UNDEFINED ? {} : {.MEMORY_READ, .MEMORY_WRITE},
		dstStageMask        = stages,
		dstAccessMask       = access,
		oldLayout           = old_layout,
		newLayout           = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = texture.image,
		subresourceRange    = {texture.aspects, 0, texture.mip_levels, 0, 1},
	}
	info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(command, &info)
}
// Whole-image transitions are recorded outside rendering, not committed here.
transition_texture :: proc(
	command: ^Command,
	texture: ^Texture,
	layout: vk.ImageLayout,
	stages: vk.PipelineStageFlags2,
	access: vk.AccessFlags2,
) -> Result {
	if command == nil || texture == nil do return .ERROR_INVALID_ARGUMENT
	if command.phase != .RECORDING do return .ERROR_STATE
	if texture.owner != command.device.device || texture.image == 0 do return .ERROR_INVALID_ARGUMENT
	required: vk.ImageUsageFlags
	#partial switch layout {
	case .GENERAL:
	case .TRANSFER_SRC_OPTIMAL:
		required = {.TRANSFER_SRC}
	case .TRANSFER_DST_OPTIMAL:
		required = {.TRANSFER_DST}
	case .SHADER_READ_ONLY_OPTIMAL:
		required = {.SAMPLED}
	case .ATTACHMENT_OPTIMAL:
		required = texture.aspects == {.COLOR} ? {.COLOR_ATTACHMENT} : {.DEPTH_STENCIL_ATTACHMENT}
	case .PRESENT_SRC_KHR:
		if texture.allocation != 0 do return .ERROR_INVALID_ARGUMENT
	case:
		return .UNSUPPORTED
	}
	if texture.usage & required != required do return .ERROR_INVALID_ARGUMENT
	old_layout := command_image_layout(command, texture)
	result := track_image(command, texture, layout)
	if result == .NONE do image_barrier(command.command, texture, old_layout, layout, stages, access)
	return result
}
copy_buffer :: proc(
	command: ^Command,
	src: ^Buffer,
	src_offset: vk.DeviceSize,
	dst: ^Buffer,
	dst_offset, size: vk.DeviceSize,
) -> Result {
	if command == nil || src == nil || dst == nil || size == 0 do return .ERROR_INVALID_ARGUMENT
	if command.phase != .RECORDING do return .ERROR_STATE
	if src.owner != command.device.device || dst.owner != command.device.device || .TRANSFER_SRC not_in src.usage || .TRANSFER_DST not_in dst.usage do return .ERROR_INVALID_ARGUMENT
	if src_offset > src.size || size > src.size - src_offset || dst_offset > dst.size || size > dst.size - dst_offset do return .OUT_OF_RANGE
	if src.buffer == dst.buffer && src_offset < dst_offset + size && dst_offset < src_offset + size do return .ERROR_INVALID_ARGUMENT
	barriers := [2]vk.BufferMemoryBarrier2 {
		{
			sType = .BUFFER_MEMORY_BARRIER_2,
			srcStageMask = {.ALL_COMMANDS},
			srcAccessMask = {.MEMORY_WRITE},
			dstStageMask = {.TRANSFER},
			dstAccessMask = {.TRANSFER_READ},
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			buffer = src.buffer,
			offset = src_offset,
			size = size,
		},
		{
			sType = .BUFFER_MEMORY_BARRIER_2,
			srcStageMask = {.ALL_COMMANDS},
			srcAccessMask = {.MEMORY_WRITE},
			dstStageMask = {.TRANSFER},
			dstAccessMask = {.TRANSFER_WRITE},
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			buffer = dst.buffer,
			offset = dst_offset,
			size = size,
		},
	}
	dependency := vk.DependencyInfo {
		sType                    = .DEPENDENCY_INFO,
		bufferMemoryBarrierCount = 2,
		pBufferMemoryBarriers    = raw_data(barriers[:]),
	}
	vk.CmdPipelineBarrier2(command.command, &dependency)
	region := vk.BufferCopy{src_offset, dst_offset, size}
	vk.CmdCopyBuffer(command.command, src.buffer, dst.buffer, 1, &region)
	barriers[1].srcStageMask, barriers[1].srcAccessMask = {.TRANSFER}, {.TRANSFER_WRITE}
	barriers[1].dstStageMask, barriers[1].dstAccessMask =
		{.ALL_COMMANDS, .HOST}, {.MEMORY_READ, .MEMORY_WRITE, .HOST_READ}
	dependency.bufferMemoryBarrierCount, dependency.pBufferMemoryBarriers = 1, &barriers[1]
	vk.CmdPipelineBarrier2(command.command, &dependency)
	return .NONE
}

@(private = "file")
attachment_valid :: proc(
	command: ^Command,
	attachment: ^Attachment,
	area: vk.Rect2D,
	aspect: vk.ImageAspectFlags,
) -> bool {
	texture := attachment.texture
	usage :=
		aspect == {.COLOR} ? vk.ImageUsageFlags{.COLOR_ATTACHMENT} : vk.ImageUsageFlags{.DEPTH_STENCIL_ATTACHMENT}
	return(
		texture != nil &&
		texture.owner == command.device.device &&
		texture.view != 0 &&
		texture.mip_levels == 1 &&
		texture.aspects & aspect != {} &&
		texture.usage & usage != {} &&
		u32(area.offset.x) <= texture.extent.width &&
		area.extent.width <= texture.extent.width - u32(area.offset.x) &&
		u32(area.offset.y) <= texture.extent.height &&
		area.extent.height <= texture.extent.height - u32(area.offset.y) &&
		(attachment.load == .CLEAR ||
				attachment.load == .DONT_CARE ||
				(attachment.load == .LOAD &&
						command_image_layout(command, texture) != .UNDEFINED)) &&
		(attachment.store == .STORE || attachment.store == .DONT_CARE) \
	)
}
begin_render :: proc(command: ^Command, desc: Render_Desc) -> Result {
	if command == nil do return .ERROR_INVALID_ARGUMENT
	if command.phase != .RECORDING do return .ERROR_STATE
	if len(desc.colors) > MAX_COLOR_ATTACHMENTS ||
	   len(desc.colors) > int(command.device.properties.limits.maxColorAttachments) ||
	   desc.area.offset.x < 0 ||
	   desc.area.offset.y < 0 ||
	   desc.area.extent.width == 0 ||
	   desc.area.extent.height == 0 ||
	   (len(desc.colors) == 0 &&
			   desc.depth == nil &&
			   desc.stencil == nil) {return .ERROR_INVALID_ARGUMENT}
	attachments: [MAX_COLOR_ATTACHMENTS + 2]^Attachment
	count := 0
	for &attachment, i in desc.colors {
		if !attachment_valid(command, &attachment, desc.area, {.COLOR}) do return .ERROR_INVALID_ARGUMENT
		for earlier in desc.colors[:i] {if attachment.texture == earlier.texture do return .ERROR_INVALID_ARGUMENT}
		attachments[count] = &attachment; count += 1
	}
	if desc.depth != nil {
		if !attachment_valid(command, desc.depth, desc.area, {.DEPTH}) do return .ERROR_INVALID_ARGUMENT
		attachments[count] = desc.depth; count += 1
	}
	if desc.stencil != nil {
		if !attachment_valid(command, desc.stencil, desc.area, {.STENCIL}) || (desc.depth != nil && desc.depth.texture != desc.stencil.texture) do return .ERROR_INVALID_ARGUMENT
		attachments[count] = desc.stencil; count += 1
	}
	new_images := 0
	for attachment, i in attachments[:count] {
		known := false
		for image in command.images[:command.image_count] do known = known || image.texture == attachment.texture
		for earlier in attachments[:i] do known = known || earlier.texture == attachment.texture
		if !known do new_images += 1
	}
	if new_images > MAX_UPLOADS - int(command.image_count) do return .CAPACITY
	viewport := vk.Viewport {
		f32(desc.area.offset.x),
		f32(desc.area.offset.y),
		f32(desc.area.extent.width),
		f32(desc.area.extent.height),
		0,
		1,
	}
	valid := validate_viewport(command.device, viewport, desc.area)
	if valid != .NONE do return valid
	limits := &command.device.properties.limits
	if u32(desc.area.offset.x) > limits.maxFramebufferWidth ||
	   desc.area.extent.width > limits.maxFramebufferWidth - u32(desc.area.offset.x) ||
	   u32(desc.area.offset.y) > limits.maxFramebufferHeight ||
	   desc.area.extent.height >
		   limits.maxFramebufferHeight - u32(desc.area.offset.y) {return .OUT_OF_RANGE}
	infos: [MAX_COLOR_ATTACHMENTS + 2]vk.RenderingAttachmentInfo
	for attachment, i in attachments[:count] {
		texture := attachment.texture
		color := i < len(desc.colors)
		stages :=
			color ? vk.PipelineStageFlags2{.COLOR_ATTACHMENT_OUTPUT} : vk.PipelineStageFlags2{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}
		access :=
			color ? vk.AccessFlags2{.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE} : vk.AccessFlags2{.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE}
		if i == 0 || attachments[i - 1].texture != texture {
			result := transition_texture(command, texture, .ATTACHMENT_OPTIMAL, stages, access)
			if result != .NONE do return result
		}
		infos[i] = {
			sType       = .RENDERING_ATTACHMENT_INFO,
			imageView   = texture.view,
			imageLayout = .ATTACHMENT_OPTIMAL,
			loadOp      = attachment.load,
			storeOp     = attachment.store,
			clearValue  = attachment.clear,
		}
	}
	rendering := vk.RenderingInfo {
		sType                = .RENDERING_INFO,
		renderArea           = desc.area,
		layerCount           = 1,
		colorAttachmentCount = u32(len(desc.colors)),
		pColorAttachments    = raw_data(infos[:]),
		pDepthAttachment     = desc.depth != nil ? &infos[len(desc.colors)] : nil,
		pStencilAttachment   = desc.stencil != nil ? &infos[count - 1] : nil,
	}
	vk.CmdBeginRendering(command.command, &rendering)
	command.phase, command.color_count = .RENDERING, u32(len(desc.colors))
	for attachment, i in desc.colors do command.colors[i] = attachment.texture.format
	command.depth_format = desc.depth != nil ? desc.depth.texture.format : .UNDEFINED
	command.stencil_format = desc.stencil != nil ? desc.stencil.texture.format : .UNDEFINED
	return set_viewport(command, viewport, desc.area)
}
end_render :: proc(command: ^Command) -> Result {
	if command == nil do return .ERROR_INVALID_ARGUMENT
	if command.phase != .RENDERING do return .ERROR_STATE
	vk.CmdEndRendering(command.command)
	command.phase = .RECORDING
	return .NONE
}
@(private = "file")
validate_viewport :: proc(device: ^Device, viewport: vk.Viewport, scissor: vk.Rect2D) -> Result {
	limits := &device.properties.limits
	for value in ([6]f32{viewport.x, viewport.y, viewport.width, viewport.height, viewport.minDepth, viewport.maxDepth}) {
		if math.is_nan(value) || math.is_inf(value) do return .OUT_OF_RANGE
	}
	if viewport.width <= 0 ||
	   viewport.height <= 0 ||
	   viewport.width > f32(limits.maxViewportDimensions[0]) ||
	   viewport.height > f32(limits.maxViewportDimensions[1]) ||
	   viewport.x < limits.viewportBoundsRange[0] ||
	   viewport.y < limits.viewportBoundsRange[0] ||
	   viewport.x + viewport.width > limits.viewportBoundsRange[1] ||
	   viewport.y + viewport.height > limits.viewportBoundsRange[1] ||
	   viewport.minDepth < 0 ||
	   viewport.minDepth > 1 ||
	   viewport.maxDepth < 0 ||
	   viewport.maxDepth > 1 ||
	   scissor.offset.x < 0 ||
	   scissor.offset.y < 0 ||
	   scissor.extent.width > u32(max(i32)) - u32(scissor.offset.x) ||
	   scissor.extent.height > u32(max(i32)) - u32(scissor.offset.y) {return .OUT_OF_RANGE}
	return .NONE
}
set_viewport :: proc(command: ^Command, viewport: vk.Viewport, scissor: vk.Rect2D) -> Result {
	if command == nil do return .ERROR_INVALID_ARGUMENT
	if !command_recording(command) do return .ERROR_STATE
	result := validate_viewport(command.device, viewport, scissor)
	if result != .NONE do return result
	view, clip := viewport, scissor
	vk.CmdSetViewportWithCount(command.command, 1, &view)
	vk.CmdSetScissorWithCount(command.command, 1, &clip)
	return .NONE
}
