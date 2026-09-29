// Character classification: the rune -> Char_Class table an analyzer
// carries, its built-in per-language ranges, and the pure build and
// validate procs. File I/O lives at the importer edge; nothing here
// touches os.
package moli

import "core:mem"
import "core:sort"

// Char_Class is a character category. The base set is stable;
// locale-specific tables may lean on more of it. Bopomofo covers
// U+3100–U+312F (proper) and U+31A0–U+31BF (Extended) for ZH-TW/HK.
Char_Class :: enum {
	Unknown,
	Hiragana,
	Katakana,
	Kanji,
	Hanzi,
	HalfwidthKatakana,
	Bopomofo,
	ASCIILetter,
	Digit,
	Punct,
	Space,
	Symbol,
	Emoji,
}

// Char_Range is one half-open [lo, hi) classification range.
Char_Range :: struct {
	lo, hi: rune,
	class:  Char_Class,
}

// Char_Flags is one char.def category row ("NAME INVOKE GROUP LENGTH")
// — how unknown-word processing fires for that class:
//
//   - invoke: fire unknown candidates even where a dictionary word
//     starts at the position (ipadic sets this for SYMBOL, NUMERIC,
//     ALPHA, KATAKANA and friends).
//   - group: add one candidate covering the whole same-class run.
//   - length: add one candidate per 1..length runes of the run.
//
// MeCab treats group and length as independent knobs; moli emits both
// kinds when both are set (a superset — the extra candidates can only
// lose in the DP, and they keep run interiors reachable).
Char_Flags :: struct {
	invoke: bool,
	group:  bool,
	length: u8,
}

// char_flags_default is the built-in behavior for classes no char.def
// category row covers: grouped-run plus single-rune candidates, no
// invoke — the lattice shape that keeps runs splittable around
// dictionary words starting inside them. It is also the entire
// behavior when the analyzer ships without a char.def.
char_flags_default :: proc() -> [len(Char_Class)]Char_Flags {
	flags: [len(Char_Class)]Char_Flags
	for i in 0 ..< len(Char_Class) {
		flags[i] = Char_Flags{invoke = false, group = true, length = 1}
	}
	return flags
}

// char_flags_parse builds one Char_Flags from a category row's three
// numeric columns: any nonzero value is true, and the length clamps
// into u8 (real dictionaries ship 0..2).
char_flags_parse :: proc(invoke, group, length: int) -> Char_Flags {
	l := length
	if l < 0 { l = 0 }
	if l > 255 { l = 255 }
	return Char_Flags{invoke = invoke != 0, group = group != 0, length = u8(l)}
}

// Char_Class_Table classifies runes by binary search over ranges, O(log n)
// in the number of ranges. The ranges must be sorted by lo,
// non-overlapping, and inside the code-point universe — validated at
// load, and a violation fails the load: a malformed table would
// silently yield wrong classes at lookup time.
//
// flat is the opt-in O(1) path: a []Char_Class of size 0x110000
// (~1.1 MB) built when Load_Options.flat_char_class is set. When flat
// is non-empty, char_class_of reads it directly.
Char_Class_Table :: struct {
	ranges: [dynamic]Char_Range,
	flat:   []Char_Class,
}

// char_class_destroy releases the table's owned buffers: the ranges
// dynamic (allocator-carrying) and the optional flat slice (made with
// the analyzer's allocator, so its delete takes the allocator
// explicitly). The single release definition for every teardown path -
// see cedar_destroy.
char_class_destroy :: proc(t: ^Char_Class_Table, allocator: mem.Allocator) {
	if t.ranges != nil { delete(t.ranges) }
	if len(t.flat) > 0 { delete(t.flat, allocator) }
}

// The built-in Space class's byte set as one shared definition: the
// control run [SPACE_CTRL_LO, SPACE_CTRL_HI) (tab, LF, VT, FF, CR) plus
// the lone space byte SPACE_SINGLE. The range table and chunking's
// safe-cut byte test both derive from these three constants, so the
// class cannot drift between its two encodings. 0x0E (SO) is outside
// the set - MeCab's char.def SPACE does not carry it either.
SPACE_CTRL_LO :: 0x09
SPACE_CTRL_HI :: 0x0E // exclusive
SPACE_SINGLE  :: 0x20

// BASE_RANGES is the universal range set as declared data, rows kept in
// the grouping the section comments read (not sorted - default_ranges
// sorts the combined set, and the locale extras append after these
// rows): ASCII classes, Hiragana, Katakana (incl. halfwidth), the CJK
// unified blocks shared by Kanji and Hanzi (the BMP core, Extension A,
// Compatibility, and the supplementary-plane Extensions B through H), a
// curated Emoji set, and a few other stable symbols.
BASE_RANGES :: [31]Char_Range{
	// ASCII ranges.
	{lo = SPACE_CTRL_LO, hi = SPACE_CTRL_HI, class = .Space}, // tab, LF, VT, FF, CR
	{lo = SPACE_SINGLE, hi = SPACE_SINGLE + 1, class = .Space}, // space
	{lo = 0x21, hi = 0x30, class = .Punct},       // !"#$%&'()*+,-./
	{lo = 0x30, hi = 0x3A, class = .Digit},       // 0-9
	{lo = 0x3A, hi = 0x41, class = .Punct},       // :;<=>?@
	{lo = 0x41, hi = 0x5B, class = .ASCIILetter}, // A-Z
	{lo = 0x5B, hi = 0x61, class = .Punct},       // [\]^_`
	{lo = 0x61, hi = 0x7B, class = .ASCIILetter}, // a-z
	{lo = 0x7B, hi = 0x7F, class = .Punct},       // {|}~ DEL

	// Latin-1 supplement: letters and symbols.
	{lo = 0xA1, hi = 0xC0, class = .Punct},
	{lo = 0xC0, hi = 0x100, class = .ASCIILetter},
	{lo = 0x100, hi = 0x180, class = .ASCIILetter},

	// Capital sharp S (German, U+1E9E) - the lowercase (U+00DF) sits
	// in the Latin-1 letter range above; and the typographic quotes
	// ' ' " " (U+2018..U+201F), German ones included.
	{lo = 0x1E9E, hi = 0x1E9F, class = .ASCIILetter},
	{lo = 0x2018, hi = 0x2020, class = .Punct},

	// Hiragana (U+3040-U+309F).
	{lo = 0x3040, hi = 0x30A0, class = .Hiragana},

	// Katakana (U+30A0-U+30FF).
	{lo = 0x30A0, hi = 0x3100, class = .Katakana},

	// Halfwidth Katakana (U+FF66-U+FF9F); the halfwidth CJK
	// punctuation below it (U+FF61-U+FF65) is not katakana.
	{lo = 0xFF66, hi = 0xFFA0, class = .HalfwidthKatakana},

	// CJK Unified Ideographs (U+4E00-U+9FFF) - the core Kanji/Hanzi block.
	{lo = 0x4E00, hi = 0xA000, class = .Hanzi},

	// CJK Unified Ideographs Extension A.
	{lo = 0x3400, hi = 0x4DC0, class = .Hanzi},

	// CJK Compatibility Ideographs.
	{lo = 0xF900, hi = 0xFB00, class = .Hanzi},

	// Supplementary-plane ideographs, still Hanzi: Extension B
	// (U+20000-U+2A6DF, classical and rare - personal names especially),
	// then a 32-codepoint strip of unassigned codepoints (the gap
	// Extension C opens at U+2A700), Extensions C through F contiguous
	// with Extension I behind them (U+2A700-U+2EE5F), Extension G
	// (U+30000-U+3134F), and Extension H (U+31350-U+323AF). The
	// planes-wide gaps between those rows stay Unknown rather than
	// riding a wider range.
	{lo = 0x20000, hi = 0x2A6E0, class = .Hanzi},
	{lo = 0x2A700, hi = 0x2EE60, class = .Hanzi},
	{lo = 0x30000, hi = 0x31350, class = .Hanzi},
	{lo = 0x31350, hi = 0x323B0, class = .Hanzi},

	// Emoji, the common presented set: Miscellaneous Symbols plus
	// Dingbats (U+2600-U+27BF), SMP symbols through Extended-A
	// (U+1F300-U+1FAFF), mahjong/dominoes/playing cards
	// (U+1F000-U+1F0FF), regional indicators (U+1F1E6-U+1F1FF), watch
	// and hourglass (U+231A-U+231B), media controls (U+23E9-U+23FA),
	// and the star/arrow block (U+2B00-U+2B5F). Variation selectors
	// (U+FE0F & co.) are deliberately not Emoji: they are combining
	// marks trailing their base character, and classifying them would
	// only split runs the base already covers.
	{lo = 0x1F300, hi = 0x1FB00, class = .Emoji},
	{lo = 0x2600, hi = 0x27C0, class = .Emoji},
	{lo = 0x1F000, hi = 0x1F100, class = .Emoji},
	{lo = 0x1F1E6, hi = 0x1F200, class = .Emoji},
	{lo = 0x231A, hi = 0x231C, class = .Emoji},
	{lo = 0x23E9, hi = 0x23FB, class = .Emoji},
	{lo = 0x2B00, hi = 0x2B60, class = .Emoji},
}

// base_ranges clones BASE_RANGES into a fresh slice made with the
// allocator (a failed make answers .OutOfMemory); caller owns it. The
// capacity reserves room for the locale extras (at most 2 more rows),
// so only the make itself is fallible.
base_ranges :: proc(allocator: mem.Allocator) -> ([dynamic]Char_Range, Load_Err) {
	src := BASE_RANGES // materialized: constants refuse variable indexing
	ranges, merr := make([dynamic]Char_Range, len(src), len(src) + 2, allocator)
	if merr != nil { return nil, .OutOfMemory }
	copy(ranges[:], src[:])
	return ranges, nil
}

// Bopomofo proper and Extended, half-open: the blocks only
// traditional-script text carries. Named once here because two
// features read them - the range table's ZH-TW/HK rows below and the
// locale classifier's traditional-detection test (locale.odin) - so
// the class data and the TW heuristic cannot drift apart.
BOPOMOFO_LO          :: rune(0x3100)
BOPOMOFO_HI          :: rune(0x3130) // exclusive; U+3100-U+312F
BOPOMOFO_EXTENDED_LO :: rune(0x31A0)
BOPOMOFO_EXTENDED_HI :: rune(0x31C0) // exclusive; U+31A0-U+31BF

// BOPOMOFO_EXTRA is the ZH-TW/HK locale addition beyond the universal
// set: the two Bopomofo blocks.
BOPOMOFO_EXTRA :: []Char_Range{
	{lo = BOPOMOFO_LO, hi = BOPOMOFO_HI, class = .Bopomofo},
	{lo = BOPOMOFO_EXTENDED_LO, hi = BOPOMOFO_EXTENDED_HI, class = .Bopomofo},
}

// LOCALE_EXTRA_RANGES holds each language's rows beyond the universal
// set, keyed by Language (nil: the language adds none).
LOCALE_EXTRA_RANGES :: [Language][]Char_Range{
	.Japanese  = nil,
	.ChineseCN = nil,
	.ChineseTW = BOPOMOFO_EXTRA,
	.ChineseHK = BOPOMOFO_EXTRA,
	.EnglishGB = nil,
	.EnglishUS = nil,
	.German    = nil,
}

// locale_extra_ranges appends the language-specific ranges to ranges.
// The destination's capacity already reserves room (see base_ranges),
// so the append cannot fail.
locale_extra_ranges :: proc(lang: Language, ranges: ^[dynamic]Char_Range) {
	extras := LOCALE_EXTRA_RANGES // materialized: constants refuse variable indexing
	append(ranges, ..extras[lang])
}

// default_ranges returns the built-in ranges for lang (Hiragana,
// Katakana, Kanji/Hanzi, ASCII, and friends; ZH-TW/HK add Bopomofo
// proper and Extended). The result is made with the allocator and sorted,
// ready to merge with char.def ranges.
default_ranges :: proc(lang: Language, allocator: mem.Allocator) -> ([dynamic]Char_Range, Load_Err) {
	ranges, berr := base_ranges(allocator)
	if berr != nil { return nil, berr }
	locale_extra_ranges(lang, &ranges)
	rs := ranges[:]
	sort.quick_sort_proc(rs, char_range_order)
	return ranges, nil
}

// char_range_order orders ranges by lo then hi - the quick_sort_proc
// comparator shared by every table construction here.
char_range_order :: proc(a, b: Char_Range) -> int {
	if a.lo < b.lo { return -1 }
	if a.lo > b.lo { return 1 }
	if a.hi < b.hi { return -1 }
	if a.hi > b.hi { return 1 }
	return 0
}

// punch_hole appends the fragments of base not covered by the
// half-open [punch_lo, punch_hi) - the single-range form used by the
// importer's override_insert. Empty fragments are never emitted.
punch_hole :: proc(out: ^[dynamic]Char_Range, base: Char_Range, punch_lo, punch_hi: rune) -> Load_Err {
	if punch_lo > base.lo {
		hi := min(punch_lo, base.hi)
		if _, e := append(out, Char_Range{lo = base.lo, hi = hi, class = base.class}); e != nil {
			return .OutOfMemory
		}
	}
	lo := max(base.lo, punch_hi)
	if lo < base.hi {
		if _, e := append(out, Char_Range{lo = lo, hi = base.hi, class = base.class}); e != nil {
			return .OutOfMemory
		}
	}
	return nil
}

// punch_holes appends the fragments of base not covered by any of defs
// (defs sorted by lo, both sides half-open). Only head fragments are
// emitted inside the loop; the surviving tail is emitted once after
// it, so overlapping defs never duplicate it. Empty fragments are
// never emitted; a base range fully covered by defs contributes
// nothing. Appends answer .OutOfMemory - one def can split many base
// ranges, so the merge buffer grows beyond any simple reservation.
punch_holes :: proc(out: ^[dynamic]Char_Range, base: Char_Range, defs: []Char_Range) -> Load_Err {
	lo := base.lo
	for d in defs {
		if lo >= base.hi { return nil }
		if d.hi <= lo { continue }
		if d.lo > lo {
			hi := min(d.lo, base.hi)
			if _, e := append(out, Char_Range{lo = lo, hi = hi, class = base.class}); e != nil {
				return .OutOfMemory
			}
		}
		lo = max(lo, d.hi)
	}
	if lo < base.hi {
		if _, e := append(out, Char_Range{lo = lo, hi = base.hi, class = base.class}); e != nil {
			return .OutOfMemory
		}
	}
	return nil
}

// char_class_build merges the built-in ranges for lang with the parsed
// char.def ranges. The char.def is authoritative where it speaks: its
// codepoints are punched out of the built-in set first, because every
// real char.def re-declares ASCII, Latin, and kana blocks the
// built-ins already cover. Overlaps among the char.def ranges
// themselves still fail the load, as does any table the merged result
// leaves unsorted. Pure: the char.def file itself is read at the
// importer edge, which hands over already-parsed ranges.
char_class_build :: proc(lang: Language, char_def_ranges: []Char_Range, flat: bool, allocator: mem.Allocator) -> (Char_Class_Table, Load_Err) {
	base, berr := default_ranges(lang, allocator)
	if berr != nil { return Char_Class_Table{}, berr }
	// base and defs never escape: the defers release them on every
	// path, failure or success.
	defer delete(base)

	defs, derr := make([dynamic]Char_Range, len(char_def_ranges), allocator)
	if derr != nil { return Char_Class_Table{}, .OutOfMemory }
	defer delete(defs)
	copy(defs[:], char_def_ranges)
	defs_view := defs[:]
	sort.quick_sort_proc(defs_view, char_range_order)

	merged, merr := make([dynamic]Char_Range, 0, len(base) + len(defs), allocator)
	if merr != nil { return Char_Class_Table{}, .OutOfMemory }
	for b in base {
		if herr := punch_holes(&merged, b, defs_view); herr != nil {
			delete(merged)
			return Char_Class_Table{}, herr
		}
	}
	for d in defs {
		if _, e := append(&merged, d); e != nil {
			delete(merged)
			return Char_Class_Table{}, .OutOfMemory
		}
	}

	rs := merged[:]
	sort.quick_sort_proc(rs, char_range_order)

	if !char_ranges_valid(merged[:]) {
		delete(merged)
		return Char_Class_Table{}, .Invalid_Format
	}

	table := Char_Class_Table{ranges = merged}
	if flat {
		flat_arr, ferr := char_class_flat_from_ranges(merged[:], allocator)
		if ferr != nil {
			delete(merged)
			return Char_Class_Table{}, .OutOfMemory
		}
		table.flat = flat_arr
	}
	return table, nil
}

// char_class_flat_from_ranges materializes the opt-in O(1) table
// (~1.1 MB, 0x110000 entries) from a validated range set. Shared by
// char_class_build and the qdct load, which rebuilds the flat table
// instead of serializing it.
char_class_flat_from_ranges :: proc(ranges: []Char_Range, allocator: mem.Allocator) -> ([]Char_Class, Load_Err) {
	flat_arr, err := make([]Char_Class, UNICODE_LIMIT, allocator)
	if err != nil { return nil, .OutOfMemory }
	// make zero-fills the table, and Char_Class.Unknown is the enum's
	// zero member — the uncovered default is already in place. A
	// reorder that moves Unknown off member 0 would break this; the
	// ABI's enum mirror (MOLI_CLASS_UNKNOWN == 0) pins it.
	for r in ranges {
		for i := int(r.lo); i < int(r.hi) && i < len(flat_arr); i += 1 {
			flat_arr[i] = r.class
		}
	}
	return flat_arr, nil
}

// char_class_of classifies a single rune. Unknown is the legitimate
// "rune not covered" answer; it never asserts.
char_class_of :: proc(t: ^Char_Class_Table, ch: rune) -> Char_Class {
	if len(t.flat) > 0 {
		if int(ch) >= 0 && int(ch) < len(t.flat) {
			return t.flat[ch]
		}
		return .Unknown
	}
	lo, hi := 0, len(t.ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		r := t.ranges[mid]
		if ch < r.lo {
			hi = mid
		} else if ch >= r.hi {
			lo = mid + 1
		} else {
			return r.class
		}
	}
	return .Unknown
}

// char_class_from_name maps a char.def category name (the first column
// of unk.def, the second of char.def) to a Char_Class. Recognized MeCab
// categories map to members; ok is false for names the enum does not
// carry - callers at the load boundary treat an unknown rule name as a
// broken dictionary, while unknown char.def range names map to
// .Unknown instead.
char_class_from_name :: proc(name: string) -> (Char_Class, bool) {
	switch name {
	case "DEFAULT":
		return .Symbol, true
	case "SPACE":
		return .Space, true
	case "KANJI":
		return .Kanji, true
	case "HIRAGANA":
		return .Hiragana, true
	case "KATAKANA":
		return .Katakana, true
	case "HALFWIDTHKATAKANA", "HALFWIDTH_KATAKANA":
		return .HalfwidthKatakana, true
	case "CHINESE", "HANZI":
		return .Hanzi, true
	case "BOPOMOFO":
		return .Bopomofo, true
	case "ALPHA", "GREEK", "CYRILLIC", "LATIN":
		return .ASCIILetter, true
	case "NUMERIC", "DIGIT", "CHINESENUMERIC", "KANJINUMERIC":
		return .Digit, true
	case "SYMBOL", "PUNCT":
		return .Punct, true
	case "EMOJI":
		return .Emoji, true
	}
	return .Unknown, false
}

// UNICODE_LIMIT is the half-open limit of the code-point universe
// (0x10FFFF + 1): the flat table's size, the range validator's bound,
// the char.def row bound, and the compose-key radix in normalize.odin
// are all this one number.
UNICODE_LIMIT :: 0x110000

// char_ranges_valid checks the table invariant: ranges ordered by lo,
// non-overlapping, and living inside the code-point universe
// ([0, UNICODE_LIMIT], hi exclusive). The bounds half is load-bearing for
// the snapshot path, whose ranges arrive raw from the image: a negative
// lo would index the flat table negatively, and the char.def path
// already enforces the same rule at parse time.
char_ranges_valid :: proc(ranges: []Char_Range) -> bool {
	if len(ranges) == 0 { return true }
	last_hi := ranges[0].lo
	for r in ranges {
		if r.lo < 0 || r.hi > UNICODE_LIMIT { return false }
		if r.lo < last_hi { return false }
		if r.hi <= r.lo { return false }
		last_hi = r.hi
	}
	return true
}
