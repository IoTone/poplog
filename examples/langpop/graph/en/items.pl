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
% The ja gloss is JAPANESE.  It used to hold "what the katakana means",
% in English -- 'apartment building' filed under ja -- which made
% gloss/3 say something it does not mean: schema.pl defines it as what
% an item means IN A NAMED LANGUAGE.  Nothing read it that way until the
% card renderer started showing a learner the gloss in their own
% language, and then the card for `mansion` proudly displayed the very
% meaning the item exists to unteach.
%
% So the contrast now lives in the English gloss, which is where a
% contrast belongs, and the Japanese slot holds Japanese.
item(Id, word, en, preschool, own(loanword_trap)) :- trap(Id, _, _, _, _).
form(Id, latin, English) :- trap(Id, English, _, _, _).
form(Id, katakana, Kata) :- trap(Id, _, Kata, _, _).
gloss(Id, en, Means) :- trap(Id, _, _, Means, _).
gloss(Id, ja, Ja) :- trap(Id, _, _, _, Ja).

% trap(Id, EnglishToUse, Katakana, WhatItMeansAndWhatTheKatakanaDoesNot, Japanese).
trap(t_mansion,  'mansion',   'マンション',
     'a very large house -- the katakana means an apartment building', '大邸宅').
trap(t_service,  'service',   'サービス',
     'work done for a customer -- the katakana means free of charge',  '客への奉仕').
trap(t_arbeit,   'part-time', 'アルバイト',
     'arbeit is German, not English -- the English word is part-time', 'アルバイト').
trap(t_consent,  'outlet',    'コンセント',
     'consent means agreement -- a コンセント is an outlet',            'コンセント').
trap(t_tension,  'excited',   'ハイテンション',
     'high tension means strain, not high spirits',                    '興奮した').
trap(t_smart,    'slim',      'スマート',
     'smart means clever -- スマート means slim',                       '細い').
trap(t_naive,    'sensitive', 'ナイーブ',
     'naive means credulous and unworldly, not sensitive',             '繊細な').
trap(t_viking,   'buffet',    'バイキング',
     'a viking is a Norse seafarer -- バイキング is a buffet',          'バイキング料理').
trap(t_claim,    'complaint', 'クレーム',
     'a claim is an assertion of a right -- クレーム is a complaint',   '苦情').
trap(t_manner,   'manners',   'マナー',
     'a manner is a way of doing something -- マナー is etiquette',     '礼儀').
trap(t_restruct, 'layoff',    'リストラ',
     'restructuring reorganises a business -- リストラ is being laid off', '解雇').
trap(t_soft,     'software',  'ソフト',
     'soft is the opposite of hard -- ソフト is software',              'ソフトウェア').

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

% And it carries its own question, which is why the English pre-school
% rung can be exited at all.
%
% The skill was measured over s_final -- a `hear` item -- so --audit
% reported it as needs_audio, and two of this rung's three criteria were
% unreachable.  Producing a final consonant without a vowel after it
% does need a microphone.  KNOWING that English does not add one is a
% count: `slim` is one syllable and スマート is four, and a learner who
% answers four has told you exactly which of the two they are reading.
probe(final_consonants, syllables(katakana)).
