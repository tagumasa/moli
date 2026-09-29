// Parallel matrix-parse bench: unidic/ipadic
// load wall time at several Load_Options.threads values, median of 3
// plain-allocator runs, plus a snapshot byte-identity + stats check
// against the serial image. One analyzer and at most two images are
// resident at any moment (the machine is memory-tight). Run from the repo root:
//   odin run bench/par_bench.odin -file -collection:moli=$(pwd)/src -o:speed
package par_bench

import "core:bytes"
import "core:fmt"
import "core:mem"
import "core:os"
import "base:runtime"
import "core:time"
import "moli:moli"

DICT_IPADIC :: "dict/ipadic-utf8/lex.csv"
DICT_UNIDIC :: "dict/unidic-mecab-2.1.2_src/lex.csv"

DictSpec :: struct {
	name: string,
	lang: moli.Language,
	path: string,
}

main :: proc() {
	allocator := runtime.default_allocator()
	threads_list := []int{0, 1, 2, 4, 8, 16}
	dicts := []DictSpec{
		{name = "unidic-2.1.2", lang = .Japanese, path = DICT_UNIDIC},
		{name = "ipadic-2.7.0", lang = .Japanese, path = DICT_IPADIC},
	}
	for dict in dicts {
		fmt.printf("\n=== %v\n", dict.name)

		// Serial baseline image, written to disk so only it (not a
		// second analyzer) stays resident across the thread counts.
		a, err := moli.load(dict.lang, dict.path, {threads = 0}, allocator)
		if err != nil { fmt.printf("  baseline load FAILED: %v\n", err); continue }
		base_img, serr := moli.snapshot(&a, allocator)
		base_stats, _ := moli.stats(&a)
		moli.free(&a)
		if serr != nil { fmt.printf("  baseline snapshot: %v\n", serr); continue }
		if werr := os.write_entire_file("tmp/par_base.qdct", base_img); werr != nil {
			fmt.printf("  baseline write: %v\n", werr)
			delete(base_img, allocator)
			continue
		}
		fmt.printf("  serial image %v bytes, explicit %v\n", len(base_img), base_stats.matrix_explicit)
		delete(base_img, allocator)

		for threads in threads_list {
			samples: [3]f64
			n_samples := 0
			for run in 1 ..= 3 {
				t0 := time.tick_now()
				na, lerr := moli.load(dict.lang, dict.path, {threads = threads}, allocator)
				secs := f64(time.tick_diff(t0, time.tick_now())) / f64(time.Second)
				if lerr != nil {
					fmt.printf("  threads=%v run %v FAILED: %v\n", threads, run, lerr)
					break
				}
				samples[n_samples] = secs
				n_samples += 1

				if run == 3 {
					// identity against the serial image, read back from
					// disk so the resident set stays one image at a time.
					img, s2 := moli.snapshot(&na, allocator)
					st, _ := moli.stats(&na)
					file_img, rerr := os.read_entire_file("tmp/par_base.qdct", allocator)
					if s2 != nil || rerr != nil {
						fmt.printf("  snapshot/read: %v / %v\n", s2, rerr)
					} else {
						same := bytes.equal(file_img, img)
						fmt.printf("  threads=%v image==serial: %v  explicit %v/%v\n",
							threads, same, st.matrix_explicit, base_stats.matrix_explicit)
						if !same || st.matrix_explicit != base_stats.matrix_explicit {
							fmt.println("  *** IDENTITY VIOLATION ***")
						}
					}
					delete(file_img, allocator)
					delete(img, allocator)
				}
				moli.free(&na)
			}
			// insertion sort of the collected samples (3 elements).
			for i in 1 ..< n_samples {
				v := samples[i]
				j := i - 1
				for j >= 0 && samples[j] > v {
					samples[j + 1] = samples[j]
					j -= 1
				}
				samples[j + 1] = v
			}
			if n_samples > 0 {
				fmt.printf("  threads=%v median %.3fs  spread %.3fs..%.3fs\n",
					threads, samples[n_samples / 2], samples[0], samples[n_samples - 1])
			}
		}
		os.remove("tmp/par_base.qdct")
	}
	fmt.println("par-bench: done")
}
