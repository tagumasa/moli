#!/usr/bin/env python3
"""Reference control: MeCab+ipadic on the SAME sentences under the
SAME boundary-F1 protocol as bench/f1_kwdlc.odin (moli harness).

The sentence set is not re-derived here. f1_kwdlc.odin writes the
corpus it scored - one line per sentence, gold surfaces joined by
single spaces - to tmp/kwdlc_sentences.txt during its first pass, and
this control consumes that file: both arms tokenize the identical
sentence set by construction, and the knp parse/filter rules exist
once, on the Odin side. (Surfaces cannot contain the separator; the
protocol filters space-bearing sentences before scoring.)

Text is reconstructed from the gold surfaces, fed to mecab (EUC-JP
dic: encode per sentence, decode output), morpheme surfaces
accumulate interior boundaries, two-pointer against gold. A sentence
MeCab's EUC-JP dictionary cannot encode cannot be dropped from this
arm alone (the moli figure covers the whole corpus), so the control
computes the drop set once and REFUSES to score until the f1
harnesses drop the same sentences: it writes them (space-joined, the
corpus format) to tmp/kwdlc_euc_drops.txt and exits - re-run
bench/f1_kwdlc.odin (it consumes the drop set), then this control.
Matching is by content, so the dance is idempotent. Numbers-only
output.

Usage: python3 bench/f1_mecab_control.py   (from the repo root,
after bench/f1_kwdlc.odin has written tmp/kwdlc_sentences.txt)
"""
import subprocess
import sys
from pathlib import Path

CORPUS = Path("tmp/kwdlc_sentences.txt")
DROPS = Path("tmp/kwdlc_euc_drops.txt")


def euc_encodable(text):
    try:
        text.encode("euc_jp")
        return True
    except UnicodeEncodeError:
        return False


def class_before(text_b, off):
    """Same classifier as the Odin harness (text_b: UTF-8 bytes)."""
    if off <= 0 or off > len(text_b):
        return 5
    i = off - 1
    while i > 0 and off - i < 4 and (text_b[i] & 0xC0) == 0x80:
        i -= 1
    # decode rune at i
    x = text_b[i]
    if x < 0x80:
        r = x
    elif x & 0xE0 == 0xC0:
        r = ((x & 0x1F) << 6) | (text_b[i + 1] & 0x3F)
    elif x & 0xF0 == 0xE0:
        r = ((x & 0x0F) << 12) | ((text_b[i + 1] & 0x3F) << 6) | (text_b[i + 2] & 0x3F)
    else:
        r = ((x & 0x07) << 18) | ((text_b[i + 1] & 0x3F) << 12) | ((text_b[i + 2] & 0x3F) << 6) | (text_b[i + 3] & 0x3F)
    if 0x3040 <= r < 0x30A0:
        return 0
    if 0x30A0 <= r < 0x3100:
        return 1
    if 0x4E00 <= r < 0xA000:
        return 2
    if r < 0x80:
        return 3
    if 0xFF00 <= r < 0xFFEF:
        return 4
    return 5


def main():
    if not CORPUS.exists():
        print(f"{CORPUS} missing - run bench/f1_kwdlc.odin first "
              "(it writes the corpus it scored)", file=sys.stderr)
        return 1
    lines = CORPUS.read_text().splitlines()
    sentences = [line.split(" ") for line in lines]
    prior_drops = set(DROPS.read_text().splitlines()) if DROPS.exists() else set()
    sentences = [s for s in sentences if " ".join(s) not in prior_drops]

    # The EUC-JP gate: every sentence of the corpus must be encodable.
    # New unmappables extend the drop set and refuse the run - the f1
    # harnesses must drop them too before parity exists.
    unmappable = [" ".join(s) for s in sentences
                  if not euc_encodable("".join(s))]
    if unmappable:
        with DROPS.open("a") as fh:
            for s in unmappable:
                fh.write(s + "\n")
        print(f"euc_unmappable={len(unmappable)} of {len(sentences)} sentences "
              f"cannot cross MeCab's EUC-JP dictionary; appended to {DROPS} - "
              "re-run bench/f1_kwdlc.odin (it consumes the drop set), "
              "then this control", file=sys.stderr)
        return 1

    # One batch mecab run.
    batch = "".join("".join(s) + "\n" for s in sentences).encode("euc_jp")
    proc = subprocess.run(["mecab"], input=batch, stdout=subprocess.PIPE, check=True)
    out = proc.stdout.decode("euc_jp")

    # Parse mecab blocks (EOS-separated) in order.
    blocks = []
    cur = []
    for line in out.split("\n"):
        if line.endswith("\r"):
            line = line[:-1]
        if line == "EOS":
            blocks.append(cur)
            cur = []
            continue
        if not line:
            continue
        cur.append(line.split("\t")[0])
    assert len(blocks) == len(sentences), \
        f"mecab blocks {len(blocks)} != sentences {len(sentences)}"

    gold_total = pred_total = match_total = 0
    sent_n = 0
    over_cls = [0] * 6
    miss_cls = [0] * 6

    for gold_s, pred_s in zip(sentences, blocks):
        gold_bounds = []
        off = 0
        for i, m in enumerate(gold_s):
            off += len(m.encode("utf-8"))
            if i < len(gold_s) - 1:
                gold_bounds.append(off)
        pred_bounds = []
        off = 0
        for i, m in enumerate(pred_s):
            off += len(m.encode("utf-8"))
            if i < len(pred_s) - 1:
                pred_bounds.append(off)

        text_b = "".join(gold_s).encode("utf-8")
        gi = pi = 0
        while gi < len(gold_bounds) and pi < len(pred_bounds):
            if gold_bounds[gi] == pred_bounds[pi]:
                match_total += 1
                gi += 1
                pi += 1
            elif gold_bounds[gi] < pred_bounds[pi]:
                miss_cls[class_before(text_b, gold_bounds[gi])] += 1
                gi += 1
            else:
                over_cls[class_before(text_b, pred_bounds[pi])] += 1
                pi += 1
        while gi < len(gold_bounds):
            miss_cls[class_before(text_b, gold_bounds[gi])] += 1
            gi += 1
        while pi < len(pred_bounds):
            over_cls[class_before(text_b, pred_bounds[pi])] += 1
            pi += 1

        gold_total += len(gold_bounds)
        pred_total += len(pred_bounds)
        sent_n += 1

    p = match_total / pred_total
    r = match_total / gold_total
    f1 = 2 * p * r / (p + r)
    print(f"sentences={sent_n} euc_dropped={len(prior_drops)} euc_unmappable=0")
    print(f"gold_b={gold_total} pred_b={pred_total} match={match_total}")
    print(f"boundary precision={p:.4f} recall={r:.4f} F1={f1:.4f}")
    print(f"over-split cls: hira={over_cls[0]} kata={over_cls[1]} kan={over_cls[2]} ascii={over_cls[3]} fw={over_cls[4]} other={over_cls[5]}")
    print(f"missed     cls: hira={miss_cls[0]} kata={miss_cls[1]} kan={miss_cls[2]} ascii={miss_cls[3]} fw={miss_cls[4]} other={miss_cls[5]}")
    # The paired moli figure is the faithful-pass output of the
    # f1_kwdlc run that wrote this corpus - same sentences, same
    # protocol, printed just before this control ran.


if __name__ == "__main__":
    sys.exit(main())
