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

# The voiced kana, from the SAME codepoints: dakuten is the base + 1 and
# handakuten the base + 2, which is the second systematic thing about the
# syllabaries and the reason these are generated and not typed.
#
# ぢ and づ are deliberately absent, and this is the only judgement in
# this file.  They are not a third and fourth sound: they are alternative
# spellings of じ and ず, used where a base kana is reduplicated or
# compounded (つづく, ちぢむ), and Hepburn spells each pair identically
# BECAUSE they are the same sound.  Two consequences, and both matter
# here:
#
#   * skill(dakuten) is "one mark changes the sound", and these are the
#     one place where it does not -- so they are not instances of the
#     skill the criterion names.
#   * kana.pl joins katakana to hiragana on the ROMAJI, so two kana with
#     the romaji "ji" would make ヂ require both じ and ぢ, and ジ require
#     ぢ -- gating a common kana behind a vanishingly rare one.  The
#     importer refuses to guess at an ambiguous JMdict key for the same
#     reason; so does this.
#
# 23 per script, 46 in all.  The pairing itself is emitted as voiced/3 so
# that the prerequisite (が after か) and the confusable pair (か/が, one
# mark apart) are both derived from it rather than listed again.
VOICED = [
    ("g", "k",  1, [("ga","ka"),("gi","ki"),("gu","ku"),("ge","ke"),("go","ko")]),
    ("z", "s",  1, [("za","sa"),("ji","shi"),("zu","su"),("ze","se"),("zo","so")]),
    ("d", "t",  1, [("da","ta"),("de","te"),("do","to")]),
    ("b", "h",  1, [("ba","ha"),("bi","hi"),("bu","fu"),("be","he"),("bo","ho")]),
    ("p", "h",  2, [("pa","ha"),("pi","hi"),("pu","fu"),("pe","he"),("po","ho")]),
]
BASE_CP = {}
for _row, _cells in ROWS:
    for _r, _cp in _cells:
        BASE_CP[_r] = _cp

out = []
for script, pfx, delta in (("hiragana","hi",0), ("katakana","ka",0x60)):
    for row, cells in ROWS:
        line = []
        for romaji, cp in cells:
            line.append("kana(%s_%s, %s, '%s', %s, %s)." % (pfx, romaji, script, chr(cp+delta), romaji, row))
        out.append("\n".join(line))
    out.append("")

for script, pfx, delta in (("hiragana","hi",0), ("katakana","ka",0x60)):
    for row, _base_row, mark, cells in VOICED:
        line = []
        for romaji, base in cells:
            cp = BASE_CP[base] + mark
            line.append("kana(%s_%s, %s, '%s', %s, %s)." % (pfx, romaji, script, chr(cp+delta), romaji, row))
        out.append("\n".join(line))
    out.append("")

# voiced(VoicedId, BaseId, Mark) -- stated once per pair, per script.
for pfx in ("hi", "ka"):
    for row, _base_row, mark, cells in VOICED:
        line = []
        for romaji, base in cells:
            line.append("voiced(%s_%s, %s_%s, %s)."
                        % (pfx, romaji, pfx, base,
                           "dakuten" if mark == 1 else "handakuten"))
        out.append("\n".join(line))
    out.append("")

print("\n".join(out))
