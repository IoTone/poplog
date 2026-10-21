% examples/langpop/tests/bad.pl -- a graph that is wrong in seven ways.
%
% Compiled LAST by the test suite, which replaces item/5, form/3 and
% requires/2 wholesale (Poplog Prolog consults are reconsults), so these
% facts are the only graph in scope while the checks run.  Without this
% file the integrity suite would pass on an empty set of rules and nobody
% would notice.

item(b_ok,        word, ja, n5,      own(test)).
item(b_offladder, word, ja, nowhere, own(test)).      % level_not_on_ladder
item(b_nosrc,     word, ja, n5,      unknown).        % item_without_source
item(b_noform,    word, ja, n5,      own(test)).      % item_without_form
item(b_cycle1,    word, ja, n5,      own(test)).
item(b_cycle2,    word, ja, n5,      own(test)).
item(b_en,        word, en, a1,      own(test)).
item(b_low,       word, ja, preschool, own(test)).

form(b_ok,        romaji, bok).
form(b_offladder, romaji, boff).
form(b_nosrc,     romaji, bnos).
form(b_cycle1,    romaji, bc1).
form(b_cycle2,    romaji, bc2).
form(b_en,        latin,  'ex').
form(b_low,       romaji, blow).

requires(b_cycle1, b_cycle2).                         % cycle
requires(b_cycle2, b_cycle1).
requires(b_ok,     b_missing).                        % requires_unknown_item
requires(b_en,     b_ok).                             % requires_crosses_language
requires(b_low,    b_ok).                             % requires_from_above
