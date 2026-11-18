package app

// GPU text and shape batch: glyph atlas cache, vertex buffer and the pipeline
// that draws everything the UI produces in a single pass.

import "base:runtime"
import "core:math"
import "core:mem"

import vk "vendor:vulkan"

import "../font"
import "../gpu"

Text_Vertex :: struct {
	pos:   [2]f32,
	uv:    [2]f32,
	color: [4]f32,
	line:  [4]f32, // Physical-pixel endpoints, used only when uv.x is negative.
}

Text_Push_Constants :: struct {
	buffer_address: u64,
	viewport_size: [2]f32,
}

// Keep these in sync with the std430 buffer reference and push constants in
// ui_rect.vert. No scalar-block-layout or shaderInt64 feature is required.
#assert(size_of(Text_Vertex) == 48)
#assert(offset_of(Text_Vertex, pos) == 0)
#assert(offset_of(Text_Vertex, uv) == 8)
#assert(offset_of(Text_Vertex, color) == 16)
#assert(offset_of(Text_Vertex, line) == 32)
#assert(size_of(Text_Push_Constants) == 16)
#assert(offset_of(Text_Push_Constants, viewport_size) == 8)

Cached_Glyph :: struct {
	using info: font.Glyph_Info,
	uv_min, uv_max: [2]f32,
}

Pending_Glyph_Upload :: struct {
	data_offset, data_size: int,
	rect: vk.Rect2D, // Includes the transparent border.
}

Glyph_Cache_Key :: struct {
	face: ^font.Face,
	size_64: u32,
	glyph_idx: i32,
}

// Owns its CPU arrays and GPU resources. Keep its address stable from upload
// staging through GPU completion; font faces are borrowed and must stay alive.
// Per frame: draw_text calls -> text_prepare_render -> text_render -> submit.
// Submit that rendering before preparing the next frame with this batch.
Text_Batch :: struct {
	vertex_buffer: gpu.Buffer,
	upload_batch: ^gpu.Upload_Batch,
	atlas_texture: gpu.Texture,
	pipeline: gpu.Pipeline,
	binding_layout: ^gpu.Binding_Layout,
	sampler: gpu.Sampler,
	resources: gpu.Binding_Set,
	glyphs: map[Glyph_Cache_Key]Cached_Glyph,
	pending_pixels: [dynamic]u8, // Concatenated upload payloads, not an atlas mirror.
	pending_glyph_uploads: [dynamic]Pending_Glyph_Upload,
	vertices: [dynamic]Text_Vertex,
	prepared_vertex_count: u32,
	atlas_width, atlas_height: u32,
	atlas_cursor_x, atlas_cursor_y, atlas_row_bottom: u32,
	white_uv: [2]f32,
	white_cached: bool,
	clip_enabled: bool,
	clip_min, clip_max: [2]f32,
	allocator: runtime.Allocator,
}

MAX_TEXT_VERTEX_BYTES :: 2 << 20
TEXT_ATLAS_WIDTH :: 1080
TEXT_ATLAS_HEIGHT :: 1080
TEXT_ATLAS_PADDING :: 1

init_text_batch :: proc(device: ^gpu.Device, color_format: vk.Format, allocator := context.allocator) -> Text_Batch {
	vertex_buffer: gpu.Buffer
	buffer_result := gpu.create_buffer(
		device, gpu.Buffer_Desc {
			size = MAX_TEXT_VERTEX_BYTES,
			usage = {.STORAGE_BUFFER, .TRANSFER_DST, .SHADER_DEVICE_ADDRESS},
			memory = .DEVICE
		},
		&vertex_buffer
	)
	assert(buffer_result == .NONE, gpu.result_string(buffer_result))
	assert(vertex_buffer.address != 0 && vertex_buffer.address % 16 == 0, "Text vertices require an aligned buffer device address")

	// Packed atlas rectangles cannot total more than the atlas area. Allow
	// additional space for the full vertex buffer and per-upload alignment.
	upload_batch, res := gpu.create_upload_batch(
		device, MAX_TEXT_VERTEX_BYTES + TEXT_ATLAS_WIDTH * TEXT_ATLAS_HEIGHT + 4 * gpu.MAX_UPLOADS,
	)
	assert(res == .NONE)

	atlas_texture: gpu.Texture
	atlas_desc := gpu.Texture_Desc {
		width = TEXT_ATLAS_WIDTH,
		height = TEXT_ATLAS_HEIGHT,
		format = .R8_UNORM,
		usage = {.SAMPLED, .TRANSFER_DST},
		mip_levels = 0
	}
	text_result := gpu.create_texture(device, atlas_desc, &atlas_texture)
	assert(text_result == .NONE, gpu.result_string(text_result))

	pipeline, binding_layout := create_text_pipeline(device, color_format)
	sampler: gpu.Sampler
	sampler_result := gpu.create_sampler(device, nil, &sampler)
	assert(sampler_result == .NONE, gpu.result_string(sampler_result))
	resources: gpu.Binding_Set
	resource_result := gpu.create_resources(device, binding_layout, &resources)
	assert(resource_result == .NONE, gpu.result_string(resource_result))
	resource_result = gpu.update_resources(device, []gpu.Binding_Write{
		{
			set = &resources,
			binding = 0,
			values = []gpu.Binding_Value{
				{texture = &atlas_texture, sampler = &sampler, image_layout = .SHADER_READ_ONLY_OPTIMAL},
			},
		},
	})
	assert(resource_result == .NONE, gpu.result_string(resource_result))

	return Text_Batch {
		vertex_buffer = vertex_buffer,
		upload_batch = upload_batch,
		atlas_texture = atlas_texture,
		pipeline = pipeline,
		binding_layout = binding_layout,
		sampler = sampler,
		resources = resources,
		glyphs = make(map[Glyph_Cache_Key]Cached_Glyph, allocator),
		pending_pixels = make([dynamic]u8, 0, TEXT_ATLAS_WIDTH * TEXT_ATLAS_HEIGHT, allocator),
		pending_glyph_uploads = make([dynamic]Pending_Glyph_Upload, 0, 64, allocator),
		vertices = make([dynamic]Text_Vertex, 0, 256, allocator),
		atlas_height = TEXT_ATLAS_HEIGHT,
		atlas_width = TEXT_ATLAS_WIDTH,
		allocator = allocator,
	}
}

// The caller owns both objects; destroy the pipeline before its binding layout.
@(private = "package")
create_text_pipeline :: proc(device: ^gpu.Device, color_format: vk.Format) -> (gpu.Pipeline, ^gpu.Binding_Layout) {

	binding_layout, binding_result := gpu.create_binding_layout(device, []gpu.Binding_Desc{
		gpu.Binding_Desc{0, .COMBINED_IMAGE_SAMPLER, {.FRAGMENT}, 1}
	})
	assert(binding_result == .NONE, gpu.result_string(binding_result))

	all_bindings := []^gpu.Binding_Layout{binding_layout}
	color_target := gpu.color_target_default(color_format)
	color_target.blend.blendEnable = true
	color_target.blend.srcColorBlendFactor = .ONE
	color_target.blend.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA
	color_target.blend.srcAlphaBlendFactor = .ONE
	color_target.blend.dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA

	pipe_desc := gpu.Pipeline_Desc {
		vertex_spirv = #load("../../shaders/ui_rect.vert.spv"),
		fragment_spirv = #load("../../shaders/ui_rect.frag.spv"),
		vertex_entry = "main",
		fragment_entry = "main",
		colors = []gpu.Color_Target{color_target},
		layouts = all_bindings,
		push_ranges = []vk.PushConstantRange{{stageFlags = {.VERTEX}, offset = 0, size = size_of(Text_Push_Constants)}}
	}
	pipeline : gpu.Pipeline
	result := gpu.create_pipeline(device, pipe_desc, &pipeline)
	assert(result == .NONE, gpu.result_string(result))

	return pipeline, binding_layout
}

// Queues pixel-aligned glyph quads; size_px is the pixel em size and pos is the
// top-left, both in physical render-target pixels.
// On failure, geometry from this call is rolled back. Successfully cached glyphs
// and their pending uploads remain reusable. Faces must stay alive and unchanged
// until their cache entries are discarded.
draw_text :: proc(batch: ^Text_Batch, face: ^font.Face, text: string, pos: [2]f32, color: [4]f32, size_px: f32) -> (ok: bool) {
	if batch == nil || face == nil || size_px <= 0 || math.is_nan(size_px) || math.is_inf(size_px) {
		return false
	}

	scaled_size := f64(size_px) * 64.0
	if scaled_size > f64(max(u32)) {
		return false
	}
	size_64 := u32(max(scaled_size, 1.0))
	metrics := font.line_metrics(face, size_64)

	// Interpret pos as the top-left; glyph offsets use a baseline.
	pen := [2]f32{pos[0], pos[1] + metrics.ascent}
	first_vertex := len(batch.vertices)
	defer if !ok do resize(&batch.vertices, first_vertex)

	for r in text {
		if r == '\r' {
			continue
		}
		if r == '\n' {
			pen[0] = pos[0]
			pen[1] += metrics.line_height
			continue
		}
		// Long documents: lines wholly outside the clip produce no quads, so
		// skip their glyph lookups, and stop below the clip.
		if batch.clip_enabled {
			top := pen[1] - metrics.ascent
			if top >= batch.clip_max[1] do break
			if top + metrics.line_height <= batch.clip_min[1] do continue
		}
		if r == '\t' {
			pen[0] = pos[0] + next_tab_stop(face, size_64, pen[0] - pos[0])
			continue
		}

		glyph_idx, found := font.glyph_index(face, r)
		if !found {
			glyph_idx, found = font.glyph_index(face, '?')
			if !found {
				continue
			}
		}

		glyph, cached := get_or_cache_glyph(batch, face, size_64, glyph_idx)
		if !cached {
			return false
		}

		if glyph.width > 0 && glyph.height > 0 {
			// Match bitmap texels to screen pixels without rounding advances:
			// snapping the pen itself would accumulate spacing errors.
			p0 := [2]f32{
				math.round(pen[0] + glyph.xoff),
				math.round(pen[1] + glyph.yoff),
			}
			p1 := [2]f32{
				p0[0] + f32(glyph.width),
				p0[1] + f32(glyph.height),
			}

			appended := append_draw_quad(
				batch, p0, p1,
				glyph.uv_min, glyph.uv_max,
				color, color,
			)
			if !appended {
				return false
			}
		}

		// Spaces advance the pen even though they have no pixels.
		pen[0] += glyph.advance_x
	}
	return true
}

get_or_cache_glyph :: proc(batch: ^Text_Batch, face: ^font.Face, size_64: u32, glyph_idx: i32) -> (Cached_Glyph, bool) {
	if batch == nil || face == nil || size_64 == 0 || glyph_idx <= 0 ||
	   batch.atlas_width == 0 || batch.atlas_height == 0 ||
	   batch.atlas_width > u32(max(i32)) || batch.atlas_height > u32(max(i32)) {
		return {}, false
	}
	key := Glyph_Cache_Key{face, size_64, glyph_idx}
	if glyph, found := batch.glyphs[key]; found {
		return glyph, true
	}
	return cache_glyph(batch, key)
}

@(private = "package")
Atlas_Placement :: struct {
	rect: vk.Rect2D,
	cursor_x, cursor_y, row_bottom: u32,
}

// Calculate a shelf placement without consuming atlas space. width/height
// include padding; the caller commits the proposed cursor only after caching.
@(private = "package")
atlas_find_space :: proc(batch: ^Text_Batch, width, height: u32) -> (Atlas_Placement, bool) {
	if width == 0 || height == 0 || width > batch.atlas_width || height > batch.atlas_height {
		return {}, false
	}
	x, y := batch.atlas_cursor_x, batch.atlas_cursor_y
	if x > batch.atlas_width || width > batch.atlas_width - x {
		x = 0
		y = batch.atlas_row_bottom
	}
	if y > batch.atlas_height || height > batch.atlas_height - y {
		return {}, false
	}
	return Atlas_Placement{
		rect = {{i32(x), i32(y)}, {width, height}},
		cursor_x = x + width,
		cursor_y = y,
		row_bottom = max(batch.atlas_row_bottom, y + height),
	}, true
}

@(private = "package")
cache_glyph :: proc(batch: ^Text_Batch, key: Glyph_Cache_Key) -> (Cached_Glyph, bool) {
	bitmap, rasterized := font.rasterize_glyph(key.face, key.size_64, key.glyph_idx, batch.allocator)
	if !rasterized do return {}, false
	defer delete(bitmap.pixels, batch.allocator)

	glyph := Cached_Glyph{info = bitmap.info}
	has_pixels := bitmap.width > 0 && bitmap.height > 0
	placement: Atlas_Placement
	pixel_count := len(batch.pending_pixels)
	upload_count := len(batch.pending_glyph_uploads)
	if has_pixels {
		placed: bool
		placement, placed = atlas_find_space(
			batch, u32(bitmap.width) + 2 * TEXT_ATLAS_PADDING,
			u32(bitmap.height) + 2 * TEXT_ATLAS_PADDING,
		)
		if !placed do return {}, false
		if !queue_glyph_upload(batch, &bitmap, placement.rect) do return {}, false

		left := u32(placement.rect.offset.x) + TEXT_ATLAS_PADDING
		top := u32(placement.rect.offset.y) + TEXT_ATLAS_PADDING
		glyph.uv_min = {f32(left) / f32(batch.atlas_width), f32(top) / f32(batch.atlas_height)}
		glyph.uv_max = {
			f32(left + u32(bitmap.width)) / f32(batch.atlas_width),
			f32(top + u32(bitmap.height)) / f32(batch.atlas_height),
		}
	}

	// Publish only a completed entry. Map allocation failure leaves neither
	// pending uploads nor occupied atlas space, so the next call can retry.
	_, entry, _, err := map_entry(&batch.glyphs, key)
	if err != nil {
		resize(&batch.pending_pixels, pixel_count)
		resize(&batch.pending_glyph_uploads, upload_count)
		return {}, false
	}
	entry^ = glyph
	if has_pixels {
		batch.atlas_cursor_x = placement.cursor_x
		batch.atlas_cursor_y = placement.cursor_y
		batch.atlas_row_bottom = placement.row_bottom
	}
	// Spaces retain their advances but need no atlas space or upload.
	return glyph, true
}

// Append one tightly packed rectangle with a transparent one-pixel border.
// Keep both queues unchanged if either append fails.
@(private = "package")
queue_glyph_upload :: proc(batch: ^Text_Batch, bitmap: ^font.Glyph_Bitmap, rect: vk.Rect2D) -> (ok: bool) {
	width, height := int(rect.extent.width), int(rect.extent.height)
	pixels, alloc_err := make([]byte, width * height, batch.allocator)
	if alloc_err != nil do return false
	defer delete(pixels, batch.allocator)
	for row in 0..<int(bitmap.height) {
		src := row * int(bitmap.width)
		dst := (row + TEXT_ATLAS_PADDING) * width + TEXT_ATLAS_PADDING
		copy(pixels[dst:dst + int(bitmap.width)], bitmap.pixels[src:src + int(bitmap.width)])
	}
	data_offset := len(batch.pending_pixels)
	upload_count := len(batch.pending_glyph_uploads)
	defer if !ok {
		resize(&batch.pending_pixels, data_offset)
		resize(&batch.pending_glyph_uploads, upload_count)
	}
	_, pixel_err := append(&batch.pending_pixels, ..pixels)
	if pixel_err != nil do return false
	_, upload_err := append(&batch.pending_glyph_uploads, Pending_Glyph_Upload{
		data_offset = data_offset,
		data_size = len(pixels),
		rect = rect,
	})
	return upload_err == nil
}

// Clip geometry and UVs on the CPU, keeping all UI elements in one draw call.
append_draw_quad :: proc(
	batch: ^Text_Batch,
	p0, p1, uv_min, uv_max: [2]f32,
	color_top, color_bottom: [4]f32,
	line: [4]f32 = {},
) -> bool {
	if batch == nil do return false
	lo, hi := p0, p1
	uv0, uv1 := uv_min, uv_max
	top, bottom := color_top, color_bottom
	if batch.clip_enabled {
		lo = {max(lo.x, batch.clip_min.x), max(lo.y, batch.clip_min.y)}
		hi = {min(hi.x, batch.clip_max.x), min(hi.y, batch.clip_max.y)}
	}
	if hi.x <= lo.x || hi.y <= lo.y do return true
	if batch.clip_enabled {
		t0, t1 := (lo - p0) / (p1 - p0), (hi - p0) / (p1 - p0)
		uv0 = uv_min + (uv_max - uv_min) * t0
		uv1 = uv_min + (uv_max - uv_min) * t1
		top = color_top + (color_bottom - color_top) * t0.y
		bottom = color_top + (color_bottom - color_top) * t1.y
	}
	if len(batch.vertices) > MAX_TEXT_VERTEX_BYTES / size_of(Text_Vertex) - 6 {
		return false
	}
	quad := [6]Text_Vertex{
		{lo, uv0, top, line},
		{{hi.x, lo.y}, {uv1.x, uv0.y}, top, line},
		{hi, uv1, bottom, line},
		{lo, uv0, top, line},
		{hi, uv1, bottom, line},
		{{lo.x, hi.y}, {uv0.x, uv1.y}, bottom, line},
	}
	_, err := append(&batch.vertices, ..quad[:])
	return err == nil
}

// Call after draw_text and before recording the rendering that consumes this
// batch. Submit previous rendering before overwriting this batch's GPU buffer.
// The batch's address must remain stable until its last GPU use completes.
// Successful preparation clears CPU queues but retains the caches and UVs.
// On failure the CPU queues remain available for retry; don't render that batch.
text_prepare_render :: proc(batch: ^Text_Batch) -> gpu.Result {
	if batch == nil || batch.upload_batch == nil {
		return .ERROR_INVALID_ARGUMENT
	}
	batch.prepared_vertex_count = 0
	vertex_bytes := mem.slice_to_bytes(batch.vertices[:])
	if vk.DeviceSize(len(vertex_bytes)) > batch.vertex_buffer.size {
		return .CAPACITY
	}
	upload_count := len(batch.pending_glyph_uploads)
	if upload_count == 0 && len(vertex_bytes) == 0 {
		return .NONE
	}
	// Reserve one record for vertices. Larger sets use multiple submissions;
	// wait only when reusing the single staging buffer between submissions.
	first := 0
	for {
		last := min(first + gpu.MAX_UPLOADS - 1, upload_count)
		last_batch := last == upload_count
		vertices: []byte
		if last_batch {
			vertices = vertex_bytes
		}
		result := text_submit_uploads(batch, batch.pending_glyph_uploads[first:last], vertices)
		if result != .NONE {
			return result
		}
		if last_batch {
			break
		}
		first = last
	}
	batch.prepared_vertex_count = u32(len(batch.vertices))
	clear(&batch.vertices)
	clear(&batch.pending_pixels)
	clear(&batch.pending_glyph_uploads)
	return .NONE
}

@(private = "file")
text_submit_uploads :: proc(batch: ^Text_Batch, uploads: []Pending_Glyph_Upload, vertices: []byte) -> gpu.Result {
	result := gpu.wait_uploads(batch.upload_batch)
	if result != .NONE do return result
	result = gpu.begin_uploads(batch.upload_batch)
	if result != .NONE do return result
	submitted := false
	defer if !submitted do gpu.cancel_uploads(batch.upload_batch)
	for upload in uploads {
		region := gpu.Texture_Upload{
			offset = upload.rect.offset,
			extent = upload.rect.extent,
			final_layout = .SHADER_READ_ONLY_OPTIMAL,
			consumer_stages = {.FRAGMENT_SHADER},
			consumer_access = {.SHADER_SAMPLED_READ},
		}
		result = gpu.upload_texture(
			batch.upload_batch, &batch.atlas_texture, &region,
			batch.pending_pixels[upload.data_offset:upload.data_offset + upload.data_size],
		)
		if result != .NONE do return result
	}
	if len(vertices) > 0 {
		result = gpu.upload_buffer(
			batch.upload_batch, &batch.vertex_buffer, 0, vertices,
			{.VERTEX_SHADER}, {.SHADER_STORAGE_READ},
		)
		if result != .NONE do return result
	}
	result = gpu.submit_uploads(batch.upload_batch)
	if result != .NONE do return result
	submitted = true
	return .NONE
}

// Record inside a rendering scope after text_prepare_render has submitted the
// uploads. Vertices are pulled through the pushed address, not a vertex binding
// or storage-buffer descriptor. extent is the render target's size in pixels.
text_render :: proc(batch: ^Text_Batch, command: ^gpu.Command, extent: vk.Extent2D) -> gpu.Result {
	if batch == nil || command == nil || extent.width == 0 || extent.height == 0 {
		return .ERROR_INVALID_ARGUMENT
	}
	if batch.prepared_vertex_count == 0 do return .NONE
	if batch.vertex_buffer.address == 0 || batch.vertex_buffer.address % 16 != 0 ||
	   u64(batch.prepared_vertex_count) * size_of(Text_Vertex) > u64(batch.vertex_buffer.size) ||
	   batch.atlas_texture.layout != .SHADER_READ_ONLY_OPTIMAL {
		return .ERROR_RESOURCE
	}
	result := gpu.bind_pipeline(command, &batch.pipeline)
	if result == .NONE do result = gpu.bind_resources(command, 0, &batch.resources)
	push := Text_Push_Constants{
		buffer_address = u64(batch.vertex_buffer.address),
		viewport_size = {f32(extent.width), f32(extent.height)},
	}
	if result == .NONE do result = gpu.push_constants(command, {.VERTEX}, 0, mem.byte_slice(&push, size_of(push)))
	if result == .NONE do result = gpu.draw(command, batch.prepared_vertex_count, 1, 0, 0)
	return result
}

// Faces are borrowed. Finish their batch's GPU work before destroying them.
destroy_text_batch :: proc(device: ^gpu.Device, batch: ^Text_Batch) -> gpu.Result {
	if device == nil || batch == nil do return .ERROR_INVALID_ARGUMENT
	wait_result := gpu.wait_idle(device)
	if wait_result != .NONE && wait_result != .DEVICE_LOST do return wait_result
	result := gpu.destroy_upload_batch(&batch.upload_batch)
	if result != .NONE && result != .DEVICE_LOST do return result
	result = gpu.destroy_resources(device, &batch.resources)
	if result != .NONE do return result
	result = gpu.destroy_sampler(device, &batch.sampler)
	if result != .NONE do return result
	result = gpu.destroy_pipeline(device, &batch.pipeline)
	if result != .NONE do return result
	result = gpu.destroy_binding_layout(device, &batch.binding_layout)
	if result != .NONE do return result
	result = gpu.destroy_texture(device, &batch.atlas_texture)
	if result != .NONE do return result
	result = gpu.destroy_buffer(device, &batch.vertex_buffer)
	if result != .NONE do return result
	delete(batch.glyphs)
	delete(batch.pending_pixels)
	delete(batch.pending_glyph_uploads)
	delete(batch.vertices)
	batch^ = {}
	return wait_result
}
