// The native reference behind the SDK FFI-overhead table in
// docs/benchmarks.md: same fixture and texts as
// sdk/moli-python-sdk/probe.py (tests/fixtures/ipadic_sample.csv,
// "犬が歩く" and ×100), same statistic - the median of five block
// means, reported by probe.py's bench() too, so the table's two
// columns are the same measurement shape. Run from the repo root:
//
//	odin run bench/native_probe.odin -file -collection:moli=$(pwd)/src -collection:bench=$(pwd)/bench -o:speed
package native_probe

import "core:fmt"
import "core:mem"
import "base:runtime"
import "core:time"
import "moli:moli"
import "bench:support"

BLOCKS :: 5

main :: proc() {
	allocator := runtime.default_allocator()
	small := "犬が歩く"

	large_buf := make([dynamic]u8, 0, 4096, allocator)
	defer delete(large_buf)
	for _ in 0 ..< 100 {
		for i in 0 ..< len(small) {
			append(&large_buf, small[i])
		}
	}
	large := string(large_buf[:])

	a, lerr := moli.load(.Japanese, "tests/fixtures/ipadic_sample.csv", {}, allocator)
	if lerr != nil {
		fmt.printf("load FAILED\n")
		return
	}
	defer moli.free(&a)
	fmt.printf("entries %v\n", len(a.entries))

	small_us := timed(&a, small, allocator, 2000, 200)
	large_us := timed(&a, large, allocator, 500, 50)
	fmt.printf("native tokenize small: %.2f us/call\n", small_us)
	fmt.printf("native tokenize large: %.2f us/call\n", large_us)
}

// timed answers the median of BLOCKS block means: a scheduler blip
// lands whole in one block mean and the median discards it (per-
// iteration medians would be a third shape; probe.py matches this
// one).
timed :: proc(a: ^moli.Analyzer, text: string, allocator: mem.Allocator, iters: int, warmup: int) -> f64 {
	backing := make([]u8, 4 << 20, allocator)
	defer delete(backing, allocator)
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	arena_alloc := mem.arena_allocator(&arena)

	ms, terr := moli.tokenize(a, text, arena_alloc)
	if terr != nil || len(ms) == 0 {
		fmt.printf("  SANITY FAILED err %v morphs %v\n", terr, len(ms))
		return -1
	}
	morphs := len(ms)

	for _ in 0 ..< warmup {
		mem.arena_init(&arena, backing)
		moli.tokenize(a, text, arena_alloc)
	}
	per_block := iters / BLOCKS
	means := make([dynamic]f64, 0, BLOCKS, allocator)
	defer delete(means)
	for _ in 0 ..< BLOCKS {
		mem.arena_init(&arena, backing)
		t0 := time.tick_now()
		for _ in 0 ..< per_block {
			moli.tokenize(a, text, arena_alloc)
		}
		append(&means, f64(time.tick_diff(t0, time.tick_now())) /
			f64(per_block) / f64(time.Microsecond))
	}
	fmt.printf("  (%v bytes, %v morphs)\n", len(text), morphs)
	return support.median_of(means[:])
}

// median_of lives in bench:support.
