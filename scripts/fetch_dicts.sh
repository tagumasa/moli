#!/usr/bin/env bash
# fetch_dicts.sh — populate dict/ (gitignored) with the source dictionaries
# the bench harnesses load and the committed fixture samples are drawn
# from. ~165 MB download, ~700 MB extracted. Nothing under dict/ is ever
# committed; see README.md ("Dictionaries") for licences and terms.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dict/downloads
cd dict

# UniDic 2.1.2 source (lex.csv, 756K rows, 21 columns, UTF-8; char/unk/
# matrix defs alongside). Copyrighted free software by the UniDic
# Consortium, released under any of GPL / LGPL / BSD — the committed
# fixture samples use the BSD option.
if [ ! -d unidic-mecab-2.1.2_src ]; then
    curl -L -o downloads/unidic-mecab-2.1.2_src.zip \
        https://clrd.ninjal.ac.jp/unidic_archive/cwj/2.1.2/unidic-mecab-2.1.2_src.zip
    echo "6cce98269214ce7de6159f61a25ffc5b436375c098cc86d6aa98c0605cbf90d4  downloads/unidic-mecab-2.1.2_src.zip" | sha256sum -c -
    unzip -q downloads/unidic-mecab-2.1.2_src.zip
fi

# mecab-jieba 0.1.1 — jieba.csv (584K rows, 9 columns) is the pure jieba
# dictionary conversion. MIT, Copyright (c) the Lindera project.
if [ ! -d mecab-jieba-0.1.1 ]; then
    curl -sL -o downloads/mecab-jieba-0.1.1.tar.gz \
        https://codeload.github.com/lindera/mecab-jieba/tar.gz/refs/tags/0.1.1
    echo "37e4c94d5b41b69855b0172290350b173ea0ca9df1d572fef7e61b97019b6fc1  downloads/mecab-jieba-0.1.1.tar.gz" | sha256sum -c -
    tar -xzf downloads/mecab-jieba-0.1.1.tar.gz
fi

# mecab-ipadic 2.7.0-20070801 — the lexicons moli loads are UTF-8, but
# ipadic ships EUC-JP per-POS CSVs, so convert after extraction: every
# *.csv (shell glob order) through iconv into one lex.csv, plus
# char.def and unk.def; matrix.def is pure ASCII and copied as-is.
# NAIST licence with ICOT terms (COPYING inside the archive) — fetched
# and used locally, never distributed: no ipadic row is committed.
if [ ! -f ipadic-utf8/lex.csv ]; then
    if [ ! -d mecab-ipadic-2.7.0-20070801 ]; then
        curl -L -o downloads/mecab-ipadic-2.7.0-20070801.tar.gz \
            https://downloads.sourceforge.net/project/mecab/mecab-ipadic/2.7.0-20070801/mecab-ipadic-2.7.0-20070801.tar.gz
        echo "b62f527d881c504576baed9c6ef6561554658b175ce6ae0096a60307e49e3523  downloads/mecab-ipadic-2.7.0-20070801.tar.gz" | sha256sum -c -
        tar -xzf downloads/mecab-ipadic-2.7.0-20070801.tar.gz
    fi
    mkdir -p ipadic-utf8
    ( cd mecab-ipadic-2.7.0-20070801 && for f in *.csv; do iconv -f EUC-JP -t UTF-8 "$f"; done ) \
        > ipadic-utf8/lex.csv
    iconv -f EUC-JP -t UTF-8 mecab-ipadic-2.7.0-20070801/char.def > ipadic-utf8/char.def
    iconv -f EUC-JP -t UTF-8 mecab-ipadic-2.7.0-20070801/unk.def > ipadic-utf8/unk.def
    cp mecab-ipadic-2.7.0-20070801/matrix.def ipadic-utf8/matrix.def
fi

echo "UniDic:  dict/unidic-mecab-2.1.2_src/lex.csv   (GPL/LGPL/BSD — fixtures use BSD)"
echo "jieba:   dict/mecab-jieba-0.1.1/jieba.csv      (MIT)"
echo "ipadic:  dict/ipadic-utf8/lex.csv              (NAIST/ICOT — converted to UTF-8)"
