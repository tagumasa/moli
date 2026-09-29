// Analyzer end-to-end coverage: smoke runs in both modes for every
// locale fixture, the load -> tokenize -> free cycle under the
// leak-check discipline, concurrent tokenize from multiple threads on
// one shared analyzer, the in-use drain under the injected wait hook,
// the acquire re-check storm (a mutating-flag flip racing an in-flight
// acquire), skipped_resources recording, and the allocation-failure
// legs of load's own setup.
package tests

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:thread"
import "moli:moli"

@(test)
analyzer_both_modes_smoke_test :: proc(t: ^testing.T) {
	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	greedy := moli.Load_Options{mode = .LongestMatch}
	viterbi := moli.Load_Options{mode = .Viterbi}

	// Japanese, both modes.
	ga, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, greedy)
	if !ok { return }
	defer moli.free(&ga)
	va, ok2 := load_ok(t, .Japanese, IPADIC_FIXTURE, viterbi)
	if !ok2 { return }
	defer moli.free(&va)
	analyzers := [2]^moli.Analyzer{&ga, &va}
	for a in analyzers {
		ms, err := moli.tokenize(a, "犬が歩く", arena_alloc)
		if err != nil {
			testing.expectf(t, false, "jp tokenize: %v", err)
			return
		}
		if len(ms) != 3 || ms[0].surface != "犬" || ms[1].surface != "が" || ms[2].surface != "歩く" {
			testing.expectf(t, false, "jp segmentation: %v morphemes", len(ms))
			return
		}
	}

	// ZH-CN (sampled jieba fixture: both words in vocabulary), ZH-TW,
	// ZH-HK, EN.
	cn, ok3 := load_ok(t, .ChineseCN, JIEBA_FIXTURE, greedy)
	if !ok3 { return }
	defer moli.free(&cn)
	ms, err := moli.tokenize(&cn, "库东类书籍", arena_alloc)
	if err != nil {
		testing.expectf(t, false, "cn tokenize: %v", err)
		return
	}
	if len(ms) != 2 || ms[0].surface != "库东" || ms[1].surface != "类书籍" {
		testing.expectf(t, false, "cn segmentation: %v morphemes", len(ms))
		return
	}

	tw, ok4 := load_ok(t, .ChineseTW, JIEBA_TW_FIXTURE, greedy)
	if !ok4 { return }
	defer moli.free(&tw)
	ms, err = moli.tokenize(&tw, "台北市", arena_alloc)
	if err != nil {
		testing.expectf(t, false, "tw tokenize: %v", err)
		return
	}
	if len(ms) != 2 || ms[0].surface != "台北" || ms[1].surface != "市" {
		testing.expectf(t, false, "tw segmentation: %v morphemes", len(ms))
		return
	}

	hk, ok5 := load_ok(t, .ChineseHK, JIEBA_HK_FIXTURE, greedy)
	if !ok5 { return }
	defer moli.free(&hk)
	ms, err = moli.tokenize(&hk, "香港島", arena_alloc)
	if err != nil {
		testing.expectf(t, false, "hk tokenize: %v", err)
		return
	}
	if len(ms) != 2 || ms[0].surface != "香港" || ms[1].surface != "島" {
		testing.expectf(t, false, "hk segmentation: %v morphemes", len(ms))
		return
	}

	en, ok6 := load_ok(t, .EnglishGB, EN_FIXTURE, greedy)
	if !ok6 { return }
	defer moli.free(&en)
	ms, err = moli.tokenize(&en, "colour travels", arena_alloc)
	if err != nil {
		testing.expectf(t, false, "en tokenize: %v", err)
		return
	}
	// The inter-word space is its own unknown morpheme.
	if len(ms) != 3 || ms[0].surface != "colour" || ms[2].surface != "travels" {
		testing.expectf(t, false, "en segmentation: %v morphemes", len(ms))
		return
	}

	// The CRLF jieba fixture loads and its readings are clean of
	// terminator bytes.
	crlf, ok7 := load_ok(t, .ChineseCN, JIEBA_CRLF_FIXTURE, greedy)
	if !ok7 { return }
	defer moli.free(&crlf)
	ms, err = moli.tokenize(&crlf, "库东", arena_alloc)
	if err != nil {
		testing.expectf(t, false, "crlf tokenize: %v", err)
		return
	}
	if len(ms) != 1 || ms[0].surface != "库东" {
		testing.expectf(t, false, "crlf segmentation: %v morphemes", len(ms))
		return
	}

	// EnglishUS shares the EN fixture: the US spelling loads through
	// the same schema.
	us, ok8 := load_ok(t, .EnglishUS, EN_FIXTURE, greedy)
	if !ok8 { return }
	defer moli.free(&us)
	ms, err = moli.tokenize(&us, "center quickly", arena_alloc)
	if err != nil {
		testing.expectf(t, false, "us tokenize: %v", err)
		return
	}
	if len(ms) != 3 || ms[0].surface != "center" || ms[2].surface != "quickly" {
		testing.expectf(t, false, "us segmentation: %v morphemes", len(ms))
		return
	}
}

@(test)
analyzer_load_tokenize_free_cycle_test :: proc(t: ^testing.T) {
	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	// Two full cycles on the same dictionary: everything load claims
	// is released by free, and the second load sees a clean slate.
	for _ in 0 ..< 2 {
		a, ok := load_ok(t, .ChineseCN, JIEBA_FIXTURE, {})
		if !ok { return }
		ms, err := moli.tokenize(&a, "库东类书籍", arena_alloc)
		if err != nil {
			testing.expectf(t, false, "tokenize: %v", err)
			moli.free(&a)
			return
		}
		if len(ms) != 2 {
			testing.expectf(t, false, "segmentation: %v morphemes", len(ms))
			moli.free(&a)
			return
		}
		ws, err2 := moli.tokenize_wakachi(&a, "库东类书籍", arena_alloc)
		if err2 != nil || len(ws) != 2 {
			testing.expectf(t, false, "wakachi: (%v, %v)", len(ws), err2)
			moli.free(&a)
			return
		}
		out: [dynamic]moli.Morpheme
		out.allocator = arena_alloc
		if err := moli.tokenize_into(&a, "库东", &out, arena_alloc); err != nil {
			testing.expectf(t, false, "tokenize_into: %v", err)
			moli.free(&a)
			return
		}
		if len(out) != 1 || out[0].surface != "库东" {
			testing.expectf(t, false, "tokenize_into result: %v", len(out))
			moli.free(&a)
			return
		}
		moli.free(&a)
	}
}

// Concurrent_Worker carries one thread's input and results; the
// pointer rides in Thread.data.
Concurrent_Worker :: struct {
	a:  ^moli.Analyzer,
	ok: ^bool,
}

// concurrent_worker_proc tokenizes a fixed input on the shared
// analyzer with its own stack arena and records whether the result
// matches the expected segmentation.
concurrent_worker_proc :: proc(th: ^thread.Thread) {
	w := cast(^Concurrent_Worker)(th.data)
	buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])

	ms, err := moli.tokenize(w.a, "犬が歩く", mem.arena_allocator(&arena))
	w.ok^ = err == nil && len(ms) == 3 &&
		ms[0].surface == "犬" && ms[1].surface == "が" && ms[2].surface == "歩く"
}

@(test)
analyzer_concurrent_tokenize_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	N_THREADS :: 4
	oks: [N_THREADS]bool
	workers: [N_THREADS]Concurrent_Worker
	threads: [N_THREADS]^thread.Thread
	for i in 0 ..< N_THREADS {
		oks[i] = false
		workers[i] = Concurrent_Worker{a = &a, ok = &oks[i]}
		threads[i] = thread.create(concurrent_worker_proc)
		threads[i].data = cast(rawptr)(&workers[i])
	}
	for i in 0 ..< N_THREADS {
		thread.start(threads[i])
	}
	for i in 0 ..< N_THREADS {
		thread.join(threads[i])
	}
	for i in 0 ..< N_THREADS {
		thread.destroy(threads[i])
	}

	for o, i in oks {
		if !o {
			testing.expectf(t, false, "worker %v saw wrong results", i)
			return
		}
	}
}

// The acquire re-check window: a flag flip landing between an acquire's
// first check and its re-check must bounce the call with in_use left
// balanced. Single-threaded tests cannot reach the re-check - the same
// values read twice cannot change - so the storm overlaps two threads:
// one hammers acquire/release, the other flips the mutating flag (the
// reversible one; teardown is never unset). Each polarity is held
// across a yield: a fully cooperative scheduler (valgrind serializes
// threads, so a yield is the only reschedule point) then hands the
// hammerer a slice inside both holds; on a
// preemptive scheduler the flips land inside live acquire windows too,
// which is the interleaving the re-check exists for. Loop bounds
// replace any timing wait. From outside an early bounce and a re-check
// bounce look identical - and a serializing profiler can never observe
// the re-check, because the flip cannot land mid-instruction-sequence
// - so the test asserts the protocol invariant instead: every call
// either registers and releases or bounces, both polarities are
// sampled, in_use drains to exactly zero, and the analyzer still
// tokenizes afterwards.
Acquire_Storm :: struct {
	a:          ^moli.Analyzer,
	iterations: int,
	accepted:   int,
	bounced:    int,
}

acquire_storm_hammerer :: proc(th: ^thread.Thread) {
	s := cast(^Acquire_Storm)(th.data)
	for i in 0 ..< s.iterations {
		if moli.acquire(s.a) {
			s.accepted += 1
			moli.release(s.a)
		} else {
			s.bounced += 1
		}
		if i % 256 == 0 {
			thread.yield()
		}
	}
}

acquire_storm_flipper :: proc(th: ^thread.Thread) {
	s := cast(^Acquire_Storm)(th.data)
	// Both halves of a round hold their polarity across the yield in
	// the middle; the atomic loads cannot be elided, so the holds are
	// real work, and the yield guarantees a cooperative scheduler
	// schedules the hammerer inside each polarity at least once.
	HOLD :: 32
	for _ in 0 ..< s.iterations / 128 {
		intrinsics.atomic_store_explicit(&s.a.mutating, true, .Release)
		for _ in 0 ..< HOLD {
			_ = intrinsics.atomic_load_explicit(&s.a.mutating, .Acquire)
		}
		thread.yield()
		for _ in 0 ..< HOLD {
			_ = intrinsics.atomic_load_explicit(&s.a.mutating, .Acquire)
		}
		intrinsics.atomic_store_explicit(&s.a.mutating, false, .Release)
		for _ in 0 ..< HOLD {
			_ = intrinsics.atomic_load_explicit(&s.a.mutating, .Acquire)
		}
		thread.yield()
		for _ in 0 ..< HOLD {
			_ = intrinsics.atomic_load_explicit(&s.a.mutating, .Acquire)
		}
	}
}

@(test)
analyzer_skipped_resources_test :: proc(t: ^testing.T) {
	// Fixture-root loads see no sibling resources: all four are
	// recorded, never silent.
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	if len(a.skipped_resources) != 4 {
		testing.expectf(t, false, "skipped: %v (want 4)", len(a.skipped_resources))
		return
	}
	found_unk, found_char, found_matrix, found_qpat := false, false, false, false
	for s in a.skipped_resources {
		if s == "unk.def" { found_unk = true }
		if s == "char.def" { found_char = true }
		if s == "matrix.def" { found_matrix = true }
		if s == "patterns.qpat" { found_qpat = true }
	}
	if !found_unk || !found_char || !found_matrix || !found_qpat {
		testing.expectf(t, false, "skipped names are not unk.def/char.def/matrix.def/patterns.qpat")
		return
	}
	if len(a.unk_patterns) != 0 {
		testing.expectf(t, false, "absent patterns.qpat must load zero rows, got %v", len(a.unk_patterns))
		return
	}

	// The resources/ fixture carries all four siblings: nothing is
	// skipped and the resources are actually loaded (the unk rule
	// changes unknown-run POS, the patterns refine it further).
	b, ok2 := load_ok(t, .Japanese, RESOURCES_FIXTURE, {})
	if !ok2 { return }
	defer moli.free(&b)

	if len(b.skipped_resources) != 0 {
		testing.expectf(t, false, "resources dir: %v skipped", len(b.skipped_resources))
		return
	}
	if len(b.unk_def) != 2 {
		testing.expectf(t, false, "unk rules loaded: %v", len(b.unk_def))
		return
	}
	if len(b.unk_patterns) != 2 {
		testing.expectf(t, false, "patterns loaded: %v", len(b.unk_patterns))
		return
	}

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	ms, err := moli.tokenize(&b, "ケケケ", mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "tokenize: %v", err)
		return
	}
	// KATAKANA rule: 名詞,一般 with cost 4000 - the fallback would
	// answer 名詞,普通名詞, and no pattern row fires on ケケケ.
	if len(ms) != 1 || ms[0].pos != "名詞,一般" || ms[0].cost != 4000 {
		testing.expectf(t, false, "katakana unknown via rule: %d morphemes (want 1 with pos 名詞,一般, cost 4000)", len(ms))
		return
	}
}

// The three collections load makes up front must fail cleanly: a
// starved budget at 0..3 hits those makes first (and spills into the
// import clones), and every failure runs the same partial-teardown
// release as any later leg - the leak gate polices it.
@(test)
load_make_oom_test :: proc(t: ^testing.T) {
	for budget in 0 ..< 4 {
		b := Budget_Allocator{backing = context.allocator, remaining = budget}
		allocator := mem.Allocator{data = &b, procedure = budget_allocator_proc}
		_, err := moli.load(.Japanese, IPADIC_FIXTURE, {}, allocator)
		testing.expectf(t, err == moli.Load_Fault.OutOfMemory,
			"budget %d: load must fail with .OutOfMemory, got %v", budget, err)
	}
}

// A call arriving after free must bounce with .Unavailable instead of
// touching freed memory - the teardown half of the acquire contract
// (the mutating flag's bounce is covered in user_dict_test).
@(test)
tokenize_after_free_bounce_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	_, err := moli.tokenize(&a, "犬が歩く", mem.arena_allocator(&arena))
	testing.expectf(t, err == .Unavailable, "tokenize after free bounces, got %v", err)
	_, werr := moli.tokenize_wakachi(&a, "犬が歩く", mem.arena_allocator(&arena))
	testing.expectf(t, werr == .Unavailable, "wakachi after free bounces, got %v", werr)
}

// The in-use drain: free must wait for a held call instead of
// destroying under it. The test registers the call directly with
// acquire and lets the injected wait hook release it on the second
// poll - free returning at all proves the drain really waited (with
// the hook inert the loop would never exit), and the bounce after
// proves teardown completed only then.
@(test)
free_drains_in_flight_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	if !moli.acquire(&a) {
		testing.expectf(t, false, "acquire on a fresh analyzer must succeed")
		return
	}
	a.drain_wait = drain_release_at_second_poll
	moli.free(&a)

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	_, err := moli.tokenize(&a, "犬が歩く", mem.arena_allocator(&arena))
	testing.expectf(t, err == .Unavailable, "tokenize after a drained free, got %v", err)
}

@(test)
acquire_recheck_storm_test :: proc(t: ^testing.T) {
	a, ok := load_ok(t, .Japanese, IPADIC_FIXTURE, {})
	if !ok { return }
	defer moli.free(&a)

	storm: Acquire_Storm
	storm.a = &a
	storm.iterations = 1_000_000

	hammerer := thread.create(acquire_storm_hammerer)
	hammerer.data = cast(rawptr)(&storm)
	flipper := thread.create(acquire_storm_flipper)
	flipper.data = cast(rawptr)(&storm)
	thread.start(hammerer)
	thread.start(flipper)
	thread.join(hammerer)
	thread.join(flipper)
	thread.destroy(hammerer)
	thread.destroy(flipper)

	if storm.accepted + storm.bounced != storm.iterations {
		testing.expectf(t, false, "storm lost calls: %v accepted + %v bounced != %v",
			storm.accepted, storm.bounced, storm.iterations)
		return
	}
	if storm.accepted == 0 || storm.bounced == 0 {
		testing.expectf(t, false,
			"storm must sample both flag polarities: accepted %v, bounced %v",
			storm.accepted, storm.bounced)
		return
	}
	if in_use := intrinsics.atomic_load_explicit(&a.in_use, .Acquire); in_use != 0 {
		testing.expectf(t, false, "in_use must drain to zero after the storm, got %v", in_use)
		return
	}

	// The analyzer must come out of the storm untouched.
	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	ms, err := moli.tokenize(&a, "犬が歩く", mem.arena_allocator(&arena))
	testing.expectf(t, err == nil && len(ms) == 3,
		"tokenize after the storm: %v (%v morphemes)", err, len(ms))
}

// The in-memory CSV entry: same analyzer as the file entry, and no
// sibling filesystem - the optional resources the file entry would
// discover next to the CSV degrade to defaults, each recorded in
// skipped_resources, while an explicitly configured resource path is
// still honored.
@(test)
load_bytes_equivalence_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()
	data, derr := os.read_entire_file(IPADIC_FIXTURE, allocator)
	if derr != nil {
		testing.expectf(t, false, "read fixture: %v", derr)
		return
	}
	defer delete(data, allocator) // load_bytes borrows; the caller keeps it

	a, lerr := moli.load_bytes(.Japanese, data, {}, allocator)
	if lerr != nil {
		testing.expectf(t, false, "load_bytes: %v", lerr)
		return
	}
	defer moli.free(&a)

	if len(a.skipped_resources) != 4 {
		testing.expectf(t, false, "bytes mode records every undiscovered resource, got %v",
			len(a.skipped_resources))
		return
	}
	for res in a.skipped_resources {
		if res != "unk.def" && res != "char.def" && res != "matrix.def" && res != "patterns.qpat" {
			testing.expectf(t, false, "unexpected skipped resource %s", res)
			return
		}
	}

	arena_buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	ms, err := moli.tokenize(&a, "犬が歩く", mem.arena_allocator(&arena))
	if err != nil {
		testing.expectf(t, false, "tokenize(load_bytes): %v", err)
		return
	}
	testing.expectf(t, len(ms) == 3 && ms[0].surface == "犬" && ms[1].surface == "が" && ms[2].surface == "歩く",
		"bytes-loaded segmentation: %v morphemes", len(ms))

	// An explicitly configured resource path is honored even without a
	// filesystem sibling: unk.def loads, so it is not recorded.
	b, berr := moli.load_bytes(.Japanese, data, {unk_def_path = "tests/fixtures/resources/unk.def"}, allocator)
	if berr != nil {
		testing.expectf(t, false, "load_bytes(override): %v", berr)
		return
	}
	defer moli.free(&b)
	for res in b.skipped_resources {
		if res == "unk.def" {
			testing.expectf(t, false, "explicit unk_def_path must be honored in bytes mode")
			return
		}
	}
}

// Malformed bytes reject through the public in-memory boundary with
// the same kinds as files: an empty image, and a row whose column
// count matches no schema.
@(test)
load_bytes_malformed_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()
	if _, err := moli.load_bytes(.Japanese, []u8{}, {}, allocator); err == nil {
		testing.expectf(t, false, "empty bytes must reject")
		return
	}
	bad_line := "too,few,columns"
	bad := transmute([]byte)bad_line
	if _, err := moli.load_bytes(.Japanese, bad, {}, allocator); err == nil {
		testing.expectf(t, false, "schema-less row must reject")
		return
	}
}

// The nil guards of the public surface: free on a nil analyzer is a
// no-op, and add_user_entries bounces with .Nil_Handle before touching
// anything.
@(test)
nil_handle_guards_test :: proc(t: ^testing.T) {
	moli.free(nil)
	if err := moli.add_user_entries(nil, nil); err != .Nil_Handle {
		testing.expectf(t, false, "add_user_entries(nil): %v", err)
		return
	}
}

// discover_sibling_path's four branches, directly: an explicit path
// that exists (cloned through scratch_allocator), one that does not (quiet
// not-found), an empty csv_path (load_bytes: nothing to join against),
// and the canonical join next to the CSV.
@(test)
sibling_path_discovery_test :: proc(t: ^testing.T) {
	// filepath.join's internal clean_path leaves an intermediate
	// allocation behind, so the whole test's scratch_allocator runs on one arena.
	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena)
	defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch_allocator := mem.dynamic_arena_allocator(&scratch_arena)

	p, ok, err := moli.discover_sibling_path("", "tests/fixtures/README.md", "char.def", scratch_allocator)
	if err != nil || !ok || p != "tests/fixtures/README.md" {
		testing.expectf(t, false, "explicit present: ok=%v err=%v p=%q", ok, err, p)
		return
	}

	p2, ok2, err2 := moli.discover_sibling_path("", "tests/fixtures/absent.def", "char.def", scratch_allocator)
	if err2 != nil || ok2 || p2 != "" {
		testing.expectf(t, false, "explicit absent: ok=%v err=%v p2=%q", ok2, err2, p2)
		return
	}

	p3, ok3, err3 := moli.discover_sibling_path("", "", "char.def", scratch_allocator)
	if err3 != nil || ok3 || p3 != "" {
		testing.expectf(t, false, "empty csv_path: ok=%v err=%v p3=%q", ok3, err3, p3)
		return
	}

	// The canonical join normalizes to the platform separator
	// (Windows answers "tests\fixtures\README.md"), so the expectation
	// is built with the same filepath.join rather than a hardcoded
	// forward-slash string.
	want4, werr4 := filepath.join({"tests", "fixtures", "README.md"}, scratch_allocator)
	if werr4 != nil {
		testing.expectf(t, false, "join expectation: %v", werr4)
		return
	}
	p4, ok4, err4 := moli.discover_sibling_path(IPADIC_FIXTURE, "", "README.md", scratch_allocator)
	if err4 != nil || !ok4 || p4 != want4 {
		testing.expectf(t, false, "canonical join: ok=%v err=%v p4=%q", ok4, err4, p4)
		return
	}

	p5, ok5, err5 := moli.discover_sibling_path(IPADIC_FIXTURE, "", "no_such.def", scratch_allocator)
	if err5 != nil || ok5 || p5 != "" {
		testing.expectf(t, false, "canonical absent: ok=%v err=%v p5=%q", ok5, err5, p5)
		return
	}
}
