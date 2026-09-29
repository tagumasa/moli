// The tokenizer: mode dispatch, the greedy longest-match loop, and the
// shared zero-copy morpheme builders. Pure analysis - no os, no
// thread; all output goes to the caller's buffer and all scratch to
// the caller's arena_allocator.
package moli

import "base:intrinsics"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// Morpheme is the minimum unit of analysis output. The struct lives in
// the caller's arena_allocator; its string fields are zero-copy slices with
// exactly two possible owners: surface (and a "*"-fallback lemma)
// slice into the input text, pos/lemma/reading/reading_jyutping into
// analyzer-owned strings. tokenize allocates nothing per morpheme -
// the only arena_allocator traffic is the output array itself.
//
// lemma falls back to the surface when the dictionary value is "*" or
// empty; unknown words likewise lemmatize to their surface. start and
// end are byte offsets into the original input. reading is pinyin for
// ZH locales, katakana for JP, "*" for EN; reading_jyutping is the
// jyutping joined from a configured HK-variant donor CSV - "*" when
// no donor was loaded or the surface had no row in it.
//
// entry_id is the morpheme's dictionary row: an index into the
// analyzer's surface-sorted entries for a dictionary match, -1 for an
// unknown word. It is stable while the analyzer's dictionary state is
// unchanged - identical across snapshot save/restore and clone - but
// add_user_entries rebuilds the entry list in surface order, so ids
// taken before a merge are stale after it. Re-resolve through
// entry_info, and detect the invalidation with Analyzer_Stats's
// entries_hash.
Morpheme :: struct {
	surface:          string,
	pos:              string,
	lemma:            string,
	reading:          string,
	reading_jyutping: string,
	entry_id:         i32,
	cost:             i16,
	start:            int,
	end:              int,
	locale:           Locale,
	char_class:       Char_Class,
	is_unknown:       bool,
}

// Tokenize_Options tunes the Viterbi search; the zero value is the
// dictionary-faithful behavior (and what the plain tokenize procs
// use).
Tokenize_Options :: struct {
	// unk_cost_bias shifts every unknown candidate's contribution to
	// the DP by this many units: positive penalizes unknown
	// segmentation (the search prefers dictionary words and shorter
	// unknown runs), negative favors it. It changes which path wins -
	// never the emitted Morpheme costs, which stay the rules' own -
	// and greedy mode ignores it (no search happens).
	unk_cost_bias: i32,
	// unk_cost_per_rune adds this many units per rune of an unknown
	// candidate's surface (on top of unk_cost_bias): a long unknown
	// grows expensive, which is what makes an out-of-vocabulary
	// compound split into dictionary parts plus a shorter unknown
	// competitive with one whole-word unknown. Same contract as
	// unk_cost_bias - search-only, never reflected in Morpheme costs,
	// ignored by greedy mode - and the N-best search applies it too,
	// so both orderings agree.
	unk_cost_per_rune: i32,
	// normalize_nfc composes the input to Unicode NFC before the
	// lattice is built (decomposed input - NFD filenames, some web
	// APIs - would otherwise produce spurious unknowns at every
	// combining mark). The normalized copy lives in the request
	// arena_allocator: with the flag set, Morpheme surfaces slice the arena_allocator
	// copy, not the caller's text, and start/end index the copy.
	// Malformed UTF-8 skips normalization (best-effort).
	normalize_nfc: bool,
	// strict_utf8 rejects what the default degrades on: text that is
	// not valid UTF-8 aborts the call before any analysis (and before
	// NFC normalization, so the offset indexes the caller's original
	// text) with Malformed_Input_Error at the first invalid byte. A
	// genuine U+FFFD is valid UTF-8 and passes. The default keeps the
	// historical behavior: invalid bytes become unknown morphemes.
	strict_utf8: bool,
	// cancel_token, when non-nil, is polled once per rune position of
	// the analysis walk; a cancelled token unwinds the call with
	// Cancelled_Error at the byte offset the walk reached (morphemes
	// already appended stay written, and a token cancelled before the
	// call bounces it at offset 0 having analyzed nothing). The DP and
	// emission phases after a completed walk are output-bounded and
	// not polled; the n-best enumeration is not (its heap frontier
	// grows with the lattice), so it polls once per heap pop and
	// unwinds at the popped prefix's node start - paths already
	// appended stay written. See Cancel_Token for the threading
	// contract.
	cancel_token: ^Cancel_Token,
}

// Cancel_Token lets the embedder abort a running tokenize-family call
// from another thread (a deadline timer, a disconnecting client). The
// zero value is a live token; cancel flips it one-way. Caller-owned
// memory with the same lifetime duty as the text argument: it must
// outlive the call. Fresh token per request is the intended pattern -
// the library never resets the flag, so a spent token bounces every
// later call that shares it.
Cancel_Token :: struct {
	cancelled: bool, // atomic: .Release store in cancel, .Acquire load in the poll
}

// cancel aborts the tokenize-family calls polling this token. Safe
// from any thread, at any time - including before the call starts,
// which bounces it at offset 0. One-way by design.
cancel :: proc(t: ^Cancel_Token) {
	intrinsics.atomic_store_explicit(&t.cancelled, true, .Release)
}

// token_cancelled is the walk-side poll; nil means no token. Acquire
// pairs with cancel's Release so a store observed by the poll is not
// reordered past it.
token_cancelled :: proc(t: ^Cancel_Token) -> bool {
	return intrinsics.atomic_load_explicit(&t.cancelled, .Acquire)
}

// decode_malformed reports whether one decode result marks an invalid
// byte: core:utf8's RUNE_ERROR with width at most 1 (a genuine U+FFFD
// decodes with its full width and passes). The shared rule of the
// strict-input pre-pass and NFC normalization's best-effort bail.
decode_malformed :: #force_inline proc(r: rune, w: int) -> bool {
	return r == utf8.RUNE_ERROR && w <= 1
}

// malformed_utf8 reports whether any byte of text fails decode as
// UTF-8 under decode_malformed's rule - the whole-string best-effort
// bail for the rewriters that iterate runes and would silently
// re-encode a bad byte as U+FFFD mid-rewrite (the ZH lemma rewriter;
// NFC normalization detects malformed inside its decomposition pass
// instead, answering the input unchanged).
malformed_utf8 :: proc(text: string) -> bool {
	i := 0
	for i < len(text) {
		r, w := utf8.decode_rune_in_string(text[i:])
		if w == 0 { break } // defense-in-depth: never spin
		if decode_malformed(r, w) { return true }
		i += w
	}
	return false
}

// strict_input_check applies the strict-input pre-pass: with
// opts.strict_utf8 set, the first byte of text that does not decode
// as UTF-8 becomes Malformed_Input_Error. The scan rejects exactly
// what decode_malformed reports. Call it before analysis and
// before NFC normalization so the offset indexes the caller's
// original text.
strict_input_check :: proc(opts: Tokenize_Options, text: string) -> Tokenize_Err {
	if !opts.strict_utf8 { return nil }
	i := 0
	for i < len(text) {
		r, w := utf8.decode_rune_in_string(text[i:])
		if w == 0 { break } // defense-in-depth: never spin
		if decode_malformed(r, w) {
			return Malformed_Input_Error{byte_offset = i}
		}
		i += w
	}
	return nil
}

// tokenize_scan_text is the one request prelude the tokenize-family
// entries run (tokenize_opt, tokenize_into_opt, tokenize_projection,
// tokenize_constrained, tokenize_nbest): the strict-input pre-pass
// (offsets index the caller's original text), then validation of an
// active constraint set (its offsets bind the text as passed), then
// NFC composition with the byte-rescale check for an active set. It
// returns the text the lattice must scan - the caller's text
// unchanged, or the arena_allocator's normalized copy.
tokenize_scan_text :: proc(opts: Tokenize_Options, text: string, cons: Constraints, arena_allocator: mem.Allocator) -> (string, Tokenize_Err) {
	if serr := strict_input_check(opts, text); serr != nil { return "", serr }
	if constraints_active(cons) {
		if cerr := validate_constraints(text, cons); cerr != nil { return "", cerr }
	}
	scan := text
	if opts.normalize_nfc {
		normalized, nerr := normalize_nfc(text, arena_allocator)
		if nerr != nil { return "", .OutOfMemory }
		// The rescale fault binds the set's offsets, so it fires only
		// for an active set - the zero value keeps tokenize_opt's
		// composition (the tokenize_nbest precedent).
		if constraints_active(cons) {
			if cerr := normalize_constraint_check(text, normalized); cerr != nil { return "", cerr }
		}
		scan = normalized
	}
	return scan, nil
}

// tokenize segments text into morphemes, honoring a.mode. The
// morphemes are written into arena_allocator - the only allocation tokenize
// performs. Thread-safe on a shared analyzer: analysis state is
// immutable post-load and each thread brings its own arena_allocator. Returns
// .Unavailable when teardown began and .OutOfMemory when the arena_allocator is
// exhausted.
tokenize :: proc(a: ^Analyzer, text: string, arena_allocator: mem.Allocator) -> ([]Morpheme, Tokenize_Err) {
	return tokenize_opt(a, text, Tokenize_Options{}, arena_allocator)
}

// tokenize_opt is tokenize with per-call options; see
// Tokenize_Options.
tokenize_opt :: proc(a: ^Analyzer, text: string, opts: Tokenize_Options, arena_allocator: mem.Allocator) -> ([]Morpheme, Tokenize_Err) {
	if !acquire(a) {
		return nil, .Unavailable
	}
	defer release(a)

	scan, serr := tokenize_scan_text(opts, text, Constraints{}, arena_allocator)
	if serr != nil { return nil, serr }
	return tokenize_opt_core(a, scan, opts, arena_allocator)
}

// tokenize_constrained is the Viterbi search under a constraint set:
// spans that must surface as exactly one morpheme (with an optional
// POS-column prefix) and byte offsets where a boundary must or must
// not exist - the partial-knowledge input the plain family has no way
// to express. See constraint.odin for the semantics, the POS-pattern
// vocabulary, and the no-synthetic-nodes limitation; opts applies exactly
// as to tokenize_opt (with the one composition rule that
// normalize_nfc must not rescale the bytes the offsets index). The
// request prelude is the one the tokenize family shares
// (tokenize_scan_text), so a rejected set faults here before any
// analysis. Constraints are per-call borrowed data; the analyzer is
// not written, and the shared-analyzer concurrency contract is the
// tokenize family's. Greedy mode is meaningless under constraints (no
// search happens), so a.mode is ignored and the lattice is always
// searched - the same precedent as tokenize_nbest. The zero
// Constraints value must reproduce tokenize_opt's Viterbi result
// exactly. Faults: the Tokenize_Err family plus Bad_Constraint_Error
// (the set was rejected before any analysis) and
// Unsatisfiable_Error (the mask left no complete path;
// byte_offset is the earliest blocked position). The wakachi/spans
// projections derive from the returned morphemes.
tokenize_constrained :: proc(a: ^Analyzer, text: string, cons: Constraints, opts: Tokenize_Options, arena_allocator: mem.Allocator) -> ([]Morpheme, Tokenize_Err) {
	if !acquire(a) {
		return nil, .Unavailable
	}
	defer release(a)

	scan, serr := tokenize_scan_text(opts, text, cons, arena_allocator)
	if serr != nil { return nil, serr }

	lattice, path, err := viterbi_path(a, scan, opts.cancel_token, opts.unk_cost_bias, opts.unk_cost_per_rune, cons, arena_allocator)
	if err != nil { return nil, err }

	buf: Morpheme_Buffer
	buf.allocator = arena_allocator
	if aerr := emit_path_morphemes_buf(a, scan, lattice, path, &buf); aerr != nil {
		return nil, aerr
	}
	return buf.data[:buf.len], nil
}

// tokenize_opt_core is the dispatch under tokenize_opt's
// acquire/release umbrella. The result grows through a Morpheme_Buffer
// (raw, non-zeroed growth on the arena) - the zero-fill of every
// doubling was the largest memset cost of large tokenizes.
tokenize_opt_core :: proc(a: ^Analyzer, text: string, opts: Tokenize_Options, arena_allocator: mem.Allocator) -> ([]Morpheme, Tokenize_Err) {
	buf: Morpheme_Buffer
	buf.allocator = arena_allocator

	if a.mode == .Viterbi {
		lattice, path, err := viterbi_path(a, text, opts.cancel_token, opts.unk_cost_bias, opts.unk_cost_per_rune, Constraints{}, arena_allocator)
		if err != nil { return nil, err }
		if aerr := emit_path_morphemes_buf(a, text, lattice, path, &buf); aerr != nil {
			return nil, aerr
		}
		return buf.data[:buf.len], nil
	}

	if terr := tokenize_greedy_buf(a, text, opts.cancel_token, &buf); terr != nil {
		return nil, terr
	}
	return buf.data[:buf.len], nil
}

// tokenize_wakachi emits only the surfaces of whichever mode's
// segmentation applies - zero-copy slices into text, no morpheme
// construction; faster than tokenize when POS and lemma are not
// needed. Same concurrency contract as tokenize.
tokenize_wakachi :: proc(a: ^Analyzer, text: string, arena_allocator: mem.Allocator) -> ([]string, Tokenize_Err) {
	return tokenize_wakachi_opt(a, text, Tokenize_Options{}, arena_allocator)
}

// tokenize_wakachi_opt is tokenize_wakachi with per-call options; see
// Tokenize_Options (strict input and cancellation apply here too, and
// normalize_nfc slices the surfaces from the arena_allocator copy).
tokenize_wakachi_opt :: proc(a: ^Analyzer, text: string, opts: Tokenize_Options, arena_allocator: mem.Allocator) -> ([]string, Tokenize_Err) {
	return tokenize_projection(a, text, opts, arena_allocator, string)
}

// Surface_Span is the slim projection of a morpheme: the surface and
// its byte offsets, without POS/lemma/reading material. surface is a
// zero-copy slice into the analyzed text (under normalize_nfc, into
// the arena_allocator's normalized copy), and start/end address that same text
// - text[start:end] == surface holds by construction. Spans are
// contiguous and total: each end is the next start, the first starts
// at 0, the last ends at the text's length.
Surface_Span :: struct {
	surface: string,
	start:   int,
	end:     int,
}

// projection_elem builds one surface-projection element from a node's
// byte range: the bare surface string when Elem == string, the
// offset-tagged span when Elem == Surface_Span. Only the branch for the
// instantiated Elem compiles.
projection_elem :: #force_inline proc(scan: string, start: int, end: int, $Elem: typeid) -> Elem {
	when Elem == string {
		return scan[start:end]
	} else {
		return Surface_Span{surface = scan[start:end], start = start, end = end}
	}
}

// tokenize_projection is the shared engine of the surface projections
// (tokenize_wakachi_opt's strings, tokenize_surfaces_with_offsets'
// spans): the acquire/release umbrella and the shared request prelude
// (tokenize_scan_text), then either the Viterbi path walk or the
// greedy scan, appending one element per non-sentinel node. Elements
// are zero-copy slices of the scanned text (the arena_allocator's
// normalized copy under normalize_nfc). Same concurrency contract and
// errors as the tokenize family.
tokenize_projection :: proc(a: ^Analyzer, text: string, opts: Tokenize_Options, arena_allocator: mem.Allocator, $Elem: typeid) -> ([]Elem, Tokenize_Err) {
	if !acquire(a) {
		return nil, .Unavailable
	}
	defer release(a)

	scan, serr := tokenize_scan_text(opts, text, Constraints{}, arena_allocator)
	if serr != nil { return nil, serr }

	if a.mode == .Viterbi {
		lattice, path, verr := viterbi_path(a, scan, opts.cancel_token, opts.unk_cost_bias, opts.unk_cost_per_rune, Constraints{}, arena_allocator)
		if verr != nil { return nil, verr }
		// The path length bounds the emission (BOS/EOS emit nothing):
		// one exact-capacity allocation instead of the doubling chain.
		out, merr := make([dynamic]Elem, 0, len(path), arena_allocator)
		if merr != nil { return nil, .OutOfMemory }
		for i in 0 ..< len(path) {
			n := &lattice[path[i]]
			if node_is_sentinel(n) { continue }
			if _, aerr := append(&out, projection_elem(scan, n.start, n.end, Elem)); aerr != nil {
				return nil, .OutOfMemory
			}
		}
		return out[:], nil
	}

	out, merr := make([dynamic]Elem, 0, SMALL_START_CAP, arena_allocator)
	if merr != nil { return nil, .OutOfMemory }

	s, serr2 := scan_table_build(&a.char_map, scan, arena_allocator)
	if serr2 != nil { return nil, .OutOfMemory }

	pos: int = 0
	for pos < len(scan) {
		if opts.cancel_token != nil && token_cancelled(opts.cancel_token) {
			return nil, Cancelled_Error{byte_offset = pos}
		}
		_, byte_end, ok := cedar_match(&a.cedar, &s, pos)
		if ok {
			if _, aerr := append(&out, projection_elem(scan, pos, byte_end, Elem)); aerr != nil {
				return nil, .OutOfMemory
			}
			pos = byte_end
			continue
		}
		run_end := unknown_run_end(&a.char_class, scan, pos)
		if _, aerr := append(&out, projection_elem(scan, pos, run_end, Elem)); aerr != nil {
			return nil, .OutOfMemory
		}
		pos = run_end
	}
	return out[:], nil
}

// tokenize_surfaces_with_offsets emits the wakachi segmentation with
// each surface's byte offsets attached - what highlighting, indexing,
// and re-slicing callers need, without materializing morphemes.
// Takes the options directly (like tokenize_nbest); the zero value
// is dictionary-faithful behavior, strict_utf8/cancel_token/
// normalize_nfc all apply, and offsets index the same text the
// surfaces slice (the normalized copy under normalize_nfc). Same
// concurrency contract and errors as the tokenize family.
tokenize_surfaces_with_offsets :: proc(a: ^Analyzer, text: string, opts: Tokenize_Options, arena_allocator: mem.Allocator) -> ([]Surface_Span, Tokenize_Err) {
	return tokenize_projection(a, text, opts, arena_allocator, Surface_Span)
}

// tokenize_into writes morphemes into the caller's buffer, for
// streaming pipelines that reuse one dynamic array across
// tokenizations; the buffer is cleared at entry (a shrinking resize
// keeps the capacity), so each call replaces the previous morphemes
// instead of appending after strings that point into a previous call's
// arena_allocator. arena_allocator stays explicit (never the ambient temp
// allocator): the Viterbi lattice is request-scoped scratch, and the
// morpheme lifetime contract must stay honest. Same concurrency
// contract as tokenize.
tokenize_into :: proc(a: ^Analyzer, text: string, out: ^[dynamic]Morpheme, arena_allocator: mem.Allocator) -> Tokenize_Err {
	return tokenize_into_opt(a, text, Tokenize_Options{}, out, arena_allocator)
}

// tokenize_into_opt is tokenize_into with per-call options; see
// Tokenize_Options. The buffer is cleared at entry, before the
// request prelude - a faulted call replaces the previous morphemes
// with nothing, never leaves them behind.
tokenize_into_opt :: proc(a: ^Analyzer, text: string, opts: Tokenize_Options, out: ^[dynamic]Morpheme, arena_allocator: mem.Allocator) -> Tokenize_Err {
	resize(out, 0)

	if !acquire(a) {
		return .Unavailable
	}
	defer release(a)

	scan, serr := tokenize_scan_text(opts, text, Constraints{}, arena_allocator)
	if serr != nil { return serr }
	return tokenize_into_opt_core(a, scan, opts, out, arena_allocator)
}

// tokenize_into_opt_core is the dispatch under tokenize_into_opt's
// acquire/release umbrella. The sink stays the caller's dynamic array
// (its capacity is the reuse across calls); tokenize_opt_core's
// raw-growth buffer belongs to the request arena and cannot back it.
tokenize_into_opt_core :: proc(a: ^Analyzer, text: string, opts: Tokenize_Options, out: ^[dynamic]Morpheme, arena_allocator: mem.Allocator) -> Tokenize_Err {
	if a.mode == .Viterbi {
		lattice, path, err := viterbi_path(a, text, opts.cancel_token, opts.unk_cost_bias, opts.unk_cost_per_rune, Constraints{}, arena_allocator)
		if err != nil { return err }
		return emit_path_morphemes(a, text, lattice, path, out)
	}
	return tokenize_greedy(a, text, opts.cancel_token, out, arena_allocator)
}

// greedy_morpheme_at resolves the LongestMatch morpheme at pos: the
// longest dictionary match (the group resolved deterministically) or
// one run-grouped unknown for the whole contiguous same-char-class
// run. The caller's scan table carries the text (one decode sweep
// serves every position's walk). Returns the morpheme and the position
// one past it - the single per-position definition behind both greedy
// walks.
greedy_morpheme_at :: proc(a: ^Analyzer, s: ^Scan_Table, pos: int) -> (m: Morpheme, next: int) {
	head, byte_end, ok := cedar_match(&a.cedar, s, pos)
	if ok {
		eid := i32(cedar_resolve_entry(&a.cedar, a.entries[:], head))
		return morpheme_from_entry(a, s.text, pos, byte_end, eid, &a.entries[eid],
			char_class_of(&a.char_class, first_rune_of(s.text, pos))), byte_end
	}
	run_end := unknown_run_end(&a.char_class, s.text, pos)
	return emit_unknown(a, s.text, pos, run_end), run_end
}

// greedy_walk is the LongestMatch scan loop behind both greedy sinks:
// at each byte position, take the longest dictionary match or emit one
// run-grouped unknown (greedy_morpheme_at is the single per-position
// definition; the cursor never backtracks). The cancel token - nil
// meaning never cancelled - is polled once per iteration before any
// work at the position. In the worst case the failed trie walks
// re-scan bytes, bounding the loop at O(|text| x L_max) where L_max is
// the longest dictionary surface; run grouping is what keeps re-walks
// at match boundaries only. allocator backs the request's scan table.
greedy_walk :: proc(a: ^Analyzer, text: string, cancel: ^Cancel_Token, $Sink: typeid, sink: ^Sink, allocator: mem.Allocator) -> Tokenize_Err {
	s, serr := scan_table_build(&a.char_map, text, allocator)
	if serr != nil { return .OutOfMemory }
	pos: int = 0
	for pos < len(text) {
		if cancel != nil && token_cancelled(cancel) {
			return Cancelled_Error{byte_offset = pos}
		}
		m, next := greedy_morpheme_at(a, &s, pos)
		if perr := sink_push(Sink, sink, m); perr != nil { return perr }
		pos = next
	}
	return nil
}

// tokenize_greedy is the LongestMatch walk into a caller-owned
// dynamic array (tokenize_into); append failures surface as
// .OutOfMemory.
tokenize_greedy :: proc(a: ^Analyzer, text: string, cancel: ^Cancel_Token, out: ^[dynamic]Morpheme, arena_allocator: mem.Allocator) -> Tokenize_Err {
	return greedy_walk(a, text, cancel, [dynamic]Morpheme, out, arena_allocator)
}

// tokenize_greedy_buf is tokenize_greedy into a Morpheme_Buffer -
// the sink behind tokenize. The scan table rides the buffer's own
// allocator (the request arena).
tokenize_greedy_buf :: proc(a: ^Analyzer, text: string, cancel: ^Cancel_Token, buf: ^Morpheme_Buffer) -> Tokenize_Err {
	return greedy_walk(a, text, cancel, Morpheme_Buffer, buf, buf.allocator)
}

// morpheme_from_entry builds the zero-copy morpheme for a dictionary
// entry. The char class is the caller's: the Viterbi emission reads it
// off the lattice node (the build classified the position's rune
// once), and the greedy path classifies its position directly - the
// surface's first rune is the text's rune at start either way, since
// the entry matched there.
morpheme_from_entry :: proc(a: ^Analyzer, text: string, start: int, end: int, entry_id: i32, e: ^Dictionary_Entry, class: Char_Class) -> Morpheme {
	surface := text[start:end]
	lemma := e.lemma
	if lemma == "*" || lemma == "" { lemma = surface }
	return Morpheme{
		surface          = surface,
		pos              = e.joined_pos,
		lemma            = lemma,
		reading          = e.reading,
		reading_jyutping = e.reading_jyutping,
		entry_id         = entry_id,
		cost             = e.cost,
		start            = start,
		end              = end,
		locale           = a.dict_locale,
		char_class       = class,
		is_unknown       = false,
	}
}

// unknown_run_end returns the byte offset one past the contiguous run
// of runes sharing the class of the rune at pos - always at least one
// rune wide, and never spinning on a zero-width decode. Malformed
// bytes decode one byte at a time as .Unknown, so a contiguous
// malformed region is one run; a genuine U+FFFD rune decodes with its
// full width and is not chopped mid-rune.
unknown_run_end :: proc(t: ^Char_Class_Table, text: string, pos: int) -> int {
	if pos >= len(text) { return pos }
	first, w := utf8.decode_rune_in_string(text[pos:])
	if w == 0 { w = 1 }
	return unknown_run_end_from(t, text, pos, w, char_class_of(t, first))
}

// unknown_run_end_from is unknown_run_end with the rune at pos
// already decoded: the caller supplies its width and class, so the
// run scan starts one rune in. unknown_run_end is its only caller -
// the lattice build reads packed widths and classes off its walk
// table instead of decoding runes here.
unknown_run_end_from :: proc(t: ^Char_Class_Table, text: string, pos: int, first_width: int, class: Char_Class) -> int {
	end := pos + first_width
	for end < len(text) {
		r, n := utf8.decode_rune_in_string(text[end:])
		if n == 0 { break }
		if char_class_of(t, r) != class { break }
		end += n
	}
	return end
}

// emit_unknown builds the run-grouped unknown morpheme for
// text[start:end]: POS, cost, and ids come from the resolution ladder
// (surface patterns, then the first matching unk rule, then the
// per-language fallback). The unknown-morpheme shape itself lives in
// emit_unknown_from_node - the greedy path has no lattice, so this
// eager resolver feeds a scratch node carrying the resolved rule
// values through it.
emit_unknown :: proc(a: ^Analyzer, text: string, start: int, end: int) -> Morpheme {
	surface := text[start:end]
	class := char_class_of(&a.char_class, first_rune_of(text, start))
	joined_pos, cost, _, _ := resolve_unk(a, class, surface)
	node := Lattice_Node{
		start      = start,
		end        = end,
		entry_id   = -1,
		is_unknown = true,
		class      = class,
		pos        = joined_pos,
		cost       = cost,
	}
	return emit_unknown_from_node(a, text, &node)
}

// unk_pattern_matches reports whether one surface-pattern row matches
// an unknown candidate's surface: by prefix, by suffix, or by the char
// class of every rune it carries.
unk_pattern_matches :: proc(p: Unk_Pattern, t: ^Char_Class_Table, surface: string) -> bool {
	switch p.kind {
	case .Prefix: return strings.has_prefix(surface, p.pat)
	case .Suffix: return strings.has_suffix(surface, p.pat)
	case .Charset:
		for r in surface {
			if char_class_of(t, r) != p.class { return false }
		}
		return true
	}
	return false
}

// resolve_unk applies the one resolution ladder to an unknown
// candidate's class and surface: surface patterns in declaration order
// first (a surface shape is stronger evidence than a first-rune
// class), then the unk rules in declaration order, then the analyzer's
// fallback POS with zero cost and zero ids.
resolve_unk :: proc(a: ^Analyzer, class: Char_Class, surface: string) -> (joined_pos: string, cost: i16, left_id: i16, right_id: i16) {
	for pattern in a.unk_patterns {
		if unk_pattern_matches(pattern, &a.char_class, surface) {
			return pattern.joined_pos, pattern.cost, pattern.left_id, pattern.right_id
		}
	}
	for rule in a.unk_def {
		if rule.class == class {
			return rule.joined_pos, rule.cost, rule.left_id, rule.right_id
		}
	}
	return a.unknown_fallback_pos, 0, 0, 0
}

// first_rune_of decodes the rune at a byte offset; malformed input
// decodes as RUNE_ERROR, which classifies as .Unknown.
first_rune_of :: proc(text: string, pos: int) -> rune {
	if pos < 0 || pos >= len(text) { return utf8.RUNE_ERROR }
	r, _ := utf8.decode_rune_in_string(text[pos:])
	return r
}
