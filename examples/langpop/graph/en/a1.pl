% examples/langpop/graph/en/a1.pl -- A1 English, for a Japanese speaker.
%
% Committed, and hand-written, which needs saying because the Japanese
% side's N5 words are neither (graph/ja/picks/n5.pl + an import).  The
% asymmetry is not an inconsistency; it is what the sources know.
%
% JMdict can be read BACKWARDS -- find the entries whose English gloss is
% 'water' and take their Japanese headwords -- and that was the obvious
% way to get these glosses for free.  It was measured before it was
% built, and it does not work:
%
%     water     -> 水分, お水, ウォーター      and never 水
%     think     -> シンク                     (the katakana loanword)
%     mountain  -> ベルグ, マウンテン, 山       (the first is German)
%     very      -> 迚も                       (an archaic spelling)
%     remember  -> 銘記
%
% Filtering to JMdict's priority-tagged entries and dropping the
% katakana-only ones cleans up the worst of it (mountain -> 山) and still
% leaves water -> 水分, which is "moisture", and very -> 迚も.  An exact
% match on a gloss is not a translation: a bilingual dictionary is
% organised to explain Japanese words in English, and reading it the
% other way finds whichever Japanese word happens to have the bare
% English word as its gloss -- which favours archaisms and transliterated
% loanwords, the latter being exactly what the pre-school level warns
% about.  Teaching 'water' as 水分 is worse than not glossing it.
%
% So the Japanese gloss is ours, typed here.  No licence reaches it, and
% nothing upstream has an opinion about which English words are A1 in the
% first place.  What the importer DOES add to these items is the one
% thing no person should type a hundred times and no human judgment
% improves: the pronunciation, and the sound contrasts it exercises --
% see import.p --source cmudict.
%
% A1 is TOEIC 120-225 (graph/en/ladder.pl).  This is a first tranche of
% 100 words and not the finished level; the ladder's own next criterion is
% exit(en, a2, vocabulary(1000), ...).  Note also that A1 declares no
% exit criterion at all, which is a gap in the ladder rather than here.

item(Id, word, en, a1, own(a1_list)) :- a1(Id, _, _, _).
form(Id, latin, Word) :- a1(Id, Word, _, _).
gloss(Id, en, En) :- a1(Id, _, En, _).
gloss(Id, ja, Ja) :- a1(Id, _, _, Ja).

% a1(Id, Word, GlossEn, GlossJa).

% --- People and family ---------------------------------------------------
a1(e_people,     'people',     'persons, in general',        '人々').
a1(e_family,     'family',     'the people you live with',   '家族').
a1(e_father,     'father',     'a male parent',              '父').
a1(e_mother,     'mother',     'a female parent',            '母').
a1(e_brother,    'brother',    'a male sibling',             '兄弟').
a1(e_sister,     'sister',     'a female sibling',           '姉妹').
a1(e_child,      'child',      'a young person',             '子供').
a1(e_friend,     'friend',     'someone you like and know',  '友達').
a1(e_woman,      'woman',      'an adult female',            '女性').
a1(e_student,    'student',    'someone who studies',        '学生').
a1(e_teacher,    'teacher',    'someone who teaches',        '先生').
a1(e_girl,       'girl',       'a young female',             '女の子').
a1(e_doctor,     'doctor',     'someone who treats illness', '医者').

% --- Places --------------------------------------------------------------
a1(e_house,      'house',      'a building people live in',  '家').
a1(e_school,     'school',     'where students are taught',  '学校').
a1(e_room,       'room',       'a space inside a building',  '部屋').
a1(e_street,     'street',     'a road in a town',           '通り').
a1(e_city,       'city',       'a large town',               '都市').
a1(e_country,    'country',    'a nation',                   '国').
a1(e_world,      'world',      'the earth and everyone on it','世界').
a1(e_station,    'station',    'where trains stop',          '駅').
a1(e_hospital,   'hospital',   'where the ill are treated',  '病院').
a1(e_library,    'library',    'where books are kept',       '図書館').
a1(e_office,     'office',     'where people do office work','事務所').
a1(e_shop,       'shop',       'where things are sold',      '店').
a1(e_restaurant, 'restaurant', 'where meals are sold',       'レストラン').

% --- Things --------------------------------------------------------------
a1(e_water,      'water',      'the liquid we drink',        '水').
a1(e_food,       'food',       'what we eat',                '食べ物').
a1(e_book,       'book',       'pages bound together',       '本').
a1(e_letter,     'letter',     'a written message sent',     '手紙').
a1(e_money,      'money',      'what things are bought with','お金').
a1(e_car,        'car',        'a vehicle you drive',        '車').
a1(e_train,      'train',      'a vehicle on rails',         '電車').
a1(e_table,      'table',      'a flat surface on legs',     'テーブル').
a1(e_door,       'door',       'what you open to go through', 'ドア').
a1(e_window,     'window',     'an opening with glass',      '窓').
a1(e_picture,    'picture',    'a drawing or photograph',    '写真').
a1(e_music,      'music',      'organised sound',            '音楽').
a1(e_phone,      'phone',      'what you call people on',    '電話').
a1(e_number,     'number',     'a quantity in figures',      '数').
a1(e_word,       'word',       'a unit of language',         '単語').
a1(e_problem,    'problem',    'something difficult to solve','問題').
a1(e_question,   'question',   'what you ask',               '質問').
a1(e_answer,     'answer',     'what you reply',             '答え').
a1(e_clothes,    'clothes',    'what you wear',              '服').
a1(e_flower,     'flower',     'the bloom of a plant',       '花').
a1(e_tree,       'tree',       'a tall woody plant',         '木').
a1(e_animal,     'animal',     'a living creature',          '動物').

% --- Time and weather ----------------------------------------------------
a1(e_time,       'time',       'when things happen',         '時間').
a1(e_day,        'day',        'twenty-four hours',          '日').
a1(e_week,       'week',       'seven days',                 '週').
a1(e_month,      'month',      'about thirty days',          '月').
a1(e_year,       'year',       'twelve months',              '年').
a1(e_morning,    'morning',    'the early part of the day',  '朝').
a1(e_night,      'night',      'when it is dark',            '夜').
a1(e_weather,    'weather',    'the state of the air',       '天気').
a1(e_rain,       'rain',       'water falling from the sky',  '雨').
a1(e_snow,       'snow',       'frozen water falling',       '雪').
a1(e_summer,     'summer',     'the hot season',             '夏').
a1(e_winter,     'winter',     'the cold season',            '冬').

% --- Doing ---------------------------------------------------------------
a1(e_eat,        'eat',        'to take in food',            '食べる').
a1(e_drink,      'drink',      'to take in liquid',          '飲む').
a1(e_go,         'go',         'to move away from here',     '行く').
a1(e_come,       'come',       'to move towards here',       '来る').
a1(e_see,        'see',        'to perceive with the eyes',  '見る').
a1(e_listen,     'listen',     'to pay attention to sound',  '聞く').
a1(e_speak,      'speak',      'to say words aloud',         '話す').
a1(e_read,       'read',       'to take in written words',   '読む').
a1(e_write,      'write',      'to put down words',          '書く').
a1(e_learn,      'learn',      'to come to know',            '学ぶ').
a1(e_think,      'think',      'to use the mind',            '考える').
a1(e_know,       'know',       'to have in mind as true',    '知る').
a1(e_want,       'want',       'to wish to have',            '欲しい').
a1(e_make,       'make',       'to bring into being',        '作る').
a1(e_take,       'take',       'to get hold of',             '取る').
a1(e_give,       'give',       'to hand to someone',         'あげる').
a1(e_buy,        'buy',        'to get for money',           '買う').
a1(e_walk,       'walk',       'to go on foot',              '歩く').
a1(e_sleep,      'sleep',      'to rest unconscious',        '寝る').
a1(e_live,       'live',       'to have one\'s home',        '住む').
a1(e_work,       'work',       'to do a job',                '働く').
a1(e_help,       'help',       'to make easier for someone', '助ける').
a1(e_wait,       'wait',       'to stay until something',    '待つ').
a1(e_meet,       'meet',       'to come together with',      '会う').
a1(e_find,       'find',       'to come upon',               '見つける').
a1(e_remember,   'remember',   'to keep in mind',            '覚える').
a1(e_understand, 'understand', 'to grasp the meaning',       '理解する').
a1(e_travel,     'travel',     'to go a long way',           '旅行する').

% --- Describing ----------------------------------------------------------
a1(e_big,        'big',        'of great size',              '大きい').
a1(e_small,      'small',      'of little size',             '小さい').
a1(e_long,       'long',       'of great length',            '長い').
a1(e_new,        'new',        'made or begun recently',     '新しい').
a1(e_good,       'good',       'of a high standard',         '良い').
a1(e_difficult,  'difficult',  'hard to do',                 '難しい').
a1(e_expensive,  'expensive',  'costing a lot',              '高い').
a1(e_beautiful,  'beautiful',  'pleasing to look at',        '美しい').
a1(e_strong,     'strong',     'having great force',         '強い').
a1(e_early,      'early',      'before the usual time',      '早い').
a1(e_busy,       'busy',       'having much to do',          '忙しい').
a1(e_very,       'very',       'to a high degree',           'とても').
