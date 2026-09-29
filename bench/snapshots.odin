// Snapshot producer: the qdct images bench harnesses load, built in
// one place so a harness never measures against an image an older
// tree or engine produced. Writes the sink probe's mode pair
// (tmp/bench_ipadic.qdct, tmp/bench_ipadic_lm.qdct) and the SDK A/B
// battery's input (tmp/sdk_ab/ipadic.qdct), and prints each image's
// entries_hash — the fingerprint the consumers assert against a fresh
// load of the same CSV before measuring. Run from the repo root:
//   odin run bench/snapshots.odin -file -collection:moli=$(pwd)/src -o:speed
package snapshots

import "core:fmt"
import "base:runtime"
import "core:mem"
import "moli:moli"

IPADIC :: "dict/ipadic-utf8/lex.csv"

main :: proc() {
	allocator := runtime.default_allocator()

	// One load per mode; the Viterbi image is saved twice (the sink
	// probe's copy and the SDK battery's copy come from one build).
	vit, verr := moli.load(.Japanese, IPADIC, {}, allocator)
	if verr != nil {
		fmt.printf("viterbi load FAILED: %v\n", verr)
		return
	}
	defer moli.free(&vit)
	save(&vit, "tmp/bench_ipadic.qdct", allocator)
	save(&vit, "tmp/sdk_ab/ipadic.qdct", allocator)

	lm, lerr := moli.load(.Japanese, IPADIC, {mode = .LongestMatch}, allocator)
	if lerr != nil {
		fmt.printf("longestmatch load FAILED: %v\n", lerr)
		return
	}
	defer moli.free(&lm)
	save(&lm, "tmp/bench_ipadic_lm.qdct", allocator)
}

// save writes one image and prints the fingerprint the consumers
// (sink_probe.odin, sdk_ab_probe.py, sdk_identity.py) compare against
// their own fresh CSV load.
save :: proc(a: ^moli.Analyzer, path: string, allocator: mem.Allocator) {
	if err := moli.save_qdct(a, path, allocator); err != nil {
		fmt.printf("save %s FAILED: %v\n", path, err)
		return
	}
	st, serr := moli.stats(a)
	if serr != nil {
		fmt.printf("%s saved, stats FAILED: %v\n", path, serr)
		return
	}
	fmt.printf("%s: %v entries, entries_hash %x\n", path, st.entries, st.entries_hash)
}
