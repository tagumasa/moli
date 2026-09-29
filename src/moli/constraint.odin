// Constrained analysis: the caller pins parts of the winning
// segmentation before the search runs - spans that must come out as
// exactly one morpheme (optionally with a POS-column prefix), and
// byte offsets where a morpheme boundary must or must not exist. The
// mechanism is a candidate mask: build_lattice enumerates its
// unconstrained nodes, then every node a constraint forbids is
// dropped before any DP sees the lattice. Nothing about the search
// changes - the winning path is still the minimum-cost path over the
// candidates that remain, so a constraint set that changes nothing
// reproduces the unconstrained analysis bit for bit, and an
// over-constrained set leaves EOS unreachable and faults
// (Unsatisfiable_Error) instead of silently relaxing.
//
// The mask creates no synthetic nodes: a pinned span survives
// only through a candidate the lattice already offers - a dictionary
// homograph of that surface, or an unknown candidate of exactly that
// span - so forcing a surface the dictionary does not carry and the
// unknown machinery cannot shape is an unsatisfiable fault, not a
// fabricated morpheme. POS patterns are comma-separated column
// prefixes ("名詞" matches "名詞,一般"; "" accepts any POS);
// mid-column wildcards are not offered because joined_pos drops "*"
// columns positionally at load, which makes a "*,非自立"-style
// pattern unverifiable from the stored data.
//
// Pure analysis like the rest of the tokenizer: constraints are
// per-call borrowed data (the slices and every pos string live for
// the call's duration, like the text argument), the analyzer is never
// written, and the shared-analyzer concurrency contract is untouched.
package moli

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// Token_Constraint pins text[start:end] to come out as exactly one
// morpheme. start and end are byte offsets into the text the call
// tokenizes (the arena's normalized copy when normalize_nfc applies -
// which the call then requires to be byte-identical). pos is a
// comma-separated POS-column prefix the morpheme's joined POS must
// match; "" accepts any POS the span's candidates carry.
Token_Constraint :: struct {
	start: int,
	end:   int,
	pos:   string,
}

// Boundary_Constraint expresses one byte offset's boundary: must_exist
// true drops every candidate spanning the offset (a boundary is forced
// there), false drops every candidate ending at it (a boundary is
// forbidden there - the winning path must cross the offset inside a
// morpheme). at is a byte offset into the tokenized text, strictly
// inside it; the text's own edges are not expressible (and not
// meaningful - BOS/EOS are not analysis decisions).
Boundary_Constraint :: struct {
	at:        int,
	must_exist: bool,
}

// Constraints is the constraint set of one call. The zero value is no
// constraints. Both slices and every string inside them are borrowed
// for the call's duration only.
Constraints :: struct {
	tokens:     []Token_Constraint,
	boundaries: []Boundary_Constraint,
}

// constraints_active reports whether a set carries anything to
// enforce; the false value is what keeps the unconstrained paths
// byte-identical to a build without the parameter.
constraints_active :: proc(cons: Constraints) -> bool {
	return len(cons.tokens) > 0 || len(cons.boundaries) > 0
}

// is_rune_boundary reports whether i is a rune start (or one of the
// two edges) of text: a byte whose top bits are not the continuation
// pattern. This is a byte-level test - malformed input validates by
// the same rule the lattice walk decodes with.
is_rune_boundary :: proc(text: string, i: int) -> bool {
	if i < 0 || i > len(text) { return false }
	if i == 0 || i == len(text) { return true }
	return text[i] & 0xC0 != 0x80
}

// pos_pattern_valid rejects POS patterns with an empty column: "" is
// the any-pattern, and ",x", "x,", "x,,y" carry an empty column no
// joined POS could ever match.
pos_pattern_valid :: proc(pattern: string) -> bool {
	if pattern == "" { return true }
	if pattern[0] == ',' || pattern[len(pattern) - 1] == ',' { return false }
	for i in 0 ..< len(pattern) - 1 {
		if pattern[i] == ',' && pattern[i + 1] == ',' { return false }
	}
	return true
}

// pos_prefix_matches reports whether joined (an entry's or an unknown
// rule's joined POS) sits under pattern as whole columns: equality,
// or a longer joined whose next character is the column separator.
pos_prefix_matches :: proc(pattern: string, joined: string) -> bool {
	if pattern == "" { return true }
	if !strings.has_prefix(joined, pattern) { return false }
	if len(joined) == len(pattern) { return true }
	return joined[len(pattern)] == ','
}

// boundary_constraint_err is the error shape every boundary-check
// fault carries: the boundary's own index and offset, and no end
// offset - end is a token-span field, and boundary faults carry the
// -1 sentinel (the Bad_Constraint_Error contract in errors.odin).
boundary_constraint_err :: proc(bi: int, at: int, reason: Constraint_Reason) -> Bad_Constraint_Error {
	return Bad_Constraint_Error{index = bi, start = at, end = -1, reason = reason}
}

// validate_constraints rejects a constraint set before any analysis
// runs: span bounds, rune boundaries, POS pattern shape, token-token
// overlap, boundary placement against tokens, and boundary-boundary
// conflicts. Deterministic scan order (tokens ascending by index,
// then boundaries, then the cross checks), first fault returns.
validate_constraints :: proc(text: string, cons: Constraints) -> Tokenize_Err {
	for tk, i in cons.tokens {
		if tk.start < 0 || tk.end > len(text) {
			return Bad_Constraint_Error{index = i, start = tk.start, end = tk.end, reason = .Out_Of_Bounds}
		}
		if tk.start >= tk.end {
			return Bad_Constraint_Error{index = i, start = tk.start, end = tk.end, reason = .Empty_Span}
		}
		if !is_rune_boundary(text, tk.start) || !is_rune_boundary(text, tk.end) {
			return Bad_Constraint_Error{index = i, start = tk.start, end = tk.end, reason = .Not_Rune_Boundary}
		}
		if !pos_pattern_valid(tk.pos) {
			return Bad_Constraint_Error{index = i, start = tk.start, end = tk.end, reason = .Bad_Pos_Pattern}
		}
	}
	for j in 1 ..< len(cons.tokens) {
		for i in 0 ..< j {
			a := cons.tokens[i]
			b := cons.tokens[j]
			if a.start < b.end && b.start < a.end {
				return Bad_Constraint_Error{index = j, start = b.start, end = b.end, reason = .Token_Overlap}
			}
		}
	}
	for b, bi in cons.boundaries {
		if b.at <= 0 || b.at >= len(text) {
			return boundary_constraint_err(bi, b.at, .Out_Of_Bounds)
		}
		if !is_rune_boundary(text, b.at) {
			return boundary_constraint_err(bi, b.at, .Not_Rune_Boundary)
		}
		for tk in cons.tokens {
			if b.at > tk.start && b.at < tk.end {
				return boundary_constraint_err(bi, b.at, .Boundary_Inside_Token)
			}
			if !b.must_exist && (b.at == tk.start || b.at == tk.end) {
				return boundary_constraint_err(bi, b.at, .Boundary_At_Token_Edge)
			}
		}
	}
	for j in 1 ..< len(cons.boundaries) {
		for i in 0 ..< j {
			if cons.boundaries[i].at == cons.boundaries[j].at &&
				cons.boundaries[i].must_exist != cons.boundaries[j].must_exist {
				return Bad_Constraint_Error{index = -1, start = cons.boundaries[j].at, end = -1, reason = .Conflicting_Boundaries}
			}
		}
	}
	return nil
}

// node_pos_of returns the POS a lattice node would emit: the entry's
// joined POS for a dictionary match, the rule's joined POS for an
// unknown. BOS/EOS carry no POS and are never token-pinned (their
// zero-width spans cannot intersect a validated token span).
node_pos_of :: proc(a: ^Analyzer, n: ^Lattice_Node) -> string {
	if n.is_unknown { return n.pos }
	return a.entries[n.entry_id].joined_pos
}

// node_allowed under one constraint set: a candidate survives unless
// a boundary constraint drops it (spanning a must-exist offset, or
// ending on a forbidden one) or a token span it partially overlaps
// claims the region - a node intersecting a token span survives only
// by being that span, with a POS under the span's pattern. The
// zero-width sentinels never trip any clause: boundaries are strictly
// interior and token spans are non-empty.
node_allowed :: proc(a: ^Analyzer, n: ^Lattice_Node, cons: Constraints) -> bool {
	for b in cons.boundaries {
		if b.must_exist {
			if n.start < b.at && n.end > b.at { return false }
		} else if n.end == b.at {
			return false
		}
	}
	for tk in cons.tokens {
		if n.start < tk.end && n.end > tk.start {
			if n.start != tk.start || n.end != tk.end { return false }
			if !pos_prefix_matches(tk.pos, node_pos_of(a, n)) { return false }
		}
	}
	return true
}

// constraint_filter_lattice compacts the node buffer down to the
// candidates the constraints allow, preserving append order (and with
// it the ascending-start grouping the successor index and both DP
// walks rely on). Returns the kept length; the caller reassigns the
// buffer's len. Allocation-free - reachability is the DP's to report.
constraint_filter_lattice :: proc(a: ^Analyzer, lattice: []Lattice_Node, cons: Constraints) -> int {
	kept := 0
	for i in 0 ..< len(lattice) {
		if !node_allowed(a, &lattice[i], cons) { continue }
		if i != kept { lattice[kept] = lattice[i] }
		kept += 1
	}
	return kept
}

// normalize_constraint_check is the normalize_nfc composition rule:
// constraint offsets index the text as passed, so a normalization
// that changes the bytes also invalidates every offset in the set -
// the call faults rather than silently re-reading offsets against a
// different string. Byte-identical normalization (already-NFC input)
// keeps the constraints meaningful and proceeds on either copy.
normalize_constraint_check :: proc(text: string, normalized: string) -> Tokenize_Err {
	if normalized != text {
		return Bad_Constraint_Error{index = -1, start = -1, end = -1, reason = .Normalization_Rescaled}
	}
	return nil
}

// mark_reached_ends builds the reached-boundary bitmap both fault
// diagnostics share: true at every byte offset some live (finite-cost)
// node ends at. Degrades to nil on a failed allocation - the callers
// then report the fault with a degraded offset, not a second fault.
mark_reached_ends :: proc(lattice: []Lattice_Node, finite: []i64, text: string, arena_allocator: mem.Allocator) -> []bool {
	reached, merr := make([]bool, len(text) + 1, arena_allocator)
	if merr != nil { return nil }
	for i in 0 ..< len(lattice) {
		if finite[i] != DP_UNREACHABLE { reached[lattice[i].end] = true }
	}
	return reached
}

// first_unreached_forward is the fault-path diagnostic of the forward
// DP: the first rune boundary no live (dp-finite) node ends at,
// scanning from the text's start - the earliest position the
// constraints block. The start itself counts as reached (BOS ends
// there). Degrades to the text length if its own scratch allocation
// fails (the fault is already certain; only its offset degrades).
first_unreached_forward :: proc(lattice: []Lattice_Node, dp: []i64, text: string, arena_allocator: mem.Allocator) -> int {
	reached := mark_reached_ends(lattice, dp, text, arena_allocator)
	if reached == nil { return len(text) }
	reached[0] = true
	p := 0
	for p < len(text) {
		_, w := utf8.decode_rune_in_string(text[p:])
		if w == 0 { w = 1 }
		q := p + w
		if !reached[q] { return q }
		p = q
	}
	return len(text)
}

// first_unreached_backward is the n-best fault-path diagnostic: the
// last rune boundary no live (completion-finite) node ends at - the
// far edge of the blocked region, where completions stop reaching.
// Degrades to offset 0 the same way.
first_unreached_backward :: proc(lattice: []Lattice_Node, h: []i64, text: string, arena_allocator: mem.Allocator) -> int {
	reached := mark_reached_ends(lattice, h, text, arena_allocator)
	if reached == nil { return 0 }
	last := 0
	p := 0
	for p < len(text) {
		_, w := utf8.decode_rune_in_string(text[p:])
		if w == 0 { w = 1 }
		q := p + w
		if !reached[q] { last = q }
		p = q
	}
	return last
}
