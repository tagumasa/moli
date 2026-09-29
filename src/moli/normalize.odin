// NFC normalization (Unicode Standard Form C, UAX #15): the input
// option that makes decomposed input (NFD - macOS filenames, some web
// APIs) match a dictionary stored in NFC. Tables are generated from
// the UCD (nfc_tables.odin); Hangul composition and decomposition are
// algorithmic. Nothing here touches os - pure analysis-core code with
// an explicit allocator.
package moli

import "core:mem"
import "core:unicode/utf8"

// Hangul constants (UAX #15).
HANGUL_S_BASE :: rune(0xAC00)
HANGUL_L_BASE :: rune(0x1100)
HANGUL_V_BASE :: rune(0x1161)
HANGUL_T_BASE :: rune(0x11A7)
HANGUL_L_COUNT :: 19
HANGUL_V_COUNT :: 21
HANGUL_T_COUNT :: 28
HANGUL_N_COUNT :: rune(HANGUL_V_COUNT * HANGUL_T_COUNT) // 588
HANGUL_S_COUNT :: rune(HANGUL_L_COUNT * HANGUL_N_COUNT) // 11172

// nfc_combining_class answers the canonical combining class of r
// (0 for starters).
nfc_combining_class :: proc(r: rune) -> u8 {
	tbl := NFC_CCC // materialized: constants refuse variable indexing
	lo, hi := 0, len(tbl) / 2
	for lo < hi {
		mid := (lo + hi) / 2
		if tbl[mid * 2] <= i32(r) { lo = mid + 1 } else { hi = mid }
	}
	i := lo - 1
	if i >= 0 && tbl[i * 2] == i32(r) {
		return u8(tbl[i * 2 + 1])
	}
	return 0
}

// nfc_decompose_step answers r's own table decomposition; b < 0 marks
// a singleton. Hangul is handled algorithmically in nfc_decompose.
nfc_decompose_step :: proc(r: rune) -> (a: rune, b: rune, ok: bool) {
	tbl := NFC_DECOMP // materialized: constants refuse variable indexing
	lo, hi := 0, len(tbl) / 3
	for lo < hi {
		mid := (lo + hi) / 2
		if tbl[mid * 3] <= i32(r) { lo = mid + 1 } else { hi = mid }
	}
	i := lo - 1
	if i >= 0 && tbl[i * 3] == i32(r) {
		return rune(tbl[i * 3 + 1]), rune(tbl[i * 3 + 2]), true
	}
	return 0, 0, false
}

// nfc_compose_pair answers the primary composite of (a, b) - Hangul
// L+V and LV+T algorithmic, then the generated table; ok is false
// when the pair composes to nothing.
nfc_compose_pair :: proc(a, b: rune) -> (r: rune, ok: bool) {
	if a >= HANGUL_L_BASE && a < HANGUL_L_BASE + HANGUL_L_COUNT &&
	   b >= HANGUL_V_BASE && b < HANGUL_V_BASE + HANGUL_V_COUNT {
		i := (int(a - HANGUL_L_BASE)) * HANGUL_V_COUNT + int(b - HANGUL_V_BASE)
		return HANGUL_S_BASE + rune(i * HANGUL_T_COUNT), true
	}
	if a >= HANGUL_S_BASE && a < HANGUL_S_BASE + HANGUL_S_COUNT &&
	   (a - HANGUL_S_BASE) % HANGUL_T_COUNT == 0 &&
	   b > HANGUL_T_BASE && b < HANGUL_T_BASE + HANGUL_T_COUNT {
		return a + (b - HANGUL_T_BASE), true
	}
	tbl := NFC_COMPOSE // materialized: constants refuse variable indexing
	lo, hi := 0, len(tbl) / 3
	// i64 keys: a * UNICODE_LIMIT overflows i32 for real codepoints.
	needle := i64(a) * UNICODE_LIMIT + i64(b)
	for lo < hi {
		mid := (lo + hi) / 2
		key := i64(tbl[mid * 3]) * UNICODE_LIMIT + i64(tbl[mid * 3 + 1])
		if key <= needle { lo = mid + 1 } else { hi = mid }
	}
	i := lo - 1
	if i >= 0 && tbl[i * 3] == i32(a) && tbl[i * 3 + 1] == i32(b) {
		return rune(tbl[i * 3 + 2]), true
	}
	return 0, false
}

// normalize_nfc composes text to NFC. When the input is already NFC,
// or is malformed UTF-8, the answer is the input slice itself,
// zero-copy; only a changed composition is a fresh allocation, which
// the caller may delete with delete(result, allocator). Callers must
// therefore not assume they own the result - the arena contract (no
// per-result delete) covers both shapes uniformly. Malformed UTF-8
// answers the input unchanged - normalization is best-effort, and the
// tokenizer's malformed-byte handling takes over downstream.
normalize_nfc :: proc(text: string, allocator: mem.Allocator) -> (string, mem.Allocator_Error) {
	rs, malformed, derr := nfc_decompose(text, allocator)
	// Registered before any early return: on mid-decomposition
	// allocation failure rs arrives partially filled and must still
	// be freed (deleting a nil dynamic is a no-op).
	defer delete(rs) // [dynamic] carries allocator
	if derr != nil { return "", derr }

	if malformed {
		return text, nil
	}
	nfc_order(rs[:])
	compacted := nfc_compose_run(rs[:])

	// The fresh encoding is compared against the input before it is
	// handed over: an already-NFC input returns the caller's slice
	// itself, zero-copy, paying one transient clone for the check.
	out, oerr := runes_to_string(compacted, allocator)
	if oerr != nil { return "", oerr }
	if out == text {
		delete(out, allocator)
		return text, nil
	}
	return out, nil
}

// runes_to_string UTF-8 encodes rs into a fresh string owned by the
// caller (delete(result, allocator)). Encoding appends into a dynamic
// buffer first, then clones once at the exact byte length: the
// returned string must be deletable with delete(result, allocator),
// which a capacity-carrying dynamic backing would not be. The ASCII
// arm keeps pure-ASCII runs on the one-byte append path. Shared by the
// NFC composer and the lemma rewriters so the ownership contract is
// stated in this one place.
runes_to_string :: proc(rs: []rune, allocator: mem.Allocator) -> (string, mem.Allocator_Error) {
	buf, merr := make([dynamic]u8, 0, len(rs) * 4, allocator)
	if merr != nil { return "", merr }
	defer delete(buf) // [dynamic] carries allocator
	for r in rs {
		if r <= 0x7F {
			if _, aerr := append(&buf, u8(r)); aerr != nil { return "", aerr }
		} else {
			enc, n := utf8.encode_rune(r)
			if _, aerr := append(&buf, ..enc[:n]); aerr != nil { return "", aerr }
		}
	}
	out, cerr := mem.alloc_bytes(len(buf), 1, allocator)
	if cerr != nil { return "", cerr }
	copy(out, buf[:])
	return string(out), nil
}

// nfc_decompose expands every rune to its full canonical
// decomposition, recursively (Hangul syllables algorithmically into
// L V T). malformed reports invalid UTF-8; rs then holds the runes
// decoded before the bad byte. err reports allocation failure
// mid-decomposition; rs is then partially filled and the caller must
// still delete it.
nfc_decompose :: proc(text: string, allocator: mem.Allocator) -> (rs: [dynamic]rune, malformed: bool, err: mem.Allocator_Error) {
	rs, err = make([dynamic]rune, 0, len(text), allocator)
	if err != nil { return nil, false, err }

	decompose_into :: proc(rs: ^[dynamic]rune, r: rune) -> mem.Allocator_Error {
		if r >= HANGUL_S_BASE && r < HANGUL_S_BASE + HANGUL_S_COUNT {
			i := r - HANGUL_S_BASE
			l := HANGUL_L_BASE + i / HANGUL_N_COUNT
			v := HANGUL_V_BASE + (i % HANGUL_N_COUNT) / HANGUL_T_COUNT
			if _, e1 := append(rs, l); e1 != nil { return e1 }
			if _, e2 := append(rs, v); e2 != nil { return e2 }
			if t := i % HANGUL_T_COUNT; t != 0 {
				if _, e3 := append(rs, HANGUL_T_BASE + t); e3 != nil { return e3 }
			}
			return nil
		}
		if a, b, ok := nfc_decompose_step(r); ok {
			if e := decompose_into(rs, a); e != nil { return e }
			if b >= 0 {
				return decompose_into(rs, b)
			}
			return nil
		}
		_, perr := append(rs, r)
		return perr
	}

	p := 0
	for p < len(text) {
		r, w := utf8.decode_rune_in_string(text[p:])
		if decode_malformed(r, w) {
			return rs, true, nil
		}
		if derr := decompose_into(&rs, r); derr != nil { return rs, false, derr }
		p += w
	}
	return rs, false, nil
}

// nfc_order applies Canonical Ordering (UAX #15): a stable insertion
// sort by combining class within each run of non-starters.
nfc_order :: proc(rs: []rune) {
	for i := 1; i < len(rs); i += 1 {
		cc := nfc_combining_class(rs[i])
		if cc == 0 || nfc_combining_class(rs[i - 1]) == 0 { continue }
		r := rs[i]
		j := i - 1
		for j >= 0 && nfc_combining_class(rs[j]) > cc {
			rs[j + 1] = rs[j]
			j -= 1
		}
		rs[j + 1] = r
	}
}

// nfc_compose_run applies Canonical Composition in place, compacting
// the slice: a character composes into the run's starter when the
// pair is a primary composite and the character is not blocked by an
// intervening equal-or-greater combining class (UAX #15). The
// last_ccc == 0 arm lets Hangul T join an LV starter.
nfc_compose_run :: proc(rs: []rune) -> []rune {
	out := 0
	starter := -1
	last_ccc := u8(0)
	for i := 0; i < len(rs); i += 1 {
		c := rs[i]
		cc := nfc_combining_class(c)
		if starter >= 0 && (last_ccc < cc || last_ccc == 0) {
			if comp, ok := nfc_compose_pair(rs[starter], c); ok {
				rs[starter] = comp
				continue
			}
		}
		rs[out] = c
		if cc == 0 {
			starter = out
			last_ccc = 0
		} else {
			last_ccc = cc
		}
		out += 1
	}
	return rs[:out]
}
