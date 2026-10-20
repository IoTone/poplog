% examples/langpop/graph/ja/ladder.pl -- the Japanese ladder, pre-school first.
%
% JLPT has no published content list: the Test Content Specifications
% were withdrawn in 2010 and the official FAQ says vocabulary and kanji
% lists are no longer released.  So the counts below are COMMUNITY
% estimates, marked as such in their source term, and the engine never
% treats them as authoritative -- they size a level, they do not define it.
%
% Pre-school is index 0 because N5 is not a starting point.  N5 assumes
% hiragana, some katakana and several hundred words; a learner with none
% of that is not a beginner at N5, they are below the ladder.

ladder(ja, 0, preschool).
ladder(ja, 1, n5).
ladder(ja, 2, n4).
ladder(ja, 3, n3).
ladder(ja, 4, n2).
ladder(ja, 5, n1).

level_name(ja, preschool, 'Pre-school', 'the three scripts, and beats').
level_name(ja, n5, 'N5', 'basic Japanese, taught slowly').
level_name(ja, n4, 'N4', 'basic Japanese').
level_name(ja, n3, 'N3', 'the bridge level').
level_name(ja, n2, 'N2', 'everyday Japanese at natural speed').
level_name(ja, n1, 'N1', 'a broad range of circumstances').

% exit(Lang, Level, Criterion, Threshold, LatencyMs)
%
% The latency is not decoration.  A student who works out か from a chart
% in four seconds has not learned it; reading is recognition, and the
% only way to tell the two apart is the clock.  Pre-school exits on
% accuracy AND speed, which is why every criterion carries both.

exit(ja, preschool, recognise(hiragana),   0.95, 2000).
exit(ja, preschool, recognise(katakana),   0.90, 2500).
exit(ja, preschool, skill(mora_count),     0.90, 4000).
exit(ja, preschool, skill(mora_sokuon),    0.85, 4000).
exit(ja, preschool, skill(dakuten),        0.90, 3000).

% --- Counts, and why each one names a channel -----------------------------
% A word you can only READ is the whole pathology of vocabulary-book
% study: the count is the one axis that enumerates, so it is the one that
% gets ground, while listening rots and the number keeps going up.  Every
% JLPT level has a 聴解 section, so demanding the same vocabulary on both
% channels is not an invention -- it is what the exam already asks.
%
% Nothing in langpop can check the hear channel (there is no audio), so
% these report as unverifiable rather than as zero.  That is the honest
% answer and it is deliberately visible: see langpop.p's VERIFIABLE and
% docs/projects/langpop-pronunciation.md.
%
% kanji takes no hear channel.  A character is not heard -- its READING
% is, and that is the word's channel, not the character's.

exit(ja, preschool, vocabulary(50, read),  0.80, 4000).
exit(ja, preschool, vocabulary(50, hear),  0.80, 4000).

exit(ja, n5, vocabulary(800, read),    0.80, 4000).
exit(ja, n5, vocabulary(800, hear),    0.80, 4000).
exit(ja, n5, kanji(103, read),         0.80, 4000).

exit(ja, n4, vocabulary(1500, read),   0.80, 3500).
exit(ja, n4, vocabulary(1500, hear),   0.80, 3500).
exit(ja, n4, kanji(284, read),         0.80, 3500).

exit(ja, n3, vocabulary(3750, read),   0.80, 3000).
exit(ja, n3, vocabulary(3750, hear),   0.80, 3000).
exit(ja, n3, kanji(650, read),         0.80, 3000).

exit(ja, n2, vocabulary(6000, read),   0.80, 2500).
exit(ja, n2, vocabulary(6000, hear),   0.80, 2500).
exit(ja, n2, kanji(1023, read),        0.80, 2500).

exit(ja, n1, vocabulary(10000, read),  0.80, 2000).
exit(ja, n1, vocabulary(10000, hear),  0.80, 2000).
exit(ja, n1, kanji(2230, read),        0.80, 2000).

% --- Where the kanji counts come from -------------------------------------
% Not round numbers, and mostly not estimates either.  KANJIDIC2 carries
% a <jlpt> field holding the PRE-2010 four-level JLPT, and counting it
% gives a cumulative figure per old level:
%
%     old 4 -> 103      old 3 -> 284      old 2 -> 1023     old 1 -> 2230
%
% The official mapping of old levels onto new ones is 4->N5, 3->N4,
% 2->N2, 1->N1, with N3 inserted between old 3 and old 2 and having no
% old equivalent at all.  So four of the five counts above are COUNTED
% from upstream data and only N3's is a community estimate -- which is
% why the provenance below says so one level at a time rather than
% tarring the whole relation with estimate(community).
%
% For scale, from the same file: 1,026 kyōiku kanji (grades 1-6), 2,136
% jōyō (grades 1-6 plus 8), and exactly 2,501 characters carry a
% frequency rank.  N1 at 2,230 therefore sits just above jōyō, which is
% the usual claim about what N1 reading demands.
%
% One caveat worth keeping in view: the official list and the
% actually-frequent list disagree.  2,037 of the 2,136 jōyō are inside
% the top 2,501 by frequency, so 99 official characters are rarer than
% rank 2,501 and 464 characters common enough to be ranked are not jōyō
% at all.  "Which 2,000 kanji" has two defensible answers and they differ
% by about 560 characters, which is an argument for ranking a criterion
% rather than counting it -- a bare kanji(2230) is satisfied by any 2,230
% characters, including 2,230 obscure ones.

provenance(ladder(ja), jlpt_faq('no content list published since 2010')).
provenance(exit(ja, n5, kanji(_, _), _, _), kanjidic2(jlpt(4))).
provenance(exit(ja, n4, kanji(_, _), _, _), kanjidic2(jlpt(3))).
provenance(exit(ja, n3, kanji(_, _), _, _), estimate(community)).
provenance(exit(ja, n2, kanji(_, _), _, _), kanjidic2(jlpt(2))).
provenance(exit(ja, n1, kanji(_, _), _, _), kanjidic2(jlpt(1))).
provenance(exit(ja, _, vocabulary(_, _), _, _), estimate(community)).
provenance(exit(ja, _, recognise(_), _, _), own(kana)).
provenance(exit(ja, _, skill(_), _, _), own(kana)).
