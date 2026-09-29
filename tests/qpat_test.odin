// Surface-pattern coverage: the loader (good rows and every malformed
// shape), the resolution ladder (patterns before unk rules, first row
// wins), the per-candidate resolution in Viterbi mode, and the
// snapshot round-trip of the pattern set.
package tests

import "base:runtime"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "moli:moli"

// The resolution ladder probed directly: patterns in declaration
// order, then the unk rules, then the fallback POS.
@(test)
qpat_ladder_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()

	a: moli.Analyzer
	a.allocator = allocator
	a.unk_def = make([dynamic]moli.Unk_Rule, 0, 4, allocator)
	a.unk_patterns = make([dynamic]moli.Unk_Pattern, 0, 4, allocator)
	a.unknown_fallback_pos = strings.clone("名詞,普通名詞", allocator)
	table, terr := moli.char_class_build(.Japanese, nil, false, allocator)
	if terr != nil {
		testing.expectf(t, false, "char_class_build: %v", terr)
		return
	}
	a.char_class = table
	defer {
		for _, i in a.unk_def {
			moli.unk_rule_destroy(&a.unk_def[i], allocator)
		}
		delete(a.unk_def)
		for _, i in a.unk_patterns {
			moli.unk_pattern_destroy(&a.unk_patterns[i], allocator)
		}
		delete(a.unk_patterns)
		delete(a.unknown_fallback_pos, allocator)
		delete(a.char_class.ranges)
	}

	append(&a.unk_def, moli.Unk_Rule{class = .Katakana, cost = 4000,
		joined_pos = strings.clone("名詞,一般", allocator)})
	// Declaration order: 的 (suffix) before 第 (prefix) before 第三
	// (the longer prefix) before the KATAKANA charset row.
	append(&a.unk_patterns, moli.Unk_Pattern{kind = .Suffix, pat = strings.clone("的", allocator),
		cost = 4500, joined_pos = strings.clone("名詞,接尾辞", allocator)})
	append(&a.unk_patterns, moli.Unk_Pattern{kind = .Prefix, pat = strings.clone("第", allocator),
		cost = 4600, joined_pos = strings.clone("名詞,接頭辞", allocator)})
	append(&a.unk_patterns, moli.Unk_Pattern{kind = .Prefix, pat = strings.clone("第三", allocator),
		cost = 4650, joined_pos = strings.clone("名詞,数接頭辞", allocator)})
	append(&a.unk_patterns, moli.Unk_Pattern{kind = .Charset, class = .Katakana,
		cost = 4800, joined_pos = strings.clone("名詞,固有名詞", allocator)})

	cases := []struct {
		surface: string,
		class:   moli.Char_Class,
		pos:     string,
		cost:    i16,
	}{
		// A suffix row outranks the unk rule for the run's class.
		{surface = "国際的", class = .Kanji, pos = "名詞,接尾辞", cost = 4500},
		// The first-declared prefix wins over its longer sibling.
		{surface = "第三回", class = .Kanji, pos = "名詞,接頭辞", cost = 4600},
		// A charset row matches the whole surface, again ahead of the
		// class rule.
		{surface = "ケケケ", class = .Katakana, pos = "名詞,固有名詞", cost = 4800},
		// No pattern fires: the class rule stands.
		{surface = "あいう", class = .Katakana, pos = "名詞,一般", cost = 4000},
		// Nothing fires: the fallback POS with zero cost.
		{surface = "ひらがな", class = .Hiragana, pos = "名詞,普通名詞", cost = 0},
	}
	for c in cases {
		pos, cost, _, _ := moli.resolve_unk(&a, c.class, c.surface)
		if pos != c.pos || cost != c.cost {
			testing.expectf(t, false, "%q: got (%s, %v), want (%s, %v)",
				c.surface, pos, cost, c.pos, c.cost)
			return
		}
	}
}

// The loader: good rows of every kind (quoting included), every
// malformed shape, the legal empty file, and the append-failure
// release.
@(test)
qpat_loader_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()

	imp: moli.Importer
	imp.allocator = allocator
	imp.unk_patterns = make([dynamic]moli.Unk_Pattern, 0, 4, allocator)
	mem.dynamic_arena_init(&imp.scratch)
	defer {
		for _, i in imp.unk_patterns {
			moli.unk_pattern_destroy(&imp.unk_patterns[i], allocator)
		}
		delete(imp.unk_patterns)
		mem.dynamic_arena_destroy(&imp.scratch)
	}

	write_tmp(t, "tmp/qpat_ok.pat",
		"prefix,第,1,2,4500,名詞,接頭辞,*\nsuffix,\"的,マル\",3,4,4600,名詞,接尾辞,*\ncharset,KATAKANA,5,6,4700,名詞,固有名詞,*\n")
	if err := moli.import_qpat(&imp, "tmp/qpat_ok.pat"); err != nil {
		testing.expectf(t, false, "qpat_ok: %v", err)
		return
	}
	if len(imp.unk_patterns) != 3 {
		testing.expectf(t, false, "rows loaded: %v", len(imp.unk_patterns))
		return
	}
	r0 := imp.unk_patterns[0]
	r1 := imp.unk_patterns[1]
	r2 := imp.unk_patterns[2]
	if r0.kind != .Prefix || r0.pat != "第" || r0.left_id != 1 || r0.right_id != 2 ||
		r0.cost != 4500 || r0.joined_pos != "名詞,接頭辞" {
		testing.expectf(t, false, "prefix row: %+v", r0)
		return
	}
	// Quoting carries a comma inside the suffix literal.
	if r1.kind != .Suffix || r1.pat != "的,マル" || r1.cost != 4600 || r1.joined_pos != "名詞,接尾辞" {
		testing.expectf(t, false, "quoted suffix row: %+v", r1)
		return
	}
	if r2.kind != .Charset || r2.class != .Katakana || r2.pat != "" || r2.cost != 4700 ||
		r2.joined_pos != "名詞,固有名詞" {
		testing.expectf(t, false, "charset row: %+v", r2)
		return
	}

	// Every malformed shape fails the load.
	bad := []string{
		"wildcard,第,1,2,4500,名詞,*\n",   // unknown kind
		"charset,FOOBAR,1,2,4500,名詞,*\n", // unknown class name
		"prefix,,1,2,4500,名詞,*\n",        // empty literal
		"suffix,的,x,2,4500,名詞,*\n",      // non-numeric id
		"suffix,的,1,2\n",                  // short row
	}
	for b in bad {
		write_tmp(t, "tmp/qpat_bad.pat", b)
		if err := moli.import_qpat(&imp, "tmp/qpat_bad.pat"); err == nil {
			testing.expectf(t, false, "malformed row must fail the load: %q", b)
			return
		}
	}

	// A file with no rows is legal: zero patterns added.
	write_tmp(t, "tmp/qpat_empty.pat", "\n")
	if err := moli.import_qpat(&imp, "tmp/qpat_empty.pat"); err != nil {
		testing.expectf(t, false, "empty file: %v", err)
		return
	}
	if len(imp.unk_patterns) != 3 {
		testing.expectf(t, false, "empty file must not change the rows: %v", len(imp.unk_patterns))
		return
	}

	// A failed pattern append destroys the row's strings and fails the
	// load: cap 1, so the second row's append grows and the no-resize
	// allocator refuses.
	nr := No_Resize_Allocator{backing = context.allocator}
	nalloc := mem.Allocator{data = &nr, procedure = no_resize_proc}
	imp2: moli.Importer
	imp2.allocator = nalloc
	imp2.unk_patterns = make([dynamic]moli.Unk_Pattern, 0, 1, nalloc)
	mem.dynamic_arena_init(&imp2.scratch)
	defer mem.dynamic_arena_destroy(&imp2.scratch)
	if err := moli.import_qpat(&imp2, "tmp/qpat_ok.pat"); err != moli.Load_Fault.OutOfMemory {
		testing.expectf(t, false, "append OOM: want .OutOfMemory, got %v", err)
		return
	}
	for _, i in imp2.unk_patterns {
		moli.unk_pattern_destroy(&imp2.unk_patterns[i], nalloc)
	}
	delete(imp2.unk_patterns)
}

// End to end through load: greedy mode resolves the emitted run;
// Viterbi mode resolves per candidate and a cheap suffix-labelled
// whole run beats every split.
@(test)
qpat_apply_test :: proc(t: ^testing.T) {
	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	write_tmp(t, "tmp/qpat_greedy.pat", "suffix,的,0,0,4500,名詞,接尾辞,*\nprefix,第,0,0,4600,名詞,接頭辞,*\n")
	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE,
		{mode = .LongestMatch, qpat_path = "tmp/qpat_greedy.pat"})
	if !ok { return }
	defer moli.free(&a)

	if len(a.unk_patterns) != 2 {
		testing.expectf(t, false, "patterns: %v", len(a.unk_patterns))
		return
	}

	greedy_cases := []struct {
		text: string,
		pos:  string,
		cost: i16,
	}{
		{text = "国際的", pos = "名詞,接尾辞", cost = 4500},
		{text = "第三", pos = "名詞,接頭辞", cost = 4600},
		{text = "ケケケ", pos = "名詞,一般", cost = 4000}, // no row fires: the unk rule stands
	}
	for c in greedy_cases {
		ms, err := moli.tokenize(&a, c.text, arena_alloc)
		if err != nil {
			testing.expectf(t, false, "tokenize %q: %v", c.text, err)
			return
		}
		if len(ms) != 1 {
			testing.expectf(t, false, "%q: %v morphemes, want 1", c.text, len(ms))
			return
		}
		if ms[0].pos != c.pos || ms[0].cost != c.cost || !ms[0].is_unknown || ms[0].lemma != c.text {
			testing.expectf(t, false, "%q: got (%q, %v, unk=%v), want (%q, %v)",
				c.text, ms[0].pos, ms[0].cost, ms[0].is_unknown, c.pos, c.cost)
			return
		}
	}

	// The class rule prices every non-suffix candidate at 5000 and the
	// suffix row prices a 的-ending candidate at -3000, so the whole
	// run is strictly the cheapest path.
	write_tmp(t, "tmp/qpat_unk.def", "KANJI,0,0,5000,名詞,一般,*\n")
	write_tmp(t, "tmp/qpat_viterbi.pat", "suffix,的,0,0,-3000,名詞,接尾辞,*\n")
	v, ok2 := load_ok(t, .Japanese, RESOURCES_FIXTURE,
		{unk_def_path = "tmp/qpat_unk.def", qpat_path = "tmp/qpat_viterbi.pat"})
	if !ok2 { return }
	defer moli.free(&v)

	ms, terr := moli.tokenize(&v, "国際的", arena_alloc)
	if terr != nil {
		testing.expectf(t, false, "tokenize (viterbi): %v", terr)
		return
	}
	if len(ms) != 1 {
		testing.expectf(t, false, "viterbi whole-run: %v morphemes, want 1", len(ms))
		return
	}
	if ms[0].pos != "名詞,接尾辞" || ms[0].cost != -3000 || !ms[0].is_unknown {
		testing.expectf(t, false, "viterbi whole-run: (%q, %v, unk=%v)",
			ms[0].pos, ms[0].cost, ms[0].is_unknown)
		return
	}
}

// The pattern set round-trips through the snapshot, and a v2 image is
// rejected by the version check.
@(test)
qpat_qdct_roundtrip_test :: proc(t: ^testing.T) {
	allocator := context.allocator

	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)
	if len(a.unk_patterns) != 2 {
		testing.expectf(t, false, "patterns: %v", len(a.unk_patterns))
		return
	}

	ra, ok_ra := qdct_roundtrip_restore(t, &a, "tmp/qpat_round.qdct",
		context.allocator, context.allocator)
	if !ok_ra { return }
	defer moli.free(&ra)

	if len(ra.unk_patterns) != len(a.unk_patterns) {
		testing.expectf(t, false, "patterns: %v vs %v", len(ra.unk_patterns), len(a.unk_patterns))
		return
	}
	for p, i in a.unk_patterns {
		q := ra.unk_patterns[i]
		if q.kind != p.kind || q.class != p.class || q.pat != p.pat || q.cost != p.cost ||
			q.left_id != p.left_id || q.right_id != p.right_id || q.joined_pos != p.joined_pos {
			testing.expectf(t, false, "pattern %d differs after the round-trip", i)
			return
		}
	}

	// Morpheme equality across both analyzers (both alive, so the
	// zero-copy strings are safe to compare).
	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	sentences := []string{"国際的", "第三", "ケケケ", "犬が歩く"}
	for s in sentences {
		ms, merr := moli.tokenize(&a, s, mem.arena_allocator(&arena))
		if merr != nil {
			testing.expectf(t, false, "tokenize %q: %v", s, merr)
			return
		}
		rs, rerr := moli.tokenize(&ra, s, mem.arena_allocator(&arena))
		if rerr != nil {
			testing.expectf(t, false, "tokenize %q (restored): %v", s, rerr)
			return
		}
		if len(ms) != len(rs) {
			testing.expectf(t, false, "%q: %v vs %v morphemes", s, len(ms), len(rs))
			return
		}
		for i := 0; i < len(ms); i += 1 {
			if ms[i].surface != rs[i].surface || ms[i].pos != rs[i].pos || ms[i].cost != rs[i].cost {
				testing.expectf(t, false, "%q morph %d differs across the round-trip", s, i)
				return
			}
		}
	}

	// A v2 image is rejected: patch the version field down.
	data, derr := os.read_entire_file("tmp/qpat_round.qdct", allocator)
	if derr != nil {
		testing.expectf(t, false, "read snapshot: %v", derr)
		return
	}
	defer delete(data, allocator)
	data[4] = 2
	if werr := os.write_entire_file("tmp/qpat_v2.qdct", data); werr != nil {
		testing.expectf(t, false, "write v2 snapshot: %v", werr)
		return
	}
	bad, berr := moli.load_qdct("tmp/qpat_v2.qdct", allocator)
	if berr == nil {
		moli.free(&bad)
		testing.expectf(t, false, "a v2 image must be rejected")
		return
	}
	if berr != moli.Load_Fault.Invalid_Format {
		testing.expectf(t, false, "v2: want .Invalid_Format, got %v", berr)
	}
}
