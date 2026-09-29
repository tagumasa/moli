// Shared helpers for the moli test suite: fixed tmp/ paths, temp-file
// writing, fixture loading, and a hand-built-analyzer constructor for
// tests that need a custom matrix or unk set. Analyzers load through
// context.allocator - the runner's per-test tracking allocator - so
// the zero-leak gate sees the lifecycle traffic; every allocation is
// still released explicitly, which is what keeps the gate green.
package tests

import "base:runtime"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "moli:moli"

// Fixture paths (relative to the repo root, where just test runs).
IPADIC_FIXTURE :: "tests/fixtures/ipadic_sample.csv"
UNIDIC_FIXTURE :: "tests/fixtures/unidic_sample.csv"
JIEBA_FIXTURE :: "tests/fixtures/jieba_sample.csv"
JIEBA_CRLF_FIXTURE :: "tests/fixtures/jieba_sample_crlf.csv"
JIEBA_TW_FIXTURE :: "tests/fixtures/jieba_tw_sample.csv"

// drain_release_at_second_poll is a drain_wait hook for the drain
// tests: the first poll observes the drain held and returns, the
// second releases the in-flight call the test registered with
// moli.acquire — the loop then advances without any sleeping. The
// drain-based proc returning at all is the assertion: with in_use
// held and the hook inert, the drain loop would never exit.
drain_release_at_second_poll :: proc(a: ^moli.Analyzer, polls: int) {
	if polls == 1 { moli.release(a) }
}
JIEBA_HK_FIXTURE :: "tests/fixtures/jieba_hk_sample.csv"
MERGE_CN_FIXTURE :: "tests/fixtures/jieba_merge_cn.csv"
MERGE_HK_FIXTURE :: "tests/fixtures/jieba_merge_hk.csv"
EN_FIXTURE :: "tests/fixtures/en_sample.csv"
RESOURCES_FIXTURE :: "tests/fixtures/resources/sample.csv"

// write_tmp writes content to a fixed path under tmp/. Callers pass
// compile-time-constant paths, so nothing here needs releasing.
write_tmp :: proc(t: ^testing.T, path: string, content: string) {
	os.remove(path)
	data := transmute([]byte)content
	if err := os.write_entire_file(path, data); err != nil {
		testing.expectf(t, false, "write %s failed: %v", path, err)
	}
}

// load_ok loads a fixture through the real load path; ok false means
// the caller should return early (the failure is already reported).
// The analyzer rides context.allocator (the tracking allocator), so a
// forgotten free surfaces as a leak block instead of passing silently.
load_ok :: proc(t: ^testing.T, lang: moli.Language, path: string, opts: moli.Load_Options) -> (moli.Analyzer, bool) {
	a, err := moli.load(lang, path, opts, context.allocator)
	if err != nil {
		testing.expectf(t, false, "load %s failed: %v", path, err)
		return moli.Analyzer{}, false
	}
	return a, true
}

// expect_morph asserts one morpheme's surface/pos/lemma triple.
expect_morph :: proc(t: ^testing.T, m: moli.Morpheme, surface: string, pos: string, lemma: string) -> bool {
	if m.surface != surface || m.pos != pos || m.lemma != lemma {
		testing.expectf(t, false, "got (%s | %s | %s), want (%s | %s | %s)", m.surface, m.pos, m.lemma, surface, pos, lemma)
		return false
	}
	return true
}

// Test_Entry describes one dictionary entry for build_test_analyzer.
Test_Entry :: struct {
	surface: string,
	left_id: i16,
	right_id: i16,
	cost:    i16,
	pos:     string,
}

// build_test_analyzer constructs an analyzer by hand: entries with
// cloned strings, a cedar over their surfaces, the default char-class
// table, an optional dense matrix (row-major cells, matrix_n x
// matrix_n, unfilled cells keep the default cost), and the
// per-language fallback POS. Ownership mirrors load's, so moli.free
// releases everything.
build_test_analyzer :: proc(t: ^testing.T, lang: moli.Language, mode: moli.Mode, entries: []Test_Entry, matrix_cells: []i16, matrix_n: int) -> (moli.Analyzer, bool) {
	allocator := context.allocator
	a: moli.Analyzer
	a.lang = lang
	a.mode = mode
	a.dict_locale = moli.dict_locale_for(lang)
	a.allocator = allocator
	a.entries = make([dynamic]moli.Dictionary_Entry, 0, len(entries), allocator)
	for te in entries {
		append(&a.entries, moli.Dictionary_Entry{
			surface          = strings.clone(te.surface, allocator),
			left_id          = te.left_id,
			right_id         = te.right_id,
			cost             = te.cost,
			joined_pos       = strings.clone(te.pos, allocator),
			lemma            = strings.clone(te.surface, allocator),
			reading          = strings.clone("*", allocator),
			reading_jyutping = strings.clone("*", allocator),
			strings_owned    = true,
		})
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	builder: moli.Cedar_Builder
	builder.cedar = &a.cedar
	builder.allocator = allocator
	builder.scratch_allocator = mem.dynamic_arena_allocator(&arena)
	builder.entries = a.entries[:]
	if err := moli.cedar_build(&builder); err != nil {
		testing.expectf(t, false, "cedar_build failed: %v", err)
		destroy_entries(a.entries)
		delete(a.cedar.base)
		delete(a.cedar.check)
		delete(a.cedar.terminals)
		delete(a.cedar.group_count)
		return moli.Analyzer{}, false
	}
	a.char_map = builder.char_map

	table, terr := moli.char_class_build(lang, nil, false, allocator)
	if terr != nil {
		testing.expectf(t, false, "char_class_build failed: %v", terr)
		destroy_entries(a.entries)
		delete(a.cedar.base)
		delete(a.cedar.check)
		delete(a.cedar.terminals)
		delete(a.cedar.group_count)
		delete(a.char_map.forward)
		if len(a.char_map.inverse) > 0 { delete(a.char_map.inverse) }
		return moli.Analyzer{}, false
	}
	a.char_class = table
	// Built-in unknown-candidate behavior (grouped run + single rune);
	// tests that need other char.def semantics assign a.char_flags
	// directly after this returns.
	a.char_flags = moli.char_flags_default()

	if matrix_n > 0 {
		costs, merr := make([dynamic]i16, matrix_n * matrix_n, allocator)
		if merr != nil {
			testing.expectf(t, false, "matrix make failed: %v", merr)
			moli.free(&a)
			return moli.Analyzer{}, false
		}
		for i in 0 ..< matrix_n * matrix_n {
			costs[i] = moli.CONNECTION_DEFAULT_COST
		}
		for v, idx in matrix_cells {
			if idx < len(costs) { costs[idx] = v }
		}
		a.conn_matrix = moli.Connection_Matrix{costs = costs, n_left = matrix_n, n_right = matrix_n}
	}

	fpos, ferr := moli.fallback_pos(lang, allocator)
	if ferr != nil {
		testing.expectf(t, false, "fallback_pos failed: %v", ferr)
		moli.free(&a)
		return moli.Analyzer{}, false
	}
	a.unknown_fallback_pos = fpos
	a.skipped_resources = make([dynamic]string, 0, 1, allocator)
	return a, true
}

// destroy_entries releases a hand-built entry list the way analyzer
// teardown would. The allocator must be the one build_test_analyzer
// cloned the strings with (context.allocator).
destroy_entries :: proc(entries: [dynamic]moli.Dictionary_Entry) {
	for _, i in entries {
		moli.dictionary_entry_destroy(&entries[i], context.allocator)
	}
	delete(entries)
}

// ---- Comparison and fault asserts ------------------------------------------

// expect_morphemes_equal asserts two tokenizations agree on every
// field a caller can observe - entry_id, locale, and char_class
// included, which is what makes the load-path-independence contracts
// (identical analysis across snapshot save/restore and clone) live.
// The slices must not alias: comparing a tokenization with one a later
// arena reset moved on top of it compares memory with itself. Where
// the two tokenizations come from different calls, route them through
// expect_analyses_equal, which owns the no-aliasing rule.
expect_morphemes_equal :: proc(t: ^testing.T, want, got: []moli.Morpheme) -> bool {
	if len(want) != len(got) {
		testing.expectf(t, false, "morpheme counts differ: %v vs %v", len(want), len(got))
		return false
	}
	for w, i in want {
		g := got[i]
		if w.surface != g.surface || w.pos != g.pos || w.lemma != g.lemma ||
			w.reading != g.reading || w.reading_jyutping != g.reading_jyutping ||
			w.entry_id != g.entry_id || w.cost != g.cost || w.start != g.start ||
			w.end != g.end || w.locale != g.locale || w.char_class != g.char_class ||
			w.is_unknown != g.is_unknown {
			testing.expectf(t, false,
				"morpheme[%v] differs: (%s|%s|%s|id %v|%v..%v|%v) vs (%s|%s|%s|id %v|%v..%v|%v)",
				i, w.surface, w.pos, w.lemma, w.entry_id, w.start, w.end, w.is_unknown,
				g.surface, g.pos, g.lemma, g.entry_id, g.start, g.end, g.is_unknown)
			return false
		}
	}
	return true
}

// expect_analyses_equal asserts two analyzers answer identically on
// every text. Each tokenization runs into its OWN stack arena - a
// shared arena reset between two calls aliases the compared slices,
// the mistake this helper exists to make impossible - and the
// comparison is expect_morphemes_equal's full-field one.
expect_analyses_equal :: proc(t: ^testing.T, a, b: ^moli.Analyzer, texts: []string) -> bool {
	for text in texts {
		a_buf: [1 << 16]byte
		a_arena: mem.Arena
		mem.arena_init(&a_arena, a_buf[:])
		b_buf: [1 << 16]byte
		b_arena: mem.Arena
		mem.arena_init(&b_arena, b_buf[:])
		ms_a, ea := moli.tokenize(a, text, mem.arena_allocator(&a_arena))
		ms_b, eb := moli.tokenize(b, text, mem.arena_allocator(&b_arena))
		if ea != nil || eb != nil {
			testing.expectf(t, false, "tokenize %q: %v / %v", text, ea, eb)
			return false
		}
		if !expect_morphemes_equal(t, ms_a, ms_b) { return false }
	}
	return true
}

// expect_save_fault asserts strictly that err is exactly want_fault.
// A bounce or fault contract must not accept success: nil fails here,
// and so does any other fault - the conditional-assert shape (failing
// only when "some error arrived but the wrong one") lets a use-after-
// free read pass for a bounce.
expect_save_fault :: proc(t: ^testing.T, label: string, err: moli.Save_Err, want: moli.Save_Fault) -> bool {
	if err == nil {
		testing.expectf(t, false, "%s: want fault %v, got success", label, want)
		return false
	}
	switch f in err {
	case moli.Save_Fault:
		if f != want {
			testing.expectf(t, false, "%s: want fault %v, got %v", label, want, f)
			return false
		}
	}
	return true
}

// qdct_roundtrip_restore saves a through the scratch allocator and
// loads the image back through the analyzer allocator - the shared
// prelude of every round-trip test. Either failure is reported here;
// ok false means the caller should return early. The caller owns the
// restored analyzer: defer moli.free on it.
qdct_roundtrip_restore :: proc(t: ^testing.T, a: ^moli.Analyzer, path: string, scratch_allocator: mem.Allocator, allocator: mem.Allocator) -> (moli.Analyzer, bool) {
	if serr := moli.save_qdct(a, path, scratch_allocator); serr != nil {
		testing.expectf(t, false, "save_qdct %s: %v", path, serr)
		return moli.Analyzer{}, false
	}
	b, lerr := moli.load_qdct(path, allocator)
	if lerr != nil {
		testing.expectf(t, false, "load_qdct %s: %v", path, lerr)
		return moli.Analyzer{}, false
	}
	return b, true
}

// ---- Failing allocators for OOM-path tests ---------------------------------

// No_Resize_Allocator lets fresh allocations through and fails only
// growth (Resize): the failure mode of an append past capacity.
No_Resize_Allocator :: struct {
	backing: mem.Allocator,
}

no_resize_proc :: proc(
	data:      rawptr,
	mode:      mem.Allocator_Mode,
	size:      int,
	alignment: int,
	old_memory: rawptr,
	old_size:  int,
	loc:       runtime.Source_Code_Location = #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	if mode == .Resize || mode == .Resize_Non_Zeroed {
		return nil, .Out_Of_Memory
	}
	nr := cast(^No_Resize_Allocator)data
	return nr.backing.procedure(nr.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

// Budget_Allocator lets only `remaining` fresh allocations through and
// then fails them; growth (Resize) does not consume the budget but
// fails once it is spent. Point backing at the test context allocator
// so every forwarded allocation lands under the suite's zero-leak
// gate. Sweep the budget over a whole allocation sequence to starve
// each allocation point in turn - no per-point counting to go stale.
Budget_Allocator :: struct {
	backing:   mem.Allocator,
	remaining: int,
}

budget_allocator_proc :: proc(
	data:      rawptr,
	mode:      mem.Allocator_Mode,
	size:      int,
	alignment: int,
	old_memory: rawptr,
	old_size:  int,
	loc:       runtime.Source_Code_Location = #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	b := cast(^Budget_Allocator)data
	if mode == .Alloc || mode == .Alloc_Non_Zeroed {
		if b.remaining <= 0 { return nil, .Out_Of_Memory }
		b.remaining -= 1
	} else if mode == .Resize || mode == .Resize_Non_Zeroed {
		if b.remaining <= 0 { return nil, .Out_Of_Memory }
	}
	return b.backing.procedure(b.backing.data, mode, size, alignment, old_memory, old_size, loc)
}
