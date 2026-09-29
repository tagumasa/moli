// The documented chunk-cut rule, pinned: cutting immediately after a
// complete newline run never splits a morpheme and reproduces the
// single call's morpheme sequence exactly on this fixture, while a
// cut between the newlines of a blank line splits it — one extra
// morpheme per such cut. Guards the unknown-run grouping the rule
// rests on; the chunking note in docs/benchmarks.md is the prose contract.
package tests

import "core:mem"
import "core:testing"
import "moli:moli"

chunk_paragraphs := []string{
	"古い時計塔の針が七時を指す。",
	"ヴェルダナートの森は雪に覆われていた。",
	"セレステは黙って頷いた。",
}

@(test)
chunk_cut_rule_test :: proc(t: ^testing.T) {
	entries := []Test_Entry{
		{surface = "時計", left_id = 0, right_id = 0, cost = 0, pos = "名詞"},
		{surface = "森",   left_id = 0, right_id = 0, cost = 0, pos = "名詞"},
		{surface = "雪",   left_id = 0, right_id = 0, cost = 0, pos = "名詞"},
	}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	buf, berr := make([dynamic]u8, 0, 4096, context.allocator)
	if berr != nil {
		testing.expectf(t, false, "text buffer make failed: %v", berr)
		return
	}
	defer delete(buf)
	for _ in 0 ..< 6 {
		for p in chunk_paragraphs {
			for i in 0 ..< len(p) {
				if _, aerr := append(&buf, p[i]); aerr != nil { break }
			}
			if _, e1 := append(&buf, u8('\n')); e1 != nil { break }
			if _, e2 := append(&buf, u8('\n')); e2 != nil { break }
		}
	}
	text := string(buf[:])

	// ~2.5 KiB of text still builds a few thousand lattice nodes (the
	// default flags add single-rune unknown candidates at every
	// position), so the piece arenas are heap-backed with headroom.
	arena_a_buf, abuf_err := make([]u8, 1 << 20, context.allocator)
	if abuf_err != nil {
		testing.expectf(t, false, "arena a make failed: %v", abuf_err)
		return
	}
	defer delete(arena_a_buf, context.allocator)
	arena_a: mem.Arena
	mem.arena_init(&arena_a, arena_a_buf[:])
	arena_b_buf, bbuf_err := make([]u8, 1 << 20, context.allocator)
	if bbuf_err != nil {
		testing.expectf(t, false, "arena b make failed: %v", bbuf_err)
		return
	}
	defer delete(arena_b_buf, context.allocator)
	arena_b: mem.Arena
	mem.arena_init(&arena_b, arena_b_buf[:])

	full, ferr := moli.tokenize(&a, text, mem.arena_allocator(&arena_a))
	if ferr != nil {
		testing.expectf(t, false, "single-call tokenize failed: %v", ferr)
		return
	}

	// The single call groups every blank line into one morpheme; the
	// grouped run is the behaviour the cut rules lean on.
	blank_runs, lone_newlines := 0, 0
	for m in full {
		if m.surface == "\n\n" { blank_runs += 1 }
		if m.surface == "\n"   { lone_newlines += 1 }
	}
	testing.expectf(t, blank_runs > 0, "expected grouped blank-line morphemes, saw %d", blank_runs)
	testing.expectf(t, lone_newlines == 0, "blank lines must group, saw %d lone-newline morphemes", lone_newlines)
	if blank_runs == 0 || lone_newlines != 0 { return }

	// Two cut sets over the same blank lines: between the two
	// newlines (inside the run) and immediately after the run.
	naive_cuts, nerr := make([dynamic]int, 0, 64, context.allocator)
	if nerr != nil {
		testing.expectf(t, false, "naive cut make failed: %v", nerr)
		return
	}
	defer delete(naive_cuts)
	safe_cuts, serr := make([dynamic]int, 0, 64, context.allocator)
	if serr != nil {
		testing.expectf(t, false, "safe cut make failed: %v", serr)
		return
	}
	defer delete(safe_cuts)
	for i in 1 ..< len(text) {
		if text[i - 1] == '\n' && text[i] == '\n' {
			if _, aerr := append(&naive_cuts, i); aerr != nil { break }
		}
		if text[i - 1] == '\n' && text[i] != '\n' {
			if _, aerr := append(&safe_cuts, i); aerr != nil { break }
		}
	}

	// chunk_run tokenizes the pieces between cuts (piece scratch reset
	// per piece in arena_b) and folds the sequence against `full`.
	// compare false counts only; compare true also records divergence.
	chunk_run :: proc(cuts: []int, compare: bool, a: ^moli.Analyzer, text: string,
			full: []moli.Morpheme, arena: ^mem.Arena) -> (count: int, diverged: bool, failed: bool) {
		prev := 0
		idx := 0
		for c in cuts {
			if c <= prev || c > len(text) { continue }
			ms, terr := moli.tokenize(a, text[prev:c], mem.arena_allocator(arena))
			if terr != nil { return 0, diverged, true }
			count += len(ms)
			if compare {
				for m in ms {
					if idx >= len(full) || m.surface != full[idx].surface || m.pos != full[idx].pos {
						diverged = true
					}
					idx += 1
				}
			}
			mem.arena_free_all(arena)
			prev = c
		}
		if prev < len(text) {
			ms, terr := moli.tokenize(a, text[prev:], mem.arena_allocator(arena))
			if terr != nil { return 0, diverged, true }
			count += len(ms)
			if compare {
				for m in ms {
					if idx >= len(full) || m.surface != full[idx].surface || m.pos != full[idx].pos {
						diverged = true
					}
					idx += 1
				}
			}
			mem.arena_free_all(arena)
		}
		return count, diverged, false
	}

	safe_count, safe_div, safe_fail := chunk_run(safe_cuts[:], true, &a, text, full, &arena_b)
	testing.expectf(t, !safe_fail, "safe-cut chunk tokenize failed")
	testing.expectf(t, !safe_div, "safe cuts must not change the morpheme sequence")
	testing.expectf(t, safe_count == len(full),
		"safe cuts must preserve the morpheme count: single %d, chunked %d", len(full), safe_count)

	naive_count, naive_div, naive_fail := chunk_run(naive_cuts[:], true, &a, text, full, &arena_b)
	testing.expectf(t, !naive_fail, "naive-cut chunk tokenize failed")
	testing.expectf(t, naive_div, "cuts inside a blank-line run must change the morpheme sequence")
	testing.expectf(t, naive_count == len(full) + len(naive_cuts),
		"a cut inside a run splits exactly one morpheme: single %d, chunked %d, cuts %d",
		len(full), naive_count, len(naive_cuts))

	// The library's chunking helper must select exactly this safe-cut
	// set at target 1 and reproduce the single call's sequence through
	// them - the public form of the rule the two hand-derived sets pin.
	helper_cuts, herr := moli.safe_chunk_offsets(text, 1, context.allocator)
	if herr != nil {
		testing.expectf(t, false, "safe_chunk_offsets failed: %v", herr)
		return
	}
	defer delete(helper_cuts, context.allocator)
	same := len(helper_cuts) == len(safe_cuts)
	if same {
		for i in 0 ..< len(helper_cuts) {
			if helper_cuts[i] != safe_cuts[i] { same = false }
		}
	}
	testing.expectf(t, same,
		"safe_chunk_offsets at target 1 must take every after-run cut: helper %d, scan %d",
		len(helper_cuts), len(safe_cuts))
	if !same { return }

	helper_count, helper_div, helper_fail := chunk_run(helper_cuts, true, &a, text, full, &arena_b)
	testing.expectf(t, !helper_fail, "helper-cut chunk tokenize failed")
	testing.expectf(t, !helper_div, "helper cuts must not change the morpheme sequence")
	testing.expectf(t, helper_count == len(full),
		"helper cuts must preserve the morpheme count: single %d, chunked %d", len(full), helper_count)
}
