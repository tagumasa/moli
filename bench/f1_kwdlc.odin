// Boundary-F1 vs KWDLC (gitignored clone under dict/kwdlc; CC-BY web
// documents; numbers-only output - no corpus text is printed).
// Protocol: reconstruct each sentence from its gold morpheme
// surfaces, tokenize with the ipadic analyzer (Viterbi default),
// compare interior boundary offsets (two-pointer over ascending
// lists), micro-aggregate. Sentences containing whitespace
// representations or empty surfaces are skipped. Run from the repo
// root:
//   odin run bench/f1_kwdlc.odin -file -collection:moli=$(pwd)/src -collection:bench=$(pwd)/bench -o:speed
package f1_kwdlc

import "core:fmt"
import "core:mem"
import "core:os"
import "base:runtime"
import "moli:moli"
import "bench:support"

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

	// The reference control's EUC-JP drop set, when it has written one
	// (see support.euc_drops_read): both arms score the identical set.
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
	pred_morphemes := 0
	first_pass_done := false
	label := "faithful"
	// The scored-corpus side product: every sentence pass 0 scores,
	// one line of space-joined gold surfaces. The reference control
	// (f1_mecab_control.py) consumes this file instead of re-parsing
	// KWDLC, so both arms run on the identical sentence set by
	// construction - the parse and filter rules exist once, here.
	// Surfaces cannot contain the separator (space-bearing sentences
	// are filtered before scoring).
	corpus_buf := make([dynamic]u8, 0, 1 << 16, allocator)
	defer delete(corpus_buf)
	// Character-class signature of unmatched boundaries (numbers
	// only): the class of the rune just before each boundary the
	// prediction added (over-split) or the gold had and the
	// prediction missed (under-split).
	over_cls := [6]int{}
	miss_cls := [6]int{}

	for pass in 0 ..< 2 {
	if pass == 1 {
		// Second configuration: built-in default flags - whole-run
		// unknowns (the pre-char.def-faithful lattice shape).
		// The corpus file is complete at this point: write it once.
		if werr := os.write_entire_file("tmp/kwdlc_sentences.txt", corpus_buf[:]); werr != nil {
			fmt.printf("corpus write FAILED: %v\n", werr)
			return
		}
		first_pass_done = true
		a.char_flags = moli.char_flags_default()
		sentences, skipped = 0, 0
		gold_total, pred_total, match_total = 0, 0, 0
		unknown_pred, pred_morphemes = 0, 0
		euc_dropped = 0
	}
	if pass == 1 { label = "run-grouped" }

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
					support.score_sentence(&a, surfaces[:], &arena, &gold_off, &pred_off, &s_text, nil)
				if scored {
					sentences += 1
					gold_total += s_gold
					pred_total += s_pred
					match_total += s_match
					unknown_pred += s_unk
					pred_morphemes += s_morphs
					if !first_pass_done {
						append_corpus_line(&corpus_buf, surfaces[:])
						support.tally_mismatches(s_text, gold_off[:], pred_off[:], &over_cls, &miss_cls)
					}
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
		fmt.printf("[%s] sentences=%d skipped=%d euc_dropped=%d gold_b=%d pred_b=%d match=%d\n",
			label, sentences, skipped, euc_dropped, gold_total, pred_total, match_total)
	fmt.printf("[%s] boundary precision=%.4f recall=%.4f F1=%.4f\n", label, p, r, f1)
	fmt.printf("[%s] predicted morphemes=%d unknown=%d (%.2f%%)\n",
		label, pred_morphemes, unknown_pred, f64(unknown_pred) * 100.0 / f64(pred_morphemes))
	if !first_pass_done {
		fmt.printf("[faithful] over-split by preceding rune class: hira=%d kata=%d kan=%d ascii=%d fw=%d other=%d; missed: hira=%d kata=%d kan=%d ascii=%d fw=%d other=%d\n",
			over_cls[0], over_cls[1], over_cls[2], over_cls[3], over_cls[4], over_cls[5],
			miss_cls[0], miss_cls[1], miss_cls[2], miss_cls[3], miss_cls[4], miss_cls[5])
	}
	} // pass loop
}

// append_corpus_line adds one sentence to the scored-corpus side
// product: surfaces joined by single spaces plus a newline. The
// separator cannot occur inside a surface (the protocol filters
// space-bearing sentences before scoring), so the line splits back
// into exactly the gold surfaces.
append_corpus_line :: proc(buf: ^[dynamic]u8, surfaces: []string) {
	for s, i in surfaces {
		if i > 0 {
			if _, aerr := append(buf, ' '); aerr != nil { return }
		}
		for b in transmute([]u8)s {
			if _, aerr := append(buf, b); aerr != nil { return }
		}
	}
	if _, aerr := append(buf, '\n'); aerr != nil { return }
}
