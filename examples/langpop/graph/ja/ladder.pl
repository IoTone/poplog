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
exit(ja, preschool, vocabulary(50),        0.80, 4000).

exit(ja, n5, vocabulary(800),  0.80, 4000).   % estimate(community)
exit(ja, n5, kanji(100),       0.80, 4000).   % estimate(community)
exit(ja, n4, vocabulary(1500), 0.80, 3500).   % estimate(community)
exit(ja, n4, kanji(300),       0.80, 3500).   % estimate(community)

provenance(ladder(ja), jlpt_faq('no content list published since 2010')).
provenance(exit(ja, n5, _), estimate(community)).
provenance(exit(ja, n4, _), estimate(community)).
