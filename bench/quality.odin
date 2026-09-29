// Hand-verified segmentation quality set. Reference
// corpora (SIGHAN, Kyoto Text Corpus, KCBS/BCCWJ) are research-use
// restricted, so the quality gate is a hand-verified set:
// sentences with expected surface chains where the correct split is
// unambiguous, and print-only eyeball rows for dialect-sensitive
// cases. Also cross-checks tokenize vs tokenize_wakachi
// self-consistency. Run from the repo root.
package quality

import "core:fmt"
import "core:mem"
import "base:runtime"
import "core:strings"
import "moli:moli"

Case :: struct {
	sent: string,
	want: []string, // nil = print-only (eyeball)
}

JP_IPADIC :: []Case{
	{sent = "犬が歩く", want = []string{"犬", "が", "歩く"}},
	{sent = "さくらの花が咲いた。", want = []string{"さくら", "の", "花", "が", "咲い", "た", "。"}},
	{sent = "東京都庁に行かなければならない", want = []string{"東京", "都庁", "に", "行か", "なけれ", "ば", "なら", "ない"}},
	{sent = "新年の初売りに多くの買い物客が訪れた。", want = []string{"新年", "の", "初", "売り", "に", "多く", "の", "買い物", "客", "が", "訪れ", "た", "。"}},
	{sent = "私は東京大学の学生です。", want = []string{"私", "は", "東京大学", "の", "学生", "です", "。"}},
	{sent = "今年の夏はとても暑かった。", want = []string{"今年", "の", "夏", "は", "とても", "暑かっ", "た", "。"}},
	{sent = "コンピュータを使って文書を作成する。", want = []string{"コンピュータ", "を", "使っ", "て", "文書", "を", "作成", "する", "。"}},
	{sent = "電車が遅れたために会議に間に合わなかった。", want = []string{"電車", "が", "遅れ", "た", "ため", "に", "会議", "に", "間に合わ", "なかっ", "た", "。"}},
	// eyeball-only: rarer vocabulary, unknown-run behavior
	{sent = "ヴェルタース地方の雑木林を訪ねた。", want = nil},
	{sent = "彼女はABC社のQRコードをスキャンした。", want = nil},
}

JP_UNIDIC :: []Case{
	{sent = "犬が歩く", want = []string{"犬", "が", "歩く"}},
	{sent = "東京都庁に行かなければならない", want = []string{"東京", "都庁", "に", "行か", "なけれ", "ば", "なら", "ない"}},
	// eyeball-only: unidic splits at different granularity than ipadic
	{sent = "さくらの花が咲いた。", want = nil},
	{sent = "私は東京大学の学生です。", want = nil},
	{sent = "今年の夏はとても暑かった。", want = nil},
	// eyeball-only: English text on the Japanese dictionary degenerates
	// per-character (a recorded note in docs/benchmarks.md)
	{sent = "The company announced record earnings.", want = nil},
}

ZH_JIEBA :: []Case{
	{sent = "我们来到了南京市长江大桥", want = []string{"我们", "来到", "了", "南京市", "长江大桥"}},
	{sent = "今天天气真好", want = []string{"今天天气", "真", "好"}},
	// eyeball-only
	{sent = "北京大学是世界著名的高等学府", want = nil},
	{sent = "他从上海坐火车到北京出差", want = nil},
	{sent = "人工智能技术正在改变我们的生活方式", want = nil},
}

main :: proc() {
	allocator := runtime.default_allocator()
	passed, failed := 0, 0

	ai, ierr := moli.load(.Japanese, "dict/ipadic-utf8/lex.csv", {}, allocator)
	if ierr != nil { fmt.printf("ipadic load FAILED: %v\n", ierr); return }
	pass, fail := run_set("ipadic", &ai, JP_IPADIC, allocator)
	passed += pass; failed += fail
	moli.free(&ai)

	au, uerr := moli.load(.Japanese, "dict/unidic-mecab-2.1.2_src/lex.csv", {}, allocator)
	if uerr != nil { fmt.printf("unidic load FAILED: %v\n", uerr); return }
	pass, fail = run_set("unidic", &au, JP_UNIDIC, allocator)
	passed += pass; failed += fail

	// LongestMatch vs Viterbi divergence survey on unidic (print only).
	fmt.println("\n[unidic LongestMatch eyeball]")
	for c in JP_UNIDIC {
		ss := surfaces(&au, c.sent, allocator)
		got := chain_string(ss, allocator)
		fmt.printf("  %q -> %v\n", c.sent, got)
		delete(got, allocator)
		delete(ss, allocator)
	}
	moli.free(&au)

	az, zerr := moli.load(.ChineseCN, "dict/mecab-jieba-0.1.1/jieba.csv", {}, allocator)
	if zerr != nil { fmt.printf("jieba load FAILED: %v\n", zerr); return }
	pass, fail = run_set("jieba", &az, ZH_JIEBA, allocator)
	passed += pass; failed += fail
	moli.free(&az)

	fmt.printf("\nquality: %v passed, %v failed (plus eyeball rows above)\n", passed, failed)
}

run_set :: proc(name: string, a: ^moli.Analyzer, cases: []Case, allocator: mem.Allocator) -> (int, int) {
	passed, failed := 0, 0
	fmt.printf("\n[%v Viterbi]\n", name)
	for c in cases {
		morphs := surfaces(a, c.sent, allocator)

		// wakachi self-consistency: same surfaces, both modes of
		// construction.
		ws := wakachi(a, c.sent, allocator)
		if !same_chain(morphs, ws) {
			got_c := chain_string(morphs, allocator)
			ws_c := chain_string(ws, allocator)
			fmt.printf("  WAKACHI MISMATCH %q:\n    tokenize: %v\n    wakachi:  %v\n", c.sent, got_c, ws_c)
			delete(got_c, allocator)
			delete(ws_c, allocator)
			failed += 1
		}
		delete(ws, allocator)

		if c.want == nil {
			got := chain_string(morphs, allocator)
			fmt.printf("  eyeball %q -> %v\n", c.sent, got)
			delete(got, allocator)
			delete(morphs, allocator)
			continue
		}
		if same_chain(morphs, c.want) {
			passed += 1
		} else {
			failed += 1
			got := chain_string(morphs, allocator)
			want := chain_string(c.want, allocator)
			fmt.printf("  FAIL %q:\n    want %v\n    got  %v\n", c.sent, want, got)
			delete(got, allocator)
			delete(want, allocator)
		}
		delete(morphs, allocator)
	}
	return passed, failed
}

surfaces :: proc(a: ^moli.Analyzer, sent: string, allocator: mem.Allocator) -> []string {
	buf := make([]u8, 1 << 18, allocator)
	arena: mem.Arena
	mem.arena_init(&arena, buf)
	ms, _ := moli.tokenize(a, sent, mem.arena_allocator(&arena))
	out := make([dynamic]string, 0, len(ms), allocator)
	for m in ms { append(&out, m.surface) }
	delete(buf, allocator)
	return out[:]
}

wakachi :: proc(a: ^moli.Analyzer, sent: string, allocator: mem.Allocator) -> []string {
	buf := make([]u8, 1 << 18, allocator)
	arena: mem.Arena
	mem.arena_init(&arena, buf)
	ws, _ := moli.tokenize_wakachi(a, sent, mem.arena_allocator(&arena))
	out := make([dynamic]string, 0, len(ws), allocator)
	for w in ws { append(&out, w) }
	delete(buf, allocator)
	return out[:]
}

same_chain :: proc(a, b: []string) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		if a[i] != b[i] { return false }
	}
	return true
}

chain_string :: proc(ss: []string, allocator: mem.Allocator) -> string {
	// plain concatenation with | separators (fmt treats braces in
	// format strings, so chains are built by hand)
	buf := make([dynamic]u8, 0, 128, allocator)
	for s, i in ss {
		if i > 0 { append(&buf, u8('|')) }
		for j in 0 ..< len(s) { append(&buf, s[j]) }
	}
	out := strings.clone(string(buf[:]), allocator)
	delete(buf)
	return out
}
