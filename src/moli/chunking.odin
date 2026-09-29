// The safe-cut rule in executable form: offsets that split a text into
// pieces a caller can tokenize independently without splitting any
// morpheme. Pure text analysis - no os, no thread.
package moli

import "core:mem"

// safe_chunk_offsets returns byte offsets that cut text into pieces for
// separate tokenize calls without landing inside a morpheme. A cut is
// placed only immediately after a whitespace run that ends with a
// newline - byte index i where text[i-1] == '\n' and text[i] is not a
// byte a whitespace run can continue over. The rule covers CRLF text
// and runs with trailing spaces by the same test: a cut never falls
// inside a "\r\n" pair, nor between a newline run and the spaces that
// extend it.
//
// Split-free holds by construction when no dictionary surface contains
// the LF byte (true of every shipped dictionary): the grouped
// whitespace run ends at the cut, and no other morpheme can span it.
// Concatenating the per-piece sequences then reproduces the single
// call's morphemes exactly in practice, but that identity is
// empirical, not a theorem - each piece restarts BOS/EOS context, so
// the transition into the first morpheme after a cut is decided
// independently. Verify the identity on any new dictionary shape
// before relying on it.
//
// Pieces: scanning left to right, the first qualifying cut at least
// target_bytes past the current piece start is taken, so every piece
// except the last is at least target_bytes long; the last piece is the
// remainder. target_bytes below 1 is treated as 1. A document with no
// qualifying cut - no newline, or nothing but whitespace after the
// last one - answers no offsets: the whole text is one piece.
//
// The returned slice is a single allocation owned by the caller
// (delete it with the same allocator). A pure function of its inputs,
// safe to call concurrently.
safe_chunk_offsets :: proc(text: string, target_bytes: int, allocator: mem.Allocator) -> (offsets: []int, aerr: mem.Allocator_Error) {
	min_gap := target_bytes
	if min_gap < 1 { min_gap = 1 }

	// One counting pass so the result is a single exact allocation.
	// Both passes take their cuts through want_cut - the one statement
	// of what a cut is, so count and fill cannot drift apart.
	n := 0
	start := 0
	for i := 1; i < len(text); i += 1 {
		if !want_cut(text, i, start, min_gap) { continue }
		n += 1
		start = i
	}

	offsets, aerr = make([]int, n, allocator)
	if aerr != nil { return nil, aerr }

	k := 0
	start = 0
	for i := 1; i < len(text); i += 1 {
		if !want_cut(text, i, start, min_gap) { continue }
		offsets[k] = i
		k += 1
		start = i
	}
	return offsets, nil
}

// want_cut reports whether byte index i is a piece boundary: a safe
// cut (a newline-terminated whitespace run before i) at least min_gap
// bytes past the current piece start.
want_cut :: proc(text: string, i: int, start: int, min_gap: int) -> bool {
	return cut_after_newline_run(text, i) && i - start >= min_gap
}

// cut_after_newline_run reports whether byte index i is a safe cut:
// the byte before it ends a whitespace run terminated by a newline,
// and that run cannot continue past i.
cut_after_newline_run :: proc(text: string, i: int) -> bool {
	return text[i - 1] == '\n' && !space_class_byte(text[i])
}

// space_class_byte reports whether b is a byte of the built-in Space
// class (the SPACE_* constants at the range table in char_class.odin):
// the bytes a grouped whitespace run can continue over, so the safe-cut
// rule never cuts before one. 0x0E (SO) is not one - the safe-cut copy
// once included it while the range table's half-open run did not, and
// the shared constants close that drift.
space_class_byte :: proc(b: u8) -> bool {
	return (b >= SPACE_CTRL_LO && b < SPACE_CTRL_HI) || b == SPACE_SINGLE
}
