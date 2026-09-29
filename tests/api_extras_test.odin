// API-extras coverage: snapshot bytes are byte-identical to
// save_qdct's file; clone is an independent copy (the source may be
// freed while the copy keeps answering, and user rows merged into a
// clone leave the shared base untouched); stats inventories content
// (entries, terminals, matrix dims/density, skipped resources) and
// reports the same numbers from a qdct restore; the surfaces-with-
// offsets walk emits contiguous spans agreeing with wakachi and the
// morpheme offsets under every option (strict, cancellation, NFC).
package tests

import "core:bytes"
import "core:mem"
import "core:os"
import "core:testing"
import "moli:moli"

@(test)
snapshot_bytes_equal_save_test :: proc(t: ^testing.T) {
	allocator := context.allocator
	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	scratch: mem.Arena
	buf := make([]u8, 1 << 22, allocator)
	defer delete(buf, allocator)
	mem.arena_init(&scratch, buf[:])
	scratch_allocator := mem.arena_allocator(&scratch)

	if serr := moli.save_qdct(&a, "tmp/api_snap.bin", scratch_allocator); serr != nil {
		testing.expectf(t, false, "save_qdct: %v", serr)
		return
	}
	file_bytes, rerr := os.read_entire_file("tmp/api_snap.bin", allocator)
	if rerr != nil {
		testing.expectf(t, false, "read back: %v", rerr)
		return
	}
	defer delete(file_bytes, allocator)

	image, serr2 := moli.snapshot(&a, allocator)
	if serr2 != nil {
		testing.expectf(t, false, "snapshot: %v", serr2)
		return
	}
	defer delete(image, allocator)

	testing.expectf(t, bytes.equal(file_bytes, image),
		"snapshot bytes differ from save_qdct's file (%v vs %v bytes)",
		len(file_bytes), len(image))
}

// expect_same_stats asserts the inventories agree field by field
// (skipped compared element-wise - the slices are separate borrows).
expect_same_stats :: proc(t: ^testing.T, want: moli.Analyzer_Stats, got: moli.Analyzer_Stats) -> bool {
	if want.entries != got.entries || want.terminals != got.terminals ||
		want.cedar_nodes != got.cedar_nodes || want.unk_rules != got.unk_rules ||
		want.unk_patterns != got.unk_patterns || want.matrix_left != got.matrix_left ||
		want.matrix_right != got.matrix_right || want.matrix_cells != got.matrix_cells ||
		want.matrix_explicit != got.matrix_explicit || want.matrix_density != got.matrix_density {
		testing.expectf(t, false, "stats differ: %+v vs %+v", want, got)
		return false
	}
	if len(want.skipped) != len(got.skipped) {
		testing.expectf(t, false, "skipped counts differ: %v vs %v", len(want.skipped), len(got.skipped))
		return false
	}
	for s, i in want.skipped {
		if got.skipped[i] != s {
			testing.expectf(t, false, "skipped[%v] differs: %s vs %s", i, s, got.skipped[i])
			return false
		}
	}
	return true
}

// expect_same_morphemes is the suite-wide full-field comparison:
// expect_morphemes_equal in helpers.odin (entry_id, locale, and
// char_class included). Kept as a local alias for the call sites
// below.
expect_same_morphemes :: proc(t: ^testing.T, want: []moli.Morpheme, got: []moli.Morpheme) -> bool {
	return expect_morphemes_equal(t, want, got)
}

@(test)
clone_answers_identically_test :: proc(t: ^testing.T) {
	allocator := context.allocator
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	sa, sa_err := moli.stats(&a)
	if sa_err != nil {
		testing.expectf(t, false, "stats before clone: %v", sa_err)
		return
	}

	c, cerr := moli.clone(&a, allocator)
	if cerr != nil {
		testing.expectf(t, false, "clone: %v", cerr)
		return
	}
	defer moli.free(&c)

	// The copy answers identically - every observable field, compared
	// through per-call arenas (expect_analyses_equal owns the
	// no-aliasing rule).
	if !expect_analyses_equal(t, &a, &c, []string{"犬が歩く。"}) { return }

	sc, sc_err := moli.stats(&c)
	if sc_err != nil {
		testing.expectf(t, false, "stats of clone: %v", sc_err)
		return
	}
	if !expect_same_stats(t, sa, sc) { return }
}

@(test)
clone_survives_source_free_test :: proc(t: ^testing.T) {
	allocator := context.allocator
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }

	c, cerr := moli.clone(&a, allocator)
	if cerr != nil {
		moli.free(&a)
		testing.expectf(t, false, "clone: %v", cerr)
		return
	}
	defer moli.free(&c)
	a_alive := true
	defer if a_alive { moli.free(&a) }

	// Two separate buffers: `before`'s backing must stay readable
	// while the second call runs - a shared arena would hand the same
	// bytes to both tokenizations.
	before_buf: [1 << 16]byte
	before_arena: mem.Arena
	mem.arena_init(&before_arena, before_buf[:])
	after_buf: [1 << 16]byte
	after_arena: mem.Arena
	mem.arena_init(&after_arena, after_buf[:])

	text := "犬が歩く。"
	before, terr := moli.tokenize(&c, text, mem.arena_allocator(&before_arena))
	if terr != nil {
		testing.expectf(t, false, "tokenize before: %v", terr)
		return
	}

	// Independence: free the SOURCE; the copy keeps answering with
	// the same results (nothing the clone reads may have been
	// shared), and the freed source's stats bounce.
	moli.free(&a)
	a_alive = false

	after, terr2 := moli.tokenize(&c, text, mem.arena_allocator(&after_arena))
	if terr2 != nil {
		testing.expectf(t, false, "tokenize after source free: %v", terr2)
		return
	}
	if !expect_same_morphemes(t, before, after) { return }

	// The freed source's stats bounce: strict, not conditional - a
	// stats call that SUCCEEDED on a torn-down analyzer (a read of
	// freed memory) must fail this assert, not pass it.
	_, dead_err := moli.stats(&a)
	if !expect_save_fault(t, "freed source stats", dead_err, .Unavailable) { return }
}

@(test)
clone_user_variant_test :: proc(t: ^testing.T) {
	allocator := context.allocator
	base, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&base)

	c, cerr := moli.clone(&base, allocator)
	if cerr != nil {
		testing.expectf(t, false, "clone: %v", cerr)
		return
	}
	defer moli.free(&c)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	user := []moli.User_Entry{
		{surface = "犬助", left_id = 0, right_id = 0, cost = -3000, pos = "名詞,固有名詞", lemma = "*", reading = "ケンスケ", reading_jyutping = "*"},
	}
	if uerr := moli.add_user_entries(&c, user); uerr != nil {
		testing.expectf(t, false, "add_user_entries into clone: %v", uerr)
		return
	}

	// The variant answers with the domain term.
	ms, terr := moli.tokenize(&c, "犬助", arena_alloc)
	if terr != nil {
		testing.expectf(t, false, "tokenize clone: %v", terr)
		return
	}
	if len(ms) != 1 || ms[0].surface != "犬助" || ms[0].is_unknown {
		testing.expectf(t, false, "variant carries the merged term, got %d morphemes", len(ms))
		return
	}

	// The shared base is untouched: after the clone's merge, the base
	// must answer exactly like a fresh load of the same dictionary on
	// every text (full-field comparison, entry ids included) - the
	// merged row leaking into the base in any observable way fails
	// here, not just the one-text negative it replaces.
	fresh, ok_f := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok_f { return }
	defer moli.free(&fresh)
	if !expect_analyses_equal(t, &base, &fresh, []string{"犬助", "犬が歩く。", "さくら"}) { return }
}

@(test)
stats_test :: proc(t: ^testing.T) {
	allocator := context.allocator

	// A matrix-bearing analyzer: the fixture enumerates all 2x2 cells.
	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)
	sa, sa_err := moli.stats(&a)
	if sa_err != nil {
		testing.expectf(t, false, "stats: %v", sa_err)
		return
	}
	if sa.matrix_left != 2 || sa.matrix_right != 2 ||
		sa.matrix_cells != 4 || sa.matrix_explicit != 4 || sa.matrix_density != 1.0 {
		testing.expectf(t, false, "matrix stats: %vx%v cells=%v explicit=%v density=%v",
			sa.matrix_left, sa.matrix_right, sa.matrix_cells, sa.matrix_explicit, sa.matrix_density)
		return
	}
	if sa.entries != len(a.entries) || sa.unk_rules != len(a.unk_def) {
		testing.expectf(t, false, "entry stats: %v/%v unk %v/%v",
			sa.entries, len(a.entries), sa.unk_rules, len(a.unk_def))
		return
	}

	// terminals == distinct surfaces: entries are surface-sorted, so
	// distinct surfaces count by adjacent comparison.
	n_distinct := 0
	for i in 0 ..< len(a.entries) {
		if i == 0 || a.entries[i].surface != a.entries[i - 1].surface { n_distinct += 1 }
	}
	if sa.terminals != n_distinct {
		testing.expectf(t, false, "terminals %v vs distinct surfaces %v", sa.terminals, n_distinct)
		return
	}

	// A restore reports the same inventory (the image's ownership
	// transfers to the restored analyzer either way).
	image, snerr := moli.snapshot(&a, allocator)
	if snerr != nil {
		testing.expectf(t, false, "snapshot: %v", snerr)
		return
	}
	r, rerr := moli.load_qdct_bytes(image, allocator)
	if rerr != nil {
		testing.expectf(t, false, "load_qdct_bytes: %v", rerr)
		return
	}
	defer moli.free(&r)
	sr, sr_err := moli.stats(&r)
	if sr_err != nil {
		testing.expectf(t, false, "stats of restore: %v", sr_err)
		return
	}
	if !expect_same_stats(t, sa, sr) { return }

	// A matrix-less analyzer: cells 0, density vacuously 1.0, and
	// the absent siblings surface in skipped.
	j, ok2 := load_ok(t, .ChineseCN, JIEBA_FIXTURE, {})
	if !ok2 { return }
	defer moli.free(&j)
	sj, sj_err := moli.stats(&j)
	if sj_err != nil {
		testing.expectf(t, false, "stats jieba: %v", sj_err)
		return
	}
	if sj.matrix_left != 0 || sj.matrix_cells != 0 ||
		sj.matrix_explicit != 0 || sj.matrix_density != 1.0 {
		testing.expectf(t, false, "matrix-less stats: %vx%v cells=%v density=%v",
			sj.matrix_left, sj.matrix_right, sj.matrix_cells, sj.matrix_density)
		return
	}
	if len(sj.skipped) != len(j.skipped_resources) || len(sj.skipped) == 0 {
		testing.expectf(t, false, "skipped borrowed: %v vs %v",
			len(sj.skipped), len(j.skipped_resources))
		return
	}
}

// expect_spans_total asserts contiguity and the slicing identity
// against the analyzed text.
expect_spans_total :: proc(t: ^testing.T, spans: []moli.Surface_Span, text: string) -> bool {
	if len(spans) == 0 {
		testing.expectf(t, false, "no spans")
		return false
	}
	if spans[0].start != 0 || spans[len(spans) - 1].end != len(text) {
		testing.expectf(t, false, "span cover: first start %v, last end %v (text %v)",
			spans[0].start, spans[len(spans) - 1].end, len(text))
		return false
	}
	for s, i in spans {
		if i > 0 && spans[i - 1].end != s.start {
			testing.expectf(t, false, "span %v not contiguous: %v vs %v", i, spans[i - 1].end, s.start)
			return false
		}
		if text[s.start:s.end] != s.surface {
			testing.expectf(t, false, "span %v slicing identity broken", i)
			return false
		}
	}
	return true
}

@(test)
surfaces_with_offsets_test :: proc(t: ^testing.T) {
	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	text := "さくらが散る。"

	// Viterbi mode (the default): spans agree with wakachi and with
	// tokenize's morpheme offsets.
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	spans, err := moli.tokenize_surfaces_with_offsets(&a, text, moli.Tokenize_Options{}, arena_alloc)
	if err != nil {
		testing.expectf(t, false, "spans viterbi: %v", err)
		return
	}
	if !expect_spans_total(t, spans, text) { return }

	// No arena reset between the runs: spans' backing lives in the
	// same arena the next call would reuse (the text is tiny - one
	// buffer holds every run).
	ws, werr := moli.tokenize_wakachi(&a, text, arena_alloc)
	if werr != nil {
		testing.expectf(t, false, "wakachi: %v", werr)
		return
	}
	if len(ws) != len(spans) {
		testing.expectf(t, false, "span count %v vs wakachi %v", len(spans), len(ws))
		return
	}
	for s, i in spans {
		if s.surface != ws[i] {
			testing.expectf(t, false, "span %v surface %s vs wakachi %s", i, s.surface, ws[i])
			return
		}
	}

	ms, merr := moli.tokenize(&a, text, arena_alloc)
	if merr != nil {
		testing.expectf(t, false, "tokenize: %v", merr)
		return
	}
	if len(ms) != len(spans) {
		testing.expectf(t, false, "span count %v vs morphemes %v", len(spans), len(ms))
		return
	}
	for s, i in spans {
		if s.start != ms[i].start || s.end != ms[i].end {
			testing.expectf(t, false, "span %v offsets %v..%v vs morpheme %v..%v",
				i, s.start, s.end, ms[i].start, ms[i].end)
			return
		}
	}

	// LongestMatch mode walks the same contract (fresh buffer so the
	// Viterbi-leg spans above stay readable).
	g, ok2 := load_ok(t, .Japanese, IPADIC_FIXTURE, {mode = .LongestMatch})
	if !ok2 { return }
	defer moli.free(&g)
	g_buf: [1 << 16]byte
	g_arena: mem.Arena
	mem.arena_init(&g_arena, g_buf[:])
	gspans, gerr := moli.tokenize_surfaces_with_offsets(&g, text, moli.Tokenize_Options{}, mem.arena_allocator(&g_arena))
	if gerr != nil {
		testing.expectf(t, false, "spans greedy: %v", gerr)
		return
	}
	if !expect_spans_total(t, gspans, text) { return }
}

@(test)
surfaces_options_test :: proc(t: ^testing.T) {
	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	// Strict input rejects before any walk, at the first bad byte.
	_, err := moli.tokenize_surfaces_with_offsets(&a, "さくらが\x81咲いた", {strict_utf8 = true}, arena_alloc)
	bad := false
	switch e in err {
	case moli.Malformed_Input_Error:
		bad = e.byte_offset == 12
		if !bad {
			testing.expectf(t, false, "strict offset: %v", e.byte_offset)
			return
		}
	case moli.Cancelled_Error:
	case moli.Tokenize_Fault:
	case moli.Bad_Constraint_Error, moli.Unsatisfiable_Error:
	}
	if !bad {
		testing.expectf(t, false, "strict: want Malformed_Input_Error, got %v", err)
		return
	}

	// A pre-cancelled token bounces at offset 0 with nothing emitted.
	tok: moli.Cancel_Token
	moli.cancel(&tok)
	_, cerr2 := moli.tokenize_surfaces_with_offsets(&a, "さくらが散る", {cancel_token = &tok}, arena_alloc)
	at_zero := false
	switch e in cerr2 {
	case moli.Cancelled_Error:
		at_zero = e.byte_offset == 0
		if !at_zero {
			testing.expectf(t, false, "cancel offset: %v", e.byte_offset)
			return
		}
	case moli.Malformed_Input_Error:
	case moli.Tokenize_Fault:
	case moli.Bad_Constraint_Error, moli.Unsatisfiable_Error:
	}
	if !at_zero {
		testing.expectf(t, false, "cancel: want Cancelled_Error, got %v", cerr2)
		return
	}

	// NFC: surfaces and offsets index the arena's composed copy - the
	// dakuten composes with its base, so the span covers 3 bytes, not
	// the 6 the caller handed in.
	mem.arena_free_all(&arena)
	spans, nerr := moli.tokenize_surfaces_with_offsets(&a, "犬か\u3099散る", {normalize_nfc = true}, arena_alloc)
	if nerr != nil {
		testing.expectf(t, false, "spans nfc: %v", nerr)
		return
	}
	found := false
	for s in spans {
		if s.surface == "が" {
			found = s.end - s.start == 3
			if !found {
				testing.expectf(t, false, "composed が spans %v bytes", s.end - s.start)
				return
			}
		}
	}
	testing.expectf(t, found, "composed が missing from spans")
}
