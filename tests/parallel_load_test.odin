// Parallel matrix-parse tests: Load_Options.threads must change no
// output - the loaded analyzer, its stats, and its snapshot bytes are
// identical at any thread count, including the repeat-cell fallback
// and the malformed-line verdict. Generated fixtures live under tmp/
// and are written through the constant-string helper (no allocation).
package tests

import "base:runtime"
import "core:bytes"
import "core:mem"
import "core:testing"
import "moli:moli"

// par_snapshot_of loads the resources fixture at the given thread
// count and snapshots it; the caller frees the analyzer and owns the
// image. Returns ok = false (after reporting) on any failure.
par_snapshot_of :: proc(t: ^testing.T, threads: int, allocator: runtime.Allocator) -> (moli.Analyzer, []u8, bool) {
	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE, {matrix_def_path = "", threads = threads})
	if !ok { return moli.Analyzer{}, nil, false }
	image, serr := moli.snapshot(&a, allocator)
	if serr != nil {
		testing.expectf(t, false, "snapshot at threads=%v: %v", threads, serr)
		moli.free(&a)
		return moli.Analyzer{}, nil, false
	}
	return a, image, true
}

// threads 0, 1, 4, and 7 produce the same snapshot bytes, the same
// morphemes, and the same stats.
@(test)
parallel_threads_identical_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()
	a0, img0, ok0 := par_snapshot_of(t, 0, allocator)
	if !ok0 { return }
	defer moli.free(&a0)
	defer delete(img0, allocator)

	counts := []int{1, 4, 7}
	for threads in counts {
		a, img, ok := par_snapshot_of(t, threads, allocator)
		if !ok { return }
		if !bytes.equal(img0, img) {
			testing.expectf(t, false, "snapshot bytes differ at threads=%v", threads)
		}
		if !par_same_morphemes(t, &a0, &a, threads) { moli.free(&a); delete(img, allocator); return }
		if !par_same_stats(t, &a0, &a, threads) { moli.free(&a); delete(img, allocator); return }
		moli.free(&a)
		delete(img, allocator)
	}
}

// A thread count far above the worker cap (and far above what the
// tiny fixture's chunk floor allows) loads cleanly and identically:
// the clamp and the empty-chunk skip are exercised, not just the
// happy four-worker shape.
@(test)
parallel_high_thread_count_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()
	a1, img1, ok1 := par_snapshot_of(t, 1, allocator)
	if !ok1 { return }
	defer moli.free(&a1)
	defer delete(img1, allocator)

	high := []int{64, 1000}
	for threads in high {
		a, img, ok := par_snapshot_of(t, threads, allocator)
		if !ok { return }
		if !bytes.equal(img1, img) {
			testing.expectf(t, false, "snapshot bytes differ at threads=%v", threads)
		}
		moli.free(&a)
		delete(img, allocator)
	}
}

// A matrix body whose (1,1) cell repeats on every second line (with
// ascending costs, so last-writer-wins is decisive) forces the
// cross-chunk repeat path at any worker count > 1: the bitset
// arithmetic detects the overlap and the serial replay repairs the
// ordering. The final body has no trailing newline, so the last
// line's chunk ownership covers the no-final-newline edge too. All
// nine cells of the 3x3 matrix are written exactly - explicit must
// be 9, counting (1,1) once.
@(test)
parallel_repeat_fallback_test :: proc(t: ^testing.T) {
	body := "3 3\n" +
		"0 0 10\n" +
		"1 1 100\n" +
		"0 1 20\n" +
		"1 1 200\n" +
		"0 2 30\n" +
		"1 1 300\n" +
		"1 0 40\n" +
		"1 1 400\n" +
		"2 0 50\n" +
		"1 1 500\n" +
		"2 1 60\n" +
		"1 1 600\n" +
		"2 2 70\n" +
		"1 1 700\n" +
		"1 2 80\n" +
		"1 1 800"
	write_tmp(t, "tmp/par_repeat_matrix.def", body)

	allocator := runtime.default_allocator()
	a1, img1, ok1 := par_matrix_snapshot(t, 1, allocator)
	if !ok1 { return }
	defer moli.free(&a1)
	defer delete(img1, allocator)

	repeat_counts := []int{2, 4, 8}
	for threads in repeat_counts {
		a, img, ok := par_matrix_snapshot(t, threads, allocator)
		if !ok { return }
		if !bytes.equal(img1, img) {
			testing.expectf(t, false, "repeat-cell snapshot differs at threads=%v", threads)
		}
		st, serr := moli.stats(&a)
		if serr != nil {
			testing.expectf(t, false, "stats at threads=%v: %v", threads, serr)
		} else if st.matrix_explicit != 9 || st.matrix_cells != 9 {
			testing.expectf(t, false, "explicit=%v cells=%v (want 9/9) at threads=%v",
				st.matrix_explicit, st.matrix_cells, threads)
		}
		moli.free(&a)
		delete(img, allocator)
	}
}

// A malformed line (an id outside the header's range) must produce
// the same verdict regardless of thread count - the earliest chunk's
// fault is the serial scan's verdict.
@(test)
parallel_malformed_determinism_test :: proc(t: ^testing.T) {
	body := "3 3\n" +
		"0 0 10\n" +
		"0 1 20\n" +
		"0 2 30\n" +
		"1 0 40\n" +
		"7 0 1\n" +
		"1 1 50\n" +
		"1 2 60\n"
	write_tmp(t, "tmp/par_bad_matrix.def", body)

	verdict_counts := []int{1, 4}
	for threads in verdict_counts {
		_, err := moli.load(.Japanese, RESOURCES_FIXTURE,
			{matrix_def_path = "tmp/par_bad_matrix.def", threads = threads},
			runtime.default_allocator())
		if err == nil {
			testing.expectf(t, false, "malformed matrix accepted at threads=%v", threads)
			return
		}
		if err != moli.Load_Fault(.Invalid_Format) {
			testing.expectf(t, false, "threads=%v verdict %v, want Invalid_Format", threads, err)
			return
		}
	}
}

// popcount must count without consuming: the first draft's
// by-reference Kernighan loop zeroed the bitset as it counted, so
// the union fell below the per-worker sum and every parallel load
// silently took the serial-replay fallback - correct output, wrong
// path, and only the wall clock knew. Count the same bitset twice
// and require the same answer both times.
@(test)
parallel_popcount_non_destructive_test :: proc(t: ^testing.T) {
	allocator := runtime.default_allocator()
	bits, berr := make([]u8, 16, allocator)
	if berr != nil {
		testing.expectf(t, false, "make: %v", berr)
		return
	}
	defer delete(bits, allocator)
	for i in 0 ..< len(bits) {
		bits[i] = u8(i * 7 + 1)
	}
	first := moli.matrix_popcount(bits)
	second := moli.matrix_popcount(bits)
	if first != second || first == 0 {
		testing.expectf(t, false, "popcount %v then %v (must be equal and non-zero)", first, second)
	}
	// The survival check: a third count after re-reading agrees too,
	// and a known pattern gives the known answer.
	bits[0] = 0b1011_0000
	bits[1] = 0
	known := moli.matrix_popcount(bits[:2])
	if known != 3 {
		testing.expectf(t, false, "popcount of 0b10110000,0 is %v, want 3", known)
	}
}

// par_matrix_snapshot loads the resources CSV against the repeat
// fixture written by the caller (sibling discovery is bypassed with
// an explicit matrix path) and snapshots the result.
par_matrix_snapshot :: proc(t: ^testing.T, threads: int, allocator: runtime.Allocator) -> (moli.Analyzer, []u8, bool) {
	a, ok := load_ok(t, .Japanese, RESOURCES_FIXTURE,
		{matrix_def_path = "tmp/par_repeat_matrix.def", threads = threads})
	if !ok { return moli.Analyzer{}, nil, false }
	image, serr := moli.snapshot(&a, allocator)
	if serr != nil {
		testing.expectf(t, false, "snapshot at threads=%v: %v", threads, serr)
		moli.free(&a)
		return moli.Analyzer{}, nil, false
	}
	return a, image, true
}

// par_same_morphemes compares one tokenize over both analyzers.
par_same_morphemes :: proc(t: ^testing.T, a, b: ^moli.Analyzer, threads: int) -> bool {
	buf: [1 << 16]byte
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	arena_alloc := mem.arena_allocator(&arena)

	ms_a, ea := moli.tokenize(a, "さくらが散る。", arena_alloc)
	ms_b, eb := moli.tokenize(b, "さくらが散る。", arena_alloc)
	if ea != nil || eb != nil {
		testing.expectf(t, false, "tokenize at threads=%v: %v / %v", threads, ea, eb)
		return false
	}
	return expect_same_morphemes(t, ms_a, ms_b)
}

// par_same_stats compares the stats read-outs (the matrix fields are
// the ones the thread count could plausibly disturb).
par_same_stats :: proc(t: ^testing.T, a, b: ^moli.Analyzer, threads: int) -> bool {
	sa, ea := moli.stats(a)
	sb, eb := moli.stats(b)
	if ea != nil || eb != nil {
		testing.expectf(t, false, "stats at threads=%v: %v / %v", threads, ea, eb)
		return false
	}
	return expect_same_stats(t, sa, sb)
}
