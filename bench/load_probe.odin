// Lexicon-arm phase probe: replicates load_from's
// sequence at unidic scale with phase clocks - read+parse+clone
// (importer_read_csv), sort+trie (cedar_build), resources, matrix -
// using the exported internals, so the serial lexicon majority
// decomposes. Run from the repo root:
//   odin run bench/load_probe.odin -file -collection:moli=$(pwd)/src -o:speed
package load_probe

import "core:fmt"
import "core:mem"
import "base:runtime"
import "core:time"
import "moli:moli"

ms :: proc(t: time.Tick) -> f64 {
	return f64(time.tick_diff(t, time.tick_now())) / f64(time.Millisecond)
}

main :: proc() {
	allocator := runtime.default_allocator()
	LEX :: "dict/unidic-mecab-2.1.2_src/lex.csv"
	MATRIX :: "dict/unidic-mecab-2.1.2_src/matrix.def"

	for run in 1 ..= 2 {
		fmt.printf("\n=== run %v\n", run)

		imp: moli.Importer
		imp.lang = .Japanese
		imp.allocator = allocator
		mem.dynamic_arena_init(&imp.scratch)
		imp.entries, _ = make([dynamic]moli.Dictionary_Entry, 0, 1024, allocator)
		imp.unk_def, _ = make([dynamic]moli.Unk_Rule, 0, 16, allocator)
		imp.unk_patterns, _ = make([dynamic]moli.Unk_Pattern, 0, 4, allocator)

		t0 := time.tick_now()
		err := moli.importer_read_csv(&imp, LEX)
		fmt.printf("read+parse+clone: %.0fms err=%v entries=%v\n", ms(t0), err, len(imp.entries))
		if err != nil { return }

		a: moli.Analyzer
		builder: moli.Cedar_Builder
		builder.cedar = &a.cedar
		builder.allocator = allocator
		builder.scratch_allocator = mem.dynamic_arena_allocator(&imp.scratch)
		builder.entries = imp.entries[:]

		t1 := time.tick_now()
		berr := moli.cedar_build(&builder)
		fmt.printf("sort+trie build: %.0fms err=%v\n", ms(t1), berr)
		if berr != nil { return }

		t2 := time.tick_now()
		a.entries = imp.entries
		imp.entries = nil
		a.char_map = builder.char_map
		if imp.conn_matrix.n_left > 0 { delete(imp.conn_matrix.costs) }
		fmt.printf("hand-over: %.0fms\n", ms(t2))

		t3 := time.tick_now()
		merr := moli.import_matrix_def(&imp, MATRIX, 8)
		fmt.printf("matrix(8t): %.0fms err=%v\n", ms(t3), merr)

		t4 := time.tick_now()
		mem.dynamic_arena_destroy(&imp.scratch)
		if imp.conn_matrix.n_left > 0 { delete(imp.conn_matrix.costs) }
		if a.char_class.ranges != nil { }
		fmt.printf("scratch destroy: %.0fms\n", ms(t4))

		// free the analyzer side (entries were handed over)
		for entry in a.entries {
			e := entry
			moli.dictionary_entry_destroy(&e, allocator)
		}
		delete(a.entries)
		delete(a.cedar.base)
		delete(a.cedar.check)
		delete(a.cedar.terminals)
		delete(a.cedar.group_count)
		delete(a.char_map.forward)
		delete(a.char_map.inverse)
	}
	fmt.println("load-probe: done")
}
