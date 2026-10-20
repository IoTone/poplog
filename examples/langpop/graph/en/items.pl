% examples/langpop/graph/en/items.pl -- English pre-school, for a Japanese speaker.
%
% Two kinds of item, and the second kind is the unusual one.
%
% SOUNDS: the contrasts Japanese does not make.  A learner who cannot
% hear /r/ against /l/ does not have a vocabulary problem when they miss
% a listening question, and no amount of sticky notes fixes it.
%
% LOANWORD TRAPS: a Japanese speaker starts English with several thousand
% words already half-known, in katakana, and some of them are wrong.
% These are not vocabulary to learn -- they are vocabulary to UNLEARN,
% which is a different exercise and needs its own items.  The same
% katakana layer that makes reading easier is what makes listening and
% usage harder, and that asymmetry is the whole reason this level exists.

% --- Sound contrasts -----------------------------------------------------
item(Id, sound, en, preschool, own(contrast)) :- contrast(Id, _, _, _).
form(Id, ipa, Ipa) :- contrast(Id, Ipa, _, _).
gloss(Id, en, Gloss) :- contrast(Id, _, Gloss, _).
gloss(Id, ja, Ja) :- contrast(Id, _, _, Ja).

% contrast(Id, Ipa, GlossEn, GlossJa).
contrast(s_r_l,    '/r/ - /l/',   'right and light',          'ラ行では区別されない').
contrast(s_th_un,  '/th/',        'think, three',             'サ行で代用しがち').
contrast(s_th_v,   '/dh/',        'this, those',              'ザ行で代用しがち').
contrast(s_v_b,    '/v/ - /b/',   'vote and boat',            'バ行で代用しがち').
contrast(s_f_h,    '/f/ - /h/',   'food and hood',            'ハ行で代用しがち').
contrast(s_ae_uh,  '/ae/ - /uh/', 'cat and cut',              'どちらもアに聞こえる').
contrast(s_si_shi, '/si/ - /sh/', 'see and she',              'シの前では混ざる').
contrast(s_final,  'final C',     'need, not need-o',         '語末に母音を付けない').
contrast(s_cluster,'CCC-',        'street, splash',           '子音連続').
contrast(s_stress, 'stress',      'PREsent and preSENT',      '強勢の位置で意味が変わる').
contrast(s_schwa,  '/uh/',        'the weak vowel in about',  '弱母音').
contrast(s_rhythm, 'rhythm',      'stress-timed, not mora-timed', 'モーラ拍ではない').

requires(s_th_v,   s_th_un).
requires(s_cluster, s_final).
requires(s_rhythm, s_stress).
requires(s_schwa,  s_stress).

% --- Loanword traps ------------------------------------------------------
item(Id, word, en, preschool, own(loanword_trap)) :- trap(Id, _, _, _, _).
form(Id, latin, English) :- trap(Id, English, _, _, _).
form(Id, katakana, Kata) :- trap(Id, _, Kata, _, _).
gloss(Id, en, Means) :- trap(Id, _, _, Means, _).
gloss(Id, ja, Expected) :- trap(Id, _, _, _, Expected).

% trap(Id, English, Katakana, WhatItMeansInEnglish, WhatTheKatakanaMeans).
trap(t_mansion,  'mansion',     'マンション',     'a very large house',           'apartment building').
trap(t_service,  'service',     'サービス',       'work done for a customer',     'free of charge').
trap(t_arbeit,   'part-time',   'アルバイト',     '(arbeit is German, not English)', 'a part-time job').
trap(t_consent,  'outlet',      'コンセント',     '(consent means agreement)',    'a power socket').
trap(t_tension,  'excited',     'ハイテンション', '(high tension means strain)',  'lively, excited').
trap(t_smart,    'slim',        'スマート',       'clever',                       'slim').
trap(t_naive,    'sensitive',   'ナイーブ',       'credulous, unworldly',         'sensitive, delicate').
trap(t_viking,   'buffet',      'バイキング',     'a Norse seafarer',             'an all-you-can-eat buffet').
trap(t_claim,    'complaint',   'クレーム',       'an assertion of a right',      'a complaint').
trap(t_manner,   'manners',     'マナー',         'a way of doing something',     'etiquette').
trap(t_restruct, 'layoff',      'リストラ',       'reorganising a business',      'being laid off').
trap(t_soft,     'software',    'ソフト',         'not hard',                     'software').

% The skill of distrusting the katakana reading.  Every trap feeds it,
% and it is what exit(en, preschool, no_katakana_reading, ...) measures.
item(no_katakana_reading, skill, en, preschool, own(contrast)).
gloss(no_katakana_reading, en, 'reads an English word without its katakana meaning').
gloss(no_katakana_reading, ja, 'カタカナ語の意味に引きずられずに読む').
requires(no_katakana_reading, Id) :- trap(Id, _, _, _, _).

item(sound_contrasts, skill, en, preschool, own(contrast)).
gloss(sound_contrasts, en, 'hears every contrast above').
requires(sound_contrasts, Id) :- contrast(Id, _, _, _).

item(final_consonants, skill, en, preschool, own(contrast)).
gloss(final_consonants, en, 'ends a word without adding a vowel').
requires(final_consonants, s_final).
