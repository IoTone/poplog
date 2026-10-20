#!/usr/bin/env python3
# mkkana.py -- emit the kana fact table for graph/ja/kana.pl.
#
# The 92 base kana are generated from their Unicode codepoints rather than
# typed, so a glyph cannot be subtly wrong.  Katakana is the hiragana block
# plus 0x60, which is the one systematic thing about the two syllabaries.
#
#     python3 tools/mkkana.py > /tmp/kana-facts.pl
#
# The output is the fact block in graph/ja/kana.pl, between its header and
# the derivation rules; regenerate and diff if you doubt a glyph.
ROWS = [
    ("vowel",   [("a",0x3042),("i",0x3044),("u",0x3046),("e",0x3048),("o",0x304A)]),
    ("k",       [("ka",0x304B),("ki",0x304D),("ku",0x304F),("ke",0x3051),("ko",0x3053)]),
    ("s",       [("sa",0x3055),("shi",0x3057),("su",0x3059),("se",0x305B),("so",0x305D)]),
    ("t",       [("ta",0x305F),("chi",0x3061),("tsu",0x3064),("te",0x3066),("to",0x3068)]),
    ("n_row",   [("na",0x306A),("ni",0x306B),("nu",0x306C),("ne",0x306D),("no",0x306E)]),
    ("h",       [("ha",0x306F),("hi",0x3072),("fu",0x3075),("he",0x3078),("ho",0x307B)]),
    ("m",       [("ma",0x307E),("mi",0x307F),("mu",0x3080),("me",0x3081),("mo",0x3082)]),
    ("y",       [("ya",0x3084),("yu",0x3086),("yo",0x3088)]),
    ("r",       [("ra",0x3089),("ri",0x308A),("ru",0x308B),("re",0x308C),("ro",0x308D)]),
    ("w",       [("wa",0x308F),("wo",0x3092)]),
    ("moraic",  [("n",0x3093)]),
]
out = []
for script, pfx, delta in (("hiragana","hi",0), ("katakana","ka",0x60)):
    for row, cells in ROWS:
        line = []
        for romaji, cp in cells:
            line.append("kana(%s_%s, %s, '%s', %s, %s)." % (pfx, romaji, script, chr(cp+delta), romaji, row))
        out.append("\n".join(line))
    out.append("")
print("\n".join(out))
