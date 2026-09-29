// The importer edge: MeCab CSV dictionary reading, schema detection,
// the quoting-aware field parser, and the optional resource readers
// (unk.def, char.def, matrix.def). The package's I/O edge spans this
// file plus the qdct snapshot boundary and its mmap twins; core:thread
// is confined to the parallel matrix parse here - everything handed
// to the analyzer is cloned into the analyzer allocator and owned.
package moli

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:thread"

// Schema is the column layout of a MeCab CSV file, detected from the
// first line's field count and disambiguated by language.
Schema :: enum {
	Ipadic,       // 13 columns (JP, IPADic)
	Unidic,       // 17+ columns (JP, UniDic; 19-25 accepted, tail -> extra)
	MeCabJieba,   // 9 columns (ZH-CN/TW)
	MeCabJiebaHK, // 9 columns (ZH-HK jyutping variant)
	EnglishExt,   // 13 columns (EN GB/US)
}

// Importer is the load-time state behind load; it never escapes. The
// scratch dynamic arena carries every transient allocation of the
// import - the whole file images, the reused per-line field and
// unquoted-byte buffers, detection scratch - so a single free-all
// ends the load and nothing transient can leak into the analyzer's
// lifetime. Only data that escapes (entry strings, joined POS, rule
// strings, matrix cells) is cloned into allocator.
//
// The per-line buffers exist so that steady-state parsing allocates
// nothing: a fresh field array per line in a never-reset arena is
// what makes a 35-million-line matrix.def cost gigabytes.
//
// The arena is initialized inside load, used through the importer's
// pointer, and destroyed before load returns - a dynamic arena is
// self-referential and must never be copied out of the procedure that
// initialized it.
Importer :: struct {
	lang:         Language,
	schema:       Schema,
	builder:      ^Cedar_Builder,
	entries:      [dynamic]Dictionary_Entry, // made with the allocator; handed over to the analyzer
	unk_def:      [dynamic]Unk_Rule,
	unk_patterns: [dynamic]Unk_Pattern, // made with the allocator; handed over to the analyzer
	conn_matrix:  Connection_Matrix, // empty when no matrix.def was supplied
	scratch:      mem.Dynamic_Arena,
	fields_buf:   [dynamic]string, // per-line CSV field slices, reset for each record
	unquoted_buf: [dynamic]u8,     // per-line unquoted-field bytes, reset the same way
	allocator:        mem.Allocator,
}

// importer_init_bufs makes the two per-line scratch buffers on first
// use (append on a nil dynamic array would grow through the context
// allocator). Both carry the scratch allocator, so growth stays inside
// the load arena; a failed make answers .OutOfMemory - a nil buffer's
// first append would grow through the ambient allocator.
importer_init_bufs :: proc(imp: ^Importer) -> Load_Err {
	scratch_allocator := mem.dynamic_arena_allocator(&imp.scratch)
	if imp.fields_buf == nil {
		buf, err := make([dynamic]string, 0, 32, scratch_allocator)
		if err != nil { return .OutOfMemory }
		imp.fields_buf = buf
	}
	if imp.unquoted_buf == nil {
		buf, err := make([dynamic]u8, 0, 64, scratch_allocator)
		if err != nil { return .OutOfMemory }
		imp.unquoted_buf = buf
	}
	return nil
}

// discover_sibling_path resolves an optional resource: the explicit
// path when one was given, otherwise the canonical file name next to
// the dictionary CSV. ok is false when the sibling is absent -
// degradation the caller records in skipped_resources - while an
// allocation failure answers .OutOfMemory: a starved load arena must
// fail the load, not silently degrade it. The returned string belongs
// to scratch_allocator (the load arena): it is used within load only. Paths are
// used as supplied: callers should pass cleaned absolute paths, and
// any directory-walking around them must be bounded - the filepath
// procedures trap on unclean input on this toolchain.
discover_sibling_path :: proc(csv_path: string, explicit: string, name: string, scratch_allocator: mem.Allocator) -> (string, bool, Load_Err) {
	if explicit != "" {
		if os.exists(explicit) {
			cloned, cerr := strings.clone(explicit, scratch_allocator)
			if cerr != nil { return "", false, .OutOfMemory }
			return cloned, true, nil
		}
		return "", false, nil
	}
	if csv_path == "" { return "", false, nil }
	dir := os.dir(csv_path)
	if dir == "" { dir = "." }
	candidate, jerr := filepath.join({dir, name}, scratch_allocator)
	if jerr != nil { return "", false, .OutOfMemory }
	if os.exists(candidate) {
		return candidate, true, nil
	}
	return "", false, nil
}

// strip_eol returns line without its terminator: the trailing '\n' the
// line scan leaves in place, and the '\r' a CRLF pair leaves in front
// of it. LF, CRLF, unterminated-final-line, and bare-CR all reduce to
// a clean record.
strip_eol :: proc(line: []byte) -> []byte {
	out := line
	if len(out) > 0 && out[len(out) - 1] == '\n' { out = out[:len(out) - 1] }
	if len(out) > 0 && out[len(out) - 1] == '\r' { out = out[:len(out) - 1] }
	return out
}

// line_end returns the offset of the next '\n' at or after pos, or
// len(data) when the final line is unterminated. The record is
// data[pos:end]; the caller advances pos to end + 1, which ends the
// walk after a final unterminated line without delivering an empty
// tail.
line_end :: proc(data: []byte, pos: int) -> int {
	end := pos
	for end < len(data) && data[end] != '\n' { end += 1 }
	return end
}

// line_blank reports whether a stripped record line carries no
// non-space rune - the same question trim_space's emptiness test
// answered, over the same is_space rune set. One forward decode stops
// at the first byte of a normal row where trim_space scanned the
// whole line backwards as well; the matrix walk pays this check for
// every one of its tens of millions of lines.
line_blank :: proc(line: []byte) -> bool {
	for r in string(line) {
		if !strings.is_space(r) { return false }
	}
	return true
}

// Line_Reader is the one record scanner behind every importer walk
// (the dictionary CSV, the line-shaped resources, the jyutping donor,
// char.def, and the matrix body): it owns the position, the physical
// line count, and the first-record BOM strip, so terminator, blank,
// and BOM handling cannot drift between readers again. Records are
// delivered stripped of their terminator (LF or CRLF) and their
// first-of-file BOM; blank lines are skipped but still counted.
Line_Reader :: struct {
	data:    []byte,
	pos:     int,
	line_no: int,  // physical line count: blanks included, 1-based on delivery
	first:   bool, // the BOM strip is still pending (next non-blank record)
}

// line_reader_init starts a reader over the whole image. Callers that
// own a prefix (the matrix header) set pos past it and clear first -
// the BOM belongs to the prefix they consumed.
line_reader_init :: proc(r: ^Line_Reader, data: []byte) {
	r^ = Line_Reader{data = data, first = true}
}

// line_reader_next delivers the next non-blank, stripped record with
// its 1-based line number; ok is false at end of data.
line_reader_next :: proc(r: ^Line_Reader) -> (record: []byte, line_no: int, ok: bool) {
	for r.pos < len(r.data) {
		end := line_end(r.data, r.pos)
		rec := strip_eol(r.data[r.pos:end])
		r.pos = end + 1
		r.line_no += 1
		if line_blank(rec) { continue }
		record = strip_bom_once(rec, &r.first)
		return record, r.line_no, true
	}
	return nil, 0, false
}

// detect_schema parses the first non-empty CSV line and maps its field
// count to a schema, using lang to break ties (9 -> jieba/HK, 13 ->
// ipadic/English, 17-25 -> UniDic). It also returns the expected
// column count that every subsequent line is validated against. An
// unclassifiable line fails the load.
detect_schema :: proc(lang: Language, first_line: string, fields_buf: ^[dynamic]string, unquoted_buf: ^[dynamic]u8) -> (Schema, int, Load_Err) {
	fields, ferr := split_fields(first_line, fields_buf, unquoted_buf)
	if ferr != nil { return .Ipadic, 0, ferr }
	n := len(fields)
	switch n {
	case 9:
		#partial switch lang {
		case .ChineseHK: return .MeCabJiebaHK, 9, nil
		case:            return .MeCabJieba, 9, nil
		}
	case 13:
		#partial switch lang {
		case .EnglishGB, .EnglishUS: return .EnglishExt, 13, nil
		case:                        return .Ipadic, 13, nil
		}
	case 17, 18, 19, 20, 21, 22, 23, 24, 25:
		return .Unidic, n, nil
	}
	return .Ipadic, 0, .Invalid_Format
}

// split_fields splits one CSV record (terminator already stripped,
// trailing \r removed) into fields through the quoting-aware parser.
// A quote inside an unquoted field is a literal; a doubled quote
// inside quotes is one quote; an unterminated quoted field is
// malformed and answers .Invalid_Format; a reused buffer that cannot
// grow for a long record answers .OutOfMemory (the growth would
// otherwise silently truncate the field). The returned slice - and
// every quoted field's unquoted bytes - are views into the caller's
// reused buffers: valid until the next split_fields or
// split_whitespace on the same buffers, which is within the record's
// own parse.
split_fields :: proc(line: string, fields_buf: ^[dynamic]string, unquoted_buf: ^[dynamic]u8) -> ([]string, Load_Err) {
	resize(fields_buf, 0)
	resize(unquoted_buf, 0)
	i: int = 0
	for i <= len(line) {
		field, next, err := parse_field(line, i, unquoted_buf)
		if err != nil { return nil, err }
		if _, aerr := append(fields_buf, field); aerr != nil { return nil, .OutOfMemory }
		i = next
	}
	f := fields_buf^
	return f[:], nil
}

// parse_field parses one field starting at byte offset start: returns
// the unquoted field, the offset just past the closing delimiter
// (len(line)+1 after the last field), and the failure - nil when the
// quoting was well-formed, .Invalid_Format for malformed quoting,
// .OutOfMemory when the unquoted buffer cannot grow (next is
// meaningless when err is set). After a closing quote only ',' or the
// end of the record may follow - records arrive terminator-stripped
// from Line_Reader, so anything else (a mid-record '\r' included) is
// malformed quoting and rejects with .Invalid_Format. A quoted field
// is unescaped by appending into the reused unquoted buffer and
// answering a view from the field's mark, so consecutive quoted
// fields in one record stay distinct.
parse_field :: proc(line: string, start: int, unquoted_buf: ^[dynamic]u8) -> (field: string, next: int, err: Load_Err) {
	if start > len(line) { return "", len(line) + 1, .Invalid_Format }
	// Quoted field.
	if start < len(line) && line[start] == '"' {
		mark := len(unquoted_buf^)
		i := start + 1
		closed := false
		next = 0
		for i < len(line) {
			c := line[i]
			if c == '"' {
				if i + 1 < len(line) && line[i + 1] == '"' {
					if _, aerr := append(unquoted_buf, '"'); aerr != nil { return "", 0, .OutOfMemory }
					i += 2
				} else {
					// Closing quote: ',' or the record's end must
					// follow; nothing else closes the field.
					i += 1
					if i >= len(line) {
						closed = true
						next = len(line) + 1
					} else if line[i] == ',' {
						closed = true
						next = i + 1
					}
					break
				}
			} else {
				if _, aerr := append(unquoted_buf, c); aerr != nil { return "", 0, .OutOfMemory }
				i += 1
			}
		}
		if !closed { return "", 0, .Invalid_Format } // unterminated (or garbage-terminated) quoted field
		u := unquoted_buf^
		return string(u[mark:]), next, nil
	}
	// Unquoted: read until comma or end-of-record.
	end := start
	for end < len(line) {
		if line[end] == ',' { break }
		end += 1
	}
	return line[start:end], end + 1, nil
}

// split_whitespace splits a whitespace-separated record (unk/char/matrix
// resource files) on spaces and tabs into the caller's reused field
// buffer. The strings are views into line, valid for the record's own
// parse; a buffer that cannot grow answers .OutOfMemory.
split_whitespace :: proc(line: string, fields_buf: ^[dynamic]string) -> ([]string, Load_Err) {
	resize(fields_buf, 0)
	i: int = 0
	for i < len(line) {
		for i < len(line) && (line[i] == ' ' || line[i] == '\t') { i += 1 }
		if i >= len(line) { break }
		start := i
		for i < len(line) && line[i] != ' ' && line[i] != '\t' { i += 1 }
		if _, aerr := append(fields_buf, line[start:i]); aerr != nil { return nil, .OutOfMemory }
	}
	f := fields_buf^
	return f[:], nil
}

// importer_read_csv reads the dictionary CSV in a single pass over a
// whole-file image: the first non-blank line (BOM stripped) feeds
// schema detection and is parsed like any other line - no rewind, so
// no line can be dropped between detection and parse, BOM or not,
// terminated or not. Blank lines are skipped; every other
// malformation aborts the load. CRLF and LF are both accepted without
// re-encoding. Reading the whole image at once (rather than a line at
// a time) keeps the load arena at one allocation per file instead of
// one per line.
// Csv_Source is the dictionary source for a load: a CSV file path or
// an in-memory CSV image. A bytes image is borrowed for the parse
// only - every string that outlives the load is cloned into the
// analyzer's allocator, and the caller keeps the buffer.
Csv_Source :: union {
	string,
	[]u8,
}

importer_read_csv :: proc(imp: ^Importer, src: Csv_Source) -> Load_Err {
	data: []u8
	switch s in src {
	case string: // CSV file path
		d, derr := read_resource_image(imp, s)
		if derr != nil { return derr }
		data = d
	case []u8: // in-memory CSV image, borrowed for the parse
		if err := importer_init_bufs(imp); err != nil { return err }
		data = s
	}

	expected_cols := 0
	detected := false
	reader: Line_Reader
	line_reader_init(&reader, data)
	for {
		record, line_no, ok := line_reader_next(&reader)
		if !ok { break }

		if !detected {
			// The first non-blank record both declares the schema and
			// parses like any other row - no rewind, so no line can be
			// dropped between detection and parse, BOM or not,
			// terminated or not (the reader owns the BOM strip).
			schema, cols, derr := detect_schema(imp.lang, string(record), &imp.fields_buf, &imp.unquoted_buf)
			if derr != nil { return derr }
			imp.schema = schema
			expected_cols = cols
			detected = true
		}

		if err := parse_and_append(imp, record, line_no, expected_cols); err != nil {
			return err
		}
	}

	if len(imp.entries) == 0 { return .Invalid_Format }
	return nil
}

// parse_and_append parses one CSV line and appends the entry in file
// order - the slice index becomes the entry id. The append is the
// load's hottest fallible allocation (real dictionaries cross the
// entries array's initial capacity thousands of rows in): a failure
// destroys the row's cloned strings here - the caller's release only
// owns appended rows - and fails the load rather than silently
// truncating the dictionary.
parse_and_append :: proc(imp: ^Importer, line: []byte, line_no: int, expected_cols: int) -> Load_Err {
	entry, perr := parse_entry(imp.schema, line, line_no, expected_cols, imp.allocator, &imp.fields_buf, &imp.unquoted_buf)
	if perr != nil { return perr }
	if _, aerr := append(&imp.entries, entry); aerr != nil {
		dictionary_entry_destroy(&entry, imp.allocator)
		return .OutOfMemory
	}
	return nil
}

// join_pos joins POS columns: skip empty and "*", join the rest with
// ",". All-skipped or all-empty collapses to a cloned "*". Built as a
// counted total over the column views plus one exact allocation - the
// per-entry parts array this replaced was a make/delete pair through
// the analyzer allocator for every one of unidic's 756K rows.
join_pos :: proc(cols: []string, allocator: mem.Allocator) -> (string, Load_Err) {
	kept: int
	total: int
	for c in cols {
		if c == "" || c == "*" { continue }
		kept += 1
		total += len(c)
	}
	if kept == 0 {
		out, err := clone_str("*", allocator)
		if err != nil { return "", err }
		return out, nil
	}
	if kept > 1 { total += kept - 1 }

	buf, aerr := mem.alloc_bytes(total, 1, allocator)
	if aerr != nil { return "", .OutOfMemory }
	pos := 0
	for c in cols {
		if c == "" || c == "*" { continue }
		if pos > 0 {
			buf[pos] = ','
			pos += 1
		}
		copy(buf[pos:pos + len(c)], c)
		pos += len(c)
	}
	return string(buf), nil
}

// append_extra clones each tail column into the entry's owned extra
// list. The list is made on first use so entries without tail columns
// carry no per-entry allocation; once made it carries its allocator
// and teardown deletes it bare.
append_extra :: proc(e: ^Dictionary_Entry, cols: []string, allocator: mem.Allocator) -> Load_Err {
	if len(cols) == 0 { return nil }
	extra, merr := make([dynamic]string, 0, len(cols), allocator)
	if merr != nil { return .OutOfMemory }
	e.extra = extra
	for c in cols {
		s, err := clone_str(c, allocator)
		if err != nil { return err }
		append(&e.extra, s)
	}
	return nil
}

// Schema_Columns is one schema's column map for parse_entry: where the
// POS join starts and stops (half-open), where the lemma and reading
// come from, and the optional extras span. parse_entry is the single
// consumer; SCHEMA_COLUMNS is the data, the parse body below is the one
// generic fill.
//
//   lemma:   the CSV column, or LEMMA_SURFACE for the surface (column
//            0, cloned separately so teardown frees two strings).
//   reading: the CSV column, or READING_NONE when the schema has no
//            reading column ("*" is stored); with reading_optional the
//            column may be absent on a short row and "*" is stored
//            instead.
//   extras:  the half-open span handed to append_extra (extras_to ==
//            EXTRAS_TO_END takes the rest of the row); the span is
//            taken only when the row has a column past extras_from.
//            EXTRAS_NONE marks schemas without extras.
//
// Every field is set in every row of SCHEMA_COLUMNS on purpose: the
// zero value is a valid column index, and an unset field would silently
// read column 0.
Schema_Columns :: struct {
	pos_from:         int,
	pos_to:           int, // exclusive
	lemma:            int, // column, or LEMMA_SURFACE
	reading:          int, // column, or READING_NONE
	reading_optional: bool,
	extras_from:      int, // column, or EXTRAS_NONE
	extras_to:        int, // exclusive, or EXTRAS_TO_END
}

LEMMA_SURFACE :: -1 // Schema_Columns.lemma: the lemma is the surface (column 0)
READING_NONE  :: -1 // Schema_Columns.reading: the schema has no reading column
EXTRAS_NONE   :: -1 // Schema_Columns.extras_from: the schema has no extras span
EXTRAS_TO_END :: -1 // Schema_Columns.extras_to: the span runs to the row's end

// SCHEMA_COLUMNS is the per-schema column map, keyed by Schema. The
// rows carry the layouts of the real dictionaries this importer reads.
SCHEMA_COLUMNS :: [Schema]Schema_Columns{
	// IPADic: cols 4-9 feed joined_pos; 10 lemma; 11 reading. The
	// pronunciation column is not stored.
	.Ipadic = {pos_from = 4, pos_to = 10, lemma = 10, reading = 11,
		reading_optional = false, extras_from = EXTRAS_NONE, extras_to = EXTRAS_NONE},

	// unidic-mecab 2.1.2: cols 4-9 are the POS hierarchy and conjugation
	// (joined_pos), col 11 the lemma, col 13 the katakana pronunciation
	// (reading); cols 17+ are extra.
	.Unidic = {pos_from = 4, pos_to = 10, lemma = 11, reading = 13,
		reading_optional = false, extras_from = 17, extras_to = EXTRAS_TO_END},

	// mecab-jieba 0.1.1: col 4 POS; col 5 pinyin -> reading; col 8
	// definition -> extra. No lemma column exists: lemma is the surface
	// value. The HK file shares this map - its col 5 is jyutping, which
	// rides in reading either way; loading the HK file alone keeps the
	// single-primary contract (reading_jyutping stays "*", the two-file
	// flow through Load_Options.jyutping_csv_path populates it).
	.MeCabJieba = {pos_from = 4, pos_to = 5, lemma = LEMMA_SURFACE, reading = 5,
		reading_optional = true, extras_from = 8, extras_to = 9},
	.MeCabJiebaHK = {pos_from = 4, pos_to = 5, lemma = LEMMA_SURFACE, reading = 5,
		reading_optional = true, extras_from = 8, extras_to = 9},

	// The extended English dictionary: col 4 POS; cols 5-9 detail (all
	// "*", dropped by the join rule); 10 lemma; 11-12
	// reading/pronunciation.
	.EnglishExt = {pos_from = 4, pos_to = 10, lemma = 10, reading = 11,
		reading_optional = true, extras_from = EXTRAS_NONE, extras_to = EXTRAS_NONE},
}

// parse_conn_triple reads a left/right/cost connection triple out of
// three consecutive columns starting at off - the column shape the
// entry rows, unk.def, patterns.qpat, and the jyutping donor all
// share. A non-numeric column marks the row a broken dictionary.
parse_conn_triple :: proc(fields: []string, off: int) -> (left, right, cost: i16, ok: bool) {
	l, lok := parse_i16_saturating(fields[off])
	r, rok := parse_i16_saturating(fields[off + 1])
	c, cok := parse_i16_saturating(fields[off + 2])
	return l, r, c, lok && rok && cok
}

// parse_entry splits one record, validates the column count against
// the schema (a mismatch answers Schema_Mismatch_Error and aborts the
// load), parses the ids and the saturated-clamped cost, prejoins the
// POS columns, and clones every escaping string into allocator - transient
// slices stay in scratch. All validation precedes the first clone, so
// failure paths never strand a partial entry; a clone that fails
// mid-way destroys what it already built and answers .OutOfMemory.
parse_entry :: proc(schema: Schema, line: []byte, line_no: int, expected_cols: int, allocator: mem.Allocator, fields_buf: ^[dynamic]string, unquoted_buf: ^[dynamic]u8) -> (Dictionary_Entry, Load_Err) {
	fields, serr := split_fields(string(line), fields_buf, unquoted_buf)
	if serr != nil { return Dictionary_Entry{}, serr }
	if len(fields) != expected_cols {
		return Dictionary_Entry{}, Schema_Mismatch_Error{line = line_no, expected = expected_cols, got = len(fields)}
	}
	if fields[0] == "" { return Dictionary_Entry{}, .Invalid_Format }

	left, right, cost, cok := parse_conn_triple(fields, 1)
	if !cok { return Dictionary_Entry{}, .Invalid_Format }

	entry: Dictionary_Entry
	entry.left_id = left
	entry.right_id = right
	entry.cost = cost
	entry.strings_owned = true

	failed: Load_Err
	entry.surface, failed = clone_str(fields[0], allocator)
	if failed == nil {
		cols := SCHEMA_COLUMNS // materialized: constants refuse variable indexing
		c := cols[schema]

		entry.joined_pos, failed = join_pos(fields[c.pos_from:c.pos_to], allocator)
		if failed == nil {
			if c.lemma == LEMMA_SURFACE {
				entry.lemma, failed = clone_str(fields[0], allocator)
			} else {
				entry.lemma, failed = clone_str(fields[c.lemma], allocator)
			}
		}
		if failed == nil {
			if c.reading == READING_NONE ||
				(c.reading_optional && len(fields) <= c.reading) {
				entry.reading, failed = clone_str("*", allocator)
			} else {
				entry.reading, failed = clone_str(fields[c.reading], allocator)
			}
		}
		if failed == nil { entry.reading_jyutping, failed = clone_str("*", allocator) }
		if failed == nil && c.extras_from != EXTRAS_NONE && len(fields) > c.extras_from {
			extras_to := c.extras_to
			if extras_to == EXTRAS_TO_END || extras_to > len(fields) { extras_to = len(fields) }
			failed = append_extra(&entry, fields[c.extras_from:extras_to], allocator)
		}
	}
	if failed != nil {
		dictionary_entry_destroy(&entry, allocator)
		return Dictionary_Entry{}, failed
	}
	return entry, nil
}

// strip_bom_once removes a UTF-8 byte-order mark from the first
// non-blank line a resource loader sees (the dictionary CSV and the
// jyutping donor already do this at their first record): editors drop
// BOMs on any text file, and one glued to the first field would
// otherwise fail the parse as garbage bytes.
strip_bom_once :: proc(line: []u8, first: ^bool) -> []u8 {
	if !first^ { return line }
	first^ = false
	if len(line) >= 3 && line[0] == 0xEF && line[1] == 0xBB && line[2] == 0xBF {
		return line[3:]
	}
	return line
}

// read_resource_lines reads one line-shaped optional-resource file
// whole and hands every non-blank line to handler, terminator stripped
// and a first-of-file BOM removed. unk.def and patterns.qpat are the
// two current users - their read ladders were byte-identical apart
// from the handler. The image lives in the importer's scratch arena
// and dies with its reset; the open/read failure mapping is the
// resources' historical one (.File_Not_Found / .IO_Read).
// read_resource_image opens path and reads it whole into the load
// scratch - the shared prelude of every resource reader (the primary
// CSV, unk.def/qpat, the jyutping donor, char.def, matrix.def). The
// image dies with the scratch arena's reset; the open/read failure
// mapping is the resources' historical one, with one split: a buffer
// allocation failure answers .OutOfMemory, not .IO_Read - the arena's
// backing is the caller's allocator, and read_entire_file reports that
// failure inside the same os.Error union as a read refusal.
read_resource_image :: proc(imp: ^Importer, path: string) -> ([]u8, Load_Err) {
	f, ferr := os.open(path)
	if ferr != nil { return nil, .File_Not_Found }
	defer os.close(f)

	if err := importer_init_bufs(imp); err != nil { return nil, err }
	scratch_allocator := mem.dynamic_arena_allocator(&imp.scratch)
	data, rerr := os.read_entire_file(f, scratch_allocator)
	if rerr != nil {
		// The allocation failure is split from the read refusals;
		// nil is unreachable under rerr != nil (see qdct_read_file
		// for the member-by-member rationale).
		switch _ in rerr {
		case runtime.Allocator_Error:                      return nil, .OutOfMemory
		case os.General_Error, io.Error, os.Platform_Error: return nil, .IO_Read
		case:                                              return nil, .IO_Read
		}
	}
	return data, nil
}

read_resource_lines :: proc(imp: ^Importer, path: string, handler: proc(imp: ^Importer, line: []u8) -> Load_Err) -> Load_Err {
	data, derr := read_resource_image(imp, path)
	if derr != nil { return derr }

	reader: Line_Reader
	line_reader_init(&reader, data)
	for {
		line, _, ok := line_reader_next(&reader)
		if !ok { break }
		if err := handler(imp, line); err != nil { return err }
	}
	return nil
}

// import_unk_def loads the unknown-word rules. Each record is
// CSV-comma-separated; column 0 names a char.def class, and an
// unrecognized class name fails the load - a rule that can never match
// is a broken dictionary. Two column orders exist in the wild and both
// are accepted (see append_unk_rule).
import_unk_def :: proc(imp: ^Importer, path: string) -> Load_Err {
	return read_resource_lines(imp, path, append_unk_rule)
}

// append_unk_rule parses one unk.def record and appends it. The layout
// is uniform across the real dictionaries (ipadic 2.7.0, unidic-mecab
// 2.1.2, mecab-jieba 0.1.1): class name, left_id, right_id, cost, then
// POS columns feeding joined_pos. A row whose id/cost columns are not
// numeric is a broken dictionary and fails the load.
append_unk_rule :: proc(imp: ^Importer, line: []byte) -> Load_Err {
	fields, serr := split_fields(string(line), &imp.fields_buf, &imp.unquoted_buf)
	if serr != nil { return serr }
	if len(fields) < 4 { return .Invalid_Format }
	cls, cls_ok := char_class_from_name(fields[0])
	if !cls_ok { return .Invalid_Format }

	// Every real unk.def (ipadic 2.7.0, unidic-mecab 2.1.2,
	// mecab-jieba 0.1.1) puts left/right/cost directly after the
	// class name; a row where those columns are not numeric ids is a
	// broken dictionary, not a second dialect.
	left, right, cost, cok := parse_conn_triple(fields, 1)
	if !cok { return .Invalid_Format }
	pos_cols: []string = fields[4:]

	joined, jerr := join_pos(pos_cols, imp.allocator)
	if jerr != nil { return jerr }
	// The unk array grows past its initial capacity on every real
	// dictionary; a failed append must destroy the rule's joined string
	// here (the caller's release only owns appended rules) and fail the
	// load, never silently truncate the rule set.
	rule := Unk_Rule{
		class      = cls,
		left_id    = left,
		right_id   = right,
		cost       = cost,
		joined_pos = joined,
	}
	if _, aerr := append(&imp.unk_def, rule); aerr != nil {
		unk_rule_destroy(&rule, imp.allocator)
		return .OutOfMemory
	}
	return nil
}

// import_qpat loads the surface-pattern rows: kind, key, left, right,
// cost, then the POS columns. Blank lines are skipped; a file with no
// rows at all is legal (zero patterns, the resolution ladder
// unchanged). Malformed rows fail the load like any other resource.
import_qpat :: proc(imp: ^Importer, path: string) -> Load_Err {
	return read_resource_lines(imp, path, append_unk_pattern)
}

// append_unk_pattern parses one patterns.qpat row. The kind decides
// what the key column means: a prefix/suffix literal (non-empty,
// cloned into the analyzer allocator) or a char.def class name mapped
// through the same table unk.def column 0 uses - an unrecognized name
// is a rule that can never match, a broken dictionary. The numeric
// columns are parsed before anything is cloned so every reject path
// frees exactly what has been allocated.
append_unk_pattern :: proc(imp: ^Importer, line: []byte) -> Load_Err {
	fields, serr := split_fields(string(line), &imp.fields_buf, &imp.unquoted_buf)
	if serr != nil { return serr }
	if len(fields) < 5 { return .Invalid_Format }

	kind: Unk_Pattern_Kind
	switch fields[0] {
	case "prefix": kind = .Prefix
	case "suffix": kind = .Suffix
	case "charset": kind = .Charset
	case: return .Invalid_Format
	}

	left, right, cost, cok := parse_conn_triple(fields, 2)
	if !cok { return .Invalid_Format }

	cls: Char_Class
	pat := ""
	if kind == .Charset {
		mapped, mok := char_class_from_name(fields[1])
		if !mok { return .Invalid_Format }
		cls = mapped
	} else {
		if len(fields[1]) == 0 { return .Invalid_Format }
		clone, cerr := clone_str(fields[1], imp.allocator)
		if cerr != nil { return cerr }
		pat = clone
	}

	joined, jerr := join_pos(fields[5:], imp.allocator)
	if jerr != nil {
		if kind != .Charset { delete(pat, imp.allocator) }
		return jerr
	}
	// A failed append must destroy the row's strings here (the
	// caller's release only owns appended patterns) and fail the load,
	// never silently truncate the pattern set.
	pattern := Unk_Pattern{
		kind       = kind,
		class      = cls,
		pat        = pat,
		left_id    = left,
		right_id   = right,
		cost       = cost,
		joined_pos = joined,
	}
	if _, aerr := append(&imp.unk_patterns, pattern); aerr != nil {
		unk_pattern_destroy(&pattern, imp.allocator)
		return .OutOfMemory
	}
	return nil
}

// import_jyutping_csv joins the HK-variant CSV at path (the 9-column
// jieba layout, col 5 jyutping) onto the already-built entries: every
// entry whose surface equals a donor row's col 0 receives that row's
// jyutping in reading_jyutping. Join, not union - donor-only surfaces
// add nothing. First row per surface wins; "*" and empty readings are
// absent data and skip. The join walks the built trie (all_matches_at
// reaches prefix surfaces too, so an equality filter keeps it exact),
// which is why the merge runs after the trie and entries were handed
// over to the analyzer.
import_jyutping_csv :: proc(imp: ^Importer, a: ^Analyzer, path: string) -> Load_Err {
	data, rerr := read_resource_image(imp, path)
	if rerr != nil { return rerr }

	scratch_allocator := mem.dynamic_arena_allocator(&imp.scratch)
	matches: Match_List
	matches.allocator = scratch_allocator

	expected, detected := 0, false
	reader: Line_Reader
	line_reader_init(&reader, data)
	for {
		record, line_no, ok := line_reader_next(&reader)
		if !ok { break }

		if !detected {
			// The donor declares its own layout: detection always runs
			// as the HK variant, whatever the primary's language. A
			// file shaped like another schema (13 ipadic columns) is
			// not a donor at all.
			schema, cols, derr := detect_schema(.ChineseHK, string(record), &imp.fields_buf, &imp.unquoted_buf)
			if derr != nil { return derr }
			if schema != .MeCabJiebaHK { return .Invalid_Format }
			expected = cols
			detected = true
		}

		fields, serr := split_fields(string(record), &imp.fields_buf, &imp.unquoted_buf)
		if serr != nil { return serr }
		if len(fields) != expected {
			return Schema_Mismatch_Error{line = line_no, expected = expected, got = len(fields)}
		}
		if fields[0] == "" { return .Invalid_Format }
		_, _, _, cok := parse_conn_triple(fields, 1)
		if !cok { return .Invalid_Format }

		jyutping := fields[5]
		if jyutping == "" || jyutping == "*" { continue }

		// Patch every entry of the surface - a multi-entry terminal
		// (homographs) patches as a group, and a later duplicate row
		// finds non-"*" readings and skips (first row wins). The join
		// walks the trie through a per-surface walk table: one tiny
		// sweep per donor row on this cold path.
		match_reset(&matches)
		tab, terr := lattice_walk_table_build(&a.char_map, &a.char_class, fields[0], scratch_allocator)
		if terr != nil { return .OutOfMemory }
		if amerr := all_matches_at(a, &tab, 0, &matches); amerr != nil {
			return .OutOfMemory
		}
		for mi in 0 ..< matches.n {
			entry_id := match_get(&matches, mi)
			e := &a.entries[entry_id]
			if e.surface != fields[0] { continue }
			if e.reading_jyutping != "*" { continue }
			cloned, cerr := clone_str(jyutping, imp.allocator)
			if cerr != nil { return cerr }
			delete(e.reading_jyutping, imp.allocator)
			e.reading_jyutping = cloned
		}
	}
	return nil
}

// import_matrix_def loads the dense connection matrix. The file is
// whitespace-separated: the header is "left_size right_size", the body
// is "left right cost" triples. The header sizes must fit i16 range;
// ids outside [0, size) and malformed triples fail the load; missing
// cells keep the default cost; costs are saturated-clamped into i16.
import_matrix_def :: proc(imp: ^Importer, path: string, threads: int) -> Load_Err {
	data, rerr := read_resource_image(imp, path)
	if rerr != nil { return rerr }

	scratch_allocator := mem.dynamic_arena_allocator(&imp.scratch)

	// Header: "left_size right_size" on the first line. A UTF-8 BOM, if
	// present, sits in front of it; strip it so the dimension parse
	// sees digits.
	pos := line_end(data, 0)
	head := strip_eol(data[:pos])
	first := true
	head = strip_bom_once(head, &first)
	hfields, herr := split_whitespace(string(head), &imp.fields_buf)
	if herr != nil { return herr }
	pos += 1
	if len(hfields) < 2 { return .Invalid_Format }
	n_left, ok1 := strconv.parse_int(hfields[0])
	n_right, ok2 := strconv.parse_int(hfields[1])
	if !ok1 || !ok2 { return .Invalid_Format }
	if n_left < 0 || n_right < 0 { return .Invalid_Format }
	i16_max := int(max(i16))
	if n_left > i16_max || n_right > i16_max { return .Invalid_Format }
	// Exactly one zero dimension is a malformed header: the snapshot
	// validator rejects such a matrix on reload (it would imply a cost
	// section with no cells), so the two validators stay in agreement
	// by refusing it here too.
	if (n_left == 0) != (n_right == 0) { return .Invalid_Format }

	total := n_left * n_right
	// One reservation with the length set up front, then an indexed
	// fill: the append form paid a capacity check per cell on unidic's
	// 35.7M-cell default fill, and with the capacity already total only
	// the single reservation can fail.
	costs, cerr := make([dynamic]i16, total, total, imp.allocator)
	if cerr != nil { return .OutOfMemory }
	for i in 0 ..< total {
		costs[i] = CONNECTION_DEFAULT_COST
	}
	imp.conn_matrix = Connection_Matrix{costs = costs, n_left = n_left, n_right = n_right}

	// Distinct-cell bitset backing conn_matrix.explicit: a repeat
	// line for an already-written cell counts once. Scratch-sized
	// (an eighth of the dense array), freed with the load arena.
	// Worker 0 of the parallel path shares this slice as its own
	// bitset; the others get siblings in matrix_parse_parallel.
	seen, merr := make([]u8, bitset_size(total), scratch_allocator)
	if merr != nil { return .OutOfMemory }

	explicit: int
	if threads > 1 {
		perr: Load_Err
		explicit, perr = matrix_parse_parallel(imp, data, pos, threads, seen)
		if perr != nil { return perr }
	} else {
		serr: Load_Err
		explicit, serr = matrix_scan_serial(imp, data, pos, seen)
		if serr != nil { return serr }
	}
	imp.conn_matrix.explicit = explicit
	return nil
}

// matrix_scan_serial is the one-pass line walk the serial path runs
// and the parallel path replays when a cross-chunk repeat cell makes
// the concurrent writes unordered. pos starts just past the header
// line, whose BOM the header parse already consumed.
matrix_scan_serial :: proc(imp: ^Importer, data: []byte, pos_in: int, seen: []u8) -> (int, Load_Err) {
	reader: Line_Reader
	line_reader_init(&reader, data)
	reader.pos = pos_in
	reader.first = false

	explicit := 0
	for {
		line, _, ok := line_reader_next(&reader)
		if !ok { break }
		added, merr := read_matrix_line(imp, line, seen)
		if merr != nil {
			return 0, merr
		}
		if added { explicit += 1 }
	}
	return explicit, nil
}

// Matrix_Worker carries one chunk's input and results; the pointer
// rides in Thread.data. Every field but costs/seen is read-only; a
// worker writes only its own bitset, its own err, and dense cells
// (distinct cells in practice - see matrix_parse_parallel).
Matrix_Worker :: struct {
	data:   []byte,       // whole file bytes, read-only share
	start:  int,          // first byte of this chunk's first line
	end:    int,          // one past this chunk's last line
	n_left: int,
	n_right: int,
	costs:  [dynamic]i16, // shared dense array; element writes only, never append
	seen:   []u8,         // this worker's private distinct-cell bitset
	err:    Load_Err,     // first fault in this chunk; nil = none
}

// matrix_worker_proc walks its chunk's lines in file order, writing
// each cell directly and marking its own bitset. The field buffer
// lives in a dynamic arena created and destroyed inside this
// procedure (a dynamic arena is self-referential and must not escape
// the procedure that initialized it); its growth races nothing
// because the arena is single-threaded per worker.
matrix_worker_proc :: proc(th: ^thread.Thread) {
	w := cast(^Matrix_Worker)(th.data)

	scratch: mem.Dynamic_Arena
	// Both arena allocators explicit: worker threads run on the
	// runtime's default context, whose allocator is the raw global
	// heap — thread-safe by contract, unlike the loading thread's
	// (possibly tracking) allocator, which must not cross the thread
	// boundary. Naming it keeps that decision visible instead of
	// implicit.
	mem.dynamic_arena_init(&scratch, block_size = 1 << 12,
	                       block_allocator = runtime.default_allocator(),
	                       array_allocator = runtime.default_allocator())
	defer mem.dynamic_arena_destroy(&scratch)
	fields, ferr := make([dynamic]string, 0, 32, mem.dynamic_arena_allocator(&scratch))
	if ferr != nil { w.err = .OutOfMemory; return }

	p := w.start
	for p < w.end {
		end := line_end(w.data, p)
		line := strip_eol(w.data[p:end])
		p = end + 1

		if !line_blank(line) {
			idx, cost, perr := parse_matrix_triple(line, w.n_left, w.n_right, &fields)
			if perr != nil { w.err = perr; return }
			// Relaxed atomic store: a cell repeated across two chunks
			// makes two workers target the same slot - the serial
			// replay repairs the outcome either way, but the store
			// itself stays a formally atomic write instead of a data
			// race. Element writes only; the join provides the
			// happens-before for the fold below.
			intrinsics.atomic_store_explicit(&w.costs[idx], cost, .Relaxed)
			bitset_set(w.seen, idx)
		}
	}
}

// matrix_popcount counts set bits without disturbing them: Kernighan
// clears bits as it counts, so the loop must consume a copy - a
// by-reference binding would zero the caller's bitset (and did, in
// the first draft: every parallel load then saw union < sum and fell
// back to the serial replay, correct but slower than serial).
// The explicit-cell bitset's encoding: one bit per dense cell, byte
// idx >> 3, bit idx & 7. Sized, set, and tested only through these
// three helpers so the sizing site, the parallel workers' writes, and
// the serial test-and-set cannot drift on the format.
bitset_size :: #force_inline proc(n: int) -> int {
	return (n + 7) / 8
}

bitset_set :: #force_inline proc(seen: []u8, idx: int) {
	seen[idx >> 3] |= 1 << u8(idx & 7)
}

bitset_has :: #force_inline proc(seen: []u8, idx: int) -> bool {
	return (seen[idx >> 3] >> u8(idx & 7)) & 1 != 0
}

matrix_popcount :: proc(b: []u8) -> int {
	n := 0
	for byte_value in b {
		v := byte_value
		for v != 0 {
			v &= v - 1
			n += 1
		}
	}
	return n
}

// matrix_join_all joins and destroys the started threads - the error
// paths and the success path share it so no worker can outlive the
// arrays it writes into.
matrix_join_all :: proc(ths: [dynamic]^thread.Thread) {
	for th in ths {
		thread.join(th)
		thread.destroy(th)
	}
}

// The parallel matrix parse bounds its fan-out: never more than
// MAX_MATRIX_WORKERS threads, and only while each would still own at
// least MIN_MATRIX_CHUNK_BYTES of the body.
MAX_MATRIX_WORKERS     :: 64
MIN_MATRIX_CHUNK_BYTES :: 16

// matrix_parse_parallel splits the matrix body into line-aligned byte
// ranges and scans them concurrently; the answer is bit-identical to
// matrix_scan_serial at any worker count. Determinism is structural:
// real matrices enumerate each cell once, so worker writes touch
// disjoint cells; the one unordered shape - a cell repeated across
// two chunks - is detected by the bitset arithmetic (the union count
// falling short of the sum of the per-worker counts) and repaired by
// replaying the whole body serially, which reproduces file order and
// overwrites whatever the racing pair left.
matrix_parse_parallel :: proc(imp: ^Importer, data: []byte, body: int, threads: int, seen: []u8) -> (int, Load_Err) {
	scratch_allocator := mem.dynamic_arena_allocator(&imp.scratch)
	span := len(data) - body
	if span <= 0 { return matrix_scan_serial(imp, data, body, seen) }

	n := threads
	if n > MAX_MATRIX_WORKERS { n = MAX_MATRIX_WORKERS }
	if n > span/MIN_MATRIX_CHUNK_BYTES + 1 { n = span/MIN_MATRIX_CHUNK_BYTES + 1 }
	if n <= 1 { return matrix_scan_serial(imp, data, body, seen) }

	// Line starts: cut i at body + span*i/n, snapped forward past any
	// partial line so a chunk owns the lines that begin inside it and
	// no line straddles a boundary. Cuts can collide or land at EOF on
	// a short body; those chunks are empty and spawn nothing.
	starts, merr := make([]int, n, scratch_allocator)
	if merr != nil { return 0, .OutOfMemory }
	starts[0] = body
	for i in 1 ..< n {
		cut := body + span * i / n
		for cut < len(data) && data[cut - 1] != '\n' { cut += 1 }
		starts[i] = cut
	}

	// Pre-sized to n so append never grows: the Thread.data pointers
	// into workers must stay stable for the workers' lifetime.
	workers, werr := make([dynamic]Matrix_Worker, 0, n, scratch_allocator)
	if werr != nil { return 0, .OutOfMemory }
	ths, terr := make([dynamic]^thread.Thread, 0, n, scratch_allocator)
	if terr != nil { return 0, .OutOfMemory }

	for i in 0 ..< n {
		s := starts[i]
		e := len(data) if i == n - 1 else starts[i + 1]
		if s >= e { continue }

		wseen := seen
		if i > 0 {
			b, berr := make([]u8, len(seen), scratch_allocator)
			if berr != nil {
				matrix_join_all(ths)
				return 0, .OutOfMemory
			}
			wseen = b
		}
		if _, aerr := append(&workers, Matrix_Worker{
			data    = data,
			start   = s,
			end     = e,
			n_left  = imp.conn_matrix.n_left,
			n_right = imp.conn_matrix.n_right,
			costs   = imp.conn_matrix.costs,
			seen    = wseen,
		}); aerr != nil {
			matrix_join_all(ths)
			return 0, .OutOfMemory
		}
		th := thread.create(matrix_worker_proc)
		if th == nil {
			matrix_join_all(ths)
			return 0, .OutOfMemory
		}
		th.data = cast(rawptr)(&workers[len(workers) - 1])
		if _, aerr := append(&ths, th); aerr != nil {
			// Unreachable in practice - ths is pre-sized to n, and at
			// most n appends occur - kept as a defensive OOM path. On
			// this toolchain thread.destroy joins, and joining a
			// never-started thread implicitly starts it first, so the
			// worker runs its chunk before the return: ordered, just
			// slower than the comment once claimed.
			thread.destroy(th)
			matrix_join_all(ths)
			return 0, .OutOfMemory
		}
		thread.start(th)
	}

	// Join everything before reading any worker state (the fold, the
	// error pick, and the fallback replay all run on this thread).
	matrix_join_all(ths)

	// The earliest chunk's fault is the serial scan's verdict.
	for w in workers {
		if w.err != nil { return 0, w.err }
	}

	// Fold the bitsets: worker 0's IS seen, so OR the siblings in and
	// compare the union count against the per-worker sum.
	sum := 0
	for w, i in workers {
		sum += matrix_popcount(w.seen)
		if i > 0 {
			for j in 0 ..< len(seen) { seen[j] |= w.seen[j] }
		}
	}
	union_count := matrix_popcount(seen)
	if union_count == sum { return union_count, nil }

	// A cell repeated across chunks: replay the body serially through
	// the shared line procedure. seen is dirty from the fold; zero it.
	for j in 0 ..< len(seen) { seen[j] = 0 }
	explicit, rerr := matrix_scan_serial(imp, data, body, seen)
	if rerr != nil { return 0, rerr }
	return explicit, nil
}

// read_matrix_line parses one `left right cost` triple and writes it
// into the matrix.
read_matrix_line :: proc(imp: ^Importer, line: []byte, seen: []u8) -> (bool, Load_Err) {
	idx, cost, perr := parse_matrix_triple(line, imp.conn_matrix.n_left, imp.conn_matrix.n_right, &imp.fields_buf)
	if perr != nil { return false, perr }
	imp.conn_matrix.costs[idx] = cost
	added := !bitset_has(seen, idx)
	bitset_set(seen, idx)
	return added, nil
}

// parse_matrix_triple is the single line-parse definition shared by
// the serial scan and the parallel workers (split into the caller's
// field buffer), so the two paths can never drift on what a line
// means.
parse_matrix_triple :: proc(line: []byte, n_left: int, n_right: int, fields_buf: ^[dynamic]string) -> (int, i16, Load_Err) {
	fields, werr := split_whitespace(string(line), fields_buf)
	if werr != nil { return 0, 0, werr }
	if len(fields) < 3 { return 0, 0, .Invalid_Format }
	left, lok := strconv.parse_int(fields[0])
	right, rok := strconv.parse_int(fields[1])
	if !lok || !rok { return 0, 0, .Invalid_Format }
	if left < 0 || left >= n_left { return 0, 0, .Invalid_Format }
	if right < 0 || right >= n_right { return 0, 0, .Invalid_Format }
	cost, cok := parse_i16_saturating(fields[2])
	if !cok { return 0, 0, .Invalid_Format }
	return left * n_right + right, cost, nil
}

// import_char_def reads a char.def into scratch-backed ranges for
// char_class_build, applying the category rows' invoke/group/length
// flags into flags (which the caller pre-fills with
// char_flags_default). The file is whitespace-separated; see
// read_char_def_line for the record forms. Unrecognized custom
// category names map to .Unknown. The returned slice belongs to the
// load scratch.
import_char_def :: proc(imp: ^Importer, path: string, flags: ^[len(Char_Class)]Char_Flags) -> ([]Char_Range, Load_Err) {
	data, derr := read_resource_image(imp, path)
	if derr != nil { return nil, derr }

	scratch_allocator := mem.dynamic_arena_allocator(&imp.scratch)
	ranges, gerr := make([dynamic]Char_Range, 0, 16, scratch_allocator)
	if gerr != nil { return nil, .OutOfMemory }

	reader: Line_Reader
	line_reader_init(&reader, data)
	for {
		line, _, ok := line_reader_next(&reader)
		if !ok { break }
		if cerr := read_char_def_line(&ranges, line, &imp.fields_buf, flags, scratch_allocator); cerr != nil {
			return nil, cerr
		}
	}
	return ranges[:], nil
}

// read_char_def_line parses one char.def record into a half-open
// [lo, hi) Char_Range. Comments ('#' to end of line, full-line or
// trailing) are stripped first; real char.def records are then either
// "lo..hi CLASS" or "lo CLASS" - the dotted and single-codepoint hex
// forms unidic and ipadic ship - with an optional "lo hi CLASS"
// two-hex form accepted as well. "NAME INVOKE GROUP LENGTH" category
// definition lines set the class's unknown-word flags: a recognized
// name (char_class_from_name) targets its class, while the mandatory
// DEFAULT row targets .Unknown, the class of characters no range
// covers; rows naming unrecognized categories only affect the ranges
// that reference them (those map to .Unknown) and are ignored here.
// Single-token lines (count headers) are skipped. The range joins the
// list through override_insert: real files declare later ranges
// inside earlier blocks (kanji numerals inside the kanji block), and
// a later line wins on shared codepoints. A range must be a valid
// half-open span of real code points - [0, 0x110000], hi exclusive,
// hi > lo; anything else answers .Invalid_Format for the row.
read_char_def_line :: proc(ranges: ^[dynamic]Char_Range, line: []byte, fields_buf: ^[dynamic]string, flags: ^[len(Char_Class)]Char_Flags, scratch_allocator: mem.Allocator) -> Load_Err {
	s := line
	if h := strings.index(string(s), "#"); h >= 0 { s = s[:h] }
	if len(strings.trim_space(string(s))) == 0 { return nil }

	fields, werr := split_whitespace(string(s), fields_buf)
	if werr != nil { return werr }
	if len(fields) <= 1 { return nil }

	lo: rune
	hi: rune
	name: string
	ok := false
	if strings.contains(fields[0], "..") {
		if l, h, rok := parse_hex_range(fields[0]); rok && len(fields) >= 2 {
			lo, hi, name, ok = l, h, fields[1], true
		}
	} else if v1, ok1 := parse_codepoint(fields[0]); ok1 {
		if v2, ok2 := parse_codepoint(fields[1]); ok2 && len(fields) >= 3 {
			// Two hex columns then the class name.
			lo, hi, name, ok = rune(v1), rune(v2 + 1), fields[2], true
		} else if len(fields) >= 2 {
			// Single codepoint then the class name.
			lo, hi, name, ok = rune(v1), rune(v1 + 1), fields[1], true
		}
	} else if len(fields) >= 4 {
		// Category definition "NAME INVOKE GROUP LENGTH".
		iv, i1 := strconv.parse_int(fields[1])
		gv, i2 := strconv.parse_int(fields[2])
		lv, i3 := strconv.parse_int(fields[3])
		if i1 && i2 && i3 {
			if fields[0] == "DEFAULT" {
				// DEFAULT is the class of characters no range covers;
				// moli classifies those as .Unknown.
				flags[int(Char_Class.Unknown)] = char_flags_parse(iv, gv, lv)
			} else if cls, cok := char_class_from_name(fields[0]); cok {
				flags[int(cls)] = char_flags_parse(iv, gv, lv)
			}
			return nil
		}
	}
	if !ok { return .Invalid_Format }
	// Ranges are half-open [lo, hi) over real code points; hi may be
	// one past the last code point (0x10FFFF + 1 = 0x110000). An
	// inverted or out-of-range row would corrupt the punch-out
	// arithmetic that keeps the range list disjoint.
	if lo < 0 || hi <= lo || hi > UNICODE_LIMIT { return .Invalid_Format }

	cls, _ := char_class_from_name(name) // unknown custom categories map to .Unknown
	return override_insert(ranges, Char_Range{lo = lo, hi = hi, class = cls}, scratch_allocator)
}

// override_insert appends r with later-wins semantics: r's codepoints
// are punched out of every earlier range (which keeps its fragments on
// both sides), so a later declaration inside an earlier block
// overrides exactly the shared codepoints - the MeCab rule. Ranges
// disjoint from everything append unchanged. The rebuilt list lives in
// scratch_allocator; the discarded backing dies with the load arena, and so does
// everything a failure leaves behind - OOM answers .OutOfMemory with
// the arena's free-all as the release. The len+2 reservation is exact:
// only the range strictly containing r can split in two, every other
// old range keeps at most one fragment, so n olds plus r never exceed
// n+2 appends.
override_insert :: proc(ranges: ^[dynamic]Char_Range, r: Char_Range, scratch_allocator: mem.Allocator) -> Load_Err {
	overlaps := false
	for old in ranges^ {
		if r.lo < old.hi && old.lo < r.hi { overlaps = true; break }
	}
	if !overlaps {
		if _, e := append(ranges, r); e != nil { return .OutOfMemory }
		return nil
	}
	out, merr := make([dynamic]Char_Range, 0, len(ranges^) + 2, scratch_allocator)
	if merr != nil { return .OutOfMemory }
	for old in ranges^ {
		if perr := punch_hole(&out, old, r.lo, r.hi); perr != nil { return perr }
	}
	if _, e := append(&out, r); e != nil { return .OutOfMemory }
	ranges^ = out
	return nil
}

// parse_hex_range parses a MeCab hex range like "0x4E00..0x9FA5" or
// "0x4E00" (single codepoint); bare hex halves ("4E00") are accepted
// through parse_codepoint. Returns half-open [lo, hi).
parse_hex_range :: proc(s: string) -> (lo, hi: rune, ok: bool) {
	sep := strings.index(s, "..")
	if sep < 0 {
		v, ok1 := parse_codepoint(s)
		if !ok1 { return 0, 0, false }
		return rune(v), rune(v + 1), true
	}
	a := s[:sep]
	b := s[sep + 2:]
	va, oka := parse_codepoint(a)
	vb, okb := parse_codepoint(b)
	if !oka || !okb { return 0, 0, false }
	return rune(va), rune(vb + 1), true
}

// parse_codepoint parses one char.def code point field: decimal, a
// prefixed literal (0x4E00), or bare hex (4E00) - the un-prefixed
// form some dictionaries ship. Decimal parses first, so an all-digit
// field keeps its decimal meaning and only fields base-10 cannot read
// fall through to base 16. The value must land inside the code point
// universe at the parse itself: core strconv.parse_int has no
// overflow detection (values past i64 wrap with ok=true), so an
// unbounded int narrowed to rune would silently truncate - every
// record form (dotted range, two-column, single codepoint) passes
// through here, and the row-level validation below stays defense in
// depth rather than the only guard.
parse_codepoint :: proc(s: string) -> (int, bool) {
	v, ok := strconv.parse_int(s)
	if !ok { v, ok = strconv.parse_int(s, 16) }
	if !ok { return 0, false }
	if v < 0 || v >= UNICODE_LIMIT { return 0, false }
	return v, true
}

// parse_i16_saturating parses an integer and saturates it into i16:
// values beyond the range clamp to the range ends, preserving
// ordering. ok is false when the text is not numeric at all.
parse_i16_saturating :: proc(s: string) -> (i16, bool) {
	v, ok := strconv.parse_int(s)
	if !ok { return 0, false }
	max16 := int(max(i16))
	min16 := int(min(i16))
	if v > max16 { return max(i16), true }
	if v < min16 { return min(i16), true }
	return i16(v), true
}
