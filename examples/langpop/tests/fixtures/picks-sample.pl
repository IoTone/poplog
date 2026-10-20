% tests/fixtures/picks-sample.pl -- picks for the importer suite.
%
% Deliberately includes every outcome: a key that resolves, an ambiguous
% one, a missing one, a kana-keyed loanword, an explicit sequence number,
% and a compound whose kanji the graph already holds.

pick(t_yama,     ja, n5, word, jmdict('1302680')).
pick(t_yama_amb, ja, n5, word, jmdict_kanji('山')).
pick(t_missing,  ja, n5, word, jmdict_kanji('存在しない')).
pick(t_coffee,   ja, n5, word, jmdict_kana('コーヒー')).
pick(t_birthday, ja, n5, word, jmdict_kanji('誕生日')).
pick(t_hitori,   ja, n5, word, jmdict_kanji('一人')).
pick(t_quote,    ja, n5, word, jmdict_kanji('試')).

pick_requires(t_birthday, t_yama).
