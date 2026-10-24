% examples/langpop/graph/ja/items.pl -- the starter lexicon, kana only.
%
% 50 words a pre-school student can both READ and WRITE with the base
% syllabary plus dakuten, chosen so that no item needs a kanji to exist.
% That constraint is the point: it is what lets a learner with no kanji
% read a whole sentence on day three instead of a word with a gap in it.
%
% The last ten were added for two reasons at once, which is why they are
% the words they are.  --audit said vocabulary(50, read) was SHORT BY 10
% -- the first rung of the Japanese ladder could not be exited, which is
% the gap a learner meets before any other.  It also said
% skill(mora_sokuon) was THIN, over a single word: がっこう was the only
% pre-school word in the graph with a small っ in it, so "how many beats"
% could be asked about one thing and no more.
%
% So the ten carry っ, ゃゅょ and ん deliberately: きって and ざっし are
% three beats each and look like two, でんしゃ and しゅくだい are the
% youon cases, みんな and でんわ the moraic ん.  Ordinary words a
% pre-school student needs anyway, chosen for what they exercise.
%
% Source is own(starter_list): these were chosen here, not taken from a
% licensed list.  The content build will attach JMdict ids to each one
% (and JMdict's own licence stays on JMdict's layer); until it does, the
% provenance says exactly what it is.

item(Id, word, ja, preschool, own(starter_list)) :- starter(Id, _, _, _).
form(Id, hiragana, Kana) :- starter(Id, Kana, _, _).
form(Id, romaji, Romaji) :- starter(Id, _, Romaji, _).
gloss(Id, en, Gloss) :- starter(Id, _, _, Gloss).
requires(Id, hiragana_all) :- starter(Id, _, _, _).

% starter(Id, Kana, Romaji, Gloss).
starter(w_hito,     'ひと',       hito,      'person').
starter(w_mizu,     'みず',       mizu,      'water').
starter(w_ie,       'いえ',       ie,        'house').
starter(w_kuruma,   'くるま',     kuruma,    'car').
starter(w_neko,     'ねこ',       neko,      'cat').
starter(w_inu,      'いぬ',       inu,       'dog').
starter(w_sakana,   'さかな',     sakana,    'fish').
starter(w_tori,     'とり',       tori,      'bird').
starter(w_asa,      'あさ',       asa,       'morning').
starter(w_yoru,     'よる',       yoru,      'night').
starter(w_kyou,     'きょう',     kyou,      'today').
starter(w_ashita,   'あした',     ashita,    'tomorrow').
starter(w_gakkou,   'がっこう',   gakkou,    'school').
starter(w_sensei,   'せんせい',   sensei,    'teacher').
starter(w_gakusei,  'がくせい',   gakusei,   'student').
starter(w_tomodachi,'ともだち',   tomodachi, 'friend').
starter(w_namae,    'なまえ',     namae,     'name').
starter(w_hon,      'ほん',       hon,       'book').
starter(w_tsukue,   'つくえ',     tsukue,    'desk').
starter(w_isu,      'いす',       isu,       'chair').
starter(w_te,       'て',         te,        'hand').
starter(w_me,       'め',         me,        'eye').
starter(w_kuchi,    'くち',       kuchi,     'mouth').
starter(w_atama,    'あたま',     atama,     'head').
starter(w_ookii,    'おおきい',   ookii,     'big').
starter(w_chiisai,  'ちいさい',   chiisai,   'small').
starter(w_atarashii,'あたらしい', atarashii, 'new').
starter(w_furui,    'ふるい',     furui,     'old').
starter(w_takai,    'たかい',     takai,     'expensive, or tall').
starter(w_yasui,    'やすい',     yasui,     'cheap').
starter(w_oishii,   'おいしい',   oishii,    'delicious').
starter(w_atsui,    'あつい',     atsui,     'hot').
starter(w_samui,    'さむい',     samui,     'cold').
starter(w_ii,       'いい',       ii,        'good').
starter(w_taberu,   'たべる',     taberu,    'to eat').
starter(w_nomu,     'のむ',       nomu,      'to drink').
starter(w_miru,     'みる',       miru,      'to see, to watch').
starter(w_iku,      'いく',       iku,       'to go').
starter(w_kuru,     'くる',       kuru,      'to come').
starter(w_suru,     'する',       suru,      'to do').

% --- Ten that carry a beat worth counting -------------------------------
% Chosen as words NORMALLY WRITTEN IN KANA, which is the criterion a
% kana-only list should have had from the start and did not.  The first
% draft of these ten picked きっぷ, ざっし, でんしゃ, おちゃ, じしょ, しゅくだい
% and でんわ -- all good mora examples, and all seven already in the N5
% pick list as 切符, 雑誌, 電車, お茶, 辞書, 宿題 and 電話.  check/1 caught
% it as requires_from_above: one id, two levels, the pre-school word
% inheriting the N5 word's kanji prerequisites.
%
% Adverbs and expressions are the right material anyway.  A learner meets
% ちょっと and たくさん constantly, in kana, and will never meet them as
% 一寸 and 沢山 -- so teaching them here costs nothing later, where
% teaching でんしゃ in kana is teaching a word that has to be re-learned
% as 電車 two rungs up.
starter(w_kitte,    'きって',     kitte,     'postage stamp').
starter(w_chotto,   'ちょっと',   chotto,    'a little, just a moment').
starter(w_yukkuri,  'ゆっくり',   yukkuri,   'slowly, at your leisure').
starter(w_ippai,    'いっぱい',   ippai,     'full, a lot of').
starter(w_motto,    'もっと',     motto,     'more').
starter(w_issho,    'いっしょ',   issho,     'together').
starter(w_omocha,   'おもちゃ',   omocha,    'toy').
starter(w_minna,    'みんな',     minna,     'everyone').
starter(w_takusan,  'たくさん',   takusan,   'a lot, plenty').
starter(w_zenbu,    'ぜんぶ',     zenbu,     'all of it').

% A small ゃゅょ is not in the kana table -- it is a modifier and not a
% syllable, which is why the graph carries `youon` as a skill rather than
% as three more glyphs.  So a word that uses one says so: reading おもちゃ
% needs the youon rule and not only the kana.
requires(w_chotto, youon).
requires(w_issho,  youon).
requires(w_omocha, youon).

% --- Three sentence patterns ---------------------------------------------
% A pattern is an item too, and it requires the words it needs to be
% demonstrated with.  The engine does not generate the sentence here --
% a DCG does that later -- but the dependency is already explicit, so
% nothing can teach a pattern before the words that fill it.

item(p_kore_wa_desu, pattern, ja, preschool, own(starter_list)).
item(p_wo_tabemasu,  pattern, ja, preschool, own(starter_list)).
item(p_ni_ikimasu,   pattern, ja, preschool, own(starter_list)).

form(p_kore_wa_desu, hiragana, 'これは___です').
form(p_wo_tabemasu,  hiragana, '___をたべます').
form(p_ni_ikimasu,   hiragana, '___にいきます').
form(p_kore_wa_desu, romaji, 'kore wa ___ desu').
form(p_wo_tabemasu,  romaji, '___ wo tabemasu').
form(p_ni_ikimasu,   romaji, '___ ni ikimasu').

gloss(p_kore_wa_desu, en, 'this is ___').
gloss(p_wo_tabemasu,  en, 'I eat ___').
gloss(p_ni_ikimasu,   en, 'I go to ___').

requires(p_kore_wa_desu, w_hon).
requires(p_wo_tabemasu,  w_taberu).
requires(p_wo_tabemasu,  w_sakana).
requires(p_ni_ikimasu,   w_iku).
requires(p_ni_ikimasu,   w_gakkou).
