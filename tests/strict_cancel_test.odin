// Strict input and cancellation: the two opt-in contracts that let an
// embedder reject malformed text instead of degrading on it, and stop
// a running tokenize when a request deadline fires. The rejection and
// unwind semantics (offsets index the caller's original text; a token
// cancelled before the call bounces at offset 0; morphemes appended
// before a mid-walk unwind stay written) are the analyzer's public
// error contract, so every leg here pins one of those sentences.
package tests

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:thread"
import "moli:moli"

// expect_malformed asserts err is Malformed_Input_Error at want_off.
expect_malformed :: proc(t: ^testing.T, err: moli.Tokenize_Err, want_off: int) -> bool {
	if err == nil {
		testing.expectf(t, false, "input must be rejected (want offset %d)", want_off)
		return false
	}
	switch e in err {
	case moli.Malformed_Input_Error:
		if e.byte_offset != want_off {
			testing.expectf(t, false, "malformed at %d, want %d", e.byte_offset, want_off)
			return false
		}
	case moli.Cancelled_Error:
		testing.expectf(t, false, "want Malformed_Input_Error, got Cancelled_Error at %d", e.byte_offset)
		return false
	case moli.Tokenize_Fault:
		testing.expectf(t, false, "want Malformed_Input_Error, got fault %v", e)
		return false
	case moli.Bad_Constraint_Error, moli.Unsatisfiable_Error:
		testing.expectf(t, false, "want Malformed_Input_Error, got %v", e)
		return false
	}
	return true
}

// expect_cancelled_at_zero asserts err is Cancelled_Error{byte_offset = 0}
// — the pre-cancelled bounce: the first poll precedes the first append.
expect_cancelled_at_zero :: proc(t: ^testing.T, err: moli.Tokenize_Err) -> bool {
	if err == nil {
		testing.expect(t, false, "pre-cancelled call must bounce")
		return false
	}
	switch e in err {
	case moli.Cancelled_Error:
		if e.byte_offset != 0 {
			testing.expectf(t, false, "pre-cancelled offset %d, want 0", e.byte_offset)
			return false
		}
	case moli.Malformed_Input_Error:
		testing.expectf(t, false, "want Cancelled_Error, got Malformed_Input_Error at %d", e.byte_offset)
		return false
	case moli.Tokenize_Fault:
		testing.expectf(t, false, "want Cancelled_Error, got fault %v", e)
		return false
	case moli.Bad_Constraint_Error, moli.Unsatisfiable_Error:
		testing.expectf(t, false, "want Cancelled_Error, got %v", e)
		return false
	}
	return true
}

@(test)
strict_rejects_invalid_utf8_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	allocator := runtime.default_allocator()

	// A lone continuation byte after four 3-byte runes: offset 12.
	bad := "さくらが\x81咲いた"
	_, err := moli.tokenize_opt(&a, bad, moli.Tokenize_Options{strict_utf8 = true}, allocator)
	if !expect_malformed(t, err, 12) { return }

	// A 3-byte sequence truncated at the text's end: offset 6.
	trunc := "犬が\xe3\x81"
	_, terr := moli.tokenize_opt(&a, trunc, moli.Tokenize_Options{strict_utf8 = true}, allocator)
	if !expect_malformed(t, terr, 6) { return }

	// The default still degrades: same bytes, no flag, no error.
	ms, derr := moli.tokenize_opt(&a, bad, moli.Tokenize_Options{}, allocator)
	if derr != nil || len(ms) == 0 {
		testing.expectf(t, false, "default must degrade, got err=%v len=%d", derr, len(ms))
	}

	// LongestMatch rejects through the same pre-pass (mode-independent).
	ga, gok := load_ok(t, .Japanese, IPADIC_FIXTURE, moli.Load_Options{mode = .LongestMatch})
	if !gok { return }
	defer moli.free(&ga)
	_, gerr := moli.tokenize_opt(&ga, bad, moli.Tokenize_Options{strict_utf8 = true}, allocator)
	if !expect_malformed(t, gerr, 12) { return }
}

@(test)
strict_passes_replacement_char_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	// A genuine U+FFFD encodes as 3 valid bytes; strict input rejects
	// only sequences that fail to decode, so this must pass.
	good := "さ\uFFFDく"
	ms, err := moli.tokenize_opt(&a, good, moli.Tokenize_Options{strict_utf8 = true}, runtime.default_allocator())
	if err != nil {
		testing.expectf(t, false, "genuine U+FFFD is valid UTF-8: %v", err)
		return
	}
	testing.expect(t, len(ms) > 0, "replacement-char text must tokenize")
}

@(test)
strict_all_opt_procs_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	allocator := runtime.default_allocator()
	bad := "さくらが\x81咲いた" // invalid at 12

	out: [dynamic]moli.Morpheme
	if ierr := moli.tokenize_into_opt(&a, bad, moli.Tokenize_Options{strict_utf8 = true}, &out, allocator); !expect_malformed(t, ierr, 12) {
		return
	}
	testing.expect(t, len(out) == 0, "rejection must append nothing")

	_, werr := moli.tokenize_wakachi_opt(&a, bad, moli.Tokenize_Options{strict_utf8 = true}, allocator)
	if !expect_malformed(t, werr, 12) { return }

	paths: [dynamic]moli.NBest_Path
	nerr := moli.tokenize_nbest(&a, bad, 3, moli.Tokenize_Options{strict_utf8 = true}, moli.Constraints{}, &paths, allocator)
	if !expect_malformed(t, nerr, 12) { return }
	testing.expect(t, len(paths) == 0, "rejection must enumerate nothing")
}

// A faulted call must not leave a previous call's results in the
// sink: the n-best sink is cleared at entry, before the request
// prelude (the tokenize_into_opt discipline).
@(test)
nbest_sink_cleared_on_fault_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	paths := make([dynamic]moli.NBest_Path, 0, 2, arena_alloc)
	if err := moli.tokenize_nbest(&a, "犬が歩く", 2, {}, moli.Constraints{}, &paths, arena_alloc); err != nil {
		testing.expectf(t, false, "prefill nbest: %v", err)
		return
	}
	testing.expect(t, len(paths) > 0, "prefill must enumerate paths")

	bad := "さくらが\x81咲いた" // invalid at 12
	nerr := moli.tokenize_nbest(&a, bad, 3, moli.Tokenize_Options{strict_utf8 = true}, moli.Constraints{}, &paths, arena_alloc)
	if !expect_malformed(t, nerr, 12) { return }
	testing.expect(t, len(paths) == 0, "the strict rejection must clear the previous call's paths")
}

@(test)
strict_before_normalization_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	// Decomposed が (か + U+3099) followed by 0xFF at original offset 6.
	// The strict check runs before NFC normalization, so the offset
	// indexes the caller's text; had normalization run first, the
	// composed copy would place the bad byte at 3.
	decomp := "か\u3099\xff"
	_, err := moli.tokenize_opt(&a, decomp, {normalize_nfc = true, strict_utf8 = true}, runtime.default_allocator())
	if !expect_malformed(t, err, 6) { return }
}

@(test)
cancel_before_call_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	allocator := runtime.default_allocator()
	tok := moli.Cancel_Token{}
	moli.cancel(&tok)
	opts := moli.Tokenize_Options{cancel_token = &tok}

	_, err := moli.tokenize_opt(&a, "犬が歩く", opts, allocator)
	if !expect_cancelled_at_zero(t, err) { return }

	out: [dynamic]moli.Morpheme
	if ierr := moli.tokenize_into_opt(&a, "犬が歩く", opts, &out, allocator); !expect_cancelled_at_zero(t, ierr) {
		return
	}
	testing.expect(t, len(out) == 0, "pre-cancelled call must append nothing")

	_, werr := moli.tokenize_wakachi_opt(&a, "犬が歩く", opts, allocator)
	if !expect_cancelled_at_zero(t, werr) { return }

	paths: [dynamic]moli.NBest_Path
	if nerr := moli.tokenize_nbest(&a, "犬が歩く", 3, opts, moli.Constraints{}, &paths, allocator); !expect_cancelled_at_zero(t, nerr) {
		return
	}

	// Empty text never enters the walk loop (the walk poll lives
	// inside it), so the first poll an n-best call reaches is the
	// enumeration's own - once per heap pop. The pre-cancelled token
	// unwinds there, at BOS's offset 0, instead of enumerating the
	// empty path.
	empty: [dynamic]moli.NBest_Path
	if eerr := moli.tokenize_nbest(&a, "", 1, opts, moli.Constraints{}, &empty, allocator); !expect_cancelled_at_zero(t, eerr) {
		return
	}

	// The greedy walk polls at the same first iteration.
	ga, gok := load_ok(t, .Japanese, IPADIC_FIXTURE, moli.Load_Options{mode = .LongestMatch})
	if !gok { return }
	defer moli.free(&ga)
	_, gerr := moli.tokenize_opt(&ga, "犬が歩く", opts, allocator)
	if !expect_cancelled_at_zero(t, gerr) { return }
}

@(test)
cancel_live_token_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	allocator := runtime.default_allocator()
	// A live token the call never observes as cancelled behaves exactly
	// like no token: same error (none) and same segmentation.
	tok := moli.Cancel_Token{}
	want, werr := moli.tokenize(&a, "犬が歩く", allocator)
	if werr != nil {
		testing.expectf(t, false, "plain tokenize: %v", werr)
		return
	}
	got, gerr := moli.tokenize_opt(&a, "犬が歩く", moli.Tokenize_Options{cancel_token = &tok}, allocator)
	if gerr != nil {
		testing.expectf(t, false, "live token must not cancel: %v", gerr)
		return
	}
	if len(got) != len(want) {
		testing.expectf(t, false, "live token len %d, want %d", len(got), len(want))
		return
	}
	for m, i in got {
		if m.surface != want[i].surface {
			testing.expectf(t, false, "morph %d: %s, want %s", i, m.surface, want[i].surface)
			return
		}
	}
}

// Cancel_Worker carries one thread's call and its result; the pointer
// rides in Thread.data (the concurrent-tokenize precedent).
Cancel_Worker :: struct {
	a:       ^moli.Analyzer,
	text:    string,
	tok:     ^moli.Cancel_Token,
	err:     moli.Tokenize_Err,
	entered: bool, // atomic: set right before the worker enters tokenize
}

// cancel_worker_proc runs one tokenize_opt over the big text with the
// shared token. The arena rides a heap buffer sized for the worst-case
// output; join gives the main thread the happens-before edge for err.
cancel_worker_proc :: proc(th: ^thread.Thread) {
	w := cast(^Cancel_Worker)(th.data)
	buf := make([]u8, CANCEL_ARENA_BYTES, runtime.default_allocator())
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	intrinsics.atomic_store_explicit(&w.entered, true, .Release)
	_, w.err = moli.tokenize_opt(w.a, w.text, moli.Tokenize_Options{cancel_token = w.tok}, mem.arena_allocator(&arena))
	delete(buf, runtime.default_allocator())
}

// cancel_mid_walk_leg runs one thread that tokenizes a large input
// while the main thread cancels the shared token, and asserts the
// interleaving invariant: the call either completes before the cancel
// is observed or unwinds with an in-bounds Cancelled_Error - never
// corrupts, never hangs, never leaves the analyzer unusable. The
// bounded yield wait below is entry synchronization, not a forcing
// primitive: the cancel fires after the worker announced it is about
// to enter tokenize, so the long walk is the interleaving actually
// exercised (the cancel landing between the announcement and the first
// poll remains possible on any scheduler, which is why the assertions
// below are race-tolerant by design - cross-thread forcing would need
// a walk-side hook the Cancel_Token does not offer).
cancel_mid_walk_leg :: proc(t: ^testing.T, a: ^moli.Analyzer, text: string, tok: ^moli.Cancel_Token) {
	w := Cancel_Worker{a = a, text = text, tok = tok}
	th := thread.create(cancel_worker_proc)
	th.data = cast(rawptr)(&w)
	thread.start(th)
	for i in 0 ..< 1_000_000 {
		if intrinsics.atomic_load_explicit(&w.entered, .Acquire) { break }
		thread.yield()
	}
	moli.cancel(tok)
	thread.join(th)
	thread.destroy(th)

	if w.err != nil {
		switch e in w.err {
		case moli.Cancelled_Error:
			if e.byte_offset < 0 || e.byte_offset > len(text) {
				testing.expectf(t, false, "cancel offset %d out of [0, %d]", e.byte_offset, len(text))
				return
			}
		case moli.Malformed_Input_Error:
			testing.expectf(t, false, "mid-walk unwind must be Cancelled_Error, got Malformed_Input_Error at %d", e.byte_offset)
			return
		case moli.Tokenize_Fault:
			testing.expectf(t, false, "mid-walk unwind must be Cancelled_Error, got fault %v", e)
			return
		case moli.Bad_Constraint_Error, moli.Unsatisfiable_Error:
			testing.expectf(t, false, "mid-walk unwind must be Cancelled_Error, got %v", e)
			return
		}
	}

	// The analyzer must still serve: in_use drained, state untouched.
	buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	ms, err := moli.tokenize(a, "犬が歩く", mem.arena_allocator(&arena))
	if err != nil || len(ms) != 3 {
		testing.expectf(t, false, "analyzer unhealthy after cancel: err=%v len=%d", err, len(ms))
	}
}

// The worker's arena must survive the worst-case output of either leg
// - every morpheme of the greedy leg's 70,000-repeat text (five
// morphemes per repeat at size_of(moli.Morpheme) bytes each - about
// 45 MB - plus the walk's scratch) - so an unwind never fails for
// arena-exhaustion reasons of the test's own making; 160 MiB leaves
// that several times over.
CANCEL_ARENA_BYTES :: int(160 * 1024 * 1024)

@(test)
cancel_mid_walk_greedy_test :: proc(t: ^testing.T) {
	ga, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, moli.Load_Options{mode = .LongestMatch})
	if !ok { return }
	defer moli.free(&ga)

	big, berr := strings.repeat("犬が歩く。", 70_000)
	if berr != nil {
		testing.expectf(t, false, "repeat: %v", berr)
		return
	}
	defer delete(big)

	tok := moli.Cancel_Token{}
	cancel_mid_walk_leg(t, &ga, big, &tok)
}

@(test)
cancel_mid_walk_viterbi_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	big, berr := strings.repeat("犬が歩く。", 7_000)
	if berr != nil {
		testing.expectf(t, false, "repeat: %v", berr)
		return
	}
	defer delete(big)

	tok := moli.Cancel_Token{}
	cancel_mid_walk_leg(t, &a, big, &tok)
}

@(test)
wakachi_opt_zero_equals_plain_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	allocator := runtime.default_allocator()
	want, werr := moli.tokenize_wakachi(&a, "犬が歩くさくら", allocator)
	if werr != nil {
		testing.expectf(t, false, "plain wakachi: %v", werr)
		return
	}
	got, gerr := moli.tokenize_wakachi_opt(&a, "犬が歩くさくら", moli.Tokenize_Options{}, allocator)
	if gerr != nil {
		testing.expectf(t, false, "wakachi_opt zero opts: %v", gerr)
		return
	}
	if len(got) != len(want) {
		testing.expectf(t, false, "len %d, want %d", len(got), len(want))
		return
	}
	for s, i in got {
		if s != want[i] {
			testing.expectf(t, false, "surface %d: %s, want %s", i, s, want[i])
			return
		}
	}

	// And the opt contract composes: strict rejection, live pre-pass.
	bad := "犬が\x81歩く"
	if _, serr := moli.tokenize_wakachi_opt(&a, bad, moli.Tokenize_Options{strict_utf8 = true}, allocator); serr == nil {
		testing.expect(t, false, "wakachi_opt strict must reject invalid UTF-8")
	}
}
