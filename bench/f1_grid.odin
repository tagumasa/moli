// Cost-parameter grid sweep over KWDLC: boundary F1 at k=1 for every
// (unk_cost_bias, unk_cost_per_rune) pair, on the same sentence set
// and protocol as f1_kwdlc (gold surfaces reconstructed, interior
// boundaries, micro-aggregated). The sentences are reconstructed once
// and cached, then each grid point re-tokenizes with tokenize_opt.
// Numbers-only output - no corpus text is printed. The sweep measures
// the space; it changes no defaults. Run from the repo root:
//   odin run bench/f1_grid.odin -file -collection:moli=$(pwd)/src -collection:bench=$(pwd)/bench -o:speed
package f1_grid

import "core:fmt"
import "core:mem"
import "core:os"
import "base:runtime"
import "moli:moli"
import "bench:support"

BIASES :: []i32{-4000, -2000, -1000, -500, 0, 500, 1000, 2000, 4000}
RUNES  :: []i32{0, 100, 300, 1000, 2300, 5000}

main :: proc() {
	allocator := runtime.default_allocator()

	a, err := moli.load(.Japanese, "dict/ipadic-utf8/lex.csv", {}, allocator)
	if err != nil { fmt.printf("load FAILED: %v\n", err); return }
	defer moli.free(&a)
	fmt.println("loaded ipadic")

	listing, lerr := os.read_entire_file("tmp/knp_files.txt", allocator)
	if lerr != nil { fmt.println("tmp/knp_files.txt missing - run: find dict/kwdlc/knp -name '*.knp' | sort > tmp/knp_files.txt"); return }
	defer delete(listing, allocator)
	files := support.parse_listing(string(listing), allocator)
	defer {
		for f in files { delete(f, allocator) }
		delete(files)
	}

	// Reconstruct-and-cache pass: one arena holds every sentence's
	// bytes, the gold offsets sit in one flat array with per-sentence
	// ranges (offsets[i] ..< offsets[i+1]).
	text_arena_buf := make([]u8, 1 << 26, allocator)
	text_arena: mem.Arena
	mem.arena_init(&text_arena, text_arena_buf[:])
	defer delete(text_arena_buf, allocator)

	texts: [dynamic]string
	gold_flat: [dynamic]int
	gold_off: [dynamic]int
	surfaces: [dynamic]string
	defer { delete(texts); delete(gold_flat); delete(gold_off); delete(surfaces) }

	skipped := 0
	for f in files {
		data, rerr := os.read_entire_file(f, allocator)
		if rerr != nil { continue }
		pos := 0
		for pos < len(data) {
			end := pos
			for end < len(data) && data[end] != '\n' { end += 1 }
			line := string(data[pos:end])
			pos = end + 1
			if support.handle_knp_line(line, &surfaces, allocator) {
				n_before := len(gold_flat)
				txt, _, ok := build_sentence(surfaces[:], &text_arena, &gold_flat)
				if ok {
					append(&gold_off, n_before)
					append(&texts, txt)
				} else if len(surfaces) > 0 {
					skipped += 1
				}
				support.clear_sentence(&surfaces, allocator)
			}
		}
		support.clear_sentence(&surfaces, allocator)
		delete(data, allocator)
	}
	append(&gold_off, len(gold_flat))
	fmt.printf("sentences=%d skipped=%d grid=%dx%d\n", len(texts), skipped, len(BIASES), len(RUNES))

	arena_buf := make([]u8, 1 << 24, allocator)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	defer delete(arena_buf, allocator)

	best_f1 := 0.0
	best_bias, best_rune: i32 = 0, 0
	for bias in BIASES {
		for per_rune in RUNES {
			opts := moli.Tokenize_Options{unk_cost_bias = bias, unk_cost_per_rune = per_rune}
			gold_total, pred_total, match_total, unk_total, morph_total := 0, 0, 0, 0, 0
			for txt, i in texts {
				mem.arena_free_all(&arena)
				ms, terr := moli.tokenize_opt(&a, txt, opts, mem.arena_allocator(&arena))
				if terr != nil { continue }
				pred_n, unk_n, match_n := score(gold_flat[gold_off[i]:gold_off[i + 1]], ms)
				gold_total += gold_off[i + 1] - gold_off[i]
				pred_total += pred_n
				match_total += match_n
				unk_total += unk_n
				morph_total += len(ms)
			}
			if pred_total == 0 { fmt.printf("bias=%5d per_rune=%5d  no boundaries\n", bias, per_rune); continue }
			p := f64(match_total) / f64(pred_total)
			r := f64(match_total) / f64(gold_total)
			f1 := 2 * p * r / (p + r)
			fmt.printf("bias=%5d per_rune=%5d  P=%.4f R=%.4f F1=%.4f  unk=%.2f%%\n",
				bias, per_rune, p, r, f1, f64(unk_total) * 100.0 / f64(morph_total))
			if f1 > best_f1 {
				best_f1, best_bias, best_rune = f1, bias, per_rune
			}
		}
	}
	fmt.printf("best: bias=%d per_rune=%d F1=%.4f (default 0/0 for comparison)\n", best_bias, best_rune, best_f1)
}

// score two-pointers the interior boundaries (same protocol as
// f1_kwdlc; the caller drops each list's final boundary).
score :: proc(gold: []int, ms: []moli.Morpheme) -> (pred_n: int, unk_n: int, match_n: int) {
	unk := 0
	pred: [dynamic]int
	defer delete(pred)
	for m in ms {
		append(&pred, m.end)
		if m.is_unknown { unk += 1 }
	}
	if len(pred) > 0 { resize(&pred, len(pred) - 1) }
	gi, pi, match := 0, 0, 0
	for gi < len(gold) && pi < len(pred) {
		if gold[gi] == pred[pi] {
			match += 1
			gi += 1
			pi += 1
		} else if gold[gi] < pred[pi] {
			gi += 1
		} else {
			pi += 1
		}
	}
	return len(pred), unk, match
}

// build_sentence concatenates the gold surfaces into the text arena,
// appends the interior gold boundaries to gold_flat, and answers how
// many it appended. ok=false marks a filtered sentence (whitespace
// representation or empty surface list).
build_sentence :: proc(surfaces: []string, arena: ^mem.Arena, gold_flat: ^[dynamic]int) -> (txt: string, n_gold: int, ok: bool) {
	if len(surfaces) == 0 { return "", 0, false }
	for s in surfaces {
		if s == "空白" || support.strings_contains_space(s) { return "", 0, false }
	}
	total := 0
	for s in surfaces { total += len(s) }
	buf, aerr := mem.alloc_bytes(total, 1, mem.arena_allocator(arena))
	if aerr != nil { return "", 0, false }
	pos := 0
	for s in surfaces {
		copy(buf[pos:pos + len(s)], transmute([]u8)s)
		pos += len(s)
	}
	off := 0
	for s in surfaces {
		off += len(s)
		append(gold_flat, off)
	}
	// The final boundary is the sentence end, not an interior one.
	resize(gold_flat, len(gold_flat^) - 1)
	return string(buf), len(surfaces) - 1, true
}

// contains_space, handle_knp_line, clear_sentence, and parse_listing
// live in bench:support, shared with the f1 family.
