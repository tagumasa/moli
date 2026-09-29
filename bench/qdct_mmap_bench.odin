// qdct restore bench: read-copy vs mapped restore
// per dictionary — 3 runs each, median, plus VmRSS after load and after
// one smoke tokenize (the copy is fully resident at load; the mapping
// faults pages in as sections are touched). Run from the repo root:
//   odin run bench/qdct_mmap_bench.odin -file -collection:moli=$(pwd)/src -collection:bench=$(pwd)/bench -o:speed
package qdct_mmap_bench

import "core:fmt"
import "core:mem"
import "core:os"
import "base:runtime"
import "core:strings"
import "core:time"
import "moli:moli"
import "bench:support"

DictSpec :: struct {
	name:  string,
	lang:  moli.Language,
	path:  string,
	qpath: string,
}

main :: proc() {
	allocator := runtime.default_allocator()
	dicts := []DictSpec{
		{name = "ipadic-2.7.0", lang = .Japanese,  path = "dict/ipadic-utf8/lex.csv",                qpath = "tmp/bench_ipadic.qdct"},
		{name = "unidic-2.1.2", lang = .Japanese,  path = "dict/unidic-mecab-2.1.2_src/lex.csv",      qpath = "tmp/bench_unidic.qdct"},
		{name = "jieba-0.1.1",  lang = .ChineseCN, path = "dict/mecab-jieba-0.1.1/jieba.csv",         qpath = "tmp/bench_jieba.qdct"},
	}

	run_buf := make([]u8, 1 << 18, allocator)
	defer delete(run_buf, allocator)
	run_arena: mem.Arena

	for d in dicts {
		fmt.printf("\n=== %v\n", d.name)
		mem.arena_init(&run_arena, run_buf)

		// Build the snapshot once (untimed). Morpheme equality between
		// the two restores is the test suite's job; each run here only
		// smokes one tokenize so a broken restore cannot pass silently.
		a, lerr := moli.load(d.lang, d.path, {}, allocator)
		if lerr != nil {
			fmt.printf("  CSV load FAILED: %v\n", lerr)
			continue
		}
		if serr := moli.save_qdct(&a, d.qpath, allocator); serr != nil {
			fmt.printf("  save FAILED: %v\n", serr)
			moli.free(&a)
			continue
		}
		fmt.printf("  %v entries, snapshot saved\n", len(a.entries))
		moli.free(&a)

		smoke := smoke_sentence(d.lang)
		copy_runs, c_base, c_load, c_tok := restore_runs(d.qpath, allocator, &run_arena, false, smoke)
		fmt.printf("  copy : median %.3fs (runs", support.median_of(copy_runs))
		for s in copy_runs { fmt.printf(" %.3f", s) }
		fmt.printf(")  rss +%v kB after load, +%v kB after tokenize\n", c_load - c_base, c_tok - c_base)
		delete(copy_runs, allocator)

		map_runs, m_base, m_load, m_tok := restore_runs(d.qpath, allocator, &run_arena, true, smoke)
		fmt.printf("  mmap : median %.3fs (runs", support.median_of(map_runs))
		for s in map_runs { fmt.printf(" %.3f", s) }
		fmt.printf(")  rss +%v kB after load, +%v kB after tokenize\n", m_load - m_base, m_tok - m_base)
		delete(map_runs, allocator)
	}
}

// restore_runs loads and frees the snapshot 3 times on the plain
// allocator; returns wall times plus VmRSS (kB) sampled before the
// first load (base), right after it, and after that load's smoke
// tokenize. The caller deletes runs.
restore_runs :: proc(path: string, allocator: mem.Allocator, arena: ^mem.Arena, mapped: bool, smoke: string) -> (runs: []f64, rss_base: i64, rss_load: i64, rss_tok: i64) {
	runs = make([]f64, 3, allocator)
	rss_base, rss_load, rss_tok = -1, -1, -1
	for run in 0 ..< 3 {
		if run == 0 { rss_base = vm_rss_kb() }
		t0 := time.tick_now()
		a, err := load_one(path, allocator, mapped)
		secs := f64(time.tick_diff(t0, time.tick_now())) / f64(time.Second)
		if err != nil {
			fmt.printf("  run %v FAILED: %v\n", run, err)
			runs[run] = -1
			continue
		}
		if run == 0 { rss_load = vm_rss_kb() }
		got := tokenize_all(&a, smoke, arena)
		if run == 0 {
			rss_tok = vm_rss_kb()
			fmt.printf("  smoke: %v morphemes\n", len(got))
		}
		moli.free(&a)
		runs[run] = secs
	}
	return runs, rss_base, rss_load, rss_tok
}

load_one :: proc(path: string, allocator: mem.Allocator, mapped: bool) -> (moli.Analyzer, moli.Load_Err) {
	if mapped { return moli.load_qdct_mmap(path, allocator) }
	return moli.load_qdct(path, allocator)
}

tokenize_all :: proc(a: ^moli.Analyzer, text: string, arena: ^mem.Arena) -> []moli.Morpheme {
	ms, err := moli.tokenize(a, text, mem.arena_allocator(arena))
	if err != nil {
		fmt.printf("  tokenize FAILED: %v\n", err)
		return nil
	}
	return ms
}

smoke_sentence :: proc(lang: moli.Language) -> string {
	#partial switch lang {
	case .Japanese:  return "庭には二羽ニワトリがいる。"
	case .ChineseCN: return "今天天气真不错，我们去公园散步吧。"
	case:            return "The quick brown fox jumps over the lazy dog."
	}
}

vm_rss_kb :: proc() -> i64 {
	data, err := os.read_entire_file("/proc/self/status", context.temp_allocator)
	if err != nil { return -1 }
	defer delete(data, context.temp_allocator)
	for line in strings.split_lines(string(data)) {
		if !strings.has_prefix(line, "VmRSS:") { continue }
		n := 0
		for i in 6 ..< len(line) {
			c := line[i]
			if c >= '0' && c <= '9' { n = n * 10 + int(c - '0') }
		}
		return i64(n)
	}
	return -1
}

// median_of lives in bench:support.
