#!/usr/bin/env python3
"""Parse callgrind_annotate output into per-line coverage of src/moli.

Method:
- annotation blocks give absolute line numbers via `-- line N ---` headers;
  count lines are executed, `.` lines are not, `=>` call arrows are skipped;
- reconstructed source text is cross-checked against the real file;
- "code lines" are non-blank, non-comment lines inside top-level proc bodies
  (`name :: proc` .. column-0 `}`), excluding lone closers and
  parameter/field-style declaration lines (`ident: type,` with no `=`).
"""
import re, sys, collections
from pathlib import Path

annot = "tmp/cov_annot_all.txt"


def moli_files():
    """Derived from the tree (same rule as cov_instr.py): a literal
    list went stale whenever a new source file landed. Platform-
    suffixed files compiled out of this build are excluded."""
    out = []
    for p in sorted(Path("src/moli").glob("*.odin")):
        if p.stem.endswith("_windows") and sys.platform != "win32":
            continue
        if p.stem.endswith("_posix") and sys.platform == "win32":
            continue
        out.append(p.stem)
    return out


files = moli_files()

# ---- 1. parse annotation -> {file: {lineno: executed_bool}} ----
covered = {f: {} for f in files}
cur_file = None
lineno = 0
mismatch = 0
checked = 0
re_file = re.compile(r"^-- User-annotated source: src/moli/(\w+)\.odin")
re_line = re.compile(r"^-- line (\d+) -+$")
re_cnt  = re.compile(r"^\s*([\d,]+) \(\s*[\d.]+%\)\s+(.*)$")
re_dot  = re.compile(r"^\s*\.\s+(.*)$")

with open(annot, errors="replace") as fh:
    for raw in fh:
        line = raw.rstrip("\n")
        m = re_file.match(line)
        if m:
            cur_file = m.group(1); lineno = 0
            continue
        if cur_file is None:
            continue
        if "<counts for unidentified lines" in line:
            cur_file = None          # tail block has its own broken numbering
            continue
        m = re_line.match(line)
        if m:
            lineno = int(m.group(1)) - 1   # next source line is N
            continue
        if lineno == 0:
            continue
        if "=>" in line.split("  ")[0] or re.search(r"\(\s*[\d.]+%\)\s+=>", line) or "=> " in line:
            # call-arrow rows carry no source line
            if "=> " in line:
                continue
        m = re_cnt.match(line)
        is_arrow = " => " in line
        if m and not is_arrow:
            covered[cur_file[0:0] or cur_file][lineno] = True
            text = m.group(2)
            lineno += 1
        elif (m2 := re_dot.match(line)):
            covered[cur_file].setdefault(lineno, False)
            text = m2.group(1)
            lineno += 1
        else:
            continue
        # cross-check against the real source
        src = open(f"src/moli/{cur_file}.odin", errors="replace").read().split("\n")
        if lineno - 1 < len(src):
            checked += 1
            if src[lineno - 1].strip() != text.strip():
                mismatch += 1

print(f"cross-check: {checked} lines, {mismatch} mismatches", file=sys.stderr)

# ---- 2. proc bodies from source ----
re_proc = re.compile(r"^([a-zA-Z_][a-zA-Z_0-9]*) :: proc")
re_closer = re.compile(r"^\}$|^\)\s*$")
re_decl = re.compile(r"^\t[a-zA-Z_][a-zA-Z_0-9]*:\s*[^=]+,?$")
code_lines = {}   # file -> set of line numbers classified as code
procs = []        # (file, name, start, end)
for f in files:
    src = open(f"src/moli/{f}.odin", errors="replace").read().split("\n")
    code = set()
    i = 0
    while i < len(src):
        m = re_proc.match(src[i])
        if m:
            start = i
            j = i
            while j < len(src) and not (j > i and re.match(r"^\}$", src[j])):
                j += 1
            procs.append((f, m.group(1), start + 1, j + 1))
            # first line containing '{' delimits the signature
            brace = next((k for k in range(start, j) if "{" in src[k]), j)
            for k in range(start, j):
                t = src[k].strip()
                if not t or t.startswith("//"):
                    continue
                if re.match(r"^[})\]]+,?$", t):
                    continue
                if k < brace and re_decl.match(src[k]):
                    continue
                if k > brace and re_decl.match(src[k]) and "=" not in t:
                    continue
                code.add(k + 1)
            i = j + 1
        else:
            i += 1
    code_lines[f] = code

# ---- 3. report ----
total_c = total_x = 0
print(f"{'file':<18} {'exec/total':>12} {'%':>7}")
dark_groups = []
for f in files:
    code = code_lines[f]
    if not code:
        continue
    x = sum(1 for n in code if covered[f].get(n - 1))
    total_c += len(code); total_x += x
    pct = 100.0 * x / len(code)
    print(f"{f+'.odin':<18} {x:>5}/{len(code):<6} {pct:6.1f}%")
    # dark groups: consecutive uncovered code lines
    ns = sorted(n for n in code if not covered[f].get(n - 1))
    for n in ns:
        if dark_groups and dark_groups[-1][0] == f and dark_groups[-1][2] == n - 1:
            dark_groups[-1] = (f, dark_groups[-1][1], n)
        else:
            dark_groups.append((f, n, n))
pct = 100.0 * total_x / total_c
print(f"{'TOTAL':<18} {total_x:>5}/{total_c:<6} {pct:6.1f}%")

# map dark groups to procs
print("\n-- dark regions (uncovered code lines, >=2 consecutive) --")
srcs = {f: open(f"src/moli/{f}.odin", errors="replace").read().split("\n") for f in files}
for (f, a, b) in dark_groups:
    if b - a < 1:
        continue
    pname = "?"
    for (pf, pn, s, e) in procs:
        if pf == f and s <= a <= e:
            pname = pn; break
    snippet = srcs[f][a - 1].strip()[:60]
    print(f"{f}.odin:{a}-{b} in {pname}: {snippet}")
