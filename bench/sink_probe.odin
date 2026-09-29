// Result-sink throughput: wakachi ([]string), spans ([]Surface_Span),
// and tokenize ([]Morpheme) over the same analyzer and text, so the
// sinks' relative costs share one session. Viterbi and LongestMatch
// modes each load their own qdct snapshot; per-iteration arena reset,
// median of N, one line per arm with the emitted item count.
//
// Run shape, common to every harness:
//
//	mkdir -p tmp
//	odin run bench/sink_probe.odin -file -collection:moli=$(pwd)/src -collection:bench=$(pwd)/bench -o:speed
package sink_probe

import "core:fmt"
import "core:mem"
import "core:time"
import "base:runtime"
import "moli:moli"
import "bench:support"

// The news pool is bench:support's jp_pool; the variant pools below
// are this harness's own.

// Variant pools (input-shape axis): fiction prose and technical
// documentation are the unknown-heavy shapes real consumers bring -
// invented proper nouns and dialect in novels; product names, ASCII
// identifiers, and idiosyncratic notation in design documents. Both
// join their parts with "\n\n" paragraph breaks, which the news pool
// does not exercise at all.
novel_paras := []string{
	"屋根裏の窓から、夕焼けが差し込んでいた。",
	"「まだ帰らないのか」と、ヴォルフガングは振り返りもせずに言った。",
	"セレステは黙って首を横に振り、マフラーを握り直した……。",
	"古い時計塔の針が、ちょうど七時を指そうとしている。",
	"「あたし、グラーヴェンスホルムの森を抜けていく」と彼女は答えた。",
	"ザックリという音がして、斧がまき割りに食い込んだ。",
	"その夜、ミルドラート家の夕食はひどく静かだった。",
	"――誰もが知っている。この町から出た者は、二度と戻らないことを。",
	"エルネストは日記の一ページを破り取って、暖炉にくべた。",
	"雨戸ががたがたと鳴り、炭火がぼんやりと橙色に揺れていた。",
	"「勘で動くな」と、船長は短く咎めた。",
	"テューリンゲンの丘陵地帯には、まだ雪が残っていた。",
}

techdoc_paras := []string{
	"本システムはAPIゲートウェイ経由でマイクロサービス群と連携する。",
	"Kubernetesクラスタ上にデプロイされた各Podは、サイドカープロキシを経由して通信する。",
	"※注記：v2.3.1以降、認証フローはOAuth 2.0のAuthorization Code Grantに統一された。",
	"ヴェルダナート・エンジンのスループットは、10Gbps環境で約9.4Gbpsを維持する。",
	"→移行手順の詳細は、別紙SR-0427を参照すること。",
	"レイテンシのSLOはp99で50ms以内と定義する。",
	"キャッシュ層にはRedis互換のヴォルティブ・ストアを採用した。",
	"データ転送にはgRPC over HTTP/2を利用し、シリアライズはProtobuf v3である。",
	"障害時はフェイルオーバー先のリージョンへ自動切り替えされる（目標RTO：30秒）。",
	"監査ログはWORMストレージに365日間保持する。",
	"①〜③の要件をすべて満たすこと。",
	"Fig. 3-2に、デプロイパイプラインの全体像を示す。",
}

code_paras := []string{
	"// エントリポイント: 設定を読み込んでワーカーを起動する\nfunc main() {\n    cfg := loadConfig(\"gateway.yaml\")\n    if cfg.Verbose {\n        log.SetLevel(log.DebugLevel)\n    }\n    for i := 0; i < cfg.Workers; i++ {\n        go worker(i, cfg.Queue)\n    }\n    select {}\n}",
	"class Tokenizer:\n    \"\"\"形態素解析のラッパー。\"\"\"\n\n    def __init__(self, dict_path: str) -> None:\n        self._analyzer = moli.load(moli.Language.Japanese, dict_path)\n\n    def tokenize(self, text: str) -> list[str]:\n        return [m.surface for m in self._analyzer.tokenize(text)]",
	"server:\n  port: 8443\n  tls:\n    enabled: true\n    cert_file: /etc/voltib/cert.pem\n  upstreams:\n    - name: auth-api\n      address: 10.0.0.11:50051\n    - name: user-api\n      address: 10.0.0.12:50051\n# 設計書4.2節の既定値とすること",
	"SELECT e.employee_id, e.last_name, d.dept_name\nFROM employees AS e\nINNER JOIN departments AS d ON e.dept_id = d.dept_id\nWHERE e.hire_date >= '2024-04-01'\n  AND e.salary BETWEEN 300000 AND 900000\nORDER BY e.hire_date DESC\nLIMIT 50;  -- 新卒採用分を抽出する",
	"{\n  \"schema_version\": \"2.3.1\",\n  \"region\": \"ap-northeast-1\",\n  \"features\": {\n    \"worm_storage\": true,\n    \"audit_log_days\": 365\n  },\n  \"endpoints\": [\n    \"https://api.verdanault.example.com/v2/entries\"\n  ]\n}",
	"#!/bin/bash\nset -euo pipefail\n\n# スナップショットを nightly で検証する\nfor f in snapshots/*.qdct; do\n    ./molicheck --verify \"$f\" || exit 1\ndone\necho \"all snapshots verified: $(ls snapshots | wc -l) files\"",
	"#ifndef MOLI_ABI_H\n#define MOLI_ABI_H\n\n/* C ABI ミラー: 構造体レイアウトは拡張側で検証される */\n#define MOLI_ABI_VERSION 3\n\ntypedef struct Moli_Morpheme {\n    const char *surface;\n    int32_t     entry_id;\n    int16_t     cost;\n} Moli_Morpheme;\n\n#endif /* MOLI_ABI_H */",
	"curl -sS -X POST \"https://api.example.com/v2/tokenize\" \\\n  -H \"Authorization: Bearer $TOKEN\" \\\n  -H \"Content-Type: application/json\" \\\n  -d '{\"text\": \"蔵書目録を解析する\", \"mode\": \"viterbi\"}' \\\n  | jq -r '.morphemes[].surface'",
	"const RE_DATE = /^(\\d{4})-(\\d{2})-(\\d{2})$/;\n\nfunction parseDate(s) {\n    const m = RE_DATE.exec(s);\n    if (!m) throw new RangeError(`invalid date: ${s}`);\n    return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));\n}",
	"<section id=\"overview\">\n  <h2>システム概要</h2>\n  <p>本システムは<b>ヴェルダナート・エンジン</b>上に構築される。</p>\n  <table class=\"slo\">\n    <tr><th>指標</th><th>目標</th></tr>\n    <tr><td>p99 レイテンシ</td><td>50ms 以内</td></tr>\n  </table>\n</section>",
	"diff --git a/src/engine.py b/src/engine.py\n--- a/src/engine.py\n+++ b/src/engine.py\n@@ -42,7 +42,7 @@\n-    threshold = 0.5\n+    threshold = 0.75   # 偽陽性率を下げる\n     for cand in candidates:\n         if cand.score >= threshold:\n             yield cand",
	"### 付録A: 移行チェックリスト\n\n1. `voltib-migrate --dry-run` を実行する\n2. バックアップを WORM 保管域に転送する\n3. 移行ウィンドウは `SR-0427` の記載に従う\n\n> 注意: ロールバック手順は 4.2 節を参照",
}

Pool :: struct {
	label: string,
	parts: []string,
	sep:   string,
}

// build_text and median_of live in bench:support.

Sink_Call :: proc(a: ^moli.Analyzer, text: string, allocator: mem.Allocator) -> (count: int, ok: bool)

measure :: proc(a: ^moli.Analyzer, pool_label: string, label: string, text: string, iters: int,
	arena: ^mem.Arena, call: Sink_Call) {
	samples := make([dynamic]f64, 0, iters, context.allocator)
	defer delete(samples)
	count := 0
	for _ in 0 ..< iters {
		mem.arena_free_all(arena)
		t0 := time.tick_now()
		n_items, ok := call(a, text, mem.arena_allocator(arena))
		if !ok || n_items == 0 { fmt.printf("%s %s FAILED\n", pool_label, label); return }
		count = n_items
		append(&samples, f64(time.tick_diff(t0, time.tick_now())) / 1000.0)
	}
	med := support.median_of(samples[:])
	mibs := f64(len(text)) / med / 1024.0 / 1024.0 * 1e6
	fmt.printf("%-8s %-18s %9.1f us  %6.2f MiB/s  items=%d\n", pool_label, label, med, mibs, count)
}

tok_count :: proc(a: ^moli.Analyzer, text: string, allocator: mem.Allocator) -> (int, bool) {
	ms, terr := moli.tokenize(a, text, allocator)
	return len(ms), terr == nil
}

// The heap-sink arm: the result array pays the default heap instead of
// the caller's arena. The Viterbi emission reserves one exact block, so
// the delete is exact; the greedy growth abandons grown-out blocks and
// therefore assumes an arena - this arm is Viterbi-only by design.
tok_count_default :: proc(a: ^moli.Analyzer, text: string, allocator: mem.Allocator) -> (int, bool) {
	ms, terr := moli.tokenize(a, text, context.allocator)
	count := len(ms)
	delete(ms, context.allocator)
	return count, terr == nil
}

wakachi_count :: proc(a: ^moli.Analyzer, text: string, allocator: mem.Allocator) -> (int, bool) {
	ws, werr := moli.tokenize_wakachi(a, text, allocator)
	return len(ws), werr == nil
}

spans_count :: proc(a: ^moli.Analyzer, text: string, allocator: mem.Allocator) -> (int, bool) {
	ss, serr := moli.tokenize_surfaces_with_offsets(a, text, moli.Tokenize_Options{}, allocator)
	return len(ss), serr == nil
}

main :: proc() {
	allocator := runtime.default_allocator()

	arena_buf := make([]u8, 1 << 27, allocator)
	defer delete(arena_buf, allocator)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])

	vit, lerr := moli.load_qdct("tmp/bench_ipadic.qdct", allocator)
	if lerr != nil { fmt.println("ipadic viterbi load FAILED"); return }
	defer moli.free(&vit)
	lm, lerr2 := moli.load_qdct("tmp/bench_ipadic_lm.qdct", allocator)
	if lerr2 != nil { fmt.println("ipadic longestmatch load FAILED"); return }
	defer moli.free(&lm)
	// Both images must carry this build's dictionary fingerprint: a
	// snapshot an older tree produced loads fine and measures wrong.
	if !support.snapshot_fresh("tmp/bench_ipadic.qdct", .Japanese, "dict/ipadic-utf8/lex.csv", allocator) ||
	   !support.snapshot_fresh("tmp/bench_ipadic_lm.qdct", .Japanese, "dict/ipadic-utf8/lex.csv", allocator) {
		return
	}

	pools := []Pool{
		{label = "news",    parts = support.jp_pool, sep = ""},
		{label = "novel",   parts = novel_paras,     sep = "\n\n"},
		{label = "techdoc", parts = techdoc_paras,   sep = "\n\n"},
		{label = "code",    parts = code_paras,      sep = "\n\n"},
	}
	for pool in pools {
		text := support.build_text(pool.parts, pool.sep, 100 << 10, allocator)
		big := support.build_text(pool.parts, pool.sep, 240 << 10, allocator)
		fmt.printf("=== result sinks (ipadic, %s pool, %d-byte text, median of 20) ===\n", pool.label, len(text))
		// one warmup call per arm: the growth chains fault in their first
		// allocations outside the measured window
		analyzers := [2]moli.Analyzer{vit, lm}
		for &a in analyzers {
			_, _ = tok_count(&a, text, mem.arena_allocator(&arena)); mem.arena_free_all(&arena)
			_, _ = wakachi_count(&a, text, mem.arena_allocator(&arena)); mem.arena_free_all(&arena)
			_, _ = spans_count(&a, text, mem.arena_allocator(&arena)); mem.arena_free_all(&arena)
			_, _ = tok_count(&a, big, mem.arena_allocator(&arena)); mem.arena_free_all(&arena)
		}

		measure(&vit, pool.label, "viterbi tokenize", text, 20, &arena, tok_count)
		measure(&vit, pool.label, "viterbi wakachi", text, 20, &arena, wakachi_count)
		measure(&vit, pool.label, "viterbi spans", text, 20, &arena, spans_count)
		measure(&lm, pool.label, "greedy tokenize", text, 20, &arena, tok_count)
		measure(&lm, pool.label, "greedy wakachi", text, 20, &arena, wakachi_count)
		measure(&lm, pool.label, "greedy spans", text, 20, &arena, spans_count)
		// The large-single-call arm: the engine holds per-byte rate at
		// this size (no core-side cliff to chunk around).
		measure(&vit, pool.label, "viterbi tok 240K", big, 10, &arena, tok_count)
		// The result-sink axis: the same call through the default heap.
		measure(&vit, pool.label, "viterbi tok heap", big, 10, &arena, tok_count_default)
		delete(text, allocator)
		delete(big, allocator)
	}
}
