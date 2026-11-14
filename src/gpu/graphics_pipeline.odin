package gpu

import "core:mem"
import vk "vendor:vulkan"

color_target_default :: proc(format: vk.Format) -> Color_Target {
	return {
		format = format,
		blend = {
			srcColorBlendFactor = .ONE,
			dstColorBlendFactor = .ZERO,
			colorBlendOp = .ADD,
			srcAlphaBlendFactor = .ONE,
			dstAlphaBlendFactor = .ZERO,
			alphaBlendOp = .ADD,
			colorWriteMask = {.R, .G, .B, .A},
		},
	}
}
@(private = "file")
validate_pipeline :: proc(device: ^Device, desc: Pipeline_Desc) -> Result {
	if len(desc.vertex_spirv) < 5 ||
	   desc.vertex_spirv[0] != 0x07230203 ||
	   (len(desc.fragment_spirv) != 0 &&
			   (len(desc.fragment_spirv) < 5 ||
					   desc.fragment_spirv[0] != 0x07230203)) {return .ERROR_INVALID_ARGUMENT}
	limits := &device.properties.limits
	if len(desc.colors) > MAX_COLOR_ATTACHMENTS ||
	   len(desc.colors) > int(limits.maxColorAttachments) ||
	   len(desc.layouts) > MAX_SET_LAYOUTS ||
	   len(desc.layouts) > int(limits.maxBoundDescriptorSets) ||
	   len(desc.push_ranges) > MAX_PUSH_RANGES {return .OUT_OF_RANGE}
	for layout in desc.layouts {if layout == nil || layout.owner != device.device do return .ERROR_INVALID_ARGUMENT}
	seen: vk.ShaderStageFlags
	for range in desc.push_ranges {
		if range.size == 0 ||
		   range.size % 4 != 0 ||
		   range.offset % 4 != 0 ||
		   range.stageFlags == {} ||
		   range.stageFlags & ~(vk.ShaderStageFlags{.VERTEX, .FRAGMENT}) != {} ||
		   seen & range.stageFlags != {} {return .ERROR_INVALID_ARGUMENT}
		if range.offset > limits.maxPushConstantsSize || range.size > limits.maxPushConstantsSize - range.offset do return .OUT_OF_RANGE
		seen |= range.stageFlags
	}
	for color, i in desc.colors {
		if color.format == .UNDEFINED || format_aspects(color.format) != {.COLOR} do return .ERROR_INVALID_ARGUMENT
		properties: vk.FormatProperties
		vk.GetPhysicalDeviceFormatProperties(device.physical_device, color.format, &properties)
		required := vk.FormatFeatureFlags{.COLOR_ATTACHMENT}
		if color.blend.blendEnable do required += {.COLOR_ATTACHMENT_BLEND}
		if properties.optimalTilingFeatures & required != required do return .UNSUPPORTED
		if i != 0 && mem.compare_ptrs(&desc.colors[i].blend, &desc.colors[0].blend, size_of(color.blend)) != 0 do return .UNSUPPORTED
	}
	if (desc.depth_format != .UNDEFINED && .DEPTH not_in format_aspects(desc.depth_format)) ||
	   (desc.stencil_format != .UNDEFINED &&
			   .STENCIL not_in format_aspects(desc.stencil_format)) ||
	   (desc.depth_format != .UNDEFINED &&
			   desc.stencil_format != .UNDEFINED &&
			   desc.depth_format != desc.stencil_format) {return .ERROR_INVALID_ARGUMENT}
	if raster := desc.rasterization; raster != nil {
		if raster.sType != .PIPELINE_RASTERIZATION_STATE_CREATE_INFO ||
		   raster.pNext != nil ||
		   raster.flags != {} ||
		   raster.depthClampEnable ||
		   raster.depthBiasClamp != 0 ||
		   raster.polygonMode != .FILL ||
		   raster.lineWidth != 1 {return .UNSUPPORTED}
	}
	if desc.topology != nil && (desc.topology^ < .POINT_LIST || desc.topology^ > .TRIANGLE_FAN) do return .UNSUPPORTED
	if input := desc.vertex_input; input != nil {
		if input.sType != .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO ||
		   input.pNext != nil ||
		   input.flags != {} ||
		   input.vertexBindingDescriptionCount > limits.maxVertexInputBindings ||
		   input.vertexAttributeDescriptionCount > limits.maxVertexInputAttributes ||
		   (input.vertexBindingDescriptionCount != 0 && input.pVertexBindingDescriptions == nil) ||
		   (input.vertexAttributeDescriptionCount != 0 &&
				   input.pVertexAttributeDescriptions == nil) {return .ERROR_INVALID_ARGUMENT}
		bindings := input.pVertexBindingDescriptions[:input.vertexBindingDescriptionCount]
		attributes := input.pVertexAttributeDescriptions[:input.vertexAttributeDescriptionCount]
		for binding, i in bindings {
			if binding.binding >= limits.maxVertexInputBindings || binding.stride > limits.maxVertexInputBindingStride || (binding.inputRate != .VERTEX && binding.inputRate != .INSTANCE) do return .ERROR_INVALID_ARGUMENT
			for earlier in bindings[:i] {if earlier.binding == binding.binding do return .ERROR_INVALID_ARGUMENT}
		}
		for attribute, i in attributes {
			found := false
			for binding in bindings do found = found || attribute.binding == binding.binding
			if !found || attribute.location >= limits.maxVertexInputAttributes || attribute.offset > limits.maxVertexInputAttributeOffset do return .ERROR_INVALID_ARGUMENT
			for earlier in attributes[:i] {if earlier.location == attribute.location do return .ERROR_INVALID_ARGUMENT}
			properties: vk.FormatProperties
			vk.GetPhysicalDeviceFormatProperties(
				device.physical_device,
				attribute.format,
				&properties,
			)
			if .VERTEX_BUFFER not_in properties.bufferFeatures do return .UNSUPPORTED
		}
	}
	return .NONE
}
create_pipeline :: proc(device: ^Device, desc: Pipeline_Desc, out: ^Pipeline) -> Result {
	if device == nil do return .NO_DEVICE
	if out == nil || out.pipeline != 0 || out.layout != 0 do return .ERROR_INVALID_ARGUMENT
	result := validate_pipeline(device, desc)
	if result != .NONE do return result
	pipeline: Pipeline
	layouts: [MAX_SET_LAYOUTS]vk.DescriptorSetLayout
	for layout, i in desc.layouts do layouts[i] = layout.layout
	layout := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = u32(len(desc.layouts)),
		pSetLayouts            = raw_data(layouts[:]),
		pushConstantRangeCount = u32(len(desc.push_ranges)),
		pPushConstantRanges    = raw_data(desc.push_ranges),
	}
	result = vk_result(
		device,
		vk.CreatePipelineLayout(device.device, &layout, nil, &pipeline.layout),
		.ERROR_RESOURCE,
	)
	modules: [2]vk.ShaderModule
	stage_count: u32 = len(desc.fragment_spirv) != 0 ? 2 : 1
	for i: u32 = 0; i < stage_count && result == .NONE; i += 1 {
		code := i == 0 ? desc.vertex_spirv : desc.fragment_spirv
		info := vk.ShaderModuleCreateInfo {
			sType    = .SHADER_MODULE_CREATE_INFO,
			codeSize = len(code) * size_of(u32),
			pCode    = raw_data(code),
		}
		result = vk_result(
			device,
			vk.CreateShaderModule(device.device, &info, nil, &modules[i]),
			.ERROR_RESOURCE,
		)
	}
	stages := [2]vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = modules[0],
			pName = desc.vertex_entry != nil ? desc.vertex_entry : "main",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = modules[1],
			pName = desc.fragment_entry != nil ? desc.fragment_entry : "main",
		},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}
	assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = desc.topology != nil ? desc.topology^ : .TRIANGLE_LIST,
	}
	viewport := vk.PipelineViewportStateCreateInfo {
		sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
	}
	raster := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		frontFace   = .COUNTER_CLOCKWISE,
		lineWidth   = 1,
	}
	samples := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}
	depth := vk.PipelineDepthStencilStateCreateInfo {
		sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
	}
	attachments: [MAX_COLOR_ATTACHMENTS]vk.PipelineColorBlendAttachmentState
	formats: [MAX_COLOR_ATTACHMENTS]vk.Format
	for color, i in desc.colors {formats[i], attachments[i] = color.format, color.blend}
	blend := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = u32(len(desc.colors)),
		pAttachments    = raw_data(attachments[:]),
	}
	dynamic_states := [?]vk.DynamicState {
		.VIEWPORT_WITH_COUNT,
		.SCISSOR_WITH_COUNT,
		.DEPTH_TEST_ENABLE,
		.DEPTH_WRITE_ENABLE,
		.DEPTH_COMPARE_OP,
		.STENCIL_TEST_ENABLE,
		.STENCIL_OP,
		.STENCIL_COMPARE_MASK,
		.STENCIL_WRITE_MASK,
		.STENCIL_REFERENCE,
	}
	dynamic_info := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = raw_data(dynamic_states[:]),
	}
	rendering := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = u32(len(desc.colors)),
		pColorAttachmentFormats = raw_data(formats[:]),
		depthAttachmentFormat   = desc.depth_format,
		stencilAttachmentFormat = desc.stencil_format,
	}
	info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering,
		stageCount          = stage_count,
		pStages             = raw_data(stages[:]),
		pVertexInputState   = desc.vertex_input != nil ? desc.vertex_input : &vertex_input,
		pInputAssemblyState = &assembly,
		pViewportState      = &viewport,
		pRasterizationState = desc.rasterization != nil ? desc.rasterization : &raster,
		pMultisampleState   = &samples,
		pDepthStencilState  = &depth,
		pColorBlendState    = &blend,
		pDynamicState       = &dynamic_info,
		layout              = pipeline.layout,
		basePipelineIndex   = -1,
	}
	if result == .NONE do result = vk_result(device, vk.CreateGraphicsPipelines(device.device, device.pipeline_cache, 1, &info, nil, &pipeline.pipeline), .ERROR_RESOURCE)
	for module in modules do vk.DestroyShaderModule(device.device, module, nil)
	if result == .NONE {
		pipeline.owner, pipeline.layout_count, pipeline.push_range_count, pipeline.color_count =
			device.device,
			u32(len(desc.layouts)),
			u32(len(desc.push_ranges)),
			u32(len(desc.colors))
		pipeline.depth_format, pipeline.stencil_format = desc.depth_format, desc.stencil_format
		for layout, i in desc.layouts {pipeline.layouts[i] = layout; layout.references += 1}
		copy(pipeline.push_ranges[:], desc.push_ranges)
		copy(pipeline.colors[:], formats[:len(desc.colors)])
		out^ = pipeline
		device.live_objects += 1
	} else {vk.DestroyPipeline(device.device, pipeline.pipeline, nil)
		vk.DestroyPipelineLayout(device.device, pipeline.layout, nil)}
	return result
}
@(private = "package")
command_defaults :: proc(command: ^Command) {
	if command.state_valid do return
	vk.CmdSetDepthTestEnable(command.command, false)
	vk.CmdSetDepthWriteEnable(command.command, true)
	vk.CmdSetDepthCompareOp(command.command, .LESS)
	vk.CmdSetStencilTestEnable(command.command, false)
	vk.CmdSetStencilOp(command.command, {.FRONT, .BACK}, .KEEP, .KEEP, .KEEP, .ALWAYS)
	vk.CmdSetStencilCompareMask(command.command, {.FRONT, .BACK}, ~u32(0))
	vk.CmdSetStencilWriteMask(command.command, {.FRONT, .BACK}, ~u32(0))
	vk.CmdSetStencilReference(command.command, {.FRONT, .BACK}, 0)
	command.depth_enabled, command.stencil_enabled, command.state_valid = false, false, true
	command.device.stats.dynamic_state_commands += 8
}
bind_pipeline :: proc(command: ^Command, pipeline: ^Pipeline) -> Result {
	if command == nil || pipeline == nil || pipeline.owner != command.device.device || pipeline.pipeline == 0 do return .ERROR_INVALID_ARGUMENT
	if !command_recording(command) do return .ERROR_STATE
	command_defaults(command)
	if command.pipeline != pipeline {
		vk.CmdBindPipeline(command.command, .GRAPHICS, pipeline.pipeline)
		command.device.stats.pipeline_binds += 1
		command.sets, command.pipeline = {}, pipeline
	}
	return .NONE
}
bind_resources :: proc(command: ^Command, set_index: u32, set: ^Binding_Set) -> Result {
	if command == nil || set == nil do return .ERROR_INVALID_ARGUMENT
	if !command_recording(command) || command.pipeline == nil do return .ERROR_STATE
	if set_index >= command.pipeline.layout_count || set.set == 0 || set.owner != command.device.device || set.layout != command.pipeline.layouts[set_index] do return .ERROR_INVALID_ARGUMENT
	if command.sets[set_index] != set.set {
		vk.CmdBindDescriptorSets(
			command.command,
			.GRAPHICS,
			command.pipeline.layout,
			set_index,
			1,
			&set.set,
			0,
			nil,
		)
		command.sets[set_index] = set.set
	}
	return .NONE
}
push_constants :: proc(
	command: ^Command,
	stages: vk.ShaderStageFlags,
	offset: u32,
	data: []byte,
) -> Result {
	if command == nil || len(data) == 0 || len(data) > int(max(u32)) || stages == {} || offset % 4 != 0 || len(data) % 4 != 0 do return .ERROR_INVALID_ARGUMENT
	if !command_recording(command) || command.pipeline == nil do return .ERROR_STATE
	size := u32(len(data))
	covered: vk.ShaderStageFlags
	for range in command.pipeline.push_ranges[:command.pipeline.push_range_count] {
		if offset >= range.offset && offset - range.offset <= range.size && size <= range.size - (offset - range.offset) do covered |= range.stageFlags
		if u64(offset) < u64(range.offset) + u64(range.size) && u64(range.offset) < u64(offset) + u64(size) && stages & range.stageFlags != range.stageFlags do return .ERROR_INVALID_ARGUMENT
	}
	if covered & stages != stages do return .OUT_OF_RANGE
	vk.CmdPushConstants(
		command.command,
		command.pipeline.layout,
		stages,
		offset,
		size,
		raw_data(data),
	)
	return .NONE
}
set_depth_test_enabled :: proc(command: ^Command, enabled: bool) -> Result {
	if command == nil do return .ERROR_INVALID_ARGUMENT
	if !command_recording(command) do return .ERROR_STATE
	command_defaults(command)
	if command.depth_enabled != enabled {
		vk.CmdSetDepthTestEnable(
			command.command,
			b32(enabled),
		); command.depth_enabled = enabled; command.device.stats.dynamic_state_commands += 1
	}
	return .NONE
}
set_stencil_test_enabled :: proc(command: ^Command, enabled: bool) -> Result {
	if command == nil do return .ERROR_INVALID_ARGUMENT
	if !command_recording(command) do return .ERROR_STATE
	command_defaults(command)
	if command.stencil_enabled != enabled {
		vk.CmdSetStencilTestEnable(
			command.command,
			b32(enabled),
		); command.stencil_enabled = enabled; command.device.stats.dynamic_state_commands += 1
	}
	return .NONE
}
set_depth_state :: proc(command: ^Command, write: bool, compare: vk.CompareOp) -> Result {
	if command == nil do return .ERROR_INVALID_ARGUMENT
	if !command_recording(command) do return .ERROR_STATE
	if compare < .NEVER || compare > .ALWAYS do return .ERROR_INVALID_ARGUMENT
	command_defaults(command)
	vk.CmdSetDepthWriteEnable(command.command, b32(write))
	vk.CmdSetDepthCompareOp(command.command, compare)
	command.device.stats.dynamic_state_commands += 2
	return .NONE
}
set_stencil_state :: proc(command: ^Command, front, back: vk.StencilOpState) -> Result {
	if command == nil do return .ERROR_INVALID_ARGUMENT
	if !command_recording(command) do return .ERROR_STATE
	states := [2]vk.StencilOpState{front, back}
	for state in states {
		if state.compareOp < .NEVER ||
		   state.compareOp > .ALWAYS ||
		   state.failOp < .KEEP ||
		   state.failOp > .DECREMENT_AND_WRAP ||
		   state.passOp < .KEEP ||
		   state.passOp > .DECREMENT_AND_WRAP ||
		   state.depthFailOp < .KEEP ||
		   state.depthFailOp > .DECREMENT_AND_WRAP {return .ERROR_INVALID_ARGUMENT}
	}
	command_defaults(command)
	for state, i in states {
		face := i == 0 ? vk.StencilFaceFlags{.FRONT} : vk.StencilFaceFlags{.BACK}
		vk.CmdSetStencilOp(
			command.command,
			face,
			state.failOp,
			state.passOp,
			state.depthFailOp,
			state.compareOp,
		)
		vk.CmdSetStencilCompareMask(command.command, face, state.compareMask)
		vk.CmdSetStencilWriteMask(command.command, face, state.writeMask)
		vk.CmdSetStencilReference(command.command, face, state.reference)
	}
	command.device.stats.dynamic_state_commands += 8
	return .NONE
}
bind_vertex_buffer :: proc(
	command: ^Command,
	binding: u32,
	buffer: ^Buffer,
	offset: vk.DeviceSize,
) -> Result {
	if command == nil do return .ERROR_INVALID_ARGUMENT
	if !command_recording(command) do return .ERROR_STATE
	if buffer == nil || buffer.owner != command.device.device || .VERTEX_BUFFER not_in buffer.usage || offset >= buffer.size || binding >= command.device.properties.limits.maxVertexInputBindings do return .ERROR_INVALID_ARGUMENT
	buffer_offset := offset
	vk.CmdBindVertexBuffers(command.command, binding, 1, &buffer.buffer, &buffer_offset)
	return .NONE
}
bind_index_buffer :: proc(
	command: ^Command,
	buffer: ^Buffer,
	offset: vk.DeviceSize,
	type: vk.IndexType,
) -> Result {
	if command == nil do return .ERROR_INVALID_ARGUMENT
	if !command_recording(command) do return .ERROR_STATE
	stride: u32 = type == .UINT16 ? 2 : (type == .UINT32 ? 4 : 0)
	if buffer == nil || buffer.owner != command.device.device || .INDEX_BUFFER not_in buffer.usage || stride == 0 || offset % vk.DeviceSize(stride) != 0 || offset >= buffer.size do return .ERROR_INVALID_ARGUMENT
	vk.CmdBindIndexBuffer(command.command, buffer.buffer, offset, type)
	command.index_bytes, command.index_stride = buffer.size - offset, stride
	return .NONE
}
@(private = "package")
check_draw :: proc(command: ^Command) -> Result {
	if command == nil do return .ERROR_INVALID_ARGUMENT
	if command.phase != .RENDERING || command.pipeline == nil do return .ERROR_STATE
	pipeline := command.pipeline
	if pipeline.color_count != command.color_count ||
	   pipeline.depth_format != command.depth_format ||
	   pipeline.stencil_format != command.stencil_format ||
	   (command.depth_enabled && command.depth_format == .UNDEFINED) ||
	   (command.stencil_enabled && command.stencil_format == .UNDEFINED) {return .ERROR_RESOURCE}
	for format, i in pipeline.colors[:pipeline.color_count] {if format != command.colors[i] do return .ERROR_RESOURCE}
	for set in command.sets[:pipeline.layout_count] {if set == 0 do return .ERROR_RESOURCE}
	return .NONE
}
draw :: proc(command: ^Command, vertices, instances, first_vertex, first_instance: u32) -> Result {
	result := check_draw(command)
	if result == .NONE {
		vk.CmdDraw(command.command, vertices, instances, first_vertex, first_instance)
		command.device.stats.draw_calls += 1
		command.device.stats.vertices_drawn += u64(vertices) * u64(instances)
	}
	return result
}
draw_indexed :: proc(
	command: ^Command,
	indices, instances, first_index: u32,
	vertex_offset: i32,
	first_instance: u32,
) -> Result {
	result := check_draw(command)
	if result == .NONE && (command.index_stride == 0 || (u64(first_index) + u64(indices)) * u64(command.index_stride) > u64(command.index_bytes)) do result = .OUT_OF_RANGE
	if result == .NONE {
		vk.CmdDrawIndexed(command.command, indices, instances, first_index, vertex_offset, first_instance)
		command.device.stats.draw_calls += 1
		command.device.stats.indices_drawn += u64(indices) * u64(instances)
	}
	return result
}
