#!/usr/bin/env python3
"""Convert the DWDSmor Open Edition wordbook into a MeCab 13-column
CSV for moli's German trial.

Inputs (all under gitignored dict/):
  dict/dwdsmor-src/lexicon/open/wb/openwb.xml  - the Open Edition
    wordbook (GPL-2.0, github.com/zentrum-lexikographie/dwdsmor;
    used locally, never committed past dict/)
  dict/venv/                                   - `pip install dwdsmor`
    provides the paradigm-generation pipeline this script drives.

Output: dict/german/german.csv - one row per inflected word form:
  surface,0,0,COST,POS,*,*,*,*,*,lemma,*,*
(ids all 0, no matrix: the trial runs on the default connection cost;
multi-word forms are skipped - MeCab surfaces must not contain the
space that separates input tokens).

Cost model: dictionary rows cost 1000 (a known word is
cheap), unknown rules stay at 6500/7500, and every boundary costs the
7000 default connection cost. Flat per-node pricing can never split an
OOV compound (the split pays one extra node + one extra boundary), so
the split decision is handed to moli's search-time
Tokenize_Options.unk_cost_per_rune (~2300/rune clears the 4-rune gap
Haus|museum without breaking whole short OOV words like "Demo" - the
window is (1000+7000)/4 < c < (1000+7000)/3). To give splits the right
shape the converter also emits:
  - articles (bestimmter/unbestimmter Artikel) via the ART paradigm;
  - Fugenlaute rows (-s-/-es-/-e-/-n-/-en-/-ns) as POS FUGE so a
    compound joint reads Arbeit|s|platz, not Arbeit|splatz;
  - a lowercase copy of every capitalized noun form, because every
    German compound part after the first is lowercase (platz, not
    Platz, inside Arbeitsplatz);
  - a bounded lidx retry for formless homograph lemmas.

Usage: dict/venv/bin/python scripts/gen_german_dict.py   (repo root)
"""
import csv
import multiprocessing as mp
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# The dwdsmor venv's site-packages, resolved by glob so a venv rebuilt
# under another python minor still imports (the documented invocation
# runs this script with the venv's own interpreter, where the insert is
# redundant but harmless).
site_dirs = sorted((ROOT / "dict/venv/lib").glob("python*/site-packages"))
if not site_dirs:
    sys.exit("dict/venv is not set up (missing dict/venv/lib/python*/site-packages)")
sys.path.insert(0, str(site_dirs[0]))

from dwdsmor import analyzer, generator  # noqa: E402
from dwdsmor.tools.paradigm import (  # noqa: E402
    create_formdict,
    get_paradigm_dicts,
)

WB = ROOT / "dict/dwdsmor-src/lexicon/open/wb/openwb.xml"
OUT = ROOT / "dict/german/german.csv"

DICT_COST = 1000
FUGEN = ("s", "es", "e", "n", "en", "ns")
NOUN_POS = {"NN", "NPROP"}

# Wortklasse (wordbook) -> paradigm-tool POS code -> MeCab POS1.
POS_MAP = {
    "Substantiv": ("NN", "NN"),
    "Eigenname": ("NPROP", "NPROP"),
    "Verb": ("V", "V"),
    "Adjektiv": ("ADJ", "ADJ"),
    "partizipiales Adjektiv": ("ADJ", "ADJ"),
    "Adverb": ("ADV", "ADV"),
    "Präposition": ("PREP", "PREP"),
    "Konjunktion": ("KONJ", "KONJ"),
    "Indefinitpronomen": ("INDEF", "PRO"),
    "Possessivpronomen": ("POSS", "PRO"),
    "Personalpronomen": ("PPRO", "PRO"),
    "Relativpronomen": ("REL", "PRO"),
    "Interrogativpronomen": ("WPRO", "PRO"),
    "Pronominaladverb": ("ADV", "ADV"),
    "Kardinalzahlwort": ("CARD", "CARD"),
    "Ordinalzahlwort": ("ORD", "CARD"),
    "Bruchzahlwort": ("FRAC", "CARD"),
    "Demonstrativpronomen": ("DEM", "PRO"),
    "Artikel": ("ART", "ART"),
    "bestimmter Artikel": ("ART", "ART"),
    "unbestimmter Artikel": ("ART", "ART"),
    "Partikel": (None, "PART"),
    "Interjektion": (None, "INTJ"),
}


def read_wordbook():
    ns = {"d": "http://www.dwds.de/ns/1.0"}
    tree = ET.parse(WB)
    for artikel in tree.getroot().findall("d:Artikel", ns):
        form = artikel.find("d:Formangabe[@Typ='Hauptform']", ns)
        if form is None:
            continue
        schreibung = form.find("d:Schreibung", ns)
        gram = form.find("d:Grammatik", ns)
        if schreibung is None or gram is None:
            continue
        wk = gram.find("d:Wortklasse", ns)
        if wk is None or not wk.text:
            continue
        yield schreibung.text.strip(), wk.text.strip()


_workers = {}


def _init():
    """Per-process automata (they are not fork-safe to share). The
    analyzer must be the INDEX automaton - the paradigm pipeline reads
    lemma/paradigm indices off its traversals; the plain lemma
    automaton yields none, and every article and homograph comes back
    formless."""
    _workers["a"] = analyzer("index")
    _workers["g"] = generator("index")


def forms_of(item):
    lemma, code = item
    got = set()

    def harvest(gen_lemma=None, lidx=None, user=False):
        try:
            formdict = create_formdict(_workers["g"], _workers["a"], "index",
                                       gen_lemma or lemma, lidx, None,
                                       code, user)
            if formdict:
                for pd in get_paradigm_dicts(lemma, formdict,
                                             no_cats=True, no_lemma=False,
                                             empty=True):
                    for entry in pd.get("paradigm", []):
                        for form in entry.get("forms", []):
                            got.add(form.strip())
        except Exception:
            pass

    if code == "ART":
        # The wordbook cites 'der'/'ein', but the article paradigms
        # hang off the citation forms the analyzer reports ('die' for
        # der/die/das, 'eine' for the indefinite series) - generate
        # from those.
        try:
            citations = sorted({t.analysis for t in _workers["a"].analyze(
                lemma, idx_to_int=True)
                if t.pos == "ART" and t.analysis})
        except Exception:
            citations = []
        for cit in citations or [lemma]:
            harvest(gen_lemma=cit)
        if not got:
            harvest(user=True)
    else:
        harvest()
    if not got:
        # Homograph lemmas can come back formless when the un-narrowed
        # spec mix confuses the generator; retry each distinct lemma
        # index the analyzer reports for this surface, bounded.
        try:
            lidxs = sorted({t.lidx for t in _workers["a"].analyze(
                lemma, idx_to_int=True)
                if t.analysis == lemma and getattr(t, "lidx", None)})[:4]
        except Exception:
            lidxs = []
        for lidx in lidxs:
            harvest(lidx=lidx)
            if got:
                break
    return lemma, got


def main():
    lemmas = list(read_wordbook())
    print(f"wordbook lemmas: {len(lemmas)}")

    work = []
    skipped_pos = {}
    for lemma, wk in lemmas:
        code, pos1 = POS_MAP.get(wk, (None, None))
        if code is None:
            skipped_pos[wk] = skipped_pos.get(wk, 0) + 1
        else:
            work.append((lemma, code, pos1))

    with mp.Pool(8, initializer=_init) as pool:
        results = pool.map(forms_of, [(l, c) for l, c, _ in work],
                           chunksize=32)

    # Rows carry their own work item's POS: one lemma can appear under
    # several Wortklassen ('der' is article AND demonstrative/relative
    # pronoun) and each reading gets its own rows.
    seen = set()
    rows = []
    lower_rows = 0
    failed = 0
    for (lemma, code, pos1), (_, got) in zip(work, results):
        if not got:
            failed += 1
            continue
        noun = code in NOUN_POS
        for form in sorted(got):
            if " " in form or "\t" in form:
                continue  # multi-word forms never match token input
            if len(form) < 2:
                # The wordbook lists letter names (a, d, ...) as noun
                # lemmas; kept, they seed junk splits of short OOV
                # words ("da" -> d|a under a per-rune unknown price).
                continue
            surfaces = [form]
            # Lowercase copies serve compound parts (platz inside
            # Arbeitsplatz), which are never single letters - and
            # copying abbreviation nouns (D, A) would seed junk splits
            # of short OOV words ("da" -> d|a).
            if noun and len(form) >= 3:
                low = form.lower()
                if low != form:
                    surfaces.append(low)
            for surface in surfaces:
                key = (surface, pos1, lemma)
                if key in seen:
                    continue
                seen.add(key)
                rows.append(key)
                if surface != form:
                    lower_rows += 1
    for f in FUGEN:
        rows.append((f, "FUGE", "-" + f + "-"))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", newline="") as fh:
        w = csv.writer(fh)
        for form, pos1, lemma in rows:
            w.writerow([form, 0, 0, DICT_COST, pos1, "*", "*", "*", "*", "*",
                        lemma, "*", "*"])
    art_rows = sum(1 for _, pos1, _ in rows if pos1 == "ART")
    print(f"rows written: {len(rows)} "
          f"(articles: {art_rows}, Fugenlaute: {len(FUGEN)}, "
          f"lowercase noun copies: {lower_rows}, "
          f"lemmas with no forms: {failed})")
    if skipped_pos:
        print("skipped Wortklassen:", skipped_pos)

    # Sibling resources, discovered at load: unknown words carry a real
    # price (6500 far above the 1000 dictionary cost, so a registered
    # word beats its unknown reading), and the letter class fires
    # unknown candidates even beside prefix dictionary matches (invoke)
    # with whole-run grouping - without it, an OOV word like "das"
    # splits into dictionary fragments ("d"+"as") because the prefix
    # match suppressed the whole-word unknown. No ranges: the built-in
    # classification already covers German (Latin letters incl.
    # umlauts and sharp S).
    (OUT.parent / "unk.def").write_text(
        "ALPHA,0,0,6500,NOUN,*,*,*,*\n"
        "DEFAULT,0,0,7500,NOUN,*,*,*,*\n"
    )
    (OUT.parent / "char.def").write_text(
        "DEFAULT 1 1 0\n"
        "ALPHA 1 1 0\n"
    )
    print("wrote sibling unk.def + char.def")


if __name__ == "__main__":
    sys.exit(main())
