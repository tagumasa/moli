// cedar_build inner-phase probe: times the surface sort
// alone against the rest of the trie build (char map + shadow trie +
// placement + group counts) at unidic scale, via exported internals.
//   odin run bench/cedar_probe.odin -file -collection:moli=$(pwd)/src -o:speed
package cedar_probe

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

	for run in 1 ..= 2 {
		fmt.printf("\n=== run %v\n", run)
		imp: moli.Importer
		imp.lang = .Japanese
		imp.allocator = allocator
		mem.dynamic_arena_init(&imp.scratch)
		imp.entries, _ = make([dynamic]moli.Dictionary_Entry, 0, 1024, allocator)
		if err := moli.importer_read_csv(&imp, LEX); err != nil { fmt.println("read failed"); return }

		// Sort alone on a COPY of the entries? sort_entries_by_surface
		// mutates b.entries (the caller's slice) - hand it the real
		// slice and time just this phase.
		a: moli.Analyzer
		builder: moli.Cedar_Builder
		builder.cedar = &a.cedar
		builder.allocator = allocator
		builder.scratch_allocator = mem.dynamic_arena_allocator(&imp.scratch)
		builder.entries = imp.entries[:]

		t0 := time.tick_now()
		serr := moli.sort_entries_by_surface(&builder)
		fmt.printf("surface sort: %.0fms err=%v\n", ms(t0), serr)

		t1 := time.tick_now()
		berr := moli.cedar_build(&builder)
		fmt.printf("cedar_build (sort re-run inside + trie): %.0fms err=%v\n", ms(t1), berr)

		// teardown
		if imp.conn_matrix.n_left > 0 { delete(imp.conn_matrix.costs) }
		mem.dynamic_arena_destroy(&imp.scratch)
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
	fmt.println("cedar-probe: done")
}
