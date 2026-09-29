// moli-ceiling: machine-ceiling measurement for the
// parallel matrix-parse load option. Answers, on THIS machine:
// (1) raw file-read throughput for the ipadic load set,
// (2) memory-scan bandwidth single-thread and 8-thread aggregate,
// (3) load decomposition - full load vs lex-only load_bytes vs lex
// slices at 25/50/100% - so per-entry parse/clone cost can be separated
// from the serial cedar build by slope, (4) a comma-split + arena-clone
// parse proxy as a lower bound on the parallelizable per-row cost.
// Run from the repo root:
//   odin run bench/ceiling.odin -file -collection:moli=$(pwd)/src -collection:bench=$(pwd)/bench -o:speed
package ceiling

import "core:fmt"
import "core:mem"
import "core:os"
import "base:runtime"
import "core:strings"
import "core:time"
import "core:thread"
import "moli:moli"
import "bench:support"

DICT_IPADIC :: "dict/ipadic-utf8/lex.csv"

main :: proc() {
	allocator := runtime.default_allocator()

	mode := "all"
	if len(os.args) > 1 { mode = os.args[1] }
	if mode == "all" || mode == "read"  { raw_read_rates(allocator) }
	if mode == "all" || mode == "scan"  { scan_rates(allocator) }
	if mode == "all" || mode == "load"  { load_decomposition(allocator) }
	if mode == "all" || mode == "proxy" { parse_proxy(allocator) }
	fmt.println("ceiling: all done")
}

// ---------------------------------------------------------------------------
// 1. Raw read throughput (page-cache warm after the first pass)
// ---------------------------------------------------------------------------

raw_read_rates :: proc(allocator: mem.Allocator) {
	fmt.println("\n=== raw read (os.read_entire_file) ===")
	paths := []string{
		"dict/ipadic-utf8/lex.csv",
		"dict/ipadic-utf8/matrix.def",
		"dict/ipadic-utf8/unk.def",
		"dict/ipadic-utf8/char.def",
	}
	total_mib := 0.0
	total_secs := 0.0
	for p in paths {
		warm := make([dynamic]f64, 0, 3, allocator)
		defer delete(warm)
		size := 0
		for rep in 0 ..< 4 {
			t0 := time.tick_now()
			data, rerr := os.read_entire_file(p, allocator)
			secs := f64(time.tick_diff(t0, time.tick_now())) / f64(time.Second)
			if rerr != nil || len(data) == 0 {
				fmt.printf("  %-38v FAILED\n", p)
				break
			}
			size = len(data)
			if rep > 0 { append(&warm, secs) }
			delete(data, allocator)
		}
		if len(warm) == 0 { continue }
		med := support.median_of(warm[:])
		mib := f64(size) / (1024.0 * 1024.0)
		fmt.printf("  %-38v %8.2f MiB  %7.1f MiB/s  (%.4fs warm median)\n",
			p, mib, mib / med, med)
		total_mib += mib
		total_secs += med
	}
	fmt.printf("  load set total %8.2f MiB in %6.3fs = %7.1f MiB/s (warm)\n",
		total_mib, total_secs, total_mib / total_secs)
}

// ---------------------------------------------------------------------------
// 2. Memory-scan bandwidth: 1 thread and 8 threads on private buffers
// ---------------------------------------------------------------------------

Scan_Worker :: struct {
	buf: []u8,
	sum: u64,
}

scan_worker :: proc(th: ^thread.Thread) {
	// single pass only: a repeat loop outside any timing region gets
	// collapsed by the optimizer, so each thread scans real bytes once
	w := cast(^Scan_Worker)(th.data)
	s := u64(0)
	for b in w.buf {
		s += u64(b)
	}
	w.sum = s
}

scan_rates :: proc(allocator: mem.Allocator) {
	fmt.println("\n=== memory-scan bandwidth ===")
	base, rerr := os.read_entire_file(DICT_IPADIC, allocator)
	if rerr != nil { fmt.println("  read FAILED"); return }
	defer delete(base, allocator)
	mib := f64(len(base)) / (1024.0 * 1024.0)

	// single thread, 10 reps over the 41.5 MiB lex buffer
	samples := make([dynamic]f64, 0, 10, allocator)
	defer delete(samples)
	s := u64(0)
	for _ in 0 ..< 10 {
		t0 := time.tick_now()
		s = 0
		for b in base {
			s += u64(b)
		}
		append(&samples, f64(time.tick_diff(t0, time.tick_now())) / f64(time.Second))
	}
	fmt.printf("  1 thread: %7.1f MiB/s  (sum %v)\n", mib / support.median_of(samples[:]), s)

	// 8 threads, each one pass over a private 4x-lex buffer (~166 MiB)
	N :: 8
	REPEAT :: 4
	bufs := make([][]u8, N, allocator)
	workers := make([]Scan_Worker, N, allocator)
	threads := make([]^thread.Thread, N, allocator)
	defer {
		for b in bufs {
			if len(b) > 0 { delete(b, allocator) }
		}
		delete(bufs, allocator)
		delete(workers, allocator)
		delete(threads, allocator)
	}
	for i in 0 ..< N {
		bufs[i] = make([]u8, len(base) * REPEAT, allocator)
		for r in 0 ..< REPEAT {
			mem.copy(&bufs[i][r * len(base)], &base[0], len(base))
		}
		workers[i] = Scan_Worker{buf = bufs[i]}
	}
	t0 := time.tick_now()
	for i in 0 ..< N {
		threads[i] = thread.create(scan_worker)
		threads[i].data = cast(rawptr)(&workers[i])
		thread.start(threads[i])
	}
	for i in 0 ..< N { thread.join(threads[i]) }
	wall := f64(time.tick_diff(t0, time.tick_now())) / f64(time.Second)
	for i in 0 ..< N { thread.destroy(threads[i]) }
	for i in 0 ..< N {
		if workers[i].sum != s * REPEAT {
			fmt.printf("  worker %v: sum %v (want %v)\n", i, workers[i].sum, s * REPEAT)
		}
	}
	total := mib * f64(N) * f64(REPEAT)
	fmt.printf("  8 threads: %7.1f MiB/s aggregate (%.3fs wall, %.0f MiB scanned)\n",
		total / wall, wall, total)
}

// ---------------------------------------------------------------------------
// 3. Load decomposition
// ---------------------------------------------------------------------------

load_decomposition :: proc(allocator: mem.Allocator) {
	fmt.println("\n=== load decomposition (median of 3) ===")

	// full load: sibling discovery picks up matrix.def / unk.def / char.def
	full := make([dynamic]f64, 0, 3, allocator)
	defer delete(full)
	n_entries := 0
	for _ in 0 ..< 3 {
		t0 := time.tick_now()
		a, err := moli.load(.Japanese, DICT_IPADIC, {}, allocator)
		secs := f64(time.tick_diff(t0, time.tick_now())) / f64(time.Second)
		if err != nil {
			fmt.printf("  full load FAILED: %v\n", err)
			return
		}
		n_entries = len(a.entries)
		moli.free(&a)
		append(&full, secs)
	}
	fmt.printf("  full load            %7.3fs  (%v entries)\n", support.median_of(full[:]), n_entries)

	// lex-only: borrowed bytes, no sibling resources
	lex, rerr := os.read_entire_file(DICT_IPADIC, allocator)
	if rerr != nil { fmt.println("  lex read FAILED"); return }
	defer delete(lex, allocator)

	lex_t := timed_load_bytes(lex, allocator)
	fmt.printf("  lex-only load_bytes  %7.3fs\n", lex_t)

	// slices at 25% / 50% of the line count for the per-entry slope
	quarter := cut_at_line(lex, n_entries / 4)
	half := cut_at_line(lex, n_entries / 2)
	t25 := timed_load_bytes(quarter, allocator)
	t50 := timed_load_bytes(half, allocator)
	fmt.printf("  lex 25%% (%5v lines)  %7.3fs\n", count_lines(quarter), t25)
	fmt.printf("  lex 50%% (%5v lines)  %7.3fs\n", count_lines(half), t50)

	// slope and intercept: t(N) = a*N + b, from the 50/100% pair and
	// cross-checked with the 25/50% pair
	n := f64(n_entries)
	a_hi := (lex_t - t50) / (n * 0.5)
	a_lo := (t50 - t25) / (n * 0.25)
	b := lex_t - a_hi * n
	fmt.printf("  per-entry slope: %8.3f us (50-100%%)  %8.3f us (25-50%%); fixed intercept %.3fs\n",
		a_hi * 1e6, a_lo * 1e6, b)
}

timed_load_bytes :: proc(data: []u8, allocator: mem.Allocator) -> f64 {
	samples := make([dynamic]f64, 0, 3, allocator)
	defer delete(samples)
	for _ in 0 ..< 3 {
		t0 := time.tick_now()
		a, err := moli.load_bytes(.Japanese, data, {}, allocator)
		secs := f64(time.tick_diff(t0, time.tick_now())) / f64(time.Second)
		if err != nil {
			fmt.printf("  load_bytes FAILED: %v\n", err)
			return -1
		}
		moli.free(&a)
		append(&samples, secs)
	}
	return support.median_of(samples[:])
}

cut_at_line :: proc(data: []u8, lines: int) -> []u8 {
	seen := 0
	for i in 0 ..< len(data) {
		if data[i] == '\n' {
			seen += 1
			if seen == lines { return data[:i + 1] }
		}
	}
	return data
}

count_lines :: proc(data: []u8) -> int {
	n := 0
	for i in 0 ..< len(data) {
		if data[i] == '\n' { n += 1 }
	}
	return n
}

// ---------------------------------------------------------------------------
// 4. Parse proxy: comma split + arena clone per field (lower bound on
//    the parallelizable per-row parse/clone cost)
// ---------------------------------------------------------------------------

parse_proxy :: proc(allocator: mem.Allocator) {
	fmt.println("\n=== parse proxy (split fields, clone into arena) ===")
	lex, rerr := os.read_entire_file(DICT_IPADIC, allocator)
	if rerr != nil { fmt.println("  read FAILED"); return }
	defer delete(lex, allocator)

	backing := make([]u8, 1 << 29, allocator) // 512 MiB, reset per rep
	defer delete(backing, allocator)
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	arena_alloc := mem.arena_allocator(&arena)

	samples := make([dynamic]f64, 0, 3, allocator)
	defer delete(samples)
	rows := 0
	fields := 0
	for _ in 0 ..< 3 {
		mem.arena_init(&arena, backing)
		rows = 0
		fields = 0
		t0 := time.tick_now()
		pos := 0
		for pos < len(lex) {
			line_start := pos
			for pos < len(lex) && lex[pos] != '\n' { pos += 1 }
			line := lex[line_start:pos]
			pos += 1
			if len(line) > 0 && line[len(line) - 1] == '\r' { line = line[:len(line) - 1] }
			rows += 1
			fstart := 0
			for i in 0 ..< len(line) {
				if line[i] == ',' {
					_ = strings.clone(string(line[fstart:i]), arena_alloc)
					fields += 1
					fstart = i + 1
				}
			}
			_ = strings.clone(string(line[fstart:]), arena_alloc)
			fields += 1
		}
		append(&samples, f64(time.tick_diff(t0, time.tick_now())) / f64(time.Second))
	}
	med := support.median_of(samples[:])
	mib := f64(len(lex)) / (1024.0 * 1024.0)
	fmt.printf("  %v rows, %v fields: %.3fs  =  %8.3f us/row  %7.1f MiB/s\n",
		rows, fields, med, med * 1e6 / f64(rows), mib / med)
}

// median_of lives in bench:support.
