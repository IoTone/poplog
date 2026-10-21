% examples/langpop/graph/en/ladder.pl -- the English ladder, as two axes.
%
% TOEIC has no syllabus to teach to, so the ladder is CEFR bands with
% their score ranges, and the scores are kept as TWO numbers plus a
% total.  Listening and Reading are each 5-495; the total is 10-990 and
% is derived from the sections, never set independently.
%
% PROVENANCE, carefully: the band ranges below come from the published
% CEFR/TOEIC correspondence tables.  Section FLOORS are a different
% claim -- a band needs a total AND a minimum in each section -- and only
% B2's floors have been verified here against the ETS mapping document.
% The other floors are deliberately absent rather than guessed: a floor
% invented by the engine would quietly fail a student who had passed.

ladder(en, 0, preschool).
ladder(en, 1, a1).
ladder(en, 2, a2).
ladder(en, 3, b1).
ladder(en, 4, b2).
ladder(en, 5, c1).

level_name(en, preschool, 'Pre-school', 'the sounds, and the katakana that lie').
level_name(en, a1, 'A1', 'TOEIC 120-225').
level_name(en, a2, 'A2', 'TOEIC 225-550').
level_name(en, b1, 'B1', 'TOEIC 550-785').
level_name(en, b2, 'B2', 'TOEIC 785-945 -- the usual hiring bar').
level_name(en, c1, 'C1', 'TOEIC 945-990').

% band(Lang, Level, TotalMin, TotalMax)
band(en, a1, 120, 225).
band(en, a2, 225, 550).
band(en, b1, 550, 785).
band(en, b2, 785, 945).
band(en, c1, 945, 990).

% floor(Lang, Level, Section, Minimum) -- only where verified.
floor(en, b2, listening, 400).
floor(en, b2, reading,   385).

% A band is reached only if every floor it declares is met.  Where no
% floor is on record the total alone decides, and the tutor says so.
reaches_band(Level, L, R) :-
    band(en, Level, Min, _), Total is L + R, Total >= Min,
    all_hold(floor(en, Level, listening, FL), L >= FL),
    all_hold(floor(en, Level, reading,   FR), R >= FR).

floors_known(Level) :- floor(en, Level, _, _).

exit(en, preschool, sound_contrasts,       0.90, 3000).
exit(en, preschool, no_katakana_reading,   0.85, 3000).
exit(en, preschool, final_consonants,      0.85, 3000).

% --- Counts, by channel ---------------------------------------------------
% graph/ja/ladder.pl argues this at length and the argument is the same
% here, with one difference worth noting: this ladder was already built
% with the counterweight, since coverage(reading, _) and
% coverage(listening, _) below are not counts at all.  Only the one
% vocabulary criterion needed splitting.
%
% The 5000 at B2 is what a strong reader is usually reckoned to carry,
% and it is an estimate.  It sits beside a coverage criterion rather than
% replacing it, because coverage is the better measure and a count is
% what a learner will actually track -- stating both is how the ladder
% says that the number is a proxy.
;;; A1 declared NO exit criterion at all, so a student who reached it
;;; could never leave: :status had nothing to measure and the level was a
;;; room with no door.  The ladder went straight from pre-school's three
;;; criteria to A2's vocabulary.  500 is the usual reckoning for A1 and
;;; it is an estimate like the rest of them.
exit(en, a1, vocabulary(500, read),        0.80, 4500).
exit(en, a1, vocabulary(500, hear),        0.80, 4500).
exit(en, a2, vocabulary(1000, read),       0.80, 4000).
exit(en, a2, vocabulary(1000, hear),       0.80, 4000).
exit(en, b2, vocabulary(5000, read),       0.80, 3500).
exit(en, b2, vocabulary(3000, hear),       0.80, 3500).
exit(en, b1, coverage(reading, 0.95),      0.80, 4000).
exit(en, b2, coverage(reading, 0.98),      0.80, 3500).
exit(en, b2, coverage(listening, 0.95),    0.80, 3500).

provenance(band(en, _, _, _), cefr_toeic_correspondence).
provenance(floor(en, b2, _, _), ets(cefr_mapping)).
provenance(exit(en, _, coverage(_, _), _, _), nation(2006)).
provenance(exit(en, _, vocabulary(_, _), _, _), estimate(community)).
