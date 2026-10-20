% examples/langpop/graph/resources.pl -- the catalogue: pointers, never content.
%
% A resource node holds a URL and a date, and nothing else.  No sentence,
% no audio, no card text ever enters this graph, so no licence from any of
% these sites reaches anything we build.  That is the whole reason the
% assignment model is shaped this way.
%
% Curated by whoever teaches, per the project's decisions -- not crawled.
% The Checked date is a promise someone made and has to keep: a catalogue
% of dead links is worse than no catalogue.
%
% resource(Id, Lang, Kind, Target, Url, Checked).

resource(r_tatoeba_ja, ja, reading, preschool,
         'https://tatoeba.org/en/sentences/search?from=jpn&to=eng', '2026-10-19').
resource(r_kana_write, ja, writing, hiragana_all,
         'https://en.wikipedia.org/wiki/Hiragana#Table_of_hiragana', '2026-10-19').
resource(r_nhk_easy,   ja, reading, n5,
         'https://www3.nhk.or.jp/news/easy/', '2026-10-19').
resource(r_forvo_ja,   ja, listening, mora_count,
         'https://forvo.com/languages/ja/', '2026-10-19').
resource(r_jisho,      ja, reference, n5,
         'https://jisho.org/', '2026-10-19').

resource(r_tatoeba_en, en, reading, preschool,
         'https://tatoeba.org/en/sentences/search?from=eng&to=jpn', '2026-10-19').
resource(r_minimal_rl, en, listening, s_r_l,
         'https://en.wikipedia.org/wiki/Minimal_pair', '2026-10-19').
resource(r_cefr_ets,   en, reference, b2,
         'https://www.ets.org/toeic/', '2026-10-19').
resource(r_ngsl,       en, vocabulary, a2,
         'https://www.newgeneralservicelist.com/', '2026-10-19').
