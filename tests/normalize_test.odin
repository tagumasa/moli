// NFC coverage: composition (Latin, katakana dakuten, Hangul
// algorithmic), canonical ordering (the UAX #15 0300/0315 swap),
// idempotence, zero-change passthrough, malformed-UTF-8 passthrough,
// and the tokenize flag making NFD input match an NFC dictionary.
package tests

import "base:runtime"
import "core:mem"
import "core:testing"
import "core:unicode/utf8"
import "moli:moli"

runes_str :: proc(rs: []rune, allocator: mem.Allocator) -> string {
	out: [32]u8
	n := 0
	for r in rs {
		buf, w := utf8.encode_rune(r)
		for b in buf[:w] {
			out[n] = b
			n += 1
		}
	}
	s, err := mem.alloc_bytes(n, 1, allocator)
	if err != nil { return "" }
	copy(s, out[:n])
	return string(s)
}

// runes_equal compares s's decoded runes against want, rune for rune.
runes_equal :: proc(s: string, want: []rune) -> bool {
	p := 0
	i := 0
	for p < len(s) {
		r, w := utf8.decode_rune_in_string(s[p:])
		if i >= len(want) || r != want[i] { return false }
		p += max(w, 1)
		i += 1
	}
	return i == len(want)
}

@(test)
nfc_compose_cases_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()
	cases := [][2][]rune{
		{{0x61, 0x301}, {0xE1}},              // a + acute -> á
		{{0x30CF, 0x3099}, {0x30D0}},         // ハ + dakuten -> バ
		{{0x304B, 0x3099}, {0x304C}},         // か + dakuten -> が
		{{0x1100, 0x1161}, {0xAC00}},         // Hangul L + V -> 가
		{{0x1100, 0x1161, 0x11A8}, {0xAC01}}, // L + V + T -> 각
		{{0xAC00, 0x11A8}, {0xAC01}},         // syllable + trailing jamo -> 각 (the S-decompose branch)
		{{0x41}, {0x41}},                     // starter alone
	}
	for c in cases {
		input := runes_str(c[0], allocator)
		got, err := moli.normalize_nfc(input, allocator)
		if err != nil {
			testing.expectf(t, false, "normalize_nfc(%x): %v", c[0], err)
			return
		}
		testing.expectf(t, runes_equal(got, c[1]), "compose %x: got %x, want %x", c[0], got, c[1])
		if got != input { delete(got, allocator) }
		delete(input, allocator)
	}
}

@(test)
nfc_ordering_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()
	// UAX #15 ordering example: 0315 (ccc 232) precedes 0300 (ccc 230)
	// in the stream; canonical order swaps them, then 0300 composes.
	input := runes_str([]rune{0x61, 0x0315, 0x0300}, allocator)
	got, err := moli.normalize_nfc(input, allocator)
	if err != nil {
		testing.expectf(t, false, "normalize_nfc: %v", err)
		return
	}
	testing.expectf(t, runes_equal(got, []rune{0xE0, 0x0315}),
		"ordering: got %x, want [e0 315]", got)
	if got != input { delete(got, allocator) }
	delete(input, allocator)
}

@(test)
nfc_idempotent_and_passthrough_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()

	already := "がギュウニクéa"
	got, err := moli.normalize_nfc(already, allocator)
	if err != nil {
		testing.expectf(t, false, "normalize_nfc(already): %v", err)
		return
	}
	testing.expectf(t, got == already, "already-NFC input passes through unchanged")
	if got != already { delete(got, allocator) }

	// Twice is once.
	input := runes_str([]rune{0x30CF, 0x3099, 0x61, 0x301}, allocator)
	once, err1 := moli.normalize_nfc(input, allocator)
	if err1 != nil { testing.expectf(t, false, "once: %v", err1); return }
	twice, err2 := moli.normalize_nfc(once, allocator)
	if err2 != nil { testing.expectf(t, false, "twice: %v", err2); return }
	testing.expectf(t, once == twice, "idempotent: %x vs %x", once, twice)
	if twice != once { delete(twice, allocator) }
	delete(once, allocator)
	delete(input, allocator)

	// Malformed UTF-8: answered unchanged, no error.
	bad := "\xC3\x28zz"
	got3, err3 := moli.normalize_nfc(bad, allocator)
	if err3 != nil {
		testing.expectf(t, false, "malformed: %v", err3)
		return
	}
	testing.expectf(t, got3 == bad, "malformed input returns unchanged")
	if got3 != bad { delete(got3, allocator) }
}

@(test)
nfc_tokenize_flag_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()
	entries := []Test_Entry{
		{surface = "が", left_id = 0, right_id = 0, cost = 0, pos = "助詞"},
	}
	a, ok := build_test_analyzer(t, .Japanese, .Viterbi, entries, nil, 0)
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	nfd := runes_str([]rune{0x304B, 0x3099}, allocator)
	defer delete(nfd, allocator)

	// Without the flag the decomposed pair never matches the NFC
	// dictionary surface.
	ms, err := moli.tokenize_opt(&a, nfd, {}, arena_alloc)
	if err != nil {
		testing.expectf(t, false, "tokenize_opt(no flag): %v", err)
		return
	}
	if len(ms) == 0 {
		testing.expectf(t, false, "no-flag tokenize: %d morphemes", len(ms))
		return
	}
	testing.expectf(t, ms[0].is_unknown, "NFD input stays unknown without the flag")

	// With it, the composed input matches the dictionary entry.
	mem.arena_free_all(&arena)
	ms2, err2 := moli.tokenize_opt(&a, nfd, {normalize_nfc = true}, arena_alloc)
	if err2 != nil {
		testing.expectf(t, false, "tokenize_opt(flag): %v", err2)
		return
	}
	if len(ms2) != 1 || ms2[0].surface != "が" || ms2[0].is_unknown {
		testing.expectf(t, false, "NFD input composes and matches: %d morphemes (unknown=%v)",
			len(ms2), len(ms2) > 0 ? ms2[0].is_unknown : false)
		return
	}
}

// Allocation failure must surface as the allocator error, never a
// silently truncated string, and every partially filled buffer on an
// error leg must be freed: the budget allocator forwards to the
// tracking allocator, so the leak gate polices the error paths. The
// Greek iota (U+0390) decomposes into three runes from a two-byte
// source, forcing the decompose buffer to grow mid-loop - the leg
// where the partially decomposed runes used to leak past an early
// return registered before the defer.
@(test)
normalize_nfc_oom_test :: proc(t: ^testing.T) {
	text := "ΐ"
	saw_oom := false
	saw_ok := false
	for budget in 0 ..< 6 {
		b := Budget_Allocator{backing = context.allocator, remaining = budget}
		allocator := mem.Allocator{data = &b, procedure = budget_allocator_proc}
		got, nerr := moli.normalize_nfc(text, allocator)
		if nerr != nil {
			testing.expectf(t, nerr == .Out_Of_Memory, "budget %d: err %v", budget, nerr)
			saw_oom = true
		} else {
			testing.expectf(t, got == text, "budget %d: NFC round-trip broken", budget)
			saw_ok = true
		}
	}
	testing.expectf(t, saw_oom && saw_ok, "sweep must cover both legs (oom=%v ok=%v)", saw_oom, saw_ok)
}
