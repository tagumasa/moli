// Lemma normalization: load-time rewrite of entry lemmas toward a
// target variant (Load_Options.lemma_locale). Two directions ship:
// English word-level GB<->US (a curated common-words list - not
// exhaustive, dictionary lemmas are dictionary words and the tail is
// long), and Chinese character-level traditional->simplified (the
// generated OpenCC table in lemma_zh_ts.odin; simplified->traditional
// is one-to-many and does not ship). Only entry lemmas are rewritten -
// surfaces reflect the input text, and "*"/empty lemmas keep their
// surface-fallback semantics. Pure analysis-core code: explicit
// allocators, no os.
package moli

import "core:mem"

// LEMMA_EN_GB_US alternates GB, US word pairs sorted by the GB side.
LEMMA_EN_GB_US :: []string{
	"aluminium", "aluminum", "analyse", "analyze",
	"analysed", "analyzed", "analyses", "analyzes",
	"analysing", "analyzing", "apologise", "apologize",
	"apologised", "apologized", "artefact", "artifact",
	"artefacts", "artifacts", "behaviour", "behavior",
	"behavioural", "behavioral", "behaviours", "behaviors",
	"cancelled", "canceled", "catalogue", "catalog",
	"catalogues", "catalogs", "centre", "center",
	"centred", "centered", "centres", "centers",
	"colour", "color", "coloured", "colored",
	"colours", "colors", "cosy", "cozy",
	"defence", "defense", "defences", "defenses",
	"enrol", "enroll", "favourite", "favorite",
	"favourites", "favorites", "fibre", "fiber",
	"fibres", "fibers", "fuelled", "fueled",
	"fulfil", "fulfill", "grey", "gray",
	"honour", "honor", "honoured", "honored",
	"honours", "honors", "jewellery", "jewelry",
	"kerb", "curb", "labelled", "labeled",
	"labour", "labor", "litre", "liter",
	"litres", "liters", "marvellous", "marvelous",
	"metre", "meter", "metres", "meters",
	"modelling", "modeling", "mould", "mold",
	"moulds", "molds", "offence", "offense",
	"offences", "offenses", "organisation", "organization",
	"organisations", "organizations", "organise", "organize",
	"organised", "organized", "plough", "plow",
	"programme", "program", "programmes", "programs",
	"pyjamas", "pajamas", "realise", "realize",
	"realised", "realized", "recognise", "recognize",
	"recognised", "recognized", "skilful", "skillful",
	"smoulder", "smolder", "speciality", "specialty",
	"storey", "story", "storeys", "stories",
	"travelled", "traveled", "travelling", "traveling",
	"tyre", "tire", "tyres", "tires",
	"wilful", "willful",
}

// LEMMA_EN_US_GB alternates US, GB word pairs sorted by the US side -
// the same pairs in the reverse direction.
LEMMA_EN_US_GB :: []string{
	"aluminum", "aluminium", "analyze", "analyse",
	"analyzed", "analysed", "analyzes", "analyses",
	"analyzing", "analysing", "apologize", "apologise",
	"apologized", "apologised", "artifact", "artefact",
	"artifacts", "artefacts", "behavior", "behaviour",
	"behavioral", "behavioural", "behaviors", "behaviours",
	"canceled", "cancelled", "catalog", "catalogue",
	"catalogs", "catalogues", "center", "centre",
	"centered", "centred", "centers", "centres",
	"color", "colour", "colored", "coloured",
	"colors", "colours", "cozy", "cosy",
	"curb", "kerb", "defense", "defence",
	"defenses", "defences", "enroll", "enrol",
	"favorite", "favourite", "favorites", "favourites",
	"fiber", "fibre", "fibers", "fibres",
	"fueled", "fuelled", "fulfill", "fulfil",
	"gray", "grey", "honor", "honour",
	"honored", "honoured", "honors", "honours",
	"jewelry", "jewellery", "labeled", "labelled",
	"labor", "labour", "liter", "litre",
	"liters", "litres", "marvelous", "marvellous",
	"meter", "metre", "meters", "metres",
	"modeling", "modelling", "mold", "mould",
	"molds", "moulds", "offense", "offence",
	"offenses", "offences", "organization", "organisation",
	"organizations", "organisations", "organize", "organise",
	"organized", "organised", "pajamas", "pyjamas",
	"plow", "plough", "program", "programme",
	"programs", "programmes", "realize", "realise",
	"realized", "realised", "recognize", "recognise",
	"recognized", "recognised", "skillful", "skilful",
	"smolder", "smoulder", "specialty", "speciality",
	"stories", "storeys", "story", "storey",
	"tire", "tyre", "tires", "tyres",
	"traveled", "travelled", "traveling", "travelling",
	"willful", "wilful",
}

// lemma_en_lookup finds s in one alternating-pair table (sorted by the
// even side); returns the partner spelling.
lemma_en_lookup :: proc(table: []string, s: string) -> (string, bool) {
	tab := table // materialized: constants refuse variable indexing
	lo, hi := 0, len(tab) / 2
	for lo < hi {
		mid := (lo + hi) / 2
		if tab[mid * 2] <= s { lo = mid + 1 } else { hi = mid }
	}
	i := lo - 1
	if i >= 0 && tab[i * 2] == s {
		return tab[i * 2 + 1], true
	}
	return "", false
}

// lemma_zh_lookup answers the simplified counterpart of one
// traditional character.
lemma_zh_lookup :: proc(r: rune) -> (rune, bool) {
	tab := ZH_TS_CHARACTERS // materialized
	lo, hi := 0, len(tab) / 2
	for lo < hi {
		mid := (lo + hi) / 2
		if tab[mid * 2] <= i32(r) { lo = mid + 1 } else { hi = mid }
	}
	i := lo - 1
	if i >= 0 && tab[i * 2] == i32(r) {
		return rune(tab[i * 2 + 1]), true
	}
	return 0, false
}

// lemma_rewrite_en maps one whole lemma through the GB<->US word
// tables; to_us selects the direction. The answer aliases s when
// nothing changed.
lemma_rewrite_en :: proc(s: string, to_us: bool, allocator: mem.Allocator) -> (string, bool, Load_Err) {
	table: []string
	if to_us { table = LEMMA_EN_GB_US } else { table = LEMMA_EN_US_GB }
	if len(s) == 0 || s == "*" { return s, false, nil }
	if m, ok := lemma_en_lookup(table, s); ok {
		c, err := clone_str(m, allocator)
		if err != nil { return s, false, err }
		return c, true, nil
	}
	return s, false, nil
}

// lemma_rewrite_zh maps every traditional character of s to its
// simplified counterpart (unmapped characters pass through). The
// answer aliases s when nothing changed. Malformed UTF-8 aliases
// through too (malformed_utf8, the best-effort rule normalize_nfc
// already follows): the rewrite loop decodes runes, and rewriting
// around a bad byte would silently re-encode it as U+FFFD.
lemma_rewrite_zh :: proc(s: string, allocator: mem.Allocator) -> (string, bool, Load_Err) {
	if len(s) == 0 || s == "*" { return s, false, nil }
	if malformed_utf8(s) { return s, false, nil }
	changed := false
	for r in s {
		if _, ok := lemma_zh_lookup(r); ok { changed = true; break }
	}
	if !changed { return s, false, nil }
	mapped, merr := make([dynamic]rune, 0, len(s), allocator)
	if merr != nil { return s, false, .OutOfMemory }
	defer delete(mapped) // [dynamic] carries allocator
	for r in s {
		m, ok := lemma_zh_lookup(r)
		if !ok { m = r }
		if _, aerr := append(&mapped, m); aerr != nil {
			return s, false, .OutOfMemory
		}
	}
	out, cerr := runes_to_string(mapped[:], allocator)
	if cerr != nil { return s, false, .OutOfMemory }
	return out, true, nil
}

// Lemma_Rewrite is the one shape normalize_lemmas applies per entry:
// rewrite one lemma under the allocator, reporting whether the answer
// is a fresh clone the caller owns (the old one must be deleted).
Lemma_Rewrite :: proc(s: string, allocator: mem.Allocator) -> (string, bool, Load_Err)

// lemma_rewrite_en_us / _gb adapt the direction-taking English
// rewriter to the Lemma_Rewrite shape; lemma_rewrite_zh already has
// it.
lemma_rewrite_en_us :: proc(s: string, allocator: mem.Allocator) -> (string, bool, Load_Err) {
	return lemma_rewrite_en(s, true, allocator)
}

lemma_rewrite_en_gb :: proc(s: string, allocator: mem.Allocator) -> (string, bool, Load_Err) {
	return lemma_rewrite_en(s, false, allocator)
}

// normalize_lemmas rewrites every entry lemma toward target when the
// analyzer's language carries that variant pair; a no-op for .None,
// for target == the dictionary's own variant, and for combinations
// with no table (Japanese and German carry no variant pair - the
// Locale model has no members for them - and simplified->traditional
// Chinese is one-to-many and does not ship). Entries whose
// lemma changed are re-cloned and the old clone is released - load's
// uniform teardown stays correct either way. The delete-and-replace
// ownership dance lives in this one loop, not per direction.
normalize_lemmas :: proc(a: ^Analyzer, target: Locale, allocator: mem.Allocator) -> Load_Err {
	if target == .None || target == a.dict_locale { return nil }
	rewrite: Lemma_Rewrite
	switch a.lang {
	case .EnglishGB, .EnglishUS:
		if target != .GB && target != .US { return nil }
		if target == .US {
			rewrite = lemma_rewrite_en_us
		} else {
			rewrite = lemma_rewrite_en_gb
		}
	case .ChineseCN, .ChineseTW, .ChineseHK:
		if target != .CN { return nil }
		rewrite = lemma_rewrite_zh
	case .Japanese, .German:
		return nil
	}
	for e, i in a.entries {
		ne, changed, err := rewrite(e.lemma, allocator)
		if err != nil { return err }
		if changed {
			delete(e.lemma, allocator)
			a.entries[i].lemma = ne
		}
	}
	return nil
}
