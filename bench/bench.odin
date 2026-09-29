// moli-bench: the library's measurement harness (results recorded in
// docs/benchmarks.md). Load timing (plain allocator) + one tracked
// pass per dict for peak/leaks; tokenize throughput at ~1K/10K/100K
// for Viterbi vs LongestMatch and binary vs flat char_class; medians,
// p95, p99. Run from the repo root:
//   odin run bench/bench.odin -file -collection:moli=$(pwd)/src -collection:bench=$(pwd)/bench -o:speed
package bench

import "core:fmt"
import "core:mem"
import "base:runtime"
import "core:time"
import "moli:moli"
import "bench:support"

DICT_IPADIC :: "dict/ipadic-utf8/lex.csv"
DICT_UNIDIC :: "dict/unidic-mecab-2.1.2_src/lex.csv"
DICT_JIEBA  :: "dict/mecab-jieba-0.1.1/jieba.csv"

main :: proc() {
	allocator := runtime.default_allocator()

	load_bench(allocator)
	tokenize_bench(allocator)
	fmt.println("bench: all done")
}

// ---------------------------------------------------------------------------
// Load benchmarks
// ---------------------------------------------------------------------------

DictSpec :: struct {
	name: string,
	lang: moli.Language,
	path: string,
}

load_bench :: proc(allocator: mem.Allocator) {
	dicts := []DictSpec{
		{name = "ipadic-2.7.0", lang = .Japanese,  path = DICT_IPADIC},
		{name = "unidic-2.1.2", lang = .Japanese,  path = DICT_UNIDIC},
		{name = "jieba-0.1.1",  lang = .ChineseCN, path = DICT_JIEBA},
	}

	for d in dicts {
		fmt.printf("\n=== load %v (%v)\n", d.name, d.path)

		// 3 timing runs on the plain allocator (no tracking overhead
		// in the timed numbers).
		samples := make([dynamic]f64, 0, 4, allocator)
		defer delete(samples)
		for run in 1 ..= 3 {
			t0 := time.tick_now()
			a, err := moli.load(d.lang, d.path, {}, allocator)
			secs := f64(time.tick_diff(t0, time.tick_now())) / f64(time.Second)
			if err != nil {
				fmt.printf("  run %v FAILED: %v\n", run, err)
				break
			}
			// one smoke tokenize so a broken load cannot pass silently
			smoke := smoke_sentence(d.lang)
			buf := make([]u8, 1 << 16, allocator)
			arena: mem.Arena
			mem.arena_init(&arena, buf)
			ms, terr := moli.tokenize(&a, smoke, mem.arena_allocator(&arena))
			if terr != nil || len(ms) == 0 {
				fmt.printf("  run %v smoke FAILED: err %v, %v morphemes\n", run, terr, len(ms))
			}
			delete(buf, allocator)
			t1 := time.tick_now()
			// Read before free: teardown deletes the entries array, and
			// the count belongs in this run's line.
			n_entries := len(a.entries)
			moli.free(&a)
			fsecs := f64(time.tick_diff(t1, time.tick_now())) / f64(time.Second)
			append(&samples, secs)
			fmt.printf("  run %v: load %7.2fs  free %6.2fs  (%v entries)\n", run, secs, fsecs, n_entries)
		}
		if len(samples) > 0 {
			fmt.printf("  load median of %v runs: %.2fs\n", len(samples), support.median_of(samples[:]))
		}

		// One tracked pass: peak memory + leak gate.
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, allocator)
		context.allocator = mem.tracking_allocator(&track)
		a, err := moli.load(d.lang, d.path, {}, context.allocator)
		if err != nil {
			fmt.printf("  tracked run FAILED: %v\n", err)
		} else {
			moli.free(&a)
			leaked := 0
			for _ in track.allocation_map { leaked += 1 }
			fmt.printf("  tracked: peak %v MiB, leaks %v\n",
				track.peak_memory_allocated >> 20, leaked)
		}
		context.allocator = allocator
		mem.tracking_allocator_destroy(&track)
	}
}

smoke_sentence :: proc(lang: moli.Language) -> string {
	if lang == .Japanese { return "犬が歩く" }
	return "我们来到了南京市长江大桥"
}

// ---------------------------------------------------------------------------
// Tokenize throughput
// ---------------------------------------------------------------------------

tokenize_bench :: proc(allocator: mem.Allocator) {
	jp_pool := support.jp_pool
	zh_pool := []string{
		"我们来到了南京市长江大桥。",
		"今天天气真好，适合出去散步。",
		"北京大学是世界著名的高等学府。",
		"中国政府发布了新的经济政策。",
		"他从上海坐火车到北京出差。",
		"这家餐厅的菜非常好吃，价格也很便宜。",
		"人工智能技术正在改变我们的生活方式。",
		"春节期间，成千上万的人返乡过年。",
		"她是一名优秀的软件工程师。",
		"长江是中国最长的河流。",
	}
	en_pool := []string{
		"The company announced record quarterly earnings on Friday.",
		"Researchers published a new study on climate change.",
		"The stock market fell sharply after the announcement.",
		"She walked quickly through the crowded station.",
		"Local authorities said the situation is under control.",
		"The engine uses a deterministic tokenizer backend.",
	}

	zone(jp_pool, en_pool, DICT_UNIDIC, "unidic-2.1.2", .Japanese, allocator)
	zone(zh_pool, en_pool, DICT_JIEBA, "jieba-0.1.1", .ChineseCN, allocator)
	zone(jp_pool, en_pool, DICT_IPADIC, "ipadic-2.7.0", .Japanese, allocator)
}

zone :: proc(main_pool, en_p: []string, path: string, name: string, lang: moli.Language, allocator: mem.Allocator) {
	fmt.printf("\n=== tokenize %v (%v)\n", name, path)
	a, err := moli.load(lang, path, {}, allocator)
	if err != nil {
		fmt.printf("  load FAILED: %v\n", err)
		return
	}
	fmt.printf("  loaded %v entries\n", len(a.entries))

	texts := make([dynamic]TextCase, 0, 8, allocator)
	defer {
		for tc in texts { delete(tc.text, allocator) }
		delete(texts)
	}
	append(&texts, TextCase{name = "main 1K",   text = support.build_text(main_pool, "", 1 << 10, allocator)})
	append(&texts, TextCase{name = "main 10K",  text = support.build_text(main_pool, "", 10 << 10, allocator)})
	append(&texts, TextCase{name = "main 100K", text = support.build_text(main_pool, "", 100 << 10, allocator)})
	append(&texts, TextCase{name = "EN 1K",     text = support.build_text(en_p, "", 1 << 10, allocator)})

	modes := []moli.Mode{.Viterbi, .LongestMatch}
	for tc in texts {
		fmt.printf("  case %-10v %7v bytes\n", tc.name, len(tc.text))
		for mode in modes {
			a.mode = mode
			run_case(&a, tc.text, mode, allocator)
		}
	}

	// flat char_class comparison on the 1K case: a second load with
	// flat_char_class = true.
	af, ferr := moli.load(lang, path, {flat_char_class = true}, allocator)
	if ferr != nil {
		fmt.printf("  flat load FAILED: %v\n", ferr)
		moli.free(&a)
		return
	}
	fmt.printf("  case %-10v %7v bytes  [flat_char_class]\n", texts[0].name, len(texts[0].text))
	af.mode = .Viterbi
	run_case(&af, texts[0].text, .Viterbi, allocator)
	moli.free(&af)

	// Transient footprint of one request: each main-pool size through
	// both modes on a dynamically grown arena under a tracking
	// allocator. The peak is the per-call memory a service pays for an
	// in-flight request; the throughput loop's fixed 96 MiB backing
	// would hide it.
	for tc in texts[:3] {
		for mode in modes {
			a.mode = mode
			track: mem.Tracking_Allocator
			mem.tracking_allocator_init(&track, allocator)
			saved := context.allocator
			context.allocator = mem.tracking_allocator(&track)
			da: mem.Dynamic_Arena
			mem.dynamic_arena_init(&da, block_size = 1 << 16)
			ms, terr := moli.tokenize(&a, tc.text, mem.dynamic_arena_allocator(&da))
			n := len(ms)
			mem.dynamic_arena_destroy(&da)
			context.allocator = saved
			mem.tracking_allocator_destroy(&track)
			if terr != nil {
				fmt.printf("    peak %-12v %-10v FAILED: %v\n", mode, tc.name, terr)
				continue
			}
			fmt.printf("    peak %-12v %-10v %6v KiB  (%v morphs)\n", mode, tc.name, track.peak_memory_allocated >> 10, n)
		}
	}

	moli.free(&a)
}

TextCase :: struct {
	name: string,
	text: string,
}

run_case :: proc(a: ^moli.Analyzer, text: string, mode: moli.Mode, allocator: mem.Allocator) {
	per_iter_morphs := 0

	backing := make([]u8, 96 << 20, allocator) // lattice + output headroom for 100K
	defer delete(backing, allocator)
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	arena_alloc := mem.arena_allocator(&arena)

	// sanity: one full run must succeed and produce morphemes
	ms, terr := moli.tokenize(a, text, arena_alloc)
	if terr != nil || len(ms) == 0 {
		fmt.printf("    %-12v SANITY FAILED err %v morphs %v\n", mode, terr, len(ms))
		return
	}
	per_iter_morphs = len(ms)

	iters := 1000
	warmup := 200
	if len(text) >= (100 << 10) { iters = 50; warmup = 10 }
	else if len(text) >= (10 << 10) { iters = 300; warmup = 50 }

	for _ in 0 ..< warmup {
		mem.arena_init(&arena, backing)
		moli.tokenize(a, text, arena_alloc)
	}

	samples := make([dynamic]f64, 0, iters, allocator)
	defer delete(samples)
	for _ in 0 ..< iters {
		mem.arena_init(&arena, backing)
		t0 := time.tick_now()
		moli.tokenize(a, text, arena_alloc)
		append(&samples, f64(time.tick_diff(t0, time.tick_now())) / f64(time.Microsecond))
	}

	med := support.median_of(samples[:])
	p95 := percentile_of(samples[:], 0.95)
	p99 := percentile_of(samples[:], 0.99)
	secs := med * f64(time.Microsecond) / f64(time.Second)
	mib_s := (f64(len(text)) / (1024.0 * 1024.0)) / secs
	fmt.printf("    %-12v median %9.1fus  p95 %9.1fus  p99 %9.1fus  %7.2f MiB/s  (%v morphs)\n",
		mode, med, p95, p99, mib_s, per_iter_morphs)
}

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

// median_of, jp_pool, and build_text live in bench:support.

percentile_of :: proc(s: []f64, p: f64) -> f64 {
	// insertion sort: samples are <= 1000 elements
	for i in 1 ..< len(s) {
		v := s[i]
		j := i - 1
		for j >= 0 && s[j] > v {
			s[j + 1] = s[j]
			j -= 1
		}
		s[j + 1] = v
	}
	idx := int(f64(len(s)) * p)
	if idx >= len(s) { idx = len(s) - 1 }
	return s[idx]
}
