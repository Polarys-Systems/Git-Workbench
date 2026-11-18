package xlsx

// Minimal ZIP writer (stored entries only), used by tests to build workbooks.

import "core:bytes"
import "core:hash"

Zip_Part :: struct {
	name: string,
	data: string,
}

// Builds an uncompressed ZIP archive (owned by the caller). Used to create
// workbooks in tests; `flags` is applied to every entry.
zip_write_stored :: proc(parts: []Zip_Part, flags: u16 = 0, allocator := context.allocator) -> []u8 {
	put16 :: proc(b: ^bytes.Buffer, v: u16) { bytes.buffer_write(b, {u8(v), u8(v >> 8)}) }
	put32 :: proc(b: ^bytes.Buffer, v: u32) { put16(b, u16(v)); put16(b, u16(v >> 16)) }
	out, central: bytes.Buffer
	bytes.buffer_init_allocator(&out, 0, 0, allocator)
	defer bytes.buffer_destroy(&central)
	for part in parts {
		offset := u32(bytes.buffer_length(&out))
		crc := hash.crc32(transmute([]u8)part.data)
		put32(&out, 0x04034b50); put16(&out, 20); put16(&out, flags); put16(&out, 0)
		put32(&out, 0); put32(&out, crc); put32(&out, u32(len(part.data))); put32(&out, u32(len(part.data)))
		put16(&out, u16(len(part.name))); put16(&out, 0)
		bytes.buffer_write_string(&out, part.name)
		bytes.buffer_write_string(&out, part.data)
		put32(&central, 0x02014b50); put16(&central, 20); put16(&central, 20); put16(&central, flags); put16(&central, 0)
		put32(&central, 0); put32(&central, crc); put32(&central, u32(len(part.data))); put32(&central, u32(len(part.data)))
		put16(&central, u16(len(part.name))); put16(&central, 0); put16(&central, 0); put16(&central, 0); put16(&central, 0)
		put32(&central, 0); put32(&central, offset)
		bytes.buffer_write_string(&central, part.name)
	}
	cd_offset := u32(bytes.buffer_length(&out))
	bytes.buffer_write(&out, bytes.buffer_to_bytes(&central))
	put32(&out, 0x06054b50); put16(&out, 0); put16(&out, 0); put16(&out, u16(len(parts))); put16(&out, u16(len(parts)))
	put32(&out, u32(bytes.buffer_length(&central))); put32(&out, cd_offset); put16(&out, 0)
	return out.buf[:]
}
