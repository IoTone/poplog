% examples/langpop/graph/ja/kana.pl -- the two syllabaries, below everything else.
%
% Generated from Unicode codepoints rather than typed, so a glyph cannot
% be wrong: see tools/mkkana.py.  The 92 base kana first, then the 46
% voiced ones -- dakuten is the base + 1 and handakuten the base + 2 --
% each requiring its base, because a student who cannot read か cannot be
% taught が.  Youon is still a skill rather than glyphs of its own.
%
% kana(Id, Script, Glyph, Romaji, Row).

kana(hi_a, hiragana, 'あ', a, vowel).
kana(hi_i, hiragana, 'い', i, vowel).
kana(hi_u, hiragana, 'う', u, vowel).
kana(hi_e, hiragana, 'え', e, vowel).
kana(hi_o, hiragana, 'お', o, vowel).
kana(hi_ka, hiragana, 'か', ka, k).
kana(hi_ki, hiragana, 'き', ki, k).
kana(hi_ku, hiragana, 'く', ku, k).
kana(hi_ke, hiragana, 'け', ke, k).
kana(hi_ko, hiragana, 'こ', ko, k).
kana(hi_sa, hiragana, 'さ', sa, s).
kana(hi_shi, hiragana, 'し', shi, s).
kana(hi_su, hiragana, 'す', su, s).
kana(hi_se, hiragana, 'せ', se, s).
kana(hi_so, hiragana, 'そ', so, s).
kana(hi_ta, hiragana, 'た', ta, t).
kana(hi_chi, hiragana, 'ち', chi, t).
kana(hi_tsu, hiragana, 'つ', tsu, t).
kana(hi_te, hiragana, 'て', te, t).
kana(hi_to, hiragana, 'と', to, t).
kana(hi_na, hiragana, 'な', na, n_row).
kana(hi_ni, hiragana, 'に', ni, n_row).
kana(hi_nu, hiragana, 'ぬ', nu, n_row).
kana(hi_ne, hiragana, 'ね', ne, n_row).
kana(hi_no, hiragana, 'の', no, n_row).
kana(hi_ha, hiragana, 'は', ha, h).
kana(hi_hi, hiragana, 'ひ', hi, h).
kana(hi_fu, hiragana, 'ふ', fu, h).
kana(hi_he, hiragana, 'へ', he, h).
kana(hi_ho, hiragana, 'ほ', ho, h).
kana(hi_ma, hiragana, 'ま', ma, m).
kana(hi_mi, hiragana, 'み', mi, m).
kana(hi_mu, hiragana, 'む', mu, m).
kana(hi_me, hiragana, 'め', me, m).
kana(hi_mo, hiragana, 'も', mo, m).
kana(hi_ya, hiragana, 'や', ya, y).
kana(hi_yu, hiragana, 'ゆ', yu, y).
kana(hi_yo, hiragana, 'よ', yo, y).
kana(hi_ra, hiragana, 'ら', ra, r).
kana(hi_ri, hiragana, 'り', ri, r).
kana(hi_ru, hiragana, 'る', ru, r).
kana(hi_re, hiragana, 'れ', re, r).
kana(hi_ro, hiragana, 'ろ', ro, r).
kana(hi_wa, hiragana, 'わ', wa, w).
kana(hi_wo, hiragana, 'を', wo, w).
kana(hi_n, hiragana, 'ん', n, moraic).

kana(ka_a, katakana, 'ア', a, vowel).
kana(ka_i, katakana, 'イ', i, vowel).
kana(ka_u, katakana, 'ウ', u, vowel).
kana(ka_e, katakana, 'エ', e, vowel).
kana(ka_o, katakana, 'オ', o, vowel).
kana(ka_ka, katakana, 'カ', ka, k).
kana(ka_ki, katakana, 'キ', ki, k).
kana(ka_ku, katakana, 'ク', ku, k).
kana(ka_ke, katakana, 'ケ', ke, k).
kana(ka_ko, katakana, 'コ', ko, k).
kana(ka_sa, katakana, 'サ', sa, s).
kana(ka_shi, katakana, 'シ', shi, s).
kana(ka_su, katakana, 'ス', su, s).
kana(ka_se, katakana, 'セ', se, s).
kana(ka_so, katakana, 'ソ', so, s).
kana(ka_ta, katakana, 'タ', ta, t).
kana(ka_chi, katakana, 'チ', chi, t).
kana(ka_tsu, katakana, 'ツ', tsu, t).
kana(ka_te, katakana, 'テ', te, t).
kana(ka_to, katakana, 'ト', to, t).
kana(ka_na, katakana, 'ナ', na, n_row).
kana(ka_ni, katakana, 'ニ', ni, n_row).
kana(ka_nu, katakana, 'ヌ', nu, n_row).
kana(ka_ne, katakana, 'ネ', ne, n_row).
kana(ka_no, katakana, 'ノ', no, n_row).
kana(ka_ha, katakana, 'ハ', ha, h).
kana(ka_hi, katakana, 'ヒ', hi, h).
kana(ka_fu, katakana, 'フ', fu, h).
kana(ka_he, katakana, 'ヘ', he, h).
kana(ka_ho, katakana, 'ホ', ho, h).
kana(ka_ma, katakana, 'マ', ma, m).
kana(ka_mi, katakana, 'ミ', mi, m).
kana(ka_mu, katakana, 'ム', mu, m).
kana(ka_me, katakana, 'メ', me, m).
kana(ka_mo, katakana, 'モ', mo, m).
kana(ka_ya, katakana, 'ヤ', ya, y).
kana(ka_yu, katakana, 'ユ', yu, y).
kana(ka_yo, katakana, 'ヨ', yo, y).
kana(ka_ra, katakana, 'ラ', ra, r).
kana(ka_ri, katakana, 'リ', ri, r).
kana(ka_ru, katakana, 'ル', ru, r).
kana(ka_re, katakana, 'レ', re, r).
kana(ka_ro, katakana, 'ロ', ro, r).
kana(ka_wa, katakana, 'ワ', wa, w).
kana(ka_wo, katakana, 'ヲ', wo, w).
kana(ka_n, katakana, 'ン', n, moraic).


% --- The voiced kana ------------------------------------------------------
% Dakuten is the base codepoint + 1 and handakuten the base + 2, which is
% the second systematic thing about the syllabaries and the reason these
% are generated rather than typed: see tools/mkkana.py.
%
% These exist because skill(dakuten) could not be met.  It required one
% item, hi_ka, and the table held base kana only -- so passing it
% demonstrated reading か, which says nothing whatever about か/が.  The
% criterion named a contrast the graph did not contain.  --audit found it.
%
% ぢ and づ are deliberately absent, and it is the only judgement in the
% table.  They are not a third and fourth sound: they are alternative
% spellings of じ and ず, used where a base kana is reduplicated or
% compounded (つづく, ちぢむ), and Hepburn spells each pair identically
% BECAUSE they are the same sound.  So they are not instances of "one
% mark changes the sound", which is what the skill names; and the
% katakana-after-hiragana rule below joins on the ROMAJI, so two kana
% spelled "ji" would make ヂ require both じ and ぢ, and ジ require ぢ --
% gating a common kana behind a vanishingly rare one.  import.p refuses
% to guess at an ambiguous JMdict key for the same reason.
%
% 23 per script, 46 in all.

kana(hi_ga, hiragana, 'が', ga, g).
kana(hi_gi, hiragana, 'ぎ', gi, g).
kana(hi_gu, hiragana, 'ぐ', gu, g).
kana(hi_ge, hiragana, 'げ', ge, g).
kana(hi_go, hiragana, 'ご', go, g).

kana(hi_za, hiragana, 'ざ', za, z).
kana(hi_ji, hiragana, 'じ', ji, z).
kana(hi_zu, hiragana, 'ず', zu, z).
kana(hi_ze, hiragana, 'ぜ', ze, z).
kana(hi_zo, hiragana, 'ぞ', zo, z).

kana(hi_da, hiragana, 'だ', da, d).
kana(hi_de, hiragana, 'で', de, d).
kana(hi_do, hiragana, 'ど', do, d).

kana(hi_ba, hiragana, 'ば', ba, b).
kana(hi_bi, hiragana, 'び', bi, b).
kana(hi_bu, hiragana, 'ぶ', bu, b).
kana(hi_be, hiragana, 'べ', be, b).
kana(hi_bo, hiragana, 'ぼ', bo, b).

kana(hi_pa, hiragana, 'ぱ', pa, p).
kana(hi_pi, hiragana, 'ぴ', pi, p).
kana(hi_pu, hiragana, 'ぷ', pu, p).
kana(hi_pe, hiragana, 'ぺ', pe, p).
kana(hi_po, hiragana, 'ぽ', po, p).

kana(ka_ga, katakana, 'ガ', ga, g).
kana(ka_gi, katakana, 'ギ', gi, g).
kana(ka_gu, katakana, 'グ', gu, g).
kana(ka_ge, katakana, 'ゲ', ge, g).
kana(ka_go, katakana, 'ゴ', go, g).

kana(ka_za, katakana, 'ザ', za, z).
kana(ka_ji, katakana, 'ジ', ji, z).
kana(ka_zu, katakana, 'ズ', zu, z).
kana(ka_ze, katakana, 'ゼ', ze, z).
kana(ka_zo, katakana, 'ゾ', zo, z).

kana(ka_da, katakana, 'ダ', da, d).
kana(ka_de, katakana, 'デ', de, d).
kana(ka_do, katakana, 'ド', do, d).

kana(ka_ba, katakana, 'バ', ba, b).
kana(ka_bi, katakana, 'ビ', bi, b).
kana(ka_bu, katakana, 'ブ', bu, b).
kana(ka_be, katakana, 'ベ', be, b).
kana(ka_bo, katakana, 'ボ', bo, b).

kana(ka_pa, katakana, 'パ', pa, p).
kana(ka_pi, katakana, 'ピ', pi, p).
kana(ka_pu, katakana, 'プ', pu, p).
kana(ka_pe, katakana, 'ペ', pe, p).
kana(ka_po, katakana, 'ポ', po, p).

% The pairing, stated once.  Both the prerequisite (が after か) and the
% confusable pair (one mark apart, which is exactly how a beginner
% misreads them) are DERIVED from this rather than listed again -- the
% same discipline as kana/5 itself.
%
% voiced(VoicedId, BaseId, Mark).

voiced(hi_ga, hi_ka, dakuten).
voiced(hi_gi, hi_ki, dakuten).
voiced(hi_gu, hi_ku, dakuten).
voiced(hi_ge, hi_ke, dakuten).
voiced(hi_go, hi_ko, dakuten).
voiced(hi_za, hi_sa, dakuten).
voiced(hi_ji, hi_shi, dakuten).
voiced(hi_zu, hi_su, dakuten).
voiced(hi_ze, hi_se, dakuten).
voiced(hi_zo, hi_so, dakuten).
voiced(hi_da, hi_ta, dakuten).
voiced(hi_de, hi_te, dakuten).
voiced(hi_do, hi_to, dakuten).
voiced(hi_ba, hi_ha, dakuten).
voiced(hi_bi, hi_hi, dakuten).
voiced(hi_bu, hi_fu, dakuten).
voiced(hi_be, hi_he, dakuten).
voiced(hi_bo, hi_ho, dakuten).
voiced(hi_pa, hi_ha, handakuten).
voiced(hi_pi, hi_hi, handakuten).
voiced(hi_pu, hi_fu, handakuten).
voiced(hi_pe, hi_he, handakuten).
voiced(hi_po, hi_ho, handakuten).

voiced(ka_ga, ka_ka, dakuten).
voiced(ka_gi, ka_ki, dakuten).
voiced(ka_gu, ka_ku, dakuten).
voiced(ka_ge, ka_ke, dakuten).
voiced(ka_go, ka_ko, dakuten).
voiced(ka_za, ka_sa, dakuten).
voiced(ka_ji, ka_shi, dakuten).
voiced(ka_zu, ka_su, dakuten).
voiced(ka_ze, ka_se, dakuten).
voiced(ka_zo, ka_so, dakuten).
voiced(ka_da, ka_ta, dakuten).
voiced(ka_de, ka_te, dakuten).
voiced(ka_do, ka_to, dakuten).
voiced(ka_ba, ka_ha, dakuten).
voiced(ka_bi, ka_hi, dakuten).
voiced(ka_bu, ka_fu, dakuten).
voiced(ka_be, ka_he, dakuten).
voiced(ka_bo, ka_ho, dakuten).
voiced(ka_pa, ka_ha, handakuten).
voiced(ka_pi, ka_hi, handakuten).
voiced(ka_pu, ka_fu, handakuten).
voiced(ka_pe, ka_he, handakuten).
voiced(ka_po, ka_ho, handakuten).

% --- Items and forms, derived ---------------------------------------------
% 138 facts above produce 138 items and 276 forms.  Nothing is enumerated
% twice, so a glyph can only be wrong in one place.

item(Id, grapheme, ja, preschool, own(kana)) :- kana(Id, _, _, _, _).
form(Id, Script, Glyph) :- kana(Id, Script, Glyph, _, _).
form(Id, romaji, Romaji) :- kana(Id, _, _, Romaji, _).
gloss(Id, en, Romaji) :- kana(Id, _, _, Romaji, _).

% Hiragana before katakana, for the same sound: a student meeting ア
% already knows あ, so the new thing is one shape and not also one sound.
requires(KId, HId) :-
    kana(KId, katakana, _, Romaji, _),
    kana(HId, hiragana, _, Romaji, _).

% が after か, and ぱ after は.  One mark is one new thing to notice, and
% it is the whole of what the voiced kana add -- so the base kana is the
% prerequisite and nothing else is.
requires(V, B) :- voiced(V, B, _).

% And the pair is confusable, because one mark apart is exactly how a
% beginner misreads it: か for が is not a wild guess, it is the mark
% going unseen.  confused_with/3 reads this both ways, so the tutor can
% diagnose it and offer the partner as a distractor.
confusable(B, V, mark(Mark)) :- voiced(V, B, Mark).

% The vowel row before the rest of hiragana.  Every other row IS a
% consonant plus one of these five, which is the one fact about the
% syllabary that makes the other 41 glyphs learnable rather than 41
% separate pictures.
requires(Id, V) :-
    kana(Id, hiragana, _, _, Row), Row \== vowel,
    kana(V, hiragana, _, _, vowel).

% --- Confusable pairs, as their own relation ------------------------------
% A beginner's errors are not random: they are these pairs.  Stated once
% each; confused_with/3 in schema.pl reads them both ways.  The tutor uses
% them to pick distractors, which is the only honest way to test reading.

confusable(hi_a,   hi_o,   shape(loop_and_cross)).
confusable(hi_ne,  hi_re,  shape(left_stroke_plus_tail)).
confusable(hi_re,  hi_wa,  shape(tail_direction)).
confusable(hi_ki,  hi_sa,  shape(stroke_count)).
confusable(hi_ru,  hi_ro,  shape(terminal_loop)).
confusable(hi_ha,  hi_ho,  shape(one_extra_stroke)).
confusable(hi_ma,  hi_mo,  shape(stroke_order)).
confusable(hi_nu,  hi_me,  shape(terminal_loop)).
confusable(ka_shi, ka_tsu, shape(stroke_direction)).
confusable(ka_so,  ka_n,   shape(stroke_direction)).
confusable(ka_ku,  ka_ta,  shape(one_extra_stroke)).
confusable(ka_su,  ka_nu,  shape(one_extra_stroke)).
confusable(ka_chi, ka_te,  shape(stroke_order)).
confusable(ka_ra,  ka_fu,  shape(stroke_count)).
confusable(ka_wa,  ka_u,   shape(opening_width)).
confusable(hi_he,  ka_he,  cross_script(near_identical)).
confusable(hi_ri,  ka_ri,  cross_script(near_identical)).
confusable(hi_ka,  ka_ka,  cross_script(shared_shape)).

% --- Mora, which is not a syllable ---------------------------------------
% These are skills, not glyphs: they have no single written form, which is
% why item_without_form/1 exempts kind skill.  A student who reads every
% kana and still hears きって as two beats cannot pass pre-school.

item(mora_count,      skill, ja, preschool, own(kana)).
item(mora_long_vowel, skill, ja, preschool, own(kana)).
item(mora_sokuon,     skill, ja, preschool, own(kana)).
item(mora_moraic_n,   skill, ja, preschool, own(kana)).
item(youon,           skill, ja, preschool, own(kana)).
item(dakuten,         skill, ja, preschool, own(kana)).

gloss(mora_count,      en, 'counting beats, not syllables').
gloss(mora_long_vowel, en, 'おう and おお are two beats').
gloss(mora_sokuon,     en, 'small つ is a beat of silence').
gloss(mora_moraic_n,   en, 'ん is its own beat').
gloss(youon,           en, 'small ゃゅょ make one beat with the kana before').
gloss(dakuten,         en, 'か/が, は/ば/ぱ -- one mark changes the sound').

requires(mora_count,      hi_a).
requires(mora_long_vowel, mora_count).
requires(mora_sokuon,     mora_count).
requires(mora_moraic_n,   hi_n).
requires(youon,           hi_ya).
% Over every voiced kana, not over か.  It used to require hi_ka alone,
% which made the criterion answerable by reading an unvoiced kana -- the
% one thing that cannot demonstrate the contrast the skill is named for.
requires(dakuten, V) :- voiced(V, _, _).

% --- The mora skills carry their own question ----------------------------
% A mora is a unit of TIME, and nothing about reading a kana demonstrates
% it: --audit reported skill(mora_count) and skill(mora_sokuon) as `thin`
% over a set of one item, あ, which cannot show whether a student hears
% きって as two beats or three.
%
% But the question does not need a microphone.  "How many beats is this?"
% is a reading question with a number for an answer, and the number is
% computable from the kana -- every kana is one beat, a small ゃゅょ joins
% the one before it, and っ, ん and ー are beats of their own.  So the
% material is drawn from the graph and the answer is derived, and nothing
% here is written out by hand.
%
% probe(Skill, morae(Feature)) -- Feature picks the material.
probe(mora_count,      morae(any)).
probe(mora_sokuon,     morae(sokuon)).
probe(mora_long_vowel, morae(long_vowel)).
probe(mora_moraic_n,   morae(moraic_n)).
probe(youon,           morae(youon)).

% --- Two aggregates, so words do not each list 46 prerequisites ----------
% "You may start on words once you can read the script" is one teaching
% decision, so it is one node.  requires/2 fans out from it by rule.

item(hiragana_all, skill, ja, preschool, own(kana)).
item(katakana_all, skill, ja, preschool, own(kana)).
gloss(hiragana_all, en, 'reads every hiragana at speed, voiced included').
gloss(katakana_all, en, 'reads every katakana at speed, voiced included').

requires(hiragana_all, Id) :- kana(Id, hiragana, _, _, _).
requires(katakana_all, Id) :- kana(Id, katakana, _, _, _).
