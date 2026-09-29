// Char classification coverage: known ranges (Hiragana, Hanzi, ASCII,
// Bopomofo U+3100-312F and U+31A0-31BF), boundary values, the sorted
// invariant, load-time rejection of unsorted/overlapping tables, and
// the allocation-failure legs of the build and override paths.
package tests

import "base:runtime"
import "core:mem"
import "core:testing"
import "moli:moli"

@(test)
char_class_known_ranges_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()

	table, err := moli.char_class_build(.Japanese, nil, false, allocator)
	if err != nil {
		testing.expectf(t, false, "build Japanese: %v", err)
		return
	}
	defer {
		if table.ranges != nil { delete(table.ranges) }
		if len(table.flat) > 0 { delete(table.flat, allocator) }
	}

	cases := []struct {
		r:    rune,
		want: moli.Char_Class,
	}{
		{r = 'あ', want = .Hiragana},
		{r = 'ア', want = .Katakana},
		{r = '漢', want = .Hanzi},
		{r = 'a', want = .ASCIILetter},
		{r = 'Z', want = .ASCIILetter},
		{r = '5', want = .Digit},
		{r = ' ', want = .Space},
		{r = ',', want = .Punct},
		{r = rune(0x1F600), want = .Emoji},
	}
	for c in cases {
		if got := moli.char_class_of(&table, c.r); got != c.want {
			testing.expectf(t, false, "Japanese %x: got %v, want %v", c.r, got, c.want)
			return
		}
	}

	// Bopomofo is a ZH-TW/HK extra.
	tw, terr := moli.char_class_build(.ChineseTW, nil, false, allocator)
	if terr != nil {
		testing.expectf(t, false, "build ChineseTW: %v", terr)
		return
	}
	defer if tw.ranges != nil { delete(tw.ranges) }
	bopomofo := []rune{rune(0x3105), rune(0x312F), rune(0x31A1), rune(0x31BF)}
	for r in bopomofo {
		if got := moli.char_class_of(&tw, r); got != .Bopomofo {
			testing.expectf(t, false, "TW bopomofo %x: got %v", r, got)
			return
		}
	}

	// The flat table answers identically.
	flat, ferr := moli.char_class_build(.Japanese, nil, true, allocator)
	if ferr != nil {
		testing.expectf(t, false, "build flat: %v", ferr)
		return
	}
	defer {
		if flat.ranges != nil { delete(flat.ranges) }
		if len(flat.flat) > 0 { delete(flat.flat, allocator) }
	}
	if got := moli.char_class_of(&flat, 'あ'); got != .Hiragana {
		testing.expectf(t, false, "flat あ: got %v", got)
		return
	}
}

@(test)
char_class_boundary_values_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()
	table, err := moli.char_class_build(.Japanese, nil, false, allocator)
	if err != nil {
		testing.expectf(t, false, "build: %v", err)
		return
	}
	defer if table.ranges != nil { delete(table.ranges) }

	// Half-open ranges: lo in, hi out, at every junction that matters.
	cases := []struct {
		r:    rune,
		want: moli.Char_Class,
	}{
		{r = rune(0x3040), want = .Hiragana},
		{r = rune(0x309F), want = .Hiragana},
		{r = rune(0x30A0), want = .Katakana},
		{r = rune(0x30FF), want = .Katakana},
		{r = rune(0xFF66), want = .HalfwidthKatakana},
		{r = rune(0xFF9F), want = .HalfwidthKatakana},
		{r = rune(0xFF65), want = .Unknown}, // halfwidth middle dot: punctuation block gap
		{r = rune(0xFFA0), want = .Unknown},
		{r = '/', want = .Punct},
		{r = '0', want = .Digit},
		{r = ':', want = .Punct},
		{r = '@', want = .Punct},
		{r = 'A', want = .ASCIILetter},
		{r = rune(0x2F), want = .Punct},
	}
	for c in cases {
		if got := moli.char_class_of(&table, c.r); got != c.want {
			testing.expectf(t, false, "%x: got %v, want %v", c.r, got, c.want)
			return
		}
	}

	// Unassigned runes and malformed decodes fall to .Unknown.
	if got := moli.char_class_of(&table, rune(0x10FFFF)); got != .Unknown {
		testing.expectf(t, false, "unassigned: got %v", got)
		return
	}
	if got := moli.char_class_of(&table, utf8_rune_error()); got != .Unknown {
		testing.expectf(t, false, "RUNE_ERROR: got %v", got)
		return
	}
}

// Supplementary-plane coverage: the CJK Extensions (B through H) are
// Hanzi like the BMP blocks - classical characters and personal names
// tokenize as Han runs instead of byte-unknowns - and the emoji set
// reaches the blocks the first cut missed (regional indicators, the
// extended pictograph ranges, dingbats, stars, watch, media controls,
// playing cards). The unassigned strips between extension blocks stay
// Unknown, and variation selectors stay Unknown: a combining mark is
// not its base's class.
@(test)
char_class_supplementary_coverage_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()
	table, err := moli.char_class_build(.Japanese, nil, false, allocator)
	if err != nil {
		testing.expectf(t, false, "build: %v", err)
		return
	}
	defer if table.ranges != nil { delete(table.ranges) }

	cases := []struct {
		r:    rune,
		want: moli.Char_Class,
	}{
		// Extension B: first slot, 𪚥 (U+2A6A5), last slot.
		{r = rune(0x20000), want = .Hanzi},
		{r = rune(0x2A6A5), want = .Hanzi},
		{r = rune(0x2A6DF), want = .Hanzi},
		// Extensions C-G run contiguous: first of C, the C|D joint,
		// the E|F|G joint, last of G.
		{r = rune(0x2A700), want = .Hanzi},
		{r = rune(0x2B740), want = .Hanzi},
		{r = rune(0x2CEB0), want = .Hanzi},
		{r = rune(0x2EE5F), want = .Hanzi},
		// Extension H: first and last slot.
		{r = rune(0x31350), want = .Hanzi},
		{r = rune(0x323AF), want = .Hanzi},
		// Unassigned strips between the extension blocks stay Unknown.
		{r = rune(0x2A6E0), want = .Unknown},
		{r = rune(0x2EE60), want = .Unknown},
		// Emoji the first cut missed.
		{r = rune(0x1F1E6), want = .Emoji}, // regional indicator A
		{r = rune(0x1FAFF), want = .Emoji}, // pictographs Extended-A tail
		{r = rune(0x2764), want = .Emoji},  // dingbats heart
		{r = rune(0x2B50), want = .Emoji},  // star
		{r = rune(0x231A), want = .Emoji},  // watch
		{r = rune(0x23FA), want = .Emoji},  // media controls tail
		{r = rune(0x1F0A1), want = .Emoji}, // playing card
		// Variation selector: combining mark, not its base's class.
		{r = rune(0xFE0F), want = .Unknown},
	}
	for c in cases {
		if got := moli.char_class_of(&table, c.r); got != c.want {
			testing.expectf(t, false, "%x: got %v, want %v", c.r, got, c.want)
			return
		}
	}
}

@(test)
char_class_rejects_malformed_table_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()

	// All cases use the 0x3200-0x3400 gap between the base table's
	// CJK and Kana blocks, so the built-in ranges cannot mask the
	// violation.

	// Overlapping char.def ranges fail the load.
	overlap := []moli.Char_Range{
		{lo = rune(0x3200), hi = rune(0x3300), class = .Hanzi},
		{lo = rune(0x3280), hi = rune(0x3400), class = .Hanzi},
	}
	if _, err := moli.char_class_build(.Japanese, overlap, false, allocator); err == nil {
		testing.expectf(t, false, "overlapping ranges must fail the build")
		return
	}

	// Zero-width ranges fail the build.
	zero_width := []moli.Char_Range{
		{lo = rune(0x3200), hi = rune(0x3200), class = .Hanzi},
	}
	if _, err := moli.char_class_build(.Japanese, zero_width, false, allocator); err == nil {
		testing.expectf(t, false, "zero-width range must fail the build")
		return
	}

	// Adjacent ranges (hi == next lo) are fine: half-open junctions.
	adjacent := []moli.Char_Range{
		{lo = rune(0x3200), hi = rune(0x3300), class = .Hanzi},
		{lo = rune(0x3300), hi = rune(0x3400), class = .Hanzi},
	}
	table, err := moli.char_class_build(.Japanese, adjacent, false, allocator)
	if err != nil {
		testing.expectf(t, false, "adjacent ranges: %v", err)
		return
	}
	if table.ranges != nil { delete(table.ranges) }
	if len(table.flat) > 0 { delete(table.flat, allocator) }
}

@(test)
char_class_chardef_merge_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()

	// The shape of a real char.def: a block re-declaring codepoints the
	// built-in table already covers, plus a later single-codepoint
	// override inside an earlier block (kanji numerals inside the kanji
	// block). The def side wins on shared codepoints, the built-ins
	// survive in the gaps, and the override carves the earlier block.
	write_tmp(t, "tmp/chardef_merge.def",
		"0x0041..0x005A SYMBOL\n0x4E00..0x4E10 KANJI\n0x4E05 NUMERIC\n")

	imp: moli.Importer
	imp.allocator = allocator
	imp.unk_def = make([dynamic]moli.Unk_Rule, 0, 2, allocator)
	defer delete(imp.unk_def)
	mem.dynamic_arena_init(&imp.scratch)
	defer mem.dynamic_arena_destroy(&imp.scratch)

	flags := moli.char_flags_default()
	ranges, ierr := moli.import_char_def(&imp, "tmp/chardef_merge.def", &flags)
	if ierr != nil {
		testing.expectf(t, false, "import_char_def: %v", ierr)
		return
	}
	table, berr := moli.char_class_build(.Japanese, ranges, false, allocator)
	if berr != nil {
		testing.expectf(t, false, "char_class_build must accept def/base overlap: %v", berr)
		return
	}
	defer if table.ranges != nil { delete(table.ranges) }

	// 'A' follows the def (SYMBOL -> .Punct), not the base .ASCIILetter
	// it overlaps; the override point classifies NUMERIC while its
	// neighbours inside the carved kanji block stay .Kanji.
	if cls := moli.char_class_of(&table, 'A'); cls != .Punct {
		testing.expectf(t, false, "'A' must follow the char.def override, got %v", cls)
		return
	}
	if cls := moli.char_class_of(&table, rune(0x4E05)); cls != .Digit {
		testing.expectf(t, false, "0x4E05 must be the NUMERIC override, got %v", cls)
		return
	}
	if cls := moli.char_class_of(&table, rune(0x4E06)); cls != .Kanji {
		testing.expectf(t, false, "0x4E06 must stay kanji, got %v", cls)
		return
	}

	// Overlap among char.def ranges handed to the build RAW (no
	// importer override pass) still fails: the build-level contract
	// stays a disjoint, sorted list.
	raw := []moli.Char_Range{
		{lo = rune(0x4E00), hi = rune(0x4E10), class = .Kanji},
		{lo = rune(0x4E05), hi = rune(0x4E06), class = .Digit},
	}
	if _, err := moli.char_class_build(.Japanese, raw, false, allocator); err == nil {
		testing.expectf(t, false, "raw overlapping def ranges must fail the build")
	}
}

// A char.def range must be a valid half-open span of real code
// points. An inverted row that straddles an existing block makes the
// punch-out emit mutually overlapping fragments, breaking the
// disjointness the len+2 reservation and the build both rely on - so
// inverted, empty, sub-zero, and past-Unicode rows are rejected at
// the row instead of corrupting the list.
@(test)
char_class_chardef_bad_range_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()
	imp: moli.Importer
	imp.allocator = allocator
	imp.unk_def = make([dynamic]moli.Unk_Rule, 0, 2, allocator)
	defer delete(imp.unk_def)
	mem.dynamic_arena_init(&imp.scratch)
	defer mem.dynamic_arena_destroy(&imp.scratch)

	bad := []string{
		"0x9FFF..0x4E00 KANJI\n", // dotted form inverted
		"0x4E10 0x4E00 KANJI\n",  // two-column form inverted
		"0x4E10 0x4E0F KANJI\n",  // empty span (hi == lo; dotted
		                          // endpoints are inclusive, so only
		                          // the two-column form can be empty)
		"0x110000..0x110010 X\n", // past the code point range
		"-1 SYMBOL\n",            // below zero
		// Past the code point range in forms the old unbounded parse
		// let through: core strconv.parse_int wraps past i64 with
		// ok=true, and 2^32 truncates to a small rune - the row below
		// used to load as the range [0,2). The bound lives in
		// parse_codepoint now, so all three record forms reject.
		"0x100000000 0x100000001 KANJI\n", // 2^32 wrap
		"0x100000000..0x100000010 X\n",    // 2^32 wrap, dotted
		"99999999999999999999 SYMBOL\n",   // wraps past i64
	}
	for row, i in bad {
		write_tmp(t, "tmp/chardef_bad.def", row)
		flags := moli.char_flags_default()
		_, err := moli.import_char_def(&imp, "tmp/chardef_bad.def", &flags)
		testing.expectf(t, err == moli.Load_Fault.Invalid_Format,
			"case %d (%q) must be rejected, got %v", i, row, err)
	}
}

// Bare (un-prefixed) hex is accepted in every field form - decimal
// semantics never change because base 10 parses first.
@(test)
char_class_chardef_bare_hex_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()
	imp: moli.Importer
	imp.allocator = allocator
	imp.unk_def = make([dynamic]moli.Unk_Rule, 0, 2, allocator)
	defer delete(imp.unk_def)
	mem.dynamic_arena_init(&imp.scratch)
	defer mem.dynamic_arena_destroy(&imp.scratch)

	write_tmp(t, "tmp/chardef_bare.def",
		"4E00..4E0F KANJI\n3041 HIRAGANA\n4E10 4E13 KANJI\n")
	flags := moli.char_flags_default()
	ranges, ierr := moli.import_char_def(&imp, "tmp/chardef_bare.def", &flags)
	if ierr != nil {
		testing.expectf(t, false, "bare-hex char.def: %v", ierr)
		return
	}
	table, berr := moli.char_class_build(.Japanese, ranges, false, allocator)
	if berr != nil {
		testing.expectf(t, false, "build: %v", berr)
		return
	}
	defer if table.ranges != nil { delete(table.ranges) }
	if cls := moli.char_class_of(&table, rune(0x4E00)); cls != .Kanji {
		testing.expectf(t, false, "bare dotted range: got %v", cls)
		return
	}
	if cls := moli.char_class_of(&table, rune(0x3041)); cls != .Hiragana {
		testing.expectf(t, false, "bare single codepoint: got %v", cls)
		return
	}
	if cls := moli.char_class_of(&table, rune(0x4E11)); cls != .Kanji {
		testing.expectf(t, false, "bare two-column range: got %v", cls)
		return
	}
	if cls := moli.char_class_of(&table, rune(0x4E14)); cls == .Kanji {
		testing.expectf(t, false, "two-column hi must be inclusive (4E14 outside)")
		return
	}
}

// utf8_rune_error returns the decode-failure rune (U+FFFD), which
// malformed input classifies as.
utf8_rune_error :: proc() -> rune { return rune(0xFFFD) }

// The makes on the char-class build path must fail as .OutOfMemory (a
// zero-value ranges array would grow through the ambient allocator);
// the successful builds release through the same still-living
// allocator, so the leak gate covers both directions.
@(test)
char_class_build_oom_test :: proc(t: ^testing.T) {
	saw_oom := false
	loaded := false
	for budget in 0 ..< 8 {
		b := Budget_Allocator{backing = context.allocator, remaining = budget}
		allocator := mem.Allocator{data = &b, procedure = budget_allocator_proc}
		table, err := moli.char_class_build(.Japanese, nil, false, allocator)
		if err == nil {
			delete(table.ranges)
			loaded = true
		} else {
			testing.expectf(t, err == moli.Load_Fault.OutOfMemory,
				"budget %d: char_class_build must fail with .OutOfMemory, got %v", budget, err)
			saw_oom = true
		}
	}
	testing.expectf(t, saw_oom && loaded,
		"the sweep must cover both failure and success (oom=%v loaded=%v)", saw_oom, loaded)

	b0 := Budget_Allocator{backing = context.allocator, remaining = 0}
	_, err := moli.base_ranges(mem.Allocator{data = &b0, procedure = budget_allocator_proc})
	testing.expectf(t, err == moli.Load_Fault.OutOfMemory,
		"base_ranges' make must fail as .OutOfMemory, got %v", err)
}

// override_insert's two reachable allocation failures: the plain
// append on the disjoint path (the ranges array grows past capacity on
// every real char.def) and the rebuild make on the overlap path. Both
// must answer .OutOfMemory and leave the caller's ranges untouched.
@(test)
override_insert_oom_test :: proc(t: ^testing.T) {
	nr := No_Resize_Allocator{backing = context.allocator}
	allocator := mem.Allocator{data = &nr, procedure = no_resize_proc}

	// Disjoint path: two ranges at capacity 2, the third append grows.
	ranges, merr := make([dynamic]moli.Char_Range, 0, 2, allocator)
	if merr != nil {
		testing.expectf(t, false, "ranges make: %v", merr)
		return
	}
	append(&ranges, moli.Char_Range{lo = rune(0x100), hi = rune(0x200), class = .Hiragana})
	append(&ranges, moli.Char_Range{lo = rune(0x300), hi = rune(0x400), class = .Katakana})
	err := moli.override_insert(&ranges, moli.Char_Range{lo = rune(0x500), hi = rune(0x600), class = .Symbol}, allocator)
	testing.expectf(t, err == moli.Load_Fault.OutOfMemory,
		"the disjoint-path growth append must fail, got %v", err)
	testing.expectf(t, len(ranges) == 2,
		"the rejected range must not land, got %d", len(ranges))
	delete(ranges)

	// Overlap path: the rebuild make itself fails under an empty budget.
	ranges2, merr2 := make([dynamic]moli.Char_Range, 0, 4, context.allocator)
	if merr2 != nil {
		testing.expectf(t, false, "ranges2 make: %v", merr2)
		return
	}
	defer delete(ranges2)
	append(&ranges2, moli.Char_Range{lo = rune(0x100), hi = rune(0x200), class = .Hiragana})
	budget := Budget_Allocator{backing = context.allocator, remaining = 0}
	err2 := moli.override_insert(&ranges2, moli.Char_Range{lo = rune(0x150), hi = rune(0x180), class = .Symbol},
		mem.Allocator{data = &budget, procedure = budget_allocator_proc})
	testing.expectf(t, err2 == moli.Load_Fault.OutOfMemory,
		"the overlap-path rebuild make must fail, got %v", err2)
	testing.expectf(t, len(ranges2) == 1,
		"the original ranges survive untouched, got %d", len(ranges2))
}
