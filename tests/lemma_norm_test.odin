// Lemma normalization coverage: the GB<->US word table (both
// directions, only whole lemmas), the ZH character table (mixed
// runs pass unmapped characters through), the load option applying
// to entry lemmas only (surfaces and "*" lemmas untouched), and the
// default keeping dictionary values verbatim.
package tests

import "base:runtime"
import "core:mem"
import "core:testing"
import "moli:moli"

@(test)
lemma_rewrite_en_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()

	got, changed, err := moli.lemma_rewrite_en("colour", true, allocator)
	if err != nil { testing.expectf(t, false, "rewrite: %v", err); return }
	testing.expectf(t, changed && got == "color", "colour -> color, got %q (changed=%v)", got, changed)
	delete(got, allocator)

	back, changed2, err2 := moli.lemma_rewrite_en("color", false, allocator)
	if err2 != nil { testing.expectf(t, false, "rewrite back: %v", err2); return }
	testing.expectf(t, changed2 && back == "colour", "color -> colour, got %q", back)
	delete(back, allocator)

	same, changed3, _ := moli.lemma_rewrite_en("quickly", true, allocator)
	testing.expectf(t, !changed3 && same == "quickly", "unlisted lemma passes through")

	star, changed4, _ := moli.lemma_rewrite_en("*", true, allocator)
	testing.expectf(t, !changed4 && star == "*", "star lemma untouched")
}

// mirror_pair_lookup is the alternating-pair table binary search the
// lemma tests use to cross-check the two direction tables (the
// library's own lookup is package-private).
mirror_pair_lookup :: proc(table: []string, key: string) -> (string, bool) {
	lo, hi := 0, len(table) / 2
	for lo < hi {
		mid := (lo + hi) / 2
		if table[mid * 2] <= key { lo = mid + 1 } else { hi = mid }
	}
	i := lo - 1
	if i >= 0 && table[i * 2] == key { return table[i * 2 + 1], true }
	return "", false
}

// The two GB<->US direction tables are hand-maintained mirrors: the
// same pairs in opposite key orders, because each direction
// binary-searches its own key side. The mirror relation is otherwise
// only a comment - a pair added to one table would silently miss
// rewrites in the other direction, and a misordered insertion would
// silently break the search. This test pins all three: equal size,
// strict key order in both, and every pair found reversed in the
// other table.
@(test)
lemma_tables_mirror_test :: proc(t: ^testing.T) {
	gb_us := moli.LEMMA_EN_GB_US
	us_gb := moli.LEMMA_EN_US_GB
	testing.expectf(t, len(gb_us) == len(us_gb) && len(gb_us)%2 == 0,
		"paired tables of equal size: %d vs %d", len(gb_us), len(us_gb))
	if len(gb_us) != len(us_gb) || len(gb_us)%2 != 0 { return }

	for i in 0 ..< len(gb_us) / 2 {
		if i > 0 {
			testing.expectf(t, gb_us[(i - 1) * 2] < gb_us[i * 2],
				"GB table row %d breaks the key order", i)
			testing.expectf(t, us_gb[(i - 1) * 2] < us_gb[i * 2],
				"US table row %d breaks the key order", i)
		}
		gb, us := gb_us[i * 2], gb_us[i * 2 + 1]
		back, ok := mirror_pair_lookup(us_gb, us)
		testing.expectf(t, ok && back == gb,
			"pair %q -> %q missing its US->GB mirror", gb, us)
	}
	for i in 0 ..< len(us_gb) / 2 {
		us, gb := us_gb[i * 2], us_gb[i * 2 + 1]
		fwd, ok := mirror_pair_lookup(gb_us, gb)
		testing.expectf(t, ok && fwd == us,
			"pair %q -> %q missing its GB->US mirror", us, gb)
	}
}

@(test)
lemma_rewrite_zh_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()

	got, changed, err := moli.lemma_rewrite_zh("認識", allocator)
	if err != nil { testing.expectf(t, false, "rewrite: %v", err); return }
	testing.expectf(t, changed && got == "认识", "認識 -> 认识, got %q", got)
	delete(got, allocator)

	// Unmapped characters (already-simplified or shared) pass through.
	mixed, changed2, err2 := moli.lemma_rewrite_zh("认識了", allocator)
	if err2 != nil { testing.expectf(t, false, "mixed: %v", err2); return }
	testing.expectf(t, changed2 && mixed == "认识了", "mixed run maps only the traditional characters, got %q", mixed)
	delete(mixed, allocator)

	same, changed3, _ := moli.lemma_rewrite_zh("你好", allocator)
	testing.expectf(t, !changed3 && same == "你好", "all-simplified run aliases through")
}

@(test)
lemma_locale_load_test :: proc(t: ^testing.T) {
	// The EN fixture carries GB lemmas (colour, defence) and its
	// language classifies GB; targeting US rewrites the lemmas, and
	// the default keeps them verbatim.
	a, ok := load_ok(t, .EnglishGB, EN_FIXTURE, {lemma_locale = .US})
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	ms, err := moli.tokenize(&a, "colour travels", mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "tokenize: %v", err)
		return
	}
	// The inter-word space is its own unknown morpheme.
	if len(ms) != 3 || ms[2].surface != "travels" {
		testing.expectf(t, false, "colour SPACE travels, got %d morphemes", len(ms))
		return
	}
	testing.expectf(t, ms[0].surface == "colour" && ms[0].lemma == "color",
		"surface stays input, lemma normalizes: (%s, %s)", ms[0].surface, ms[0].lemma)
	testing.expectf(t, ms[2].lemma == "travel", "unlisted lemma untouched")

	b, ok2 := load_ok(t, .EnglishGB, EN_FIXTURE, {})
	if !ok2 { return }
	defer moli.free(&b)
	ms2, err2 := moli.tokenize(&b, "colour", mem.arena_allocator(&arena))
	if err2 != nil {
		testing.expectf(t, false, "tokenize default: %v", err2)
		return
	}
	if len(ms2) == 0 {
		testing.expectf(t, false, "default load: %d morphemes", len(ms2))
		return
	}
	testing.expectf(t, ms2[0].lemma == "colour", "default load keeps the dictionary lemma verbatim")

	// The GB direction through the load path: a US-variant English
	// load targeting .GB runs the GB rewriter over every entry (the
	// fixture's GB lemmas alias through unchanged).
	c, ok3 := load_ok(t, .EnglishUS, EN_FIXTURE, {lemma_locale = .GB})
	if !ok3 { return }
	defer moli.free(&c)
	ms3, err3 := moli.tokenize(&c, "colour", mem.arena_allocator(&arena))
	if err3 != nil {
		testing.expectf(t, false, "tokenize GB-target: %v", err3)
		return
	}
	if len(ms3) == 0 {
		testing.expectf(t, false, "GB-target: %d morphemes", len(ms3))
		return
	}
	testing.expectf(t, ms3[0].lemma == "colour", "GB-targeted load keeps GB lemmas verbatim")
}

// The ZH direction of the same option: a TW jieba row whose lemma (the
// surface value) carries traditional characters rewrites toward .CN
// while the surface stays the dictionary value verbatim, and the
// default load keeps both verbatim.
@(test)
lemma_locale_zh_load_test :: proc(t: ^testing.T) {
	write_tmp(t, "tmp/zh_lemma.csv", "認識,0,0,1000,n,renshi,*,*,*\n")
	a, ok := load_ok(t, .ChineseTW, "tmp/zh_lemma.csv", {lemma_locale = .CN})
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	ms, err := moli.tokenize(&a, "認識", mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "tokenize: %v", err)
		return
	}
	if len(ms) != 1 || ms[0].surface != "認識" || ms[0].lemma != "认识" {
		testing.expectf(t, false, "ZH lemma normalizes toward .CN: %d morphemes, first (%s, %s)",
			len(ms), len(ms) > 0 ? ms[0].surface : "", len(ms) > 0 ? ms[0].lemma : "")
		return
	}

	b, ok2 := load_ok(t, .ChineseTW, "tmp/zh_lemma.csv", {})
	if !ok2 { return }
	defer moli.free(&b)
	ms2, err2 := moli.tokenize(&b, "認識", mem.arena_allocator(&arena))
	if err2 != nil {
		testing.expectf(t, false, "tokenize default: %v", err2)
		return
	}
	if len(ms2) == 0 {
		testing.expectf(t, false, "default load: %d morphemes", len(ms2))
		return
	}
	testing.expectf(t, ms2[0].lemma == "認識", "default load keeps the ZH lemma verbatim")
}

// Malformed UTF-8 skips the ZH rewrite - the best-effort rule
// normalize_nfc already follows. The rewrite loop decodes runes, and
// rewriting around a bad byte would silently re-encode it as U+FFFD,
// even when a mappable character sits beside the bad byte. The
// importer accepts the malformed row (malformed bytes are input, not
// a schema fault), so the guard is load-time load-bearing.
@(test)
lemma_rewrite_zh_malformed_test :: proc(t: ^testing.T) {
	same, changed, err := moli.lemma_rewrite_zh("漢\xff", runtime.default_allocator())
	if err != nil || changed || same != "漢\xff" {
		testing.expectf(t, false, "malformed lemma must alias through: (%q, %v, %v)", same, changed, err)
		return
	}

	// Through the load option: 漢 maps, so without the bad byte the
	// lemma would rewrite; with it the whole lemma stays
	// byte-identical while the clean row beside it still rewrites.
	write_tmp(t, "tmp/zh_lemma_bad.csv",
		"漢\xff,0,0,1000,n,han,*,*,*\n認識,0,0,1000,n,renshi,*,*,*\n")
	a, ok := load_ok(t, .ChineseTW, "tmp/zh_lemma_bad.csv", {lemma_locale = .CN})
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	ms, terr := moli.tokenize(&a, "漢\xff", mem.arena_allocator(&arena))
	if terr != nil {
		testing.expectf(t, false, "tokenize: %v", terr)
		return
	}
	if len(ms) < 1 {
		testing.expectf(t, false, "malformed-surface text must tokenize, got %d morphemes", len(ms))
		return
	}
	testing.expectf(t, ms[0].entry_id >= 0 && ms[0].lemma == "漢\xff",
		"the malformed-lemma row resolves with its lemma byte-identical: (id %d, %q)",
		ms[0].entry_id, ms[0].lemma)

	ms2, terr2 := moli.tokenize(&a, "認識", mem.arena_allocator(&arena))
	if terr2 != nil {
		testing.expectf(t, false, "tokenize clean row: %v", terr2)
		return
	}
	if len(ms2) != 1 {
		testing.expectf(t, false, "clean row: %d morphemes", len(ms2))
		return
	}
	testing.expectf(t, ms2[0].lemma == "认识",
		"control: the clean row still rewrites toward .CN, got %q", ms2[0].lemma)
}

// Same OOM discipline on the zh rewrite: the failure legs must
// return .OutOfMemory with the rewrite buffer freed (the alloc_bytes
// leg used to return around the delete), and the leak gate polices
// the partial releases.
@(test)
lemma_rewrite_zh_oom_test :: proc(t: ^testing.T) {
	saw_oom := false
	saw_ok := false
	for budget in 0 ..< 4 {
		b := Budget_Allocator{backing = context.allocator, remaining = budget}
		allocator := mem.Allocator{data = &b, procedure = budget_allocator_proc}
		got, changed, lerr := moli.lemma_rewrite_zh("認識", allocator)
		if lerr != nil {
			testing.expectf(t, lerr == moli.Load_Fault.OutOfMemory, "budget %d: %v", budget, lerr)
			saw_oom = true
		} else {
			testing.expectf(t, changed && got == "认识", "budget %d: got %q", budget, got)
			delete(got, allocator)
			saw_ok = true
		}
	}
	testing.expectf(t, saw_oom && saw_ok, "sweep must cover both legs (oom=%v ok=%v)", saw_oom, saw_ok)
}
