// Quick sanity: ipadic tokenize throughput after the char.def-flags
// lattice change (invoke=1 classes add candidates; KANJI splits runs
// into 1..2-rune candidates). 1K/10K bytes, Viterbi, medians.
package flags_speed

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

	sentence := "東京都庁に行かなければならない。新年の初売りに多くの買い物客が訪れた。"
	// Repeat the sentence to ~1K and ~10K bytes of JP text.
	unit := len(sentence)
	buf1 := make([dynamic]u8, 0, 1024, allocator)
	for len(buf1) < 1024 - unit { append(&buf1, ..(transmute([]u8)sentence)) }
	buf10 := make([dynamic]u8, 0, 10 * 1024, allocator)
	for len(buf10) < 10 * 1024 - unit { append(&buf10, ..(transmute([]u8)sentence)) }
	t1 := transmute(string)buf1[:]
	t10 := transmute(string)buf10[:]

	arena_buf := make([]u8, 1 << 24, allocator)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	Spec :: struct { name: string, text: string }
	specs := []Spec{
		{name = "1K",  text = t1},
		{name = "10K", text = t10},
	}
	for spec in specs {
		samples := make([dynamic]time.Duration, 0, 9, allocator)
		for i in 0 ..< 9 {
			mem.arena_free_all(&arena)
			t0 := time.tick_now()
			ms, terr := moli.tokenize(&a, spec.text, mem.arena_allocator(&arena))
			d := time.tick_diff(t0, time.tick_now()) / time.Nanosecond
			if terr != nil { fmt.printf("%s FAILED: %v\n", spec.name, terr); return }
			if i >= 2 { append(&samples, d) } // warm-up two rounds
			if len(ms) == 0 { fmt.printf("%s: empty output\n", spec.name); return }
		}
		xs := samples[:]
		sort_durations(xs)
		median := xs[len(xs) / 2]
		fmt.printf("%s bytes: viterbi median %v us (%.2f MiB/s)\n",
			spec.name, f64(median) / 1000.0,
			f64(len(spec.text)) / (f64(median) / 1000.0) / (1024.0 * 1024.0))
		delete(samples)
	}

	delete(buf1)
	delete(buf10)
	delete(arena_buf, allocator)
	fmt.println("done")
}

sort_durations :: proc(xs: []time.Duration) {
	for i in 1 ..< len(xs) {
		x := xs[i]
		j := i - 1
		for j >= 0 && xs[j] > x { xs[j + 1] = xs[j]; j -= 1 }
		xs[j + 1] = x
	}
}
