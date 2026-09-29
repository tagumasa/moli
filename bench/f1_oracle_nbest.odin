// N-best oracle measurement over the same KWDLC protocol as
// f1_kwdlc.odin (gitignored clone under dict/kwdlc; CC-BY web
// documents; numbers-only output - no corpus text is printed). Each
// sentence is reconstructed from its gold morpheme surfaces and
// enumerated with tokenize_nbest; every returned path is scored
// against the gold interior boundaries. Three questions get numbers:
// (1) oracle@k - the boundary F1 of the best path among the k
// cheapest, the ceiling any N-best re-ranker could reach; (2) at
// which rank the exactly-gold segmentation first appears; (3) how
// far above the cheapest path its cost sits - the margin a re-ranker
// would have to overturn. oracle@1 must reproduce the f1_kwdlc
// faithful arm (same engine, same protocol). Run from the repo root:
//   odin run bench/f1_oracle_nbest.odin -file -collection:moli=$(pwd)/src -collection:bench=$(pwd)/bench -o:speed
package f1_oracle_nbest

import "core:fmt"
import "core:mem"
import "core:os"
import "base:runtime"
import "moli:moli"
import "bench:support"

K_MAX :: 10
KS :: [4]int{1, 3, 5, 10}

// Oracle_Stats accumulates the whole-corpus measurement. gap_min
// needs the i64 ceiling at init (struct field defaults do not exist
// on this toolchain); the zero value of everything else is correct.
Oracle_Stats :: struct {
	sentences:   int,
	skipped:     int,
	paths_total: int,
	paths_short: int, // sentences returning fewer than K_MAX paths
	o_gold:      [4]int, // per k in KS: gold boundaries summed over chosen paths
	o_pred:      [4]int,
	o_match:     [4]int,
	rank_hist:   [K_MAX + 1]int, // exact-gold first rank; [K_MAX] = absent
	gap_n:       int, // sentences whose exact-gold path is in the K_MAX
	gap_zero:    int, // ... and costs the same as the cheapest path
	gap_t:       [5]int, // nonzero gaps bucketed <=10, <=100, <=1000, <=10000, over
	gap_min:     i64,
	gap_sum:     i64,
	gap_max:     i64,
}

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
	fmt.printf("knp files: %d\n", len(files))

	// The reference control's EUC-JP drop set, when present, keeps
	// every f1 arm on the identical sentence set (see
	// support.euc_drops_read).
	drops, drops_ok := support.euc_drops_read("tmp/kwdlc_euc_drops.txt", allocator)
	defer support.euc_drops_free(&drops, allocator)
	if drops_ok { fmt.printf("euc drop set: %d sentences\n", len(drops)) }
	euc_dropped := 0

	arena_buf := make([]u8, 1 << 24, allocator)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	defer delete(arena_buf, allocator)

	surfaces := make([dynamic]string, 0, 256, allocator)
	defer delete(surfaces)
	gold_off := make([dynamic]int, 0, 256, allocator)
	defer delete(gold_off)

	st := Oracle_Stats{gap_min = i64(max(i64))}

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
				if support.sentence_euc_dropped(drops[:], surfaces[:], allocator) {
					euc_dropped += 1
					support.clear_sentence(&surfaces, allocator)
					continue
				}
				scored, s_skipped, n_paths :=
					score_nbest(&a, surfaces[:], &arena, &gold_off, &st)
				if scored {
					st.sentences += 1
					st.paths_total += n_paths
					if n_paths < K_MAX { st.paths_short += 1 }
				} else if s_skipped {
					st.skipped += 1
				}
				support.clear_sentence(&surfaces, allocator)
			}
		}
		support.clear_sentence(&surfaces, allocator)
		delete(data, allocator)
	}

	if st.sentences == 0 { fmt.println("no sentences scored"); return }
	fmt.printf("sentences=%d skipped=%d euc_dropped=%d paths_mean=%.2f paths_short(<%d)=%d\n",
		st.sentences, st.skipped, euc_dropped,
		f64(st.paths_total) / f64(st.sentences), K_MAX, st.paths_short)

	ks := KS
	f1s: [4]f64
	for k, ki in ks {
		if st.o_pred[ki] == 0 || st.o_gold[ki] == 0 { continue }
		p := f64(st.o_match[ki]) / f64(st.o_pred[ki])
		r := f64(st.o_match[ki]) / f64(st.o_gold[ki])
		f1s[ki] = 2 * p * r / (p + r)
		fmt.printf("oracle@%-2d P=%.4f R=%.4f F1=%.4f\n", k, p, r, f1s[ki])
	}
	fmt.printf("headroom vs oracle@1: @3=%+.2fpt @5=%+.2fpt @10=%+.2fpt\n",
		(f1s[1] - f1s[0]) * 100.0, (f1s[2] - f1s[0]) * 100.0, (f1s[3] - f1s[0]) * 100.0)

	fmt.printf("gold-exact rank histogram:")
	for r in 0 ..< K_MAX { fmt.printf(" %d:%d", r + 1, st.rank_hist[r]) }
	fmt.printf(" absent>%d:%d\n", K_MAX, st.rank_hist[K_MAX])
	fmt.print("gold-exact within:")
	for k in ks {
		in_k := 0
		for r in 0 ..< min(k, K_MAX) { in_k += st.rank_hist[r] }
		fmt.printf(" k=%d:%d(%.2f%%)", k, in_k, f64(in_k) * 100.0 / f64(st.sentences))
	}
	fmt.println()

	if st.gap_n > 0 {
		fmt.printf("cost gap (exact-gold vs cheapest, n=%d): zero=%d <=10=%d <=100=%d <=1000=%d <=10000=%d >10000=%d min=%d mean=%.1f max=%d\n",
			st.gap_n, st.gap_zero, st.gap_t[0], st.gap_t[1], st.gap_t[2], st.gap_t[3], st.gap_t[4],
			st.gap_min, f64(st.gap_sum) / f64(st.gap_n), st.gap_max)
	} else {
		fmt.println("cost gap: no sentence has its exact-gold path in the enumeration")
	}
}

// score_nbest enumerates one sentence and folds its paths into st;
// scored=false with skipped=true when the sentence is filtered out
// or the enumeration fails.
score_nbest :: proc(a: ^moli.Analyzer, surfaces: []string, arena: ^mem.Arena,
	gold_off: ^[dynamic]int, st: ^Oracle_Stats,
) -> (scored: bool, skipped: bool, n_paths: int) {
	if len(surfaces) == 0 { return false, false, 0 }
	for s in surfaces {
		if s == "空白" || support.strings_contains_space(s) { return false, true, 0 }
	}

	mem.arena_free_all(arena)
	arena_alloc := mem.arena_allocator(arena)
	total := 0
	for s in surfaces { total += len(s) }
	buf, aerr := mem.alloc_bytes(total, 1, arena_alloc)
	if aerr != nil { return false, true, 0 }
	pos := 0
	for s in surfaces {
		copy(buf[pos:pos + len(s)], transmute([]u8)s)
		pos += len(s)
	}
	txt := string(buf)

	resize(gold_off, 0)
	off := 0
	for s in surfaces {
		off += len(s)
		append(gold_off, off)
	}
	// Drop the final boundary (end of sentence): interior only.
	resize(gold_off, len(gold_off^) - 1)
	gold_n := len(gold_off^)

	paths := make([dynamic]moli.NBest_Path, 0, K_MAX, arena_alloc)
	if nerr := moli.tokenize_nbest(a, txt, K_MAX, {}, {}, &paths, arena_alloc); nerr != nil {
		return false, true, 0
	}
	n := len(paths)
	if n == 0 { return false, true, 0 }

	// Per-path boundary tallies and the first exactly-gold rank.
	match_n: [K_MAX]int
	pred_n: [K_MAX]int
	exact_rank := -1
	pred_off := make([dynamic]int, 0, 64, arena_alloc)
	for pth, r in paths {
		resize(&pred_off, 0)
		for m in pth.morphemes { append(&pred_off, m.end) }
		if len(pred_off) > 0 { resize(&pred_off, len(pred_off) - 1) }
		pred_n[r] = len(pred_off)
		gi, pi := 0, 0
		match := 0
		for gi < gold_n && pi < len(pred_off) {
			if gold_off^[gi] == pred_off[pi] {
				match += 1
				gi += 1
				pi += 1
			} else if gold_off^[gi] < pred_off[pi] {
				gi += 1
			} else {
				pi += 1
			}
		}
		match_n[r] = match
		if exact_rank < 0 && pred_n[r] == gold_n && match == gold_n {
			exact_rank = r
		}
	}

	// oracle@k: the best per-sentence F1 among the k cheapest paths;
	// the first strict maximum wins, so ties go to the cheaper path.
	ks := KS
	for k, ki in ks {
		limit := k
		if limit > n { limit = n }
		best_r, best_f := 0, -1.0
		for r in 0 ..< limit {
			f := 0.0
			if match_n[r] > 0 {
				f = 2.0 * f64(match_n[r]) / f64(pred_n[r] + gold_n)
			} else if gold_n == 0 && pred_n[r] == 0 {
				f = 1.0
			}
			if f > best_f { best_f = f; best_r = r }
		}
		st.o_gold[ki] += gold_n
		st.o_pred[ki] += pred_n[best_r]
		st.o_match[ki] += match_n[best_r]
	}

	if exact_rank >= 0 {
		st.rank_hist[exact_rank] += 1
		gap := paths[exact_rank].cost - paths[0].cost
		st.gap_n += 1
		if gap == 0 {
			st.gap_zero += 1
		} else {
			switch {
			case gap <= 10:    st.gap_t[0] += 1
			case gap <= 100:   st.gap_t[1] += 1
			case gap <= 1000:  st.gap_t[2] += 1
			case gap <= 10000: st.gap_t[3] += 1
			case:              st.gap_t[4] += 1
			}
		}
		if gap < st.gap_min { st.gap_min = gap }
		if gap > st.gap_max { st.gap_max = gap }
		st.gap_sum += gap
	} else {
		st.rank_hist[K_MAX] += 1
	}
	return true, false, n
}

// handle_knp_line, clear_sentence, parse_listing, and the whitespace
// filter live in bench:support, shared with the f1 family.
