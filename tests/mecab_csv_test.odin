// MeCab CSV coverage: schema detection, the quoting-aware field
// parser (embedded commas, doubled quotes, trailing quoted fields),
// per-schema parse, integer-parse saturation (the i16 clamp and the
// decimal parse's i64 edges), the empty/BOM/malformed file gauntlet
// at the load boundary, and the allocation-failure legs (parse_entry's
// clone ladder, the entries append at a growth point).
package tests

import "core:mem"
import "core:testing"
import "moli:moli"

// The reference ipadic row the schema-detection and parse tests share
// (13 columns; the real first row of tests/fixtures/ipadic_sample.csv).
ipadic_reference_row :: "さくら,0,0,5500,名詞,一般,*,*,*,*,さくら,サクラ,サクラ"

// parse_intern builds the intern table parse_entry borrows its
// repeatable fields through; the caller releases it with
// intern_table_release.
parse_intern :: proc(t: ^testing.T, allocator: mem.Allocator) -> (intern: map[string]string, ok: bool) {
	table, err := moli.intern_table_init(allocator)
	if err != nil {
		testing.expectf(t, false, "intern table init: %v", err)
		return nil, false
	}
	return table, true
}

@(test)
csv_schema_detection_test :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	scratch_allocator := mem.dynamic_arena_allocator(&arena)
	fields_buf := make([dynamic]string, 0, 16, scratch_allocator)
	unquoted_buf := make([dynamic]u8, 0, 16, scratch_allocator)

	// Real first rows from the committed fixtures (the ipadic one is
	// the shared reference row above).
	unidic_line := "ぬかそっ,1323,1323,12837,動詞,一般,*,*,五段-サ行,意志推量形,ヌカス,吐かす,ぬかそっ,ヌカソッ,ぬかす,ヌカス,和,*,*,*,*"
	jieba_line := "库东,0,0,763,ns,*,*,*,*"

	schema, cols, err := moli.detect_schema(.Japanese, ipadic_reference_row, &fields_buf, &unquoted_buf)
	if err != nil || schema != .Ipadic || cols != 13 {
		testing.expectf(t, false, "ipadic: got (%v, %v, %v)", schema, cols, err)
		return
	}
	schema, cols, err = moli.detect_schema(.Japanese, unidic_line, &fields_buf, &unquoted_buf)
	if err != nil || schema != .Unidic || cols != 21 {
		testing.expectf(t, false, "unidic: got (%v, %v, %v)", schema, cols, err)
		return
	}
	schema, cols, err = moli.detect_schema(.ChineseCN, jieba_line, &fields_buf, &unquoted_buf)
	if err != nil || schema != .MeCabJieba || cols != 9 {
		testing.expectf(t, false, "jieba CN: got (%v, %v, %v)", schema, cols, err)
		return
	}
	schema, _, err = moli.detect_schema(.ChineseHK, jieba_line, &fields_buf, &unquoted_buf)
	if err != nil || schema != .MeCabJiebaHK {
		testing.expectf(t, false, "jieba HK: got (%v, %v)", schema, err)
		return
	}
	schema, _, err = moli.detect_schema(.EnglishGB, ipadic_reference_row, &fields_buf, &unquoted_buf)
	if err != nil || schema != .EnglishExt {
		testing.expectf(t, false, "english 13-col: got (%v, %v)", schema, err)
		return
	}

	// An unclassifiable field count fails the load.
	if _, _, err := moli.detect_schema(.Japanese, "abc", &fields_buf, &unquoted_buf); err == nil {
		testing.expectf(t, false, "1-column line must be unclassifiable")
		return
	}
	// An unterminated quote is malformed, not unclassifiable.
	if _, _, err := moli.detect_schema(.Japanese, "\"abc,1,2", &fields_buf, &unquoted_buf); err == nil {
		testing.expectf(t, false, "unterminated quote must fail detection")
		return
	}
}

@(test)
csv_quoting_test :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	scratch_allocator := mem.dynamic_arena_allocator(&arena)
	fields_buf := make([dynamic]string, 0, 16, scratch_allocator)
	unquoted_buf := make([dynamic]u8, 0, 16, scratch_allocator)

	cases := []struct {
		line:   string,
		fields: []string,
	}{
		{line = "a,\"b,c\",d", fields = []string{"a", "b,c", "d"}},
		{line = "x,\"\"\"q\"\"\",y", fields = []string{"x", "\"q\"", "y"}},
		{line = "a\"b,c", fields = []string{"a\"b", "c"}},
		{line = "さくら,0,\"quoted\"", fields = []string{"さくら", "0", "quoted"}},
		{line = "a,,c", fields = []string{"a", "", "c"}},
		{line = "a,,", fields = []string{"a", "", ""}},
	}
	for c in cases {
		fields, err := moli.split_fields(c.line, &fields_buf, &unquoted_buf)
		if err != nil {
			testing.expectf(t, false, "split_fields(%q) reported %v", c.line, err)
			return
		}
		if len(fields) != len(c.fields) {
			testing.expectf(t, false, "split_fields(%q): got %v fields, want %v", c.line, len(fields), len(c.fields))
			return
		}
		for f, i in fields {
			if f != c.fields[i] {
				testing.expectf(t, false, "split_fields(%q)[%v]: got %q, want %q", c.line, i, f, c.fields[i])
				return
			}
		}
	}

	// The trailing-quoted-field case is a regression guard: the parser
	// once returned next = len(line) here and split_fields appended a
	// spurious empty extra field.
	fields, err := moli.split_fields("a,\"b,c\"", &fields_buf, &unquoted_buf)
	if err != nil || len(fields) != 2 || fields[1] != "b,c" {
		testing.expectf(t, false, "trailing quoted field: got (%v fields, err=%v)", len(fields), err)
		return
	}

		// An unterminated quoted field is malformed.
	if _, err2 := moli.split_fields("a,\"bc", &fields_buf, &unquoted_buf); err2 == nil {
		testing.expectf(t, false, "unterminated quote must answer malformed")
	}
}

// The reused per-line buffers grow past their reservations when a
// quoted field exceeds 64 bytes or a record carries more than 32
// fields: the growth must surface as .OutOfMemory, never a silently
// truncated field (the pre-fix behavior under arena exhaustion).
@(test)
field_buffer_growth_oom_test :: proc(t: ^testing.T) {
	nr := No_Resize_Allocator{backing = context.allocator}
	allocator := mem.Allocator{data = &nr, procedure = no_resize_proc}
	fields_buf := make([dynamic]string, 0, 32, allocator)
	defer delete(fields_buf)
	unquoted_buf := make([dynamic]u8, 0, 64, allocator)
	defer delete(unquoted_buf)
	intern, iok := parse_intern(t, context.allocator)
	if !iok { return }
	defer moli.intern_table_release(&intern, context.allocator)

	// A 79-byte quoted field must grow the unquoted buffer; the
	// no-resize allocator fails exactly that growth.
	quoted :: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+abcd"
	long_line := "\"" + quoted + "\",0,0,0,名詞,一般,*,*,*,*,x,y,z"
	_, qerr := moli.parse_entry(.Ipadic, transmute([]byte)long_line, 1, 13, context.allocator, &fields_buf, &unquoted_buf, &intern)
	testing.expectf(t, qerr == moli.Load_Fault.OutOfMemory,
		"quoted-field buffer growth must surface as .OutOfMemory, got %v", qerr)

	// A 39-field record must grow the fields buffer.
	wide := "a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z,aa,bb,cc,dd,ee,ff,gg,hh,ii,jj,kk,ll,mm,nn"
	_, werr := moli.split_fields(wide, &fields_buf, &unquoted_buf)
	testing.expectf(t, werr == moli.Load_Fault.OutOfMemory,
		"fields-buffer growth must surface as .OutOfMemory, got %v", werr)

	// Correctness at scale under a healthy allocator: the same long
	// quoted field parses whole.
	fb := make([dynamic]string, 0, 8, context.allocator)
	defer delete(fb)
	ub := make([dynamic]u8, 0, 16, context.allocator)
	defer delete(ub)
	e, perr := moli.parse_entry(.Ipadic, transmute([]byte)long_line, 1, 13, context.allocator, &fb, &ub, &intern)
	if perr != nil {
		testing.expectf(t, false, "long quoted field must parse: %v", perr)
		return
	}
	testing.expectf(t, e.surface == quoted,
		"the long quoted field must arrive whole, got %d bytes", len(e.surface))
	moli.dictionary_entry_destroy(&e, context.allocator)
}

// The malformed-file gauntlet through the public load boundary: every
// rejection must propagate with its error kind intact (and each
// rejection drives the partial teardown, which the leak gate checks).
@(test)
load_malformed_gauntlet_test :: proc(t: ^testing.T) {
	// context.allocator puts every load's lifecycle under the leak gate,
	// which is what makes the partial teardown of each rejection
	// checkable instead of invisible.
	allocator := context.allocator

	// Empty file.
	write_tmp(t, "tmp/bad_empty.csv", "")
	_, e1 := moli.load(.Japanese, "tmp/bad_empty.csv", {}, allocator)
	testing.expectf(t, e1 == moli.Load_Fault.Invalid_Format, "empty file: %v", e1)

	// Blank lines only: no entry ever lands.
	write_tmp(t, "tmp/bad_blank.csv", "\n\n   \n\n")
	_, e2 := moli.load(.Japanese, "tmp/bad_blank.csv", {}, allocator)
	testing.expectf(t, e2 == moli.Load_Fault.Invalid_Format, "blank-only file: %v", e2)

	// A later row's column count mismatches the schema: the load fails
	// with Schema_Mismatch_Error carrying the line number.
	write_tmp(t, "tmp/bad_cols.csv",
		"犬,0,0,0,名詞,一般,*,*,*,*,犬,イヌ,イヌ\n猫,0,0,0,名詞\n")
	_, e3 := moli.load(.Japanese, "tmp/bad_cols.csv", {}, allocator)
	if e3 == nil {
		testing.expectf(t, false, "column mismatch must fail the load, got success")
		return
	}
	switch v in e3 {
	case moli.Schema_Mismatch_Error:
		testing.expectf(t, v.line == 2, "mismatch line: %v", v.line)
	case moli.Load_Fault:
		testing.expectf(t, false, "column mismatch must carry Schema_Mismatch_Error, got %v", e3)
	}

	// An unterminated quoted field fails the whole load.
	write_tmp(t, "tmp/bad_quote.csv", "\"犬,0,0,0,名詞,一般,*,*,*,*,犬,イヌ,イヌ\n")
	_, e4 := moli.load(.Japanese, "tmp/bad_quote.csv", {}, allocator)
	testing.expectf(t, e4 == moli.Load_Fault.Invalid_Format, "unterminated quote: %v", e4)

	// Garbage right after a closing quote - a mid-record CR included -
	// is malformed quoting, not a truncated record: the field parser
	// closes a quoted field only on ',' or the record end (records
	// arrive terminator-stripped from the line reader), so the fault
	// is .Invalid_Format, never a Schema_Mismatch from a silently
	// dropped tail.
	write_tmp(t, "tmp/bad_quote_cr.csv", "\"犬\"\r,0,0,0,名詞,一般,*,*,*,*,犬,イヌ,イヌ\n")
	_, e4b := moli.load(.Japanese, "tmp/bad_quote_cr.csv", {}, allocator)
	testing.expectf(t, e4b == moli.Load_Fault.Invalid_Format, "post-quote CR: %v", e4b)

	// Malformed UTF-8 in a row is NOT a load failure: the loader does
	// no UTF-8 validation (tokenizer-side strictness is a per-call
	// option), the invalid byte decodes as U+FFFD on every path that
	// reads it (build-time mapping and tokenize-time walking agree),
	// and the row lands as a matchable dictionary entry.
	write_tmp(t, "tmp/bad_utf8.csv",
		"\x81,0,0,0,名詞,一般,*,*,*,*,\x81,イヌ,イヌ\n")
	a8, e8 := moli.load(.Japanese, "tmp/bad_utf8.csv", {}, allocator)
	testing.expectf(t, e8 == nil, "malformed UTF-8 row must load: %v", e8)
	if e8 == nil {
		// The standard 64 KiB request arena: the lattice node buffer
		// alone has a 4608-byte floor, so a smaller arena would fail
		// as .OutOfMemory for reasons unrelated to the case.
		arena_buf: [1 << 16]byte
		arena: mem.Arena
		mem.arena_init(&arena, arena_buf[:])
		// The same invalid byte decodes to U+FFFD at tokenize time, so
		// the row matches as a dictionary morpheme, not an unknown.
		ms8, terr8 := moli.tokenize(&a8, "\x81", mem.arena_allocator(&arena))
		testing.expectf(t, terr8 == nil && len(ms8) == 1 && !ms8[0].is_unknown && ms8[0].entry_id >= 0,
			"malformed surface must resolve to its dictionary row, got %d morphemes", len(ms8))
		moli.free(&a8)
	}

	// Malformed optional resources through their explicit paths.
	write_tmp(t, "tmp/bad_res.csv", "犬,0,0,0,名詞,一般,*,*,*,*,犬,イヌ,イヌ\n")
	write_tmp(t, "tmp/bad_unk.def", "NOSUCHCLASS,0,0,5000,名詞\n")
	write_tmp(t, "tmp/bad_char.def", "0xZZ..0x9FFF KANJI\n")
	write_tmp(t, "tmp/bad_matrix.def", "1 1\n5 0 100\n")

	_, e5 := moli.load(.Japanese, "tmp/bad_res.csv", {unk_def_path = "tmp/bad_unk.def"}, allocator)
	testing.expectf(t, e5 == moli.Load_Fault.Invalid_Format, "bad unk.def: %v", e5)

	_, e6 := moli.load(.Japanese, "tmp/bad_res.csv", {char_def_path = "tmp/bad_char.def"}, allocator)
	testing.expectf(t, e6 == moli.Load_Fault.Invalid_Format, "bad char.def: %v", e6)

	_, e7 := moli.load(.Japanese, "tmp/bad_res.csv", {matrix_def_path = "tmp/bad_matrix.def"}, allocator)
	testing.expectf(t, e7 == moli.Load_Fault.Invalid_Format, "bad matrix.def: %v", e7)
}

@(test)
csv_per_schema_parse_test :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	scratch_allocator := mem.dynamic_arena_allocator(&arena)
	fields_buf := make([dynamic]string, 0, 16, scratch_allocator)
	unquoted_buf := make([dynamic]u8, 0, 16, scratch_allocator)
	// parse_entry's clone/destroy pairing rides the tracking allocator.
	allocator := context.allocator
	intern, iok := parse_intern(t, allocator)
	if !iok { return }
	defer moli.intern_table_release(&intern, allocator)

	// Ipadic 13-column row (the shared reference row).
	line := ipadic_reference_row
	e, err := moli.parse_entry(.Ipadic, transmute([]byte)line, 1, 13, allocator, &fields_buf, &unquoted_buf, &intern)
	if err != nil {
		testing.expectf(t, false, "ipadic parse: %v", err)
		return
	}
	if e.surface != "さくら" || e.left_id != 0 || e.right_id != 0 || e.cost != 5500 {
		testing.expectf(t, false, "ipadic head fields: %+v", e)
		moli.dictionary_entry_destroy(&e, allocator)
		return
	}
	if e.joined_pos != "名詞,一般" || e.lemma != "さくら" || e.reading != "サクラ" || e.reading_jyutping != "*" {
		testing.expectf(t, false, "ipadic strings: (%s|%s|%s|%s)", e.joined_pos, e.lemma, e.reading, e.reading_jyutping)
		moli.dictionary_entry_destroy(&e, allocator)
		return
	}
	moli.dictionary_entry_destroy(&e, allocator)

	// MeCabJieba 9-column row with a quoted definition tail: the lemma
	// is a separate clone of the surface value.
	jieba_line := "一乾二淨,0,0,763,i,yi1 gan1 er4 jing4,一乾二淨,一干二净,\"thoroughly, completely\""
	e, err = moli.parse_entry(.MeCabJieba, transmute([]byte)jieba_line, 1, 9, allocator, &fields_buf, &unquoted_buf, &intern)
	if err != nil {
		testing.expectf(t, false, "jieba parse: %v", err)
		return
	}
	if e.surface != "一乾二淨" || e.joined_pos != "i" || e.reading != "yi1 gan1 er4 jing4" {
		testing.expectf(t, false, "jieba fields: (%s|%s|%s)", e.surface, e.joined_pos, e.reading)
		moli.dictionary_entry_destroy(&e, allocator)
		return
	}
	if e.lemma != "一乾二淨" || e.reading_jyutping != "*" {
		testing.expectf(t, false, "jieba lemma/jyutping: (%s|%s)", e.lemma, e.reading_jyutping)
		moli.dictionary_entry_destroy(&e, allocator)
		return
	}
	if len(e.extra) != 1 || e.extra[0] != "thoroughly, completely" {
		testing.expectf(t, false, "jieba extra: %v", e.extra)
		moli.dictionary_entry_destroy(&e, allocator)
		return
	}
	moli.dictionary_entry_destroy(&e, allocator)

	// Unidic 21-column row (unidic-mecab 2.1.2 layout): POS cols 4-9,
	// lemma col 11, pronunciation col 13, cols 17+ extra.
	unidic_line := "ぬかそっ,1323,1323,12837,動詞,一般,*,*,五段-サ行,意志推量形,ヌカス,吐かす,ぬかそっ,ヌカソッ,ぬかす,ヌカス,和,*,*,*,*"
	e, err = moli.parse_entry(.Unidic, transmute([]byte)unidic_line, 1, 21, allocator, &fields_buf, &unquoted_buf, &intern)
	if err != nil {
		testing.expectf(t, false, "unidic parse: %v", err)
		return
	}
	if e.left_id != 1323 || e.right_id != 1323 || e.cost != 12837 {
		testing.expectf(t, false, "unidic head fields: %+v", e)
		moli.dictionary_entry_destroy(&e, allocator)
		return
	}
	if e.joined_pos != "動詞,一般,五段-サ行,意志推量形" || e.lemma != "吐かす" || e.reading != "ヌカソッ" {
		testing.expectf(t, false, "unidic strings: (%s|%s|%s)", e.joined_pos, e.lemma, e.reading)
		moli.dictionary_entry_destroy(&e, allocator)
		return
	}
	if len(e.extra) != 4 {
		testing.expectf(t, false, "unidic extra: %v fields", len(e.extra))
		moli.dictionary_entry_destroy(&e, allocator)
		return
	}
	moli.dictionary_entry_destroy(&e, allocator)

	// Column-count mismatch answers Schema_Mismatch_Error.
	bad_line := "さくら,0,0,5500,名詞,一般,*,*,*,*,さくら,サクラ"
	_, err = moli.parse_entry(.Ipadic, transmute([]byte)bad_line, 7, 13, allocator, &fields_buf, &unquoted_buf, &intern)
	if err == nil {
		testing.expectf(t, false, "12-col ipadic line must fail with Schema_Mismatch_Error, got success")
		return
	}
	switch e2 in err {
	case moli.Schema_Mismatch_Error:
		if e2.line != 7 || e2.expected != 13 || e2.got != 12 {
			testing.expectf(t, false, "mismatch context: %+v", e2)
			return
		}
	case moli.Load_Fault:
		testing.expectf(t, false, "12-col ipadic line: want Schema_Mismatch_Error, got %v", e2)
		return
	}

	// An empty surface and non-numeric ids abort the load.
	empty_surface := ",0,0,5000,名詞,一般,*,*,*,*,x,y,z"
	if _, err := moli.parse_entry(.Ipadic, transmute([]byte)empty_surface, 1, 13, allocator, &fields_buf, &unquoted_buf, &intern); err == nil {
		testing.expectf(t, false, "empty surface must fail")
		return
	}
	bad_id := "犬,x,0,5000,名詞,一般,*,*,*,*,犬,イヌ,イヌ"
	if _, err := moli.parse_entry(.Ipadic, transmute([]byte)bad_id, 1, 13, allocator, &fields_buf, &unquoted_buf, &intern); err == nil {
		testing.expectf(t, false, "non-numeric left id must fail")
		return
	}
}

@(test)
csv_intern_sharing_test :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	scratch_allocator := mem.dynamic_arena_allocator(&arena)
	fields_buf := make([dynamic]string, 0, 16, scratch_allocator)
	unquoted_buf := make([dynamic]u8, 0, 16, scratch_allocator)
	allocator := context.allocator
	intern, iok := parse_intern(t, allocator)
	if !iok { return }
	defer moli.intern_table_release(&intern, allocator)

	// Two rows whose joined POS and "*" sentinels repeat: the second
	// row borrows the first's canonical backing (one copy per distinct
	// value), while surfaces stay private per row.
	line_a := "さくら,0,0,5500,名詞,一般,*,*,*,*,さくら,サクラ,サクラ"
	line_b := "すずめ,0,0,5500,名詞,一般,*,*,*,*,すずめ,スズメ,スズメ"
	ea, ea_err := moli.parse_entry(.Ipadic, transmute([]byte)line_a, 1, 13, allocator, &fields_buf, &unquoted_buf, &intern)
	if ea_err != nil {
		testing.expectf(t, false, "row a: %v", ea_err)
		return
	}
	eb, eb_err := moli.parse_entry(.Ipadic, transmute([]byte)line_b, 1, 13, allocator, &fields_buf, &unquoted_buf, &intern)
	if eb_err != nil {
		moli.dictionary_entry_destroy(&ea, allocator)
		testing.expectf(t, false, "row b: %v", eb_err)
		return
	}
	shared_pos := raw_data(ea.joined_pos) == raw_data(eb.joined_pos)
	shared_star := raw_data(ea.reading_jyutping) == raw_data(eb.reading_jyutping)
	private_surface := raw_data(ea.surface) != raw_data(eb.surface)
	private_reading := raw_data(ea.reading) != raw_data(eb.reading)
	moli.dictionary_entry_destroy(&ea, allocator)
	moli.dictionary_entry_destroy(&eb, allocator)
	testing.expectf(t, shared_pos, "repeated joined_pos must share the canonical backing")
	testing.expectf(t, shared_star, "the \"*\" sentinel must share the canonical backing")
	testing.expectf(t, private_surface, "surfaces stay private per row")
	testing.expectf(t, private_reading, "distinct readings stay private per row")
}

@(test)
csv_cost_saturation_test :: proc(t: ^testing.T) {
	if v, ok := moli.parse_i16_saturating("40000"); !ok || v != 32767 {
		testing.expectf(t, false, "40000: got (%v, %v)", v, ok)
		return
	}
	if v, ok := moli.parse_i16_saturating("-40000"); !ok || v != -32768 {
		testing.expectf(t, false, "-40000: got (%v, %v)", v, ok)
		return
	}
	if v, ok := moli.parse_i16_saturating("7000"); !ok || v != 7000 {
		testing.expectf(t, false, "7000: got (%v, %v)", v, ok)
		return
	}
	if _, ok := moli.parse_i16_saturating("abc"); ok {
		testing.expectf(t, false, "abc must not parse")
		return
	}
	if _, ok := moli.parse_i16_saturating(""); ok {
		testing.expectf(t, false, "empty string must not parse")
		return
	}
}

// parse_decimal's value contract at its edges: an optionally signed
// run of ASCII digits, a magnitude the ladder cannot hold saturates
// to the i64 ends (the callers' range checks and the i16 clamp own
// the decisions), and anything else - a radix prefix, an underscore
// separator, surrounding whitespace, a bare sign - is not a number.
@(test)
parse_decimal_edge_test :: proc(t: ^testing.T) {
	cases := []struct {
		input:   string,
		want:    int,
		want_ok: bool,
	}{
		{"", 0, false},
		{"0", 0, true},
		{"-0", 0, true},
		{"+5", 5, true},
		{"-5", -5, true},
		{"007", 7, true},
		{" 5", 0, false},
		{"5 ", 0, false},
		{"0x10", 0, false},
		{"1_0", 0, false},
		{"9z", 0, false},
		{"+", 0, false},
		{"-", 0, false},
		// Saturation fires on the running digit prefix at
		// (max(i64)-9)/10: inputs up to max(i64)-8 multiply out
		// exactly, the window from max(i64)-7 up answers the ends -
		// at every caller (dimension and id range checks, the i16
		// clamp) the saturated outcome matches the exact value's.
		{"9223372036854775798", 9223372036854775798, true},
		{"9223372036854775800", max(int), true},
		{"9223372036854775807", max(int), true},
		{"9223372036854775808", max(int), true},
		{"99999999999999999999", max(int), true},
		{"-9223372036854775808", min(int), true},
		{"-99999999999999999999", min(int), true},
	}
	for c in cases {
		got, ok := moli.parse_decimal(c.input)
		if ok != c.want_ok || got != c.want {
			testing.expectf(t, false, "parse_decimal(%q): want (%v, %v), got (%v, %v)",
				c.input, c.want, c.want_ok, got, ok)
			return
		}
	}
}

@(test)
csv_empty_and_malformed_test :: proc(t: ^testing.T) {
	allocator := context.allocator

	// Empty file: no schema to detect.
	write_tmp(t, "tmp/csv_empty.csv", "")
	if _, err := moli.load(.Japanese, "tmp/csv_empty.csv", {}, allocator); err == nil {
		testing.expectf(t, false, "empty file must fail")
		return
	}

	// BOM + a single unterminated line: both the BOM drop and the EOF
	// drop are regression guards - this file loads exactly one entry.
	write_tmp(t, "tmp/csv_bom_one.csv", "\xEF\xBB\xBF犬,0,0,5000,名詞,一般,*,*,*,*,犬,イヌ,イヌ")
	a, err := moli.load(.Japanese, "tmp/csv_bom_one.csv", {}, allocator)
	if err != nil {
		testing.expectf(t, false, "BOM + EOF line: %v", err)
		return
	}
	if len(a.entries) != 1 || a.entries[0].surface != "犬" {
		testing.expectf(t, false, "BOM + EOF line: %v entries", len(a.entries))
		moli.free(&a)
		return
	}
	moli.free(&a)

	// BOM + two terminated lines; the terminator must not leak into
	// the last column. Entries arrive surface-sorted: が sorts before
	// 犬 regardless of file order.
	write_tmp(t, "tmp/csv_bom_two.csv", "\xEF\xBB\xBF犬,0,0,5000,名詞,一般,*,*,*,*,犬,イヌ,イヌ\nが,0,0,4000,助詞,格助詞,一般,*,*,*,が,ガ,ガ\n")
	a, err = moli.load(.Japanese, "tmp/csv_bom_two.csv", {}, allocator)
	if err != nil {
		testing.expectf(t, false, "BOM two-line: %v", err)
		return
	}
	if len(a.entries) != 2 || a.entries[0].surface != "が" || a.entries[1].surface != "犬" {
		testing.expectf(t, false, "BOM two-line: %v entries, want surface-sorted [が, 犬]", len(a.entries))
		moli.free(&a)
		return
	}
	if a.entries[1].reading != "イヌ" {
		testing.expectf(t, false, "terminator leaked into last column: reading %q", a.entries[1].reading)
		moli.free(&a)
		return
	}
	moli.free(&a)

	// Unterminated quote aborts the load.
	write_tmp(t, "tmp/csv_badquote.csv", "犬,0,0,5000,\"名詞,一般,*,*,*,*,犬,イヌ,イヌ\n")
	if _, err := moli.load(.Japanese, "tmp/csv_badquote.csv", {}, allocator); err == nil {
		testing.expectf(t, false, "unterminated quote must fail the load")
		return
	}

	// A one-field line is unclassifiable.
	write_tmp(t, "tmp/csv_onefield.csv", "nocolumns\n")
	if _, err := moli.load(.Japanese, "tmp/csv_onefield.csv", {}, allocator); err == nil {
		testing.expectf(t, false, "one-field line must fail the load")
		return
	}

	// A missing dictionary is a hard .File_Not_Found.
	if _, err := moli.load(.Japanese, "tmp/csv_absent.csv", {}, allocator); err == nil {
		testing.expectf(t, false, "missing file must fail")
		return
	}
	switch e in err {
	case moli.Load_Fault:
		if e != .File_Not_Found {
			testing.expectf(t, false, "missing file: want File_Not_Found, got %v", e)
			return
		}
	case moli.Schema_Mismatch_Error:
		testing.expectf(t, false, "missing file: want Load_Fault, got %v", e)
		return
	}
}

// parse_entry's clone/allocate ladder must fail cleanly at every
// point: a budget sweep starves each allocation in turn, every failure
// answers .OutOfMemory, and the ladder destroys its partial row (the
// leak gate sees anything left behind).
@(test)
parse_entry_oom_sweep_test :: proc(t: ^testing.T) {
	fields_buf := make([dynamic]string, 0, 32, context.allocator)
	defer delete(fields_buf)
	unquoted_buf := make([dynamic]u8, 0, 64, context.allocator)
	defer delete(unquoted_buf)
	// The intern table rides the plain allocator so the sweep starves
	// only the ladder's clones; borrowed fields skip each iteration's
	// destroy by mask.
	intern, iok := parse_intern(t, context.allocator)
	if !iok { return }
	defer moli.intern_table_release(&intern, context.allocator)

	line := "犬,1285,1285,5000,名詞,一般,*,*,*,*,犬,イヌ,イヌ"
	saw_oom := false
	parsed := false
	for budget in 0 ..< 12 {
		b := Budget_Allocator{backing = context.allocator, remaining = budget}
		allocator := mem.Allocator{data = &b, procedure = budget_allocator_proc}
		e, err := moli.parse_entry(.Ipadic, transmute([]byte)line, 1, 13, allocator, &fields_buf, &unquoted_buf, &intern)
		if err == nil {
			moli.dictionary_entry_destroy(&e, allocator)
			parsed = true
		} else {
			testing.expectf(t, err == moli.Load_Fault.OutOfMemory,
				"budget %d: parse_entry must fail with .OutOfMemory, got %v", budget, err)
			saw_oom = true
		}
	}
	testing.expectf(t, saw_oom && parsed,
		"the sweep must cover both failure and success (oom=%v parsed=%v)", saw_oom, parsed)
}

// A growth failure of the entries append - the hottest fallible import
// allocation, since real dictionaries cross the array's initial
// capacity thousands of rows in - must fail the load and destroy the
// rejected row's cloned strings, never silently truncate the
// dictionary behind a nil error.
@(test)
import_append_growth_oom_test :: proc(t: ^testing.T) {
	nr := No_Resize_Allocator{backing = context.allocator}
	allocator := mem.Allocator{data = &nr, procedure = no_resize_proc}

	imp: moli.Importer
	imp.lang = .Japanese
	imp.allocator = allocator
	mem.dynamic_arena_init(&imp.scratch)
	defer mem.dynamic_arena_destroy(&imp.scratch)

	// Capacity 1: the second row's append must grow, and the no-resize
	// allocator fails exactly that.
	entries, merr := make([dynamic]moli.Dictionary_Entry, 0, 1, allocator)
	if merr != nil {
		testing.expectf(t, false, "entries make: %v", merr)
		return
	}
	imp.entries = entries
	if err := moli.importer_init_bufs(&imp); err != nil {
		testing.expectf(t, false, "init bufs: %v", err)
		return
	}
	// The intern table is part of the importer's initialized state: a
	// nil map would grow its first insert through the ambient
	// allocator (the documented nil-collection landmine).
	intern_table, ierr := moli.intern_table_init(allocator)
	if ierr != nil {
		testing.expectf(t, false, "intern init: %v", ierr)
		return
	}
	imp.intern = intern_table

	line1 := "犬,1285,1285,5000,名詞,一般,*,*,*,*,犬,イヌ,イヌ"
	line2 := "猫,1285,1285,5000,名詞,一般,*,*,*,*,猫,ネコ,ネコ"
	if err := moli.parse_and_append(&imp, transmute([]byte)line1, 1, 13); err != nil {
		testing.expectf(t, false, "first row must parse: %v", err)
		return
	}
	err := moli.parse_and_append(&imp, transmute([]byte)line2, 2, 13)
	testing.expectf(t, err == moli.Load_Fault.OutOfMemory,
		"the growth append must fail the row, got %v", err)
	testing.expectf(t, len(imp.entries) == 1,
		"the failed row must not land, got %d entries", len(imp.entries))

	for _, i in imp.entries {
		e := imp.entries[i]
		moli.dictionary_entry_destroy(&e, allocator)
	}
	delete(imp.entries)
	moli.intern_table_release(&imp.intern, allocator)
}

// A UTF-8 BOM in front of any optional resource is tolerated: every
// resource loader strips it from the first non-blank line, the way
// the dictionary CSV always has. Editors drop BOMs on any text file.
@(test)
resources_bom_test :: proc(t: ^testing.T) {
	write_tmp(t, "tmp/bom_unk.def", "\xEF\xBB\xBFDEFAULT,0,0,10000,名詞,普通名詞,*\n")
	write_tmp(t, "tmp/bom_char.def", "\xEF\xBB\xBF0x0041..0x005A SYMBOL\n")
	write_tmp(t, "tmp/bom_matrix.def", "\xEF\xBB\xBF1 1\n0 0 100\n")
	write_tmp(t, "tmp/bom_qpat.pat", "\xEF\xBB\xBFprefix,第,1,2,4500,名詞,接頭辞,*\n")

	a, err := moli.load(.Japanese, RESOURCES_FIXTURE, {
		unk_def_path    = "tmp/bom_unk.def",
		char_def_path   = "tmp/bom_char.def",
		matrix_def_path = "tmp/bom_matrix.def",
		qpat_path       = "tmp/bom_qpat.pat",
	}, context.allocator)
	if err != nil {
		testing.expectf(t, false, "BOM'd resources must load: %v", err)
		return
	}
	testing.expectf(t, len(a.unk_def) == 1 && len(a.unk_patterns) == 1,
		"the BOM'd rows landed (unk %d, qpat %d)", len(a.unk_def), len(a.unk_patterns))
	moli.free(&a)
}
