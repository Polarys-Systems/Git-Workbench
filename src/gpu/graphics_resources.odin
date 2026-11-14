package gpu

import vk "vendor:vulkan"

@(private = "package")
descriptor_types :: [DESCRIPTOR_TYPES]vk.DescriptorType {
	.SAMPLER,
	.COMBINED_IMAGE_SAMPLER,
	.SAMPLED_IMAGE,
	.STORAGE_IMAGE,
	.UNIFORM_BUFFER,
	.STORAGE_BUFFER,
}
@(private = "package")
descriptor_type_index :: proc(type: vk.DescriptorType) -> int {
	for value, i in descriptor_types {if value == type do return i}
	return DESCRIPTOR_TYPES
}

create_binding_layout :: proc(
	device: ^Device,
	bindings: []Binding_Desc,
) -> (
	^Binding_Layout,
	Result,
) {
	if device == nil do return nil, .NO_DEVICE
	if len(bindings) == 0 do return nil, .ERROR_INVALID_ARGUMENT
	if len(bindings) > MAX_BINDINGS do return nil, .CAPACITY
	layout, err := new(Binding_Layout, device.allocator)
	if err != nil do return nil, .NO_MEMORY
	committed := false
	defer if !committed do free(layout, device.allocator)
	native: [MAX_BINDINGS]vk.DescriptorSetLayoutBinding
	for binding, i in bindings {
		type := descriptor_type_index(binding.type)
		if type == DESCRIPTOR_TYPES ||
		   binding.count == 0 ||
		   binding.stages == {} ||
		   binding.stages & ~(vk.ShaderStageFlags{.VERTEX, .FRAGMENT, .COMPUTE}) !=
			   {} {return nil, .ERROR_INVALID_ARGUMENT}
		for earlier in bindings[:i] {if earlier.binding == binding.binding do return nil, .ERROR_INVALID_ARGUMENT}
		if binding.count > ~u32(0) - layout.budgets[type] do return nil, .OUT_OF_RANGE
		layout.budgets[type] += binding.count
		layout.bindings[i] = binding
		native[i] = {binding.binding, binding.type, binding.count, binding.stages, nil}
	}

	// Bindings have fixed counts and are updated before use. Match the ordinary
	// descriptor pools below; UPDATE_AFTER_BIND_POOL requires compatible pools.
	info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = u32(len(bindings)),
		pBindings    = raw_data(native[:]),
	}
	supported := vk.DescriptorSetLayoutSupport {
		sType = .DESCRIPTOR_SET_LAYOUT_SUPPORT,
	}
	vk.GetDescriptorSetLayoutSupport(device.device, &info, &supported)
	if !supported.supported do return nil, .UNSUPPORTED
	result := vk_result(
		device,
		vk.CreateDescriptorSetLayout(device.device, &info, nil, &layout.layout),
		.ERROR_RESOURCE,
	)
	if result != .NONE do return nil, result
	layout.owner, layout.count = device.device, u32(len(bindings))
	device.live_objects += 1
	device.stats.descriptor_layout_creations += 1
	committed = true
	return layout, .NONE
}
destroy_binding_layout :: proc(device: ^Device, layout: ^^Binding_Layout) -> Result {
	if device == nil do return .NO_DEVICE
	if layout == nil do return .ERROR_INVALID_ARGUMENT
	if layout^ == nil do return .NONE
	if layout^.owner != device.device do return .ERROR_INVALID_ARGUMENT
	if layout^.references != 0 do return .ERROR_RESOURCE
	vk.DestroyDescriptorSetLayout(device.device, layout^.layout, nil)
	device.live_objects -= 1
	free(layout^, device.allocator)
	layout^ = nil
	return .NONE
}
create_resources :: proc(device: ^Device, layout: ^Binding_Layout, out: ^Binding_Set) -> Result {
	if device == nil do return .NO_DEVICE
	if layout == nil || layout.owner != device.device || out == nil || out.set != 0 do return .ERROR_INVALID_ARGUMENT
	for &pool, i in device.descriptor_pools {
		created := pool.pool == 0
		if created {
			budgets: [DESCRIPTOR_TYPES]vk.DescriptorPoolSize
			for type, j in descriptor_types {budgets[j] = {type, max(layout.budgets[j], 128)}}
			info := vk.DescriptorPoolCreateInfo {
				sType         = .DESCRIPTOR_POOL_CREATE_INFO,
				flags         = {.FREE_DESCRIPTOR_SET},
				maxSets       = 64,
				poolSizeCount = DESCRIPTOR_TYPES,
				pPoolSizes    = raw_data(budgets[:]),
			}
			result := vk_result(
				device,
				vk.CreateDescriptorPool(device.device, &info, nil, &pool.pool),
				.NO_MEMORY,
			)
			if result != .NONE do return result
			for budget, j in budgets do pool.available[j] = budget.descriptorCount
			device.stats.descriptor_pool_creations += 1
		}
		fits := pool.live_sets < 64
		for budget, j in layout.budgets do fits = fits && pool.available[j] >= budget
		if !fits do continue
		set := Binding_Set {
			owner      = device.device,
			layout     = layout,
			pool_index = u32(i),
		}
		info := vk.DescriptorSetAllocateInfo {
			sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
			descriptorPool     = pool.pool,
			descriptorSetCount = 1,
			pSetLayouts        = &layout.layout,
		}
		result := vk.AllocateDescriptorSets(device.device, &info, &set.set)
		if result == .SUCCESS {
			for budget, j in layout.budgets do pool.available[j] -= budget
			pool.live_sets += 1
			layout.references += 1
			device.live_objects += 1
			out^ = set
			return .NONE
		}
		if created {vk.DestroyDescriptorPool(device.device, pool.pool, nil); pool = {}}
		if created || (result != .ERROR_OUT_OF_POOL_MEMORY && result != .ERROR_FRAGMENTED_POOL) do return vk_result(device, result, .ERROR_RESOURCE)
	}
	return .CAPACITY
}
destroy_resources :: proc(device: ^Device, set: ^Binding_Set) -> Result {
	if device == nil do return .NO_DEVICE
	if set == nil || (set.owner != nil && set.owner != device.device) do return .ERROR_INVALID_ARGUMENT
	if set.set != 0 {
		pool := &device.descriptor_pools[set.pool_index]
		result := vk_result(
			device,
			vk.FreeDescriptorSets(device.device, pool.pool, 1, &set.set),
			.ERROR_RESOURCE,
		)
		if result != .NONE do return result
		pool.live_sets -= 1
		for budget, j in set.layout.budgets do pool.available[j] += budget
		set.layout.references -= 1
		device.live_objects -= 1
	}
	set^ = {}
	return .NONE
}
update_resources :: proc(device: ^Device, writes: []Binding_Write) -> Result {
	if device == nil do return .NO_DEVICE
	if len(writes) == 0 do return .ERROR_INVALID_ARGUMENT
	if len(writes) > MAX_DESCRIPTOR_WRITES do return .CAPACITY
	native: [MAX_DESCRIPTOR_WRITES]vk.WriteDescriptorSet
	buffers: [MAX_DESCRIPTOR_VALUES]vk.DescriptorBufferInfo
	images: [MAX_DESCRIPTOR_VALUES]vk.DescriptorImageInfo
	used := 0
	for write, i in writes {
		if write.set == nil || write.set.owner != device.device || write.set.set == 0 || len(write.values) == 0 do return .ERROR_INVALID_ARGUMENT
		if len(write.values) > MAX_DESCRIPTOR_VALUES - used do return .CAPACITY
		binding: ^Binding_Desc
		for &candidate in write.set.layout.bindings[:write.set.layout.count] {if candidate.binding == write.binding do binding = &candidate}
		if binding == nil do return .ERROR_INVALID_ARGUMENT
		if write.first_element > binding.count || u64(len(write.values)) > u64(binding.count - write.first_element) do return .OUT_OF_RANGE
		buffer_type := binding.type == .UNIFORM_BUFFER || binding.type == .STORAGE_BUFFER
		native[i] = {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = write.set.set,
			dstBinding      = write.binding,
			dstArrayElement = write.first_element,
			descriptorCount = u32(len(write.values)),
			descriptorType  = binding.type,
			pBufferInfo     = buffer_type ? &buffers[used] : nil,
			pImageInfo      = buffer_type ? nil : &images[used],
		}
		for value in write.values {
			if buffer_type {
				buffer := value.buffer
				uniform := binding.type == .UNIFORM_BUFFER
				usage :=
					uniform ? vk.BufferUsageFlags{.UNIFORM_BUFFER} : vk.BufferUsageFlags{.STORAGE_BUFFER}
				alignment :=
					uniform ? device.properties.limits.minUniformBufferOffsetAlignment : device.properties.limits.minStorageBufferOffsetAlignment
				max_size :=
					uniform ? device.properties.limits.maxUniformBufferRange : device.properties.limits.maxStorageBufferRange
				if buffer == nil || buffer.owner != device.device || buffer.buffer == 0 || buffer.usage & usage == {} || value.size == 0 || value.size > vk.DeviceSize(max_size) || value.offset % alignment != 0 do return .ERROR_INVALID_ARGUMENT
				if value.offset > buffer.size || value.size > buffer.size - value.offset do return .OUT_OF_RANGE
				buffers[used] = {buffer.buffer, value.offset, value.size}
			} else {
				needs_image := binding.type != .SAMPLER
				needs_sampler :=
					binding.type == .SAMPLER || binding.type == .COMBINED_IMAGE_SAMPLER
				if needs_sampler && (value.sampler == nil || value.sampler.owner != device.device || value.sampler.sampler == 0) do return .ERROR_INVALID_ARGUMENT
				if needs_image {
					usage :=
						binding.type == .STORAGE_IMAGE ? vk.ImageUsageFlags{.STORAGE} : vk.ImageUsageFlags{.SAMPLED}
					if value.texture == nil ||
					   value.texture.owner != device.device ||
					   value.texture.view == 0 ||
					   value.texture.aspects == {.DEPTH, .STENCIL} ||
					   value.texture.usage & usage == {} ||
					   (value.image_layout != .GENERAL &&
							   (binding.type == .STORAGE_IMAGE ||
									   value.image_layout !=
										   .SHADER_READ_ONLY_OPTIMAL)) {return .ERROR_INVALID_ARGUMENT}
				}
				images[used] = {
					needs_sampler ? value.sampler.sampler : 0,
					needs_image ? value.texture.view : 0,
					needs_image ? value.image_layout : .UNDEFINED,
				}
			}
			used += 1
		}
	}
	vk.UpdateDescriptorSets(device.device, u32(len(writes)), raw_data(native[:]), 0, nil)
	device.stats.descriptor_update_calls += 1
	return .NONE
}
