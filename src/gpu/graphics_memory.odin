package gpu

import "core:mem"
import vk "vendor:vulkan"

@(private = "file")
memory_type :: proc(device: ^Device, mask: u32, kind: Alloc_Type) -> u32 {
	required :=
		kind == .DEVICE ? vk.MemoryPropertyFlags{.DEVICE_LOCAL} : vk.MemoryPropertyFlags{.HOST_VISIBLE, .HOST_COHERENT}
	selected := ~u32(0)
	best := -1
	for properties, i in device.memory_properties.memoryTypes[:device.memory_properties.memoryTypeCount] {
		flags := properties.propertyFlags
		if mask & (u32(1) << u32(i)) != 0 && flags & required == required {
			score := 0
			if kind == .READBACK && .HOST_CACHED in flags do score += 2
			if kind == .UPLOAD && .DEVICE_LOCAL in flags do score += 1
			if kind == .DEVICE && .HOST_VISIBLE not_in flags do score += 1
			if score > best {best = score; selected = u32(i)}
		}
	}
	return selected
}
@(private = "file")
block_offset :: proc(
	device: ^Device,
	index: u32,
	requirements: ^vk.MemoryRequirements,
) -> (
	vk.DeviceSize,
	u32,
	bool,
) {
	block := &device.memory_blocks[index]
	offset: vk.DeviceSize
	previous: u32
	next := block.first
	for {
		device.stats.allocation_search_steps += 1
		padding :=
			(requirements.alignment - offset % requirements.alignment) % requirements.alignment
		end := next != 0 ? device.allocations[next - 1].offset : block.size
		if offset <= end && padding <= end - offset && requirements.size <= end - offset - padding do return offset + padding, previous, true
		if next == 0 do return 0, 0, false
		entry := &device.allocations[next - 1]
		offset, previous, next = entry.offset + entry.size, next, entry.next
	}
}
@(private = "file")
release_block :: proc(device: ^Device, block: ^Memory_Block) {
	if block.mapped != nil do vk.UnmapMemory(device.device, block.memory)
	vk.FreeMemory(device.device, block.memory, nil)
	device.stats.reserved_bytes -= block.size
	block^ = {}
}
@(private = "package")
memory_acquire :: proc(
	device: ^Device,
	requirements: ^vk.MemoryRequirements,
	kind: Alloc_Type,
	buffer: vk.Buffer,
	image: vk.Image,
	require_dedicated: bool,
	allocation: ^u32,
) -> Result {
	type := memory_type(device, requirements.memoryTypeBits, kind)
	if type == ~u32(0) do return .NO_DEVICE_MEM
	if device.free_allocation == 0 do return .CAPACITY
	is_image := image != 0
	dedicated := require_dedicated || requirements.size > MEMORY_BLOCK_SIZE
	index := u32(MAX_MEMORY_BLOCKS)
	previous: u32
	offset: vk.DeviceSize
	if !dedicated {
		for &block, i in device.memory_blocks {
			if block.memory != 0 &&
			   !block.dedicated &&
			   block.memory_type == type &&
			   block.image == is_image {
				if found_offset, found_previous, fits := block_offset(
					device,
					u32(i),
					requirements,
				); fits {
					index, offset, previous = u32(i), found_offset, found_previous
					break
				}
			}
		}
	}
	result := Result.NONE
	if index == MAX_MEMORY_BLOCKS {
		for &block, i in device.memory_blocks {
			if block.memory != 0 &&
			   block.live_allocations == 0 {release_block(device, &block); index = u32(i); break}
		}
		if index == MAX_MEMORY_BLOCKS {
			for block, i in device.memory_blocks {if block.memory == 0 {index = u32(i); break}}
		}
		if index == MAX_MEMORY_BLOCKS do return .CAPACITY
		dedicated_info := vk.MemoryDedicatedAllocateInfo {
			sType  = .MEMORY_DEDICATED_ALLOCATE_INFO,
			image  = image,
			buffer = buffer,
		}
		flags := vk.MemoryAllocateFlagsInfo {
			sType = .MEMORY_ALLOCATE_FLAGS_INFO,
			pNext = dedicated ? &dedicated_info : nil,
		}
		if device.enabled.buffer_device_address && !is_image do flags.flags = {.DEVICE_ADDRESS}
		info := vk.MemoryAllocateInfo {
			sType           = .MEMORY_ALLOCATE_INFO,
			pNext           = &flags,
			allocationSize  = dedicated ? requirements.size : MEMORY_BLOCK_SIZE,
			memoryTypeIndex = type,
		}
		block := &device.memory_blocks[index]
		memory: vk.DeviceMemory
		result = vk_result(
			device,
			vk.AllocateMemory(device.device, &info, nil, &memory),
			.NO_DEVICE_MEM,
		)
		if result == .NONE {
			block^ = {
				memory      = memory,
				size        = info.allocationSize,
				memory_type = type,
				image       = is_image,
				dedicated   = dedicated,
			}
			device.stats.memory_allocations += 1
			device.stats.reserved_bytes += block.size
			properties := device.memory_properties.memoryTypes[type].propertyFlags
			if !is_image &&
			   properties & {.HOST_VISIBLE, .HOST_COHERENT} == {.HOST_VISIBLE, .HOST_COHERENT} {
				result = vk_result(
					device,
					vk.MapMemory(
						device.device,
						memory,
						0,
						vk.DeviceSize(vk.WHOLE_SIZE),
						{},
						&block.mapped,
					),
					.NO_MEMORY,
				)
				if result != .NONE do release_block(device, block)
			}
		}
		offset, previous = 0, 0
	}
	if result == .NONE {
		slot := device.free_allocation
		entry := &device.allocations[slot - 1]
		device.free_allocation = entry.next
		block := &device.memory_blocks[index]
		link := previous != 0 ? &device.allocations[previous - 1].next : &block.first
		entry^ = {offset, requirements.size, index + 1, link^}
		link^ = slot
		block.live_allocations += 1
		allocation^ = slot
	}
	return result
}
@(private = "package")
memory_release :: proc(device: ^Device, allocation: u32) {
	if allocation == 0 || allocation > MAX_ALLOCATIONS do return
	entry := &device.allocations[allocation - 1]
	if entry.block == 0 do return
	block := &device.memory_blocks[entry.block - 1]
	link := &block.first
	for link^ != 0 && link^ != allocation do link = &device.allocations[link^ - 1].next
	if link^ == allocation do link^ = entry.next
	block.live_allocations -= 1
	if block.dedicated do release_block(device, block)
	entry^ = {
		next = device.free_allocation,
	}
	device.free_allocation = allocation
}

create_buffer :: proc(device: ^Device, desc: Buffer_Desc, out: ^Buffer) -> Result {
	if device == nil do return .NO_DEVICE
	if out == nil ||
	   out.buffer != 0 ||
	   desc.size == 0 ||
	   desc.usage == {} ||
	   (desc.memory != .UPLOAD && desc.memory != .DEVICE && desc.memory != .READBACK) ||
	   (desc.memory != .DEVICE && desc.size > vk.DeviceSize(max(int))) ||
	   (.SHADER_DEVICE_ADDRESS in desc.usage &&
			   !device.enabled.buffer_device_address) {return .ERROR_INVALID_ARGUMENT}
	buffer: Buffer
	info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = desc.size,
		usage = desc.usage,
	}
	result := vk_result(
		device,
		vk.CreateBuffer(device.device, &info, nil, &buffer.buffer),
		.ERROR_RESOURCE,
	)
	if result == .NONE {
		dedicated := vk.MemoryDedicatedRequirements {
			sType = .MEMORY_DEDICATED_REQUIREMENTS,
		}
		requirements := vk.MemoryRequirements2 {
			sType = .MEMORY_REQUIREMENTS_2,
			pNext = &dedicated,
		}
		query := vk.BufferMemoryRequirementsInfo2 {
			sType  = .BUFFER_MEMORY_REQUIREMENTS_INFO_2,
			buffer = buffer.buffer,
		}
		vk.GetBufferMemoryRequirements2(device.device, &query, &requirements)
		result = memory_acquire(
			device,
			&requirements.memoryRequirements,
			desc.memory,
			buffer.buffer,
			0,
			bool(dedicated.requiresDedicatedAllocation),
			&buffer.allocation,
		)
	}
	if result == .NONE {
		entry := &device.allocations[buffer.allocation - 1]
		block := &device.memory_blocks[entry.block - 1]
		if block.mapped != nil do buffer.mapped = mem.ptr_offset(([^]byte)(block.mapped), int(entry.offset))
		result = vk_result(
			device,
			vk.BindBufferMemory(device.device, buffer.buffer, block.memory, entry.offset),
			.NO_DEVICE_MEM,
		)
	}
	if result == .NONE {
		buffer.owner, buffer.size, buffer.usage = device.device, desc.size, desc.usage
		if .SHADER_DEVICE_ADDRESS in desc.usage {
			address := vk.BufferDeviceAddressInfo {
				sType  = .BUFFER_DEVICE_ADDRESS_INFO,
				buffer = buffer.buffer,
			}
			buffer.address = vk.GetBufferDeviceAddress(device.device, &address)
		}
		out^ = buffer
		device.live_objects += 1
	} else {vk.DestroyBuffer(device.device, buffer.buffer, nil)
		memory_release(device, buffer.allocation)}
	return result
}
destroy_buffer :: proc(device: ^Device, buffer: ^Buffer) -> Result {
	if device == nil do return .NO_DEVICE
	if buffer == nil || (buffer.owner != nil && buffer.owner != device.device) do return .ERROR_INVALID_ARGUMENT
	if buffer.buffer !=
	   0 {vk.DestroyBuffer(device.device, buffer.buffer, nil); memory_release(device, buffer.allocation); device.live_objects -= 1}
	buffer^ = {}
	return .NONE
}
write_buffer :: proc(
	device: ^Device,
	buffer: ^Buffer,
	offset: vk.DeviceSize,
	data: []byte,
) -> Result {
	if device == nil do return .NO_DEVICE
	if buffer == nil || raw_data(data) == nil || buffer.owner != device.device || buffer.buffer == 0 do return .ERROR_INVALID_ARGUMENT
	if offset > buffer.size || vk.DeviceSize(len(data)) > buffer.size - offset || offset > vk.DeviceSize(max(int)) do return .OUT_OF_RANGE
	if buffer.mapped == nil do return .NO_MAPPEABLE
	mem.copy(mem.ptr_offset(([^]byte)(buffer.mapped), int(offset)), raw_data(data), len(data))
	return .NONE
}

@(private = "package")
format_bytes :: proc(format: vk.Format) -> u32 {
	#partial switch format {
	case .R8_UNORM, .R8_UINT:
		return 1
	case .R8G8_UNORM, .R16_UNORM, .R16_SFLOAT:
		return 2
	case .R8G8B8A8_UNORM,
	     .B8G8R8A8_UNORM,
	     .R8G8B8A8_SRGB,
	     .B8G8R8A8_SRGB,
	     .R16G16_SFLOAT,
	     .R32_SFLOAT,
	     .R32_UINT:
		return 4
	case .R16G16B16A16_SFLOAT, .R32G32_SFLOAT:
		return 8
	case .R32G32B32_SFLOAT:
		return 12
	case .R32G32B32A32_SFLOAT:
		return 16
	case:
		return 0
	}
}
@(private = "package")
format_aspects :: proc(format: vk.Format) -> vk.ImageAspectFlags {
	#partial switch format {
	case .D16_UNORM, .X8_D24_UNORM_PACK32, .D32_SFLOAT:
		return {.DEPTH}
	case .S8_UINT:
		return {.STENCIL}
	case .D16_UNORM_S8_UINT, .D24_UNORM_S8_UINT, .D32_SFLOAT_S8_UINT:
		return {.DEPTH, .STENCIL}
	case:
		return {.COLOR}
	}
}
create_texture :: proc(device: ^Device, desc: Texture_Desc, out: ^Texture) -> Result {
	if device == nil do return .NO_DEVICE
	if out == nil ||
	   out.image != 0 ||
	   desc.width == 0 ||
	   desc.height == 0 ||
	   desc.format == .UNDEFINED ||
	   desc.usage == {} ||
	   desc.usage &
			   ~(vk.ImageUsageFlags {
						   .SAMPLED,
						   .STORAGE,
						   .COLOR_ATTACHMENT,
						   .DEPTH_STENCIL_ATTACHMENT,
						   .TRANSFER_SRC,
						   .TRANSFER_DST,
					   }) !=
		   {} ||
	   desc.usage & {.SAMPLED, .STORAGE, .COLOR_ATTACHMENT, .DEPTH_STENCIL_ATTACHMENT} ==
		   {} {return .ERROR_INVALID_ARGUMENT}
	mips := max(desc.mip_levels, 1)
	max_mips: u32 = 1
	for dimension := max(desc.width, desc.height); dimension > 1; dimension >>= 1 {max_mips += 1}
	if mips > max_mips do return .OUT_OF_RANGE
	properties: vk.ImageFormatProperties
	supported := vk.GetPhysicalDeviceImageFormatProperties(
		device.physical_device,
		desc.format,
		.D2,
		.OPTIMAL,
		desc.usage,
		{},
		&properties,
	)
	if supported != .SUCCESS do return vk_result(device, supported, .UNSUPPORTED)
	if desc.width > properties.maxExtent.width || desc.height > properties.maxExtent.height || mips > properties.maxMipLevels do return .OUT_OF_RANGE
	texture := Texture {
		format     = desc.format,
		extent     = {desc.width, desc.height, 1},
		usage      = desc.usage,
		mip_levels = mips,
		aspects    = format_aspects(desc.format),
	}
	info := vk.ImageCreateInfo {
		sType       = .IMAGE_CREATE_INFO,
		imageType   = .D2,
		format      = texture.format,
		extent      = texture.extent,
		mipLevels   = mips,
		arrayLayers = 1,
		samples     = {._1},
		tiling      = .OPTIMAL,
		usage       = desc.usage,
	}
	result := vk_result(
		device,
		vk.CreateImage(device.device, &info, nil, &texture.image),
		.ERROR_RESOURCE,
	)
	if result == .NONE {
		dedicated := vk.MemoryDedicatedRequirements {
			sType = .MEMORY_DEDICATED_REQUIREMENTS,
		}
		requirements := vk.MemoryRequirements2 {
			sType = .MEMORY_REQUIREMENTS_2,
			pNext = &dedicated,
		}
		query := vk.ImageMemoryRequirementsInfo2 {
			sType = .IMAGE_MEMORY_REQUIREMENTS_INFO_2,
			image = texture.image,
		}
		vk.GetImageMemoryRequirements2(device.device, &query, &requirements)
		result = memory_acquire(
			device,
			&requirements.memoryRequirements,
			.DEVICE,
			0,
			texture.image,
			bool(dedicated.requiresDedicatedAllocation),
			&texture.allocation,
		)
	}
	if result == .NONE {
		entry := &device.allocations[texture.allocation - 1]
		result = vk_result(
			device,
			vk.BindImageMemory(
				device.device,
				texture.image,
				device.memory_blocks[entry.block - 1].memory,
				entry.offset,
			),
			.NO_DEVICE_MEM,
		)
	}
	if result == .NONE {
		view := vk.ImageViewCreateInfo {
			sType            = .IMAGE_VIEW_CREATE_INFO,
			image            = texture.image,
			viewType         = .D2,
			format           = texture.format,
			subresourceRange = {texture.aspects, 0, mips, 0, 1},
		}
		result = vk_result(
			device,
			vk.CreateImageView(device.device, &view, nil, &texture.view),
			.ERROR_RESOURCE,
		)
	}
	if result == .NONE {texture.owner = device.device; out^ = texture; device.live_objects += 1
	} else {vk.DestroyImage(device.device, texture.image, nil)
		memory_release(device, texture.allocation)}
	return result
}
destroy_texture :: proc(device: ^Device, texture: ^Texture) -> Result {
	if device == nil do return .NO_DEVICE
	if texture == nil || (texture.owner != nil && texture.owner != device.device) || (texture.image != 0 && texture.allocation == 0) do return .ERROR_INVALID_ARGUMENT
	if texture.image != 0 {
		vk.DestroyImageView(device.device, texture.view, nil)
		vk.DestroyImage(device.device, texture.image, nil)
		memory_release(device, texture.allocation)
		device.live_objects -= 1
	}
	texture^ = {}
	return .NONE
}
