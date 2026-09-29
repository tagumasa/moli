// Real-scale n-best sanity: ipadic, 5-best on a sentence, 50 rounds,
// timing + a couple of path dumps.
package nbest_trial

import "core:fmt"
import "core:mem"
import "base:runtime"
import "core:time"
import "moli:moli"

main :: proc() {
	allocator := runtime.default_allocator()
	a, err := moli.load(.Japanese, "dict/ipadic-utf8/lex.csv", {}, allocator)
	if err != nil { fmt.printf("load FAILED: %v\n", err); return }
	defer moli.free(&a)

	arena_buf := make([]u8, 1 << 24, allocator)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	s := "東京都庁に行かなければならない。"
	paths := make([dynamic]moli.NBest_Path, 0, 8, allocator)

	rounds := 50
	t0 := time.tick_now()
	for i in 0 ..< rounds {
		mem.arena_free_all(&arena)
		resize(&paths, 0)
		if err2 := moli.tokenize_nbest(&a, s, 5, {}, {}, &paths, mem.arena_allocator(&arena)); err2 != nil {
			fmt.printf("nbest FAILED: %v\n", err2)
			return
		}
	}
	d := time.tick_diff(t0, time.tick_now()) / time.Nanosecond
	fmt.printf("5-best x %d rounds on %d chars: total %v us, per call %v us, paths %d\n",
		rounds, len(s), f64(d) / 1000.0, f64(d) / 1000.0 / f64(rounds), len(paths))

	for p, i in paths {
		if i >= 2 { break }
		fmt.printf("path %d cost %v:", i, p.cost)
		for m in p.morphemes {
			fmt.printf("|%s", m.surface)
		}
		fmt.println()
	}

	delete(paths)
	delete(arena_buf, allocator)
	fmt.println("done")
}
