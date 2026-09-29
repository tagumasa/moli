// Boundary-F1 vs KWDLC (gitignored clone under dict/kwdlc; CC-BY web
// documents; numbers-only output - no corpus text is printed).
// Protocol: reconstruct each sentence from its gold morpheme
// surfaces, tokenize with the ipadic analyzer (Viterbi default,
// surface patterns loaded), compare interior boundary offsets
// (two-pointer over ascending lists), micro-aggregate. Sentences
// containing whitespace representations or empty surfaces are
// skipped. Run from the repo root:
//   odin run bench/f1_kwdlc_qpat.odin -file -collection:moli=$(pwd)/src -collection:bench=$(pwd)/bench -o:speed
package f1_kwdlc_qpat

import "core:fmt"
import "core:mem"
import "core:os"
import "base:runtime"
import "moli:moli"
import "bench:support"

main :: proc() {
	allocator := runtime.default_allocator()

	a, err := moli.load(.Japanese, "dict/ipadic-utf8/lex.csv", {qpat_path = "bench/ipadic_patterns.qpat"}, allocator)
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

	gold_off: [dynamic]int
	pred_off: [dynamic]int
	surfaces: [dynamic]string
	defer { delete(gold_off); delete(pred_off); delete(surfaces) }

	sentences := 0
	skipped := 0
	gold_total := 0
	pred_total := 0
	match_total := 0
	unknown_pred := 0
	pattern_hits: int = 0
	pred_morphemes := 0
	// Character-class signature of unmatched boundaries (numbers
	// only): the class of the rune just before each boundary the
	// prediction added (over-split) or the gold had and the
	// prediction missed (under-split).
	over_cls := [6]int{}
	miss_cls := [6]int{}

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
				s_text := ""
				scored, s_skipped, s_gold, s_pred, s_match, s_unk, s_morphs :=
					support.score_sentence(&a, surfaces[:], &arena, &gold_off, &pred_off, &s_text, &pattern_hits)
				if scored {
					sentences += 1
					gold_total += s_gold
					pred_total += s_pred
					match_total += s_match
					unknown_pred += s_unk
					pred_morphemes += s_morphs
					support.tally_mismatches(s_text, gold_off[:], pred_off[:], &over_cls, &miss_cls)
				} else if s_skipped {
					skipped += 1
				}
				support.clear_sentence(&surfaces, allocator)
			}
		}
		support.clear_sentence(&surfaces, allocator)
		delete(data, allocator)
	}

	if gold_total == 0 || pred_total == 0 {
		fmt.println("no boundaries scored")
		return
	}
	p := f64(match_total) / f64(pred_total)
	r := f64(match_total) / f64(gold_total)
	f1 := 2 * p * r / (p + r)
	fmt.printf("[faithful] sentences=%d skipped=%d euc_dropped=%d gold_b=%d pred_b=%d match=%d\n",
		sentences, skipped, euc_dropped, gold_total, pred_total, match_total)
	fmt.printf("[faithful] boundary precision=%.4f recall=%.4f F1=%.4f\n", p, r, f1)
	fmt.printf("[faithful] predicted morphemes=%d unknown=%d (%.2f%%) pattern-labelled=%d\n",
		pred_morphemes, unknown_pred, f64(unknown_pred) * 100.0 / f64(pred_morphemes), pattern_hits)
	fmt.printf("[faithful] over-split by preceding rune class: hira=%d kata=%d kan=%d ascii=%d fw=%d other=%d; missed: hira=%d kata=%d kan=%d ascii=%d fw=%d other=%d\n",
		over_cls[0], over_cls[1], over_cls[2], over_cls[3], over_cls[4], over_cls[5],
		miss_cls[0], miss_cls[1], miss_cls[2], miss_cls[3], miss_cls[4], miss_cls[5])
}
