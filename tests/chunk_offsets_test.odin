// safe_chunk_offsets pins: the cut rule (only after complete
// LF-terminated whitespace runs - never before a run's trailing space,
// never inside a CRLF pair), the greedy target semantics, and the
// degenerate documents. The identity fold over a real analyzer lives
// in chunk_identity_test.
package tests

import "core:testing"
import "moli:moli"

Chunk_Case :: struct {
	text:   string,
	target: int,
	want:   []int,
}

chunk_rule_cases := []Chunk_Case{
	// Paragraph text with blank-line separators: every run end is a
	// cut at target 1, and larger targets defer to the first cut that
	// clears the gap.
	{text = "AA\n\nBB\n\nCC", target = 1,  want = []int{4, 8}},
	{text = "AA\n\nBB\n\nCC", target = 4,  want = []int{4, 8}},
	{text = "AA\n\nBB\n\nCC", target = 5,  want = []int{8}},
	{text = "AA\n\nBB\n\nCC", target = 64, want = nil},
	// A target below 1 is clamped to 1: both take every run end.
	{text = "AA\n\nBB\n\nCC", target = 0,  want = []int{4, 8}},
	{text = "AA\n\nBB\n\nCC", target = -3, want = []int{4, 8}},
	// CRLF blank lines: cuts fall after the complete "\r\n\r\n" run,
	// never between its pairs.
	{text = "\r\n\r\nX\r\n\r\nY", target = 1, want = []int{4, 9}},
	// A space extending a newline run keeps the run alive: the only
	// cut is after the later, space-free run.
	{text = "A\n\n B\n\nC", target = 1, want = []int{7}},
	// A tab after a newline likewise continues the whitespace run.
	{text = "A\n\tB", target = 1, want = nil},
	// No newline, empty text, nothing but whitespace: one piece.
	{text = "ABC", target = 1, want = nil},
	{text = "", target = 1, want = nil},
	{text = "\n\n\n", target = 1, want = nil},
}

@(test)
safe_chunk_offsets_rule_test :: proc(t: ^testing.T) {
	for c in chunk_rule_cases {
		got, aerr := moli.safe_chunk_offsets(c.text, c.target, context.allocator)
		if aerr != nil {
			testing.expectf(t, false, "safe_chunk_offsets(%q, %d) failed: %v", c.text, c.target, aerr)
			return
		}

		ok := len(got) == len(c.want)
		if ok {
			for i in 0 ..< len(got) {
				if got[i] != c.want[i] { ok = false }
			}
		}
		testing.expectf(t, ok, "safe_chunk_offsets(%q, %d): got %v, want %v",
			c.text, c.target, got, c.want)
		delete(got, context.allocator)
	}
}

@(test)
safe_chunk_offsets_property_test :: proc(t: ^testing.T) {
	// Mixed separators exercise the rule on text no hand-written
	// expectation covers: LF pairs, CRLF pairs, a run extended by a
	// space, and a lone LF between sentences.
	seps := []string{"\n\n", "\r\n\r\n", "\n \n", "\n"}
	buf, berr := make([dynamic]u8, 0, 4096, context.allocator)
	if berr != nil {
		testing.expectf(t, false, "buffer make failed: %v", berr)
		return
	}
	defer delete(buf)
	for rep in 0 ..< 12 {
		for p in chunk_paragraphs {
			for i in 0 ..< len(p) {
				if _, aerr := append(&buf, p[i]); aerr != nil { break }
			}
			sep := seps[rep % len(seps)]
			for i in 0 ..< len(sep) {
				if _, aerr := append(&buf, sep[i]); aerr != nil { break }
			}
		}
	}
	text := string(buf[:])

	targets := []int{1, 37, 200, 1 << 20}
	for target in targets {
		cuts, cerr := moli.safe_chunk_offsets(text, target, context.allocator)
		if cerr != nil {
			testing.expectf(t, false, "safe_chunk_offsets(text, %d) failed: %v", target, cerr)
			return
		}
		defer delete(cuts, context.allocator)

		prev := 0
		for c in cuts {
			// The interior-offset property is a guard for the indexing
			// below, so it returns instead of reporting and continuing.
			if c <= prev || c >= len(text) {
				testing.expectf(t, false,
					"target %d: cuts must be strictly increasing interior offsets (prev %d, cut %d)", target, prev, c)
				return
			}
			testing.expectf(t, text[c - 1] == '\n',
				"target %d: cut at %d must sit after a newline", target, c)
			testing.expectf(t, !((text[c] >= 0x09 && text[c] <= 0x0E) || text[c] == 0x20),
				"target %d: cut at %d precedes a byte the whitespace run continues over", target, c)
			if target > 1 {
				testing.expectf(t, c - prev >= target,
					"target %d: piece before cut %d is %d bytes", target, c, c - prev)
			}
			prev = c
		}
		if prev > 0 {
			testing.expectf(t, prev < len(text), "target %d: the tail piece must be non-empty", target)
		}
	}
}
