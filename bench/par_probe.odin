// Matrix-arm isolation probe: times import_matrix_def
// alone at several thread counts on the real unidic matrix, so the
// parallel arm's cost is separated from the lexicon/trie load.
//   odin run bench/par_probe.odin -file -collection:moli=$(pwd)/src -o:speed
package par_probe

import "core:fmt"
import "core:mem"
import "base:runtime"
import "core:time"
import "moli:moli"

MATRIX_UNIDIC :: "dict/unidic-mecab-2.1.2_src/matrix.def"
MATRIX_IPADIC :: "dict/ipadic-utf8/matrix.def"

main :: proc() {
	allocator := runtime.default_allocator()
	paths := []string{MATRIX_UNIDIC, MATRIX_IPADIC}
	for path in paths {
		fmt.printf("\n=== %v\n", path)
		counts := []int{0, 2, 4, 8}
		for threads in counts {
			best := f64(1e9)
			for run in 1 ..= 3 {
				imp: moli.Importer
				imp.allocator = allocator
				mem.dynamic_arena_init(&imp.scratch)
				t0 := time.tick_now()
				err := moli.import_matrix_def(&imp, path, threads)
				secs := f64(time.tick_diff(t0, time.tick_now())) / f64(time.Second)
				if err != nil {
					fmt.printf("  threads=%v FAILED: %v\n", threads, err)
					break
				}
				if secs < best { best = secs }
				fmt.printf("  threads=%v run %v: %.3fs (explicit %v)\n",
					threads, run, secs, imp.conn_matrix.explicit)
				delete(imp.conn_matrix.costs)
				mem.dynamic_arena_destroy(&imp.scratch)
			}
		}
	}
	fmt.println("probe: done")
}
