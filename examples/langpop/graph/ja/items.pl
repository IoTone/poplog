% examples/langpop/graph/ja/items.pl -- the starter lexicon, kana only.
%
% 40 words a pre-school student can both READ and WRITE with the base
% syllabary plus dakuten, chosen so that no item needs a kanji to exist.
% That constraint is the point: it is what lets a learner with no kanji
% read a whole sentence on day three instead of a word with a gap in it.
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
