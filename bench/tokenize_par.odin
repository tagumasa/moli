// Concurrent tokenize scaling: G workers tokenize the same ~100K
// jp_pool text on one shared, read-only analyzer, each with its own
// arena - the documented concurrent-server contract (tokenize is
// thread-safe on a shared ^Analyzer). The load is serial; the arm
// measures tokenize only. Wall time per G, median of 3, numbers only.
//
// A second pass repeats the sweep with one analyzer per worker (the
// separate-analyzer control): if the two passes scale alike, the
// shared read-only analyzer adds no contention of its own.
//
// Run shape, common to every harness:
//
//	mkdir -p tmp
//	odin run bench/tokenize_par.odin -file -collection:moli=$(pwd)/src -collection:bench=$(pwd)/bench -o:speed
package tokenize_par

import "core:fmt"
import "core:mem"
import "base:runtime"
import "core:thread"
import "core:time"
import "moli:moli"
import "bench:support"

Worker :: struct {
	a:         ^moli.Analyzer,
	text:      string,
	arena_buf: []u8,
	arena:     mem.Arena,
	rounds:    int,
	morphs:    int,
	fail:      bool,
}

worker_main :: proc(t: ^thread.Thread) {
	w := cast(^Worker)t.data
	for _ in 0 ..< w.rounds {
		mem.arena_free_all(&w.arena)
		ms, terr := moli.tokenize(w.a, w.text, mem.arena_allocator(&w.arena))
		if terr != nil || len(ms) == 0 {
			w.fail = true
			return
		}
		w.morphs += len(ms)
	}
}

// build_text and median_of live in bench:support.

run_scaling :: proc(analyzers: []moli.Analyzer, shared: bool, text: string, allocator: mem.Allocator) {
	rounds: int = 20
	gs := [4]int{1, 2, 4, 8}
	base_mibs: f64 = -1
	for g in gs {
		workers := make([]Worker, g, allocator)
		threads := make([]^thread.Thread, g, allocator)
		walls := make([dynamic]f64, 0, 3, allocator)
		defer {
			for i in 0 ..< g {
				if len(workers[i].arena_buf) > 0 { delete(workers[i].arena_buf, allocator) }
				if threads[i] != nil { thread.destroy(threads[i]) }
			}
			delete(workers, allocator)
			delete(threads, allocator)
			delete(walls)
		}
		for i in 0 ..< g {
			if shared {
				workers[i].a = &analyzers[0]
			} else {
				workers[i].a = &analyzers[i]
			}
			workers[i].text = text
			workers[i].rounds = rounds
			workers[i].arena_buf = make([]u8, 1 << 26, allocator)
			mem.arena_init(&workers[i].arena, workers[i].arena_buf)
		}
		for rep in 0 ..< 3 {
			for i in 0 ..< g {
				workers[i].morphs = 0
				workers[i].fail = false
			}
			t0 := time.tick_now()
			for i in 0 ..< g {
				threads[i] = thread.create(worker_main)
				threads[i].data = cast(rawptr)&workers[i]
				thread.start(threads[i])
			}
			for i in 0 ..< g { thread.join(threads[i]) }
			wall := f64(time.tick_diff(t0, time.tick_now()))
			for i in 0 ..< g {
				if workers[i].fail {
					fmt.printf("  workers=%v rep %v: tokenize FAILED\n", g, rep)
					return
				}
			}
			append(&walls, wall)
		}
		median := support.median_of(walls[:])
		mibs := f64(g) * f64(rounds) * f64(len(text)) / median * 1e9 / (1024.0 * 1024.0)
		if g == 1 { base_mibs = mibs }
		fmt.printf("  workers=%v  wall %.1fms  %7.2f MiB/s aggregate  scaling %.2fx\n",
			g, median / 1e6, mibs, mibs / base_mibs)
	}
}

main :: proc() {
	allocator := runtime.default_allocator()

	text := support.build_text(support.jp_pool, "", 100 << 10, allocator)
	defer delete(text, allocator)

	fmt.printf("=== concurrent tokenize scaling (ipadic, %d-byte text, median of 3) ===\n", len(text))

	fmt.println("-- shared analyzer (the documented contract) --")
	a, err := moli.load(.Japanese, "dict/ipadic-utf8/lex.csv", {}, allocator)
	if err != nil {
		fmt.printf("load FAILED: %v\n", err)
		return
	}
	defer moli.free(&a)
	shared := make([]moli.Analyzer, 1, allocator)
	defer delete(shared, allocator)
	shared[0] = a
	run_scaling(shared, true, text, allocator)

	fmt.println("-- separate-analyzer control (one analyzer per worker) --")
	own := make([]moli.Analyzer, 8, allocator)
	defer {
		for i in 0 ..< 8 { moli.free(&own[i]) }
		delete(own, allocator)
	}
	for i in 0 ..< 8 {
		own[i], err = moli.load(.Japanese, "dict/ipadic-utf8/lex.csv", {}, allocator)
		if err != nil {
			fmt.printf("load %v FAILED: %v\n", i, err)
			return
		}
	}
	run_scaling(own, false, text, allocator)
}
