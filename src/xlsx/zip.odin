package xlsx

import "core:bytes"
import "core:compress/zlib"
import "core:hash"

// Declared sizes above this are refused before anything is inflated.
MAX_ENTRY_SIZE :: 512 * 1024 * 1024

Zip_Entry :: struct {
	name: string, // Borrows the archive bytes.
	flags, method: u16,
	crc: u32,
	compressed_size, size, header_offset: u64,
}

// A read-only view of an in-memory ZIP archive. Entry names borrow `data`,
// so the archive bytes must outlive the Zip.
Zip :: struct {
	data: []u8,
	entries: [dynamic]Zip_Entry,
}

@(private)
u16le :: proc(b: []u8, at: int) -> u16 {
	if at < 0 || at + 2 > len(b) do return 0
	return u16(b[at]) | u16(b[at + 1]) << 8
}

@(private)
u32le :: proc(b: []u8, at: int) -> u32 {
	if at < 0 || at + 4 > len(b) do return 0
	return u32(u16le(b, at)) | u32(u16le(b, at + 2)) << 16
}

@(private)
u64le :: proc(b: []u8, at: int) -> u64 {
	if at < 0 || at + 8 > len(b) do return 0
	return u64(u32le(b, at)) | u64(u32le(b, at + 4)) << 32
}

zip_destroy :: proc(z: ^Zip) {
	delete(z.entries)
	z^ = {}
}

// Reads the central directory (including ZIP64). Returns "" on success.
zip_open :: proc(z: ^Zip, data: []u8) -> string {
	z.data = data
	if len(data) < 22 do return "not a ZIP archive"
	eocd := -1
	lowest := max(0, len(data) - 22 - 65535) // The archive comment is at most 64 KiB.
	for i := len(data) - 22; i >= lowest; i -= 1 {
		if u32le(data, i) == 0x06054b50 {
			eocd = i
			break
		}
	}
	if eocd < 0 do return "not a ZIP archive"
	count := u64(u16le(data, eocd + 10))
	cd_size := u64(u32le(data, eocd + 12))
	cd_offset := u64(u32le(data, eocd + 16))
	if count == 0xFFFF || cd_size == 0xFFFFFFFF || cd_offset == 0xFFFFFFFF {
		locator := eocd - 20
		if u32le(data, locator) != 0x07064b50 do return "damaged ZIP64 archive"
		record := u64le(data, locator + 8)
		if record > u64(len(data)) || u32le(data, int(record)) != 0x06064b50 do return "damaged ZIP64 archive"
		count = u64le(data, int(record) + 32)
		cd_size = u64le(data, int(record) + 40)
		cd_offset = u64le(data, int(record) + 48)
	}
	if cd_offset > u64(len(data)) || cd_size > u64(len(data)) - cd_offset do return "damaged ZIP archive"
	end := int(cd_offset + cd_size)
	p := int(cd_offset)
	for _ in 0..<count {
		if p + 46 > end || u32le(data, p) != 0x02014b50 do return "damaged ZIP central directory"
		e := Zip_Entry{
			flags = u16le(data, p + 8), method = u16le(data, p + 10), crc = u32le(data, p + 16),
			compressed_size = u64(u32le(data, p + 20)), size = u64(u32le(data, p + 24)),
			header_offset = u64(u32le(data, p + 42)),
		}
		name_len, extra_len, comment_len := int(u16le(data, p + 28)), int(u16le(data, p + 30)), int(u16le(data, p + 32))
		next := p + 46 + name_len + extra_len + comment_len
		if next > end do return "damaged ZIP central directory"
		e.name = string(data[p + 46:][:name_len])
		extra := data[p + 46 + name_len:][:extra_len]
		for q := 0; q + 4 <= len(extra); {
			id, size := u16le(extra, q), int(u16le(extra, q + 2))
			if q + 4 + size > len(extra) do break
			if id == 0x0001 { // ZIP64: only the overflowing fields are present, in this order.
				f, stop := q + 4, q + 4 + size
				if e.size == 0xFFFFFFFF && f + 8 <= stop { e.size = u64le(extra, f); f += 8 }
				if e.compressed_size == 0xFFFFFFFF && f + 8 <= stop { e.compressed_size = u64le(extra, f); f += 8 }
				if e.header_offset == 0xFFFFFFFF && f + 8 <= stop { e.header_offset = u64le(extra, f) }
			}
			q += 4 + size
		}
		append(&z.entries, e)
		p = next
	}
	return ""
}

// Finds an entry ignoring ASCII case and treating '\' as '/', since some
// writers differ from the paths the package relationships name.
zip_find :: proc(z: ^Zip, name: string) -> (^Zip_Entry, bool) {
	norm :: proc(ch: u8) -> u8 {
		if ch == '\\' do return '/'
		if ch >= 'A' && ch <= 'Z' do return ch + 32
		return ch
	}
	outer: for &e in z.entries {
		if len(e.name) != len(name) do continue
		for i in 0..<len(name) do if norm(e.name[i]) != norm(name[i]) do continue outer
		return &e, true
	}
	return nil, false
}

// Returns the entry's uncompressed bytes (owned by the caller), verified with CRC-32.
zip_read :: proc(z: ^Zip, e: ^Zip_Entry, allocator := context.allocator) -> ([]u8, string) {
	context.allocator = allocator
	if e.flags & 1 != 0 do return nil, "the workbook is password-protected or encrypted"
	if e.size > MAX_ENTRY_SIZE do return nil, "a part of the workbook is too large to read"
	h := e.header_offset
	if h > u64(len(z.data)) || u32le(z.data, int(h)) != 0x04034b50 do return nil, "damaged ZIP entry"
	start := u64(int(h) + 30 + int(u16le(z.data, int(h) + 26)) + int(u16le(z.data, int(h) + 28)))
	if start > u64(len(z.data)) || e.compressed_size > u64(len(z.data)) - start do return nil, "damaged ZIP entry"
	raw := z.data[start:][:e.compressed_size]
	out: []u8
	switch e.method {
	case 0:
		if u64(len(raw)) != e.size do return nil, "damaged ZIP entry"
		out = make([]u8, len(raw))
		copy(out, raw)
	case 8:
		buf: bytes.Buffer
		if zlib.inflate_from_byte_array_raw(raw, &buf, expected_output_size = int(e.size)) != nil || u64(len(buf.buf)) != e.size {
			bytes.buffer_destroy(&buf)
			return nil, "damaged compressed data in the workbook"
		}
		out = buf.buf[:]
	case:
		return nil, "the workbook uses an unsupported ZIP compression method"
	}
	if hash.crc32(out) != e.crc {
		delete(out)
		return nil, "damaged ZIP entry (checksum mismatch)"
	}
	return out, ""
}
