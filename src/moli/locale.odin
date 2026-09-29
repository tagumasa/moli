// Locale classification heuristics: spelling variants for English GB
// vs US, traditional-specific blocks for Chinese CN vs TW/HK. Pure —
// a function of the analyzer's language and the input text; no
// allocation.
package moli

// classify_locale guesses the variant of text when the analyzer's
// language has one: spelling variants decide GB vs US, the
// traditional-specific Bopomofo blocks decide TW. Answers .None for
// Japanese or when classification is ambiguous - Chinese text without
// a traditional marker shares its codepoints between CN, TW, and HK,
// so guessing one would be noise.
classify_locale :: proc(a: ^Analyzer, text: string) -> Locale {
	switch a.lang {
	case .EnglishGB, .EnglishUS:
		return classify_english_variant(text)
	case .ChineseCN, .ChineseTW, .ChineseHK:
		return classify_chinese_variant(text)
	case .Japanese, .German:
		return .None
	}
	return .None
}

// classify_english_variant counts GB-only vs US-only spelling hits
// and returns GB, US, or .None when counts tie or both are zero.
classify_english_variant :: proc(text: string) -> Locale {
	gb_hits, us_hits := 0, 0
	for pair in SPELLING_PAIRS {
		if contains_ci(text, pair[0]) { gb_hits += 1 }
		if contains_ci(text, pair[1]) { us_hits += 1 }
	}
	if gb_hits > us_hits { return .GB }
	if us_hits > gb_hits { return .US }
	return .None
}

// classify_chinese_variant detects the Bopomofo blocks that TW/HK text
// carries and simplified CN text never does, answering .TW when one is
// present. Without a marker the script variant is ambiguous between
// CN, TW, and HK, so the answer is .None rather than a guess; empty
// input is .None too.
classify_chinese_variant :: proc(text: string) -> Locale {
	if len(text) == 0 { return .None }
	for r in text {
		if (r >= BOPOMOFO_LO && r < BOPOMOFO_HI) ||
		   (r >= BOPOMOFO_EXTENDED_LO && r < BOPOMOFO_EXTENDED_HI) {
			return .TW
		}
	}
	return .None
}

// contains_ci answers whether text contains word as a case-insensitive
// SUBSTRING - deliberately not word-boundary matching: morphological
// derivations preserve the variant (colourless still counts for
// "colour", colorless for "color"), so substring hits classify derived
// forms correctly. Used by the spelling heuristics; not
// general-purpose.
contains_ci :: proc(text, word: string) -> bool {
	if len(word) == 0 || len(word) > len(text) { return false }
	for i in 0 ..= len(text) - len(word) {
		match := true
		for j in 0 ..< len(word) {
			c1 := text[i + j]
			c2 := word[j]
			if c1 >= 'A' && c1 <= 'Z' { c1 += 32 }
			if c2 >= 'A' && c2 <= 'Z' { c2 += 32 }
			if c1 != c2 {
				match = false
				break
			}
		}
		if match { return true }
	}
	return false
}

// GB/US spelling exemplar pairs, one row per pair - the set
// classify_english_variant counts hits over. Row form, not parallel
// lists: a positional pair encoding mispairs silently the day a word
// lands in one list and not the other. Exemplars for now; the
// load-time GB<->US lemma rewrite (lemma_norm.odin) carries the long
// list, and a test pins its two tables to exact mirrors.
SPELLING_PAIRS :: [][2]string{
	{"colour", "color"},
	{"defence", "defense"},
	{"centre", "center"},
	{"travelling", "traveling"},
}
