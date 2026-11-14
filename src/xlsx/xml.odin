package xlsx

import "core:strconv"
import "core:strings"

// A minimal streaming XML reader for the SpreadsheetML subset: elements,
// attributes, text and CDATA. Comments, processing instructions and DOCTYPE
// are skipped. Names are returned without their namespace prefix.
Xml_Kind :: enum { EOF, START, END, TEXT }

Xml :: struct {
	src: string,
	pos: int,
	kind: Xml_Kind,
	name: string,  // START/END: local name.
	attrs: string, // START: raw attribute text.
	text: string,  // TEXT: raw (undecoded unless cdata) text.
	cdata: bool,
	pending_end: bool, // A self-closing START is followed by a synthetic END.
	failed: bool,
}

@(private)
local_name :: proc(qname: string) -> string {
	if i := strings.last_index_byte(qname, ':'); i >= 0 do return qname[i + 1:]
	return qname
}

@(private)
is_space :: proc(ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'
}

// Advances to the next event; returns false at the end or on malformed input
// (check `failed`).
xml_next :: proc(x: ^Xml) -> bool {
	if x.pending_end {
		x.pending_end = false
		x.kind = .END
		return true
	}
	s := x.src
	for x.pos < len(s) {
		if s[x.pos] != '<' {
			end := strings.index_byte(s[x.pos:], '<')
			end = end < 0 ? len(s) : x.pos + end
			x.kind, x.text, x.cdata = .TEXT, s[x.pos:end], false
			x.pos = end
			return true
		}
		rest := s[x.pos:]
		switch {
		case strings.has_prefix(rest, "<!--"):
			end := strings.index(rest, "-->")
			if end < 0 do return xml_fail(x)
			x.pos += end + 3
		case strings.has_prefix(rest, "<![CDATA["):
			end := strings.index(rest, "]]>")
			if end < 0 do return xml_fail(x)
			x.kind, x.text, x.cdata = .TEXT, rest[9:end], true
			x.pos += end + 3
			return true
		case strings.has_prefix(rest, "<?"):
			end := strings.index(rest, "?>")
			if end < 0 do return xml_fail(x)
			x.pos += end + 2
		case strings.has_prefix(rest, "<!"):
			end := strings.index_byte(rest, '>')
			if end < 0 do return xml_fail(x)
			x.pos += end + 1
		case strings.has_prefix(rest, "</"):
			end := strings.index_byte(rest, '>')
			if end < 0 do return xml_fail(x)
			x.kind, x.name = .END, local_name(strings.trim_space(rest[2:end]))
			x.pos += end + 1
			return true
		case:
			// Find the closing '>' outside attribute quotes.
			quote: u8 = 0
			end := -1
			for i in 1..<len(rest) {
				ch := rest[i]
				if quote != 0 {
					if ch == quote do quote = 0
				} else if ch == '"' || ch == '\'' {
					quote = ch
				} else if ch == '>' {
					end = i
					break
				}
			}
			if end < 0 do return xml_fail(x)
			body := rest[1:end]
			empty := strings.has_suffix(body, "/")
			if empty do body = body[:len(body) - 1]
			n := 0
			for n < len(body) && !is_space(body[n]) do n += 1
			x.kind, x.name, x.attrs = .START, local_name(body[:n]), body[n:]
			x.pending_end = empty
			x.pos += end + 1
			return true
		}
	}
	x.kind = .EOF
	return false
}

@(private)
xml_fail :: proc(x: ^Xml) -> bool {
	x.failed = true
	x.kind = .EOF
	x.pos = len(x.src)
	return false
}

// Returns the raw (undecoded) value of the attribute whose local name matches.
xml_attr :: proc(x: ^Xml, name: string) -> (string, bool) {
	a := x.attrs
	i := 0
	for i < len(a) {
		for i < len(a) && is_space(a[i]) do i += 1
		start := i
		for i < len(a) && a[i] != '=' && !is_space(a[i]) do i += 1
		key := a[start:i]
		for i < len(a) && (is_space(a[i]) || a[i] == '=') do i += 1
		if i >= len(a) || (a[i] != '"' && a[i] != '\'') do return "", false
		quote := a[i]
		i += 1
		vstart := i
		for i < len(a) && a[i] != quote do i += 1
		value := a[vstart:min(i, len(a))]
		i += 1
		if key != "" && local_name(key) == name do return value, true
	}
	return "", false
}

// Appends text with XML entities decoded. With `excel`, the _xHHHH_ escapes
// Excel uses for control characters are decoded as well.
xml_decode :: proc(b: ^strings.Builder, raw: string, excel := false) {
	i := 0
	for i < len(raw) {
		ch := raw[i]
		if ch == '&' {
			end := strings.index_byte(raw[i:], ';')
			if end > 1 && end < 12 {
				entity := raw[i + 1:i + end]
				r: rune = -1
				switch entity {
				case "amp": r = '&'
				case "lt": r = '<'
				case "gt": r = '>'
				case "quot": r = '"'
				case "apos": r = '\''
				case:
					if strings.has_prefix(entity, "#x") || strings.has_prefix(entity, "#X") {
						if v, ok := strconv.parse_u64_of_base(entity[2:], 16); ok do r = rune(v)
					} else if strings.has_prefix(entity, "#") {
						if v, ok := strconv.parse_u64_of_base(entity[1:], 10); ok do r = rune(v)
					}
				}
				if r >= 0 {
					strings.write_rune(b, r)
					i += end + 1
					continue
				}
			}
		} else if excel && ch == '_' && i + 6 < len(raw) && raw[i + 1] == 'x' && raw[i + 6] == '_' {
			if v, ok := strconv.parse_u64_of_base(raw[i + 2:i + 6], 16); ok {
				strings.write_rune(b, rune(v))
				i += 7
				continue
			}
		}
		strings.write_byte(b, ch)
		i += 1
	}
}

// Decodes text into a new string allocated with context.allocator.
xml_decoded :: proc(raw: string, excel := false) -> string {
	if strings.index_byte(raw, '&') < 0 && (!excel || strings.index(raw, "_x") < 0) do return strings.clone(raw)
	b := strings.builder_make()
	xml_decode(&b, raw, excel)
	return strings.to_string(b)
}
