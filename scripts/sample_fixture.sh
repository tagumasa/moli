#!/usr/bin/env bash
# sample_fixture.sh — deterministically sample a MeCab-CSV fixture from
# a downloaded source dictionary (provenance and licenses:
# tests/fixtures/README.md).
#
# Usage: sample_fixture.sh <src.csv> <count> <seed> <out.csv>
#
# The sample is <count> rows drawn without replacement by GNU shuf,
# seeded through --random-source so regeneration is byte-identical on
# the same coreutils. Then the first two rows (file order) of the first
# surface that occurs more than once are appended — a real homograph
# pair for the entry-chain tests. Field-1 matching is exact for these
# sources: their surfaces never contain commas or quotes.
set -euo pipefail

src=$1; count=$2; seed=$3; out=$4

if [ ! -f "$src" ]; then
    echo "no such source: $src (run: just dict-fetch)" >&2
    exit 1
fi

mkdir -p "$(dirname "$out")"

shuf --random-source=<(yes "$seed") -n "$count" "$src" > "$out"

# awk scans the whole file and prints only the first duplicated surface
# (file order); no early-exit pipe stages — under `set -o pipefail` a
# `head` closing early would SIGPIPE the producer.
dup_surface=$(cut -d, -f1 "$src" | awk 'seen[$0]++ == 1 && !done { print; done = 1 }')
if [ -n "$dup_surface" ]; then
    awk -F, -v s="$dup_surface" '$1 == s && n++ < 2' "$src" >> "$out"
else
    echo "warning: $src has no homographs; fixture lacks a chain case" >&2
fi

wc -c "$out"
