#!/usr/bin/env python3
"""Per-instruction coverage of src/moli from a raw callgrind dump.

Input:  tmp/callgrind_instr.out  (valgrind --tool=callgrind --dump-instr=yes)
Method: every cost line in the callgrind format carries its instruction
address (absolute 0x.. or +delta or *), and a cost line exists iff that
instruction executed.  Line attribution comes from the binary's DWARF
via addr2line -- the callgrind line column is ignored -- so instructions
folded into inline/memcpy sequences still land on their own source lines
where DWARF puts them.  Line coverage = a code line is covered iff some
instruction attributed to it executed.  (valgrind serializes threads, so
genuinely-racy windows cannot show up here; that is a property of the
tool, recorded in docs/benchmarks.md.)
"""
import re, subprocess, sys
from pathlib import Path

CALLGRIND = "tmp/callgrind_instr.out"
BINARY = "tmp/test_debug"


def moli_files():
    """The tree's own file list, derived - a literal list went stale
    whenever a new source file landed (new files silently unmeasured,
    their functions reported as never executed). Platform-suffixed
    files compiled out of this build are excluded: their lines carry
    no machine code here and would count as permanently dark."""
    out = []
    for p in sorted(Path("src/moli").glob("*.odin")):
        if p.stem.endswith("_windows") and sys.platform != "win32":
            continue
        if p.stem.endswith("_posix") and sys.platform == "win32":
            continue
        out.append(p.stem)
    return out


files = moli_files()

# ---- 1. collect (address, executed) pairs + moli function blocks ----
# Cost lines in the dump have exactly three fields: address position
# (absolute 0x.. or +delta or *), source-line position, and one Ir cost
# (* repeats the previous).  Anything else is a header/name/call record.
addr_seen = {}          # addr -> True (a cost line implies execution)
fn_total = {}           # "moli::name" -> total Ir in its own blocks
cur_fn = None
cur_addr = None
prev_cost = 0

with open(CALLGRIND, errors="replace") as fh:
    for raw in fh:
        line = raw.rstrip("\n")
        if line.startswith(("summary:", "desc:", "positions:", "part:",
                            "version:", "total-")):
            continue                     # header records (summary sits early in 3.22)
        if line.startswith("fn="):
            cur_fn = line.split(None, 1)[1] if " " in line else line[3:]
            fn_total.setdefault(cur_fn, 0)
            continue
        if line.startswith(("cfn=", "cfi=", "fl=", "fi=", "ob=", "cob=",
                            "calls=", "recursion=", "jfi=")):
            continue
        f = line.split()
        if len(f) != 3 or not (f[2] == "*" or f[2].isdigit()):
            continue                     # header/comment/other record
        if f[0].startswith("0x"):
            cur_addr = int(f[0], 16)
        elif f[0].startswith("+"):
            cur_addr = cur_addr + int(f[0][1:]) if cur_addr is not None else None
        elif f[0] != "*":
            continue
        cost = prev_cost if f[2] == "*" else int(f[2])
        prev_cost = cost
        if cur_addr is None:
            continue
        addr_seen[cur_addr] = True
        if cur_fn and cur_fn.startswith("moli::"):
            fn_total[cur_fn] += cost

# ---- 2. addr2line every executed address ----
addrs = sorted(addr_seen)
inp = "\n".join(hex(a) for a in addrs)
out = subprocess.run(["addr2line", "-e", BINARY, "-f", "-C"],
                     input=inp, capture_output=True, text=True)
lines = out.stdout.splitlines()          # pairs: func, file:line
covered = {f: set() for f in files}      # file stem -> {lineno}
addr_loc = {}                            # addr -> (file, line) for spot checks
execd_names = set()                      # moli:: func names on executed addrs
for i, a in enumerate(addrs):
    if 2 * i + 1 >= len(lines):
        break
    loc = lines[2 * i + 1]
    m = re.match(r"^.*/src/moli/(\w+)\.odin:(\d+)", loc)
    if m:
        f, n = m.group(1), int(m.group(2))
        if f in covered:
            covered[f].add(n)
            addr_loc[a] = (f, n)
            execd_names.add(lines[2 * i])

# ---- 3. code-line classification (same rules as cov_parse.py) ----
re_proc = re.compile(r"^([a-zA-Z_][a-zA-Z_0-9]*) :: proc")
re_decl = re.compile(r"^\t[a-zA-Z_][a-zA-Z_0-9]*:\s*[^=]+,?$")
code_lines, procs = {}, []
for f in files:
    src = open(f"src/moli/{f}.odin", errors="replace").read().split("\n")
    code, i = set(), 0
    while i < len(src):
        m = re_proc.match(src[i])
        if m:
            start = i; j = i
            while j < len(src) and not (j > i and re.match(r"^\}$", src[j])):
                j += 1
            procs.append((f, m.group(1), start + 1, j + 1))
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

# ---- 4. report ----
# Ground truth for "lines that carry machine code at all": the binary's
# decoded DWARF line table.  A dark line absent from it is structural
# (multi-line literal continuation, else-brace, jump-table case label)
# and can never light up under any execution; a dark line present in it
# is genuinely unexecuted code.
has_code = {f: set() for f in files}
cur_src = None
re_moli = re.compile(r"^.*/src/moli/(\w+)\.odin:\s*$")
dw = subprocess.run(["readelf", "--debug-dump=decodedline", BINARY],
                    capture_output=True, text=True).stdout
for l in dw.splitlines():
    m = re_moli.match(l.strip())
    if m:
        cur_src = m.group(1) if m.group(1) in has_code else None
        continue
    if cur_src:
        f = l.split()
        if len(f) >= 3 and f[0] == f"{cur_src}.odin" and f[1].isdigit():
            has_code[cur_src].add(int(f[1]))

total_c = total_x = 0
dark, dark_struct, dark_exec = [], [], []
for f in files:
    code = code_lines[f]
    if not code:
        continue
    x = sum(1 for n in code if n in covered[f])
    total_c += len(code); total_x += x
    print(f"{f+'.odin':<18} {x:>5}/{len(code):<6} {100.0*x/len(code):6.1f}%")
    for n in sorted(code):
        if n in covered[f]:
            continue
        dark.append((f, n))
        (dark_exec if n in has_code[f] else dark_struct).append((f, n))
print(f"{'TOTAL':<18} {total_x:>5}/{total_c:<6} {100.0*total_x/total_c:6.1f}%")
den = total_x + len(dark_exec)
print(f"executable-line coverage: {total_x}/{den} = {100.0*total_x/den:.1f}%"
      f"  ({len(dark_struct)} structural dark lines carry no machine code)")

# Branch coverage: every conditional jump with either side executed is
# an encountered site; it counts when BOTH its fall-through and its
# target executed. Sites are scoped to moli the same way the line and
# function passes scope: a jump counts only when its own address
# attributes (addr2line) to a src/moli file - the binary's runtime and
# test-harness code is not part of the denominator. No landing-side
# exclusion (unlike the retired ad-hoc 2026-09-01 pass, which dropped
# runtime-check arms) — this figure errs low.
dis = subprocess.run(["objdump", "-d", "--no-show-raw-insn", BINARY],
                     capture_output=True, text=True).stdout
re_cond = re.compile(r"^\s*([0-9a-f]+):\s+j(?!mp)\w{1,2}\s+([0-9a-f]+)")
re_ins = re.compile(r"^\s*([0-9a-f]+):")
prev_cond = None
encountered = both_dirs = 0
for l in dis.splitlines():
    mi = re_ins.match(l)
    if not mi:
        continue
    if prev_cond is not None:
        a, tgt = prev_cond
        fall = int(mi.group(1), 16)
        if a in addr_loc:  # the site itself is moli code
            encountered += 1
            if fall in addr_seen and tgt in addr_seen:
                both_dirs += 1
        prev_cond = None
    mc = re_cond.match(l)
    if mc:
        prev_cond = (int(mc.group(1), 16), int(mc.group(2), 16))
if encountered:
    print(f"branch coverage: {both_dirs}/{encountered} = "
          f"{100.0*both_dirs/encountered:.1f}% of encountered moli conditional "
          f"sites executed in both directions")

execd = [k for k, v in fn_total.items() if v > 0 and k.startswith("moli::")]
moli_fns = [k for k in fn_total if k.startswith("moli::")]
print(f"\nfunctions with Ir>0: {len(execd)}/{len(moli_fns)} moli:: blocks")

# Symbol-level function coverage: distinct moli:: text symbols in the
# binary vs distinct moli:: names among executed addresses.
nmsyms = subprocess.run(["nm", BINARY], capture_output=True, text=True).stdout
defined = set()
for l in nmsyms.splitlines():
    f = l.split()
    if len(f) == 3 and f[1] == "T" and f[2].startswith("moli::"):
        defined.add(f[2])
hit = sorted(n for n in defined if n in execd_names)
print(f"function coverage: {len(hit)}/{len(defined)} moli:: symbols executed")
for n in sorted(defined - execd_names):
    print(f"  not executed: {n}")

print("\n-- dark code lines --")
srcs = {f: open(f"src/moli/{f}.odin", errors="replace").read().split("\n") for f in files}
groups = []
for (f, n) in dark:
    if groups and groups[-1][0] == f and groups[-1][2] == n - 1:
        groups[-1] = (f, groups[-1][1], n)
    else:
        groups.append((f, n, n))
for (f, a, b) in groups:
    kind = "CODE" if any(n in has_code[f] for n in range(a, b + 1)) else "----"
    pname = next((pn for (pf, pn, s, e) in procs if pf == f and s <= a <= e), "?")
    print(f"{kind} {f}.odin:{a}-{b} in {pname}: {srcs[f][a-1].strip()[:60]}")

# ---- 5. spot checks ----
if "--acquire" in sys.argv:
    print("\n-- acquire instructions (addr, loc) --")
    for a in addrs:
        if a in addr_loc and addr_loc[a][0] == "analyzer" and 70 <= addr_loc[a][1] <= 90:
            print(f"0x{a:x} analyzer.odin:{addr_loc[a][1]}")
