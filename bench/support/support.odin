// Shared bench support: the corpus readers, text builders, pools, and
// stats the measurement harnesses under bench/ share. One definition
// of each, so harnesses cannot drift - the f1 family grew four copies
// of the KWDLC readers (one renamed), and median_of six divergent
// definitions, before this package existed. Referenced through the
// bench collection; every harness run line carries both collections:
//
//	odin run bench/<harness>.odin -file \
//	  -collection:moli=$(pwd)/src -collection:bench=$(pwd)/bench
package support

import "core:fmt"
import "core:mem"
import "core:os"

import "moli:moli"

// snapshot_fresh refuses a stale measurement input: it loads the CSV
// a snapshot was produced from and compares the dictionary
// fingerprint (entries_hash) against the snapshot's. A snapshot an
// older tree or engine wrote loads fine and measures wrong, so every
// consumer calls this before its first timed round and exits on
// false (the message says how to regenerate). mode does not enter the
// fingerprint - it is a property of the dictionary rows, so one check
// covers both mode images of the same CSV.
snapshot_fresh :: proc(qdct_path: string, lang: moli.Language, csv_path: string, allocator: mem.Allocator) -> bool {
	snap, lerr := moli.load_qdct(qdct_path, allocator)
	if lerr != nil {
		fmt.printf("%s failed to load: %v - run: just bench-snapshots\n", qdct_path, lerr)
		return false
	}
	defer moli.free(&snap)
	fresh, ferr := moli.load(lang, csv_path, {}, allocator)
	if ferr != nil {
		fmt.printf("fresh %s load failed: %v\n", csv_path, ferr)
		return false
	}
	defer moli.free(&fresh)
	snap_st, serr := moli.stats(&snap)
	fresh_st, ferr2 := moli.stats(&fresh)
	if serr != nil || ferr2 != nil {
		fmt.printf("stats failed while checking %s\n", qdct_path)
		return false
	}
	if snap_st.entries_hash != fresh_st.entries_hash {
		fmt.printf("%s is stale: entries_hash %x != fresh %x - run: just bench-snapshots\n",
			qdct_path, snap_st.entries_hash, fresh_st.entries_hash)
		return false
	}
	return true
}

// jp_pool is the shared Japanese news-pool seed text (12 sentences).
jp_pool := []string{
	"東京都は二十五日、新型コロナウイルスの感染者数が過去最多を更新したと発表した。",
	"政府は来年度予算案の編成に向け、歳出改革の議論を本格化させる方針だ。",
	"市場関係者は日経平均株価の急落を警戒している。",
	"研究チームは気候変動が生態系に与える影響を分析した。",
	"駅前の新しい図書館は来月一日に開館する。",
	"彼女はヴェルタース地方の雑木林を訪ねた。",
	"社長は記者会見で増益決算を説明した。",
	"台風九号は日本海へ進み、北海道に接近している。",
	"その提案には賛成できないと彼は述べた。",
	"最新の観測データによれば、地震活動は沈静化しつつある。",
	"私たちは東京駅から新幹線に乗って京都へ向かった。",
	"この地域では米や野菜の生産が盛んだ。",
}

// median_of answers the median of the samples - the average of the two
// middle values when n is even (the pre-support harnesses split on
// this: four took the upper middle, two averaged; the average is the
// one definition kept). The input is left unsorted: the sort runs on a
// scratch copy.
median_of :: proc(values: []f64) -> f64 {
	n := len(values)
	if n == 0 { return 0 }
	sorted := make([dynamic]f64, n, context.temp_allocator)
	defer delete(sorted)
	for v, i in values { sorted[i] = v }
	for i := 1; i < n; i += 1 {
		v := sorted[i]
		j := i - 1
		for j >= 0 && sorted[j] > v {
			sorted[j + 1] = sorted[j]
			j -= 1
		}
		sorted[j + 1] = v
	}
	if n % 2 == 1 { return sorted[n / 2] }
	return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
}

// build_text joins parts (interleaving sep after each part, whole
// parts only) and repeats until the text reaches target bytes; the
// answer is one exact-length clone owned by the caller
// (delete(result, allocator)).
build_text :: proc(parts: []string, sep: string, target: int, allocator: mem.Allocator) -> string {
	buf := make([dynamic]u8, 0, target + 256, allocator)
	defer delete(buf)
	for len(buf) < target {
		for s in parts {
			for i in 0 ..< len(s) {
				if _, aerr := append(&buf, s[i]); aerr != nil { break }
			}
			if len(buf) >= target { break }
			for i in 0 ..< len(sep) {
				if _, aerr := append(&buf, sep[i]); aerr != nil { break }
			}
		}
	}
	out, _ := mem.alloc_bytes(len(buf), 1, allocator)
	copy(out, buf[:])
	return string(out)
}

// --- KWDLC corpus reading (the f1 family) ---------------------------

// strings_contains_space reports whether s carries an ASCII space or
// tab - the filter that drops sentences whose gold surfaces contain
// whitespace representations.
strings_contains_space :: proc(s: string) -> bool {
	for b in s {
		if b == ' ' || b == '\t' { return true }
	}
	return false
}

// handle_knp_line folds one line into the sentence accumulator;
// returns true when the sentence is complete (EOS). Morpheme lines
// carry the surface in field 0; #/*/+/@ and EOS are structure.
handle_knp_line :: proc(line: string, surfaces: ^[dynamic]string, allocator: mem.Allocator) -> bool {
	s := line
	// Strip trailing CR.
	if len(s) > 0 && s[len(s) - 1] == '\r' { s = s[:len(s) - 1] }
	if len(s) == 0 { return false }
	if s[0] == '#' { return false }
	if s == "EOS" { return true }
	if s[0] == '*' || s[0] == '+' || s[0] == '@' || s[0] == 'E' { return false }
	end := 0
	for end < len(s) && s[end] != ' ' && s[end] != '\t' { end += 1 }
	clone, cerr := mem.alloc_bytes(end, 1, allocator)
	if cerr != nil { return false }
	copy(clone, transmute([]u8)s[:end])
	append(surfaces, string(clone))
	return false
}

clear_sentence :: proc(surfaces: ^[dynamic]string, allocator: mem.Allocator) {
	for s in surfaces^ { delete(s, allocator) }
	resize(surfaces, 0)
}

// --- EUC-JP drop set (the reference-control parity) ------------------
//
// The MeCab control's dictionary is EUC-JP, and a sentence carrying a
// JIS-unmappable rune cannot cross it. Which sentences those are is a
// property only the encoding side can decide, so the control computes
// the drop set and writes it (one space-joined sentence per line, the
// corpus format) to tmp/kwdlc_euc_drops.txt; every f1 harness loads
// that file when present and drops the same sentences, keeping both
// arms on the identical set. Matching is by content, so the dance is
// idempotent: after the harnesses re-run without the dropped
// sentences, the control's gate passes and the file simply matches
// nothing. Corpus text never leaves tmp/.

// euc_drops_read loads the drop set; ok=false when the file is absent
// (the first run on a fresh corpus - nothing is dropped yet). Each
// line is cloned out of the read buffer (which dies with this proc),
// so the strings live until the caller's euc_drops_free.
euc_drops_read :: proc(path: string, allocator: mem.Allocator) -> (drops: [dynamic]string, ok: bool) {
	drops = make([dynamic]string, 0, 16, allocator)
	data, err := os.read_entire_file(path, allocator)
	if err != nil { return drops, false }
	defer delete(data, allocator)
	pos := 0
	for pos < len(data) {
		end := pos
		for end < len(data) && data[end] != '\n' { end += 1 }
		line := data[pos:end]
		pos = end + 1
		if len(line) > 0 && line[len(line) - 1] == '\r' { line = line[:len(line) - 1] }
		if len(line) == 0 { continue }
		clone, cerr := mem.alloc_bytes(len(line), 1, allocator)
		if cerr != nil { break }
		copy(clone, line)
		append(&drops, string(clone))
	}
	return drops, true
}

// euc_drops_free releases a drop set: the cloned lines first, then
// the array (a bare delete would leak every line).
euc_drops_free :: proc(drops: ^[dynamic]string, allocator: mem.Allocator) {
	for d in drops^ { delete(d, allocator) }
	delete(drops^)
}

// sentence_euc_dropped reports whether the sentence's corpus line is
// in the drop set (content match, same space-joined form the corpus
// and the drop file share).
sentence_euc_dropped :: proc(drops: []string, surfaces: []string, allocator: mem.Allocator) -> bool {
	if len(drops) == 0 { return false }
	n := len(surfaces) - 1
	for s in surfaces { n += len(s) }
	buf, aerr := mem.alloc_bytes(n, 1, allocator)
	if aerr != nil { return false }
	defer delete(buf, allocator)
	pos := 0
	for s, i in surfaces {
		if i > 0 {
			buf[pos] = ' '
			pos += 1
		}
		copy(buf[pos:pos + len(s)], transmute([]u8)s)
		pos += len(s)
	}
	joined := string(buf[:pos])
	for d in drops {
		if d == joined { return true }
	}
	return false
}

parse_listing :: proc(data: string, allocator: mem.Allocator) -> [dynamic]string {
	out := make([dynamic]string, 0, 6000, allocator)
	pos := 0
	for pos < len(data) {
		end := pos
		for end < len(data) && data[end] != '\n' { end += 1 }
		line := data[pos:end]
		pos = end + 1
		if len(line) == 0 { continue }
		if line[len(line) - 1] == '\r' { line = line[:len(line) - 1] }
		if len(line) == 0 { continue }
		clone, cerr := mem.alloc_bytes(len(line), 1, allocator)
		if cerr != nil { break }
		copy(clone, transmute([]u8)line)
		append(&out, string(clone))
	}
	return out
}

// score_sentence tokenizes the reconstructed sentence and answers
// micro-tallies; scored=false with skipped=true when the sentence is
// filtered out or the tokenize fails. pattern_hits, when non-nil,
// counts unknown morphemes whose joined POS carries 接頭辞 or 接尾辞 -
// the surface-pattern (qpat) arm's label-hit count; the plain f1
// harness passes nil.
score_sentence :: proc(a: ^moli.Analyzer, surfaces: []string, arena: ^mem.Arena,
	gold_off: ^[dynamic]int, pred_off: ^[dynamic]int, text_out: ^string, pattern_hits: ^int,
) -> (scored: bool, skipped: bool, gold_n: int, pred_n: int, match_n: int, unk_n: int, morphs: int) {
	if len(surfaces) == 0 { return false, false, 0, 0, 0, 0, 0 }
	for s in surfaces {
		if s == "空白" || strings_contains_space(s) { return false, true, 0, 0, 0, 0, 0 }
	}

	mem.arena_free_all(arena)
	total := 0
	for s in surfaces { total += len(s) }
	buf, aerr := mem.alloc_bytes(total, 1, mem.arena_allocator(arena))
	if aerr != nil { return false, true, 0, 0, 0, 0, 0 }
	pos := 0
	for s in surfaces {
		copy(buf[pos:pos + len(s)], transmute([]u8)s)
		pos += len(s)
	}
	txt := string(buf)
	text_out^ = txt

	resize(gold_off, 0)
	off := 0
	for s in surfaces {
		off += len(s)
		append(gold_off, off)
	}
	// Drop the final boundary (end of sentence): interior only.
	resize(gold_off, len(gold_off^) - 1)

	ms, terr := moli.tokenize(a, txt, mem.arena_allocator(arena))
	if terr != nil { return false, true, 0, 0, 0, 0, 0 }
	resize(pred_off, 0)
	unk := 0
	for m in ms {
		append(pred_off, m.end)
		if m.is_unknown {
			unk += 1
			if pattern_hits != nil && (pos_has(m.pos, "接頭辞") || pos_has(m.pos, "接尾辞")) {
				pattern_hits^ += 1
			}
		}
	}
	if len(pred_off^) > 0 { resize(pred_off, len(pred_off^) - 1) }

	gi, pi := 0, 0
	match := 0
	for gi < len(gold_off^) && pi < len(pred_off^) {
		if gold_off^[gi] == pred_off^[pi] {
			match += 1
			gi += 1
			pi += 1
		} else if gold_off^[gi] < pred_off^[pi] {
			gi += 1
		} else {
			pi += 1
		}
	}
	return true, false, len(gold_off^), len(pred_off^), match, unk, len(ms)
}

pos_has :: proc(s: string, needle: string) -> bool {
	if len(needle) > len(s) { return false }
	for i in 0 ..= len(s) - len(needle) {
		if s[i:i + len(needle)] == needle { return true }
	}
	return false
}

// tally_mismatches histograms (numbers only) the unmatched
// boundaries: over-split = prediction added, miss = gold had and
// prediction lacks. The class comes from the rune just before the
// boundary - a class-only tally (no known/unknown split: morpheme
// identity does not enter this histogram).
tally_mismatches :: proc(text: string, gold, pred: []int, over_cls, miss_cls: ^[6]int) {
	gi, pi := 0, 0
	for gi < len(gold) || pi < len(pred) {
		if gi < len(gold) && pi < len(pred) && gold[gi] == pred[pi] {
			gi += 1
			pi += 1
		} else if pi < len(pred) && (gi >= len(gold) || pred[pi] < gold[gi]) {
			c := class_of_byte_before(text, pred[pi])
			over_cls[c] += 1
			pi += 1
		} else if gi < len(gold) {
			c := class_of_byte_before(text, gold[gi])
			miss_cls[c] += 1
			gi += 1
		} else {
			break
		}
	}
}

class_of_byte_before :: proc(text: string, off: int) -> int {
	if off <= 0 || off > len(text) { return 5 }
	// Walk back to the rune start (at most 3 continuation bytes).
	i := off - 1
	for i > 0 && off - i < 4 && (text[i] & 0xC0) == 0x80 { i -= 1 }
	r, _ := decode_rune(text, i)
	switch {
	case r >= 0x3040 && r < 0x30A0: return 0 // hiragana
	case r >= 0x30A0 && r < 0x3100: return 1 // katakana
	case r >= 0x4E00 && r < 0xA000: return 2 // kanji
	case r < 0x80: return 3                  // ascii
	case r >= 0xFF00 && r < 0xFFEF: return 4 // fullwidth
	}
	return 5
}

decode_rune :: proc(s: string, at: int) -> (rune, int) {
	b := s[at]
	switch {
	case b < 0x80: return rune(b), 1
	case b & 0xE0 == 0xC0 && at + 1 < len(s): return rune(b & 0x1F) << 6 | rune(s[at + 1] & 0x3F), 2
	case b & 0xF0 == 0xE0 && at + 2 < len(s): return rune(b & 0x0F) << 12 | rune(s[at + 1] & 0x3F) << 6 | rune(s[at + 2] & 0x3F), 3
	case b & 0xF8 == 0xF0 && at + 3 < len(s): return rune(b & 0x07) << 18 | rune(s[at + 1] & 0x3F) << 12 | rune(s[at + 2] & 0x3F) << 6 | rune(s[at + 3] & 0x3F), 4
	}
	return rune(b), 1
}
