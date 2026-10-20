% examples/langpop/graph/ja/picks/n5.pl -- which words are N5, and who they are.
%
% This file is the CURATION, and it is the part of an import that is ours.
% It holds no Japanese that upstream wrote: a pick is an identity, a level
% and a lookup key, and examples/langpop/import.p fetches the forms and
% the glosses from JMdict at build time so that upstream's share-alike
% stays on upstream's layer.  That is the whole arrangement -- see
% import.p's header, and graph/ja/generated/.gitignore.
%
% WHY A PICK LIST AT ALL.  JLPT has published no content list since 2010
% (graph/ja/ladder.pl says so at more length), and JMdict carries no level
% marking of any kind.  So unlike the N5 kanji -- which come straight out
% of KANJIDIC2's <jlpt> field, because old level 4 is exactly what became
% N5 -- "which words are N5" is a judgment nobody upstream has made, and
% a human has to make it here.  These are therefore an ESTIMATE, and
% graph/ja/ladder.pl's provenance(exit(ja, n5, _), estimate(community))
% already says so for the counts they are measured against.
%
%   pick(Id, Lang, Level, Kind, Key).
%
% The key names an upstream entry one of three ways:
%
%   jmdict_kanji('山')     the entry whose kanji headword is 山
%   jmdict_kana('きっぷ')   the entry whose reading is きっぷ
%   jmdict('1518850')     that entry, by sequence number
%
% The first two are what a person can actually write.  The third is the
% escape hatch, and it is needed more often than it looks: 空 is そら and
% から and くう, and a key that names three entries names none of them.
% The importer REFUSES an ambiguous key and prints the candidates with
% their glosses, which is how the jmdict(...) keys below were arrived at.
%
% WHAT IS NOT HERE.  The forty words at pre-school (graph/ja/items.pl) are
% N5 words too, and they are deliberately not re-picked.  An item is its
% identity and not its spelling, so みず and 水 are one item, w_mizu, which
% already exists -- and the N5 work for that word is the CHARACTER 水,
% which the kanji import already made an item in its own right.  Picking
% it again would mint a second identity for one word and split a student's
% beliefs in half without telling anybody.  import.p refuses that too.
%
% This is a first tranche and not the finished level: the ladder wants
% vocabulary(800) and there are a few over 160 picks here.  The rest is
% curation, which is the work this file exists to make possible.

% --- The world ------------------------------------------------------------
pick(w_yama,       ja, n5, word, jmdict('1302680')).
pick(w_kawa, ja, n5, word, jmdict_kanji('川')).
pick(w_umi,        ja, n5, word, jmdict_kanji('海')).
pick(w_sora, ja, n5, word, jmdict('1245290')).
pick(w_hana, ja, n5, word, jmdict_kanji('花')).
pick(w_ki, ja, n5, word, jmdict('1534520')).
pick(w_ishi, ja, n5, word, jmdict('1382440')).
pick(w_ame, ja, n5, word, jmdict_kanji('雨')).
pick(w_yuki,       ja, n5, word, jmdict_kanji('雪')).
pick(w_kaze, ja, n5, word, jmdict('1499720')).
pick(w_tenki,      ja, n5, word, jmdict_kanji('天気')).
pick(w_hi, ja, n5, word, jmdict('1463770')).

% --- Time -----------------------------------------------------------------
pick(w_jikan,      ja, n5, word, jmdict_kanji('時間')).
pick(w_tokei,      ja, n5, word, jmdict_kanji('時計')).
pick(w_mainichi,   ja, n5, word, jmdict_kanji('毎日')).
pick(w_kinou,      ja, n5, word, jmdict_kanji('昨日')).
pick(w_gozen,      ja, n5, word, jmdict_kanji('午前')).
pick(w_gogo,       ja, n5, word, jmdict_kanji('午後')).
pick(w_kotoshi,    ja, n5, word, jmdict_kanji('今年')).
pick(w_rainen,     ja, n5, word, jmdict_kanji('来年')).
pick(w_kyonen,     ja, n5, word, jmdict_kanji('去年')).
pick(w_konshuu,    ja, n5, word, jmdict_kanji('今週')).
pick(w_raishuu,    ja, n5, word, jmdict_kanji('来週')).
pick(w_senshuu,    ja, n5, word, jmdict_kanji('先週')).
pick(w_tanjoubi,   ja, n5, word, jmdict_kanji('誕生日')).

% --- Places ---------------------------------------------------------------
pick(w_eki, ja, n5, word, jmdict_kanji('駅')).
pick(w_mise, ja, n5, word, jmdict('1582120')).
pick(w_michi, ja, n5, word, jmdict('1454080')).
pick(w_mado,       ja, n5, word, jmdict_kanji('窓')).
pick(w_heya,       ja, n5, word, jmdict_kanji('部屋')).
pick(w_daidokoro,  ja, n5, word, jmdict_kanji('台所')).
pick(w_genkan,     ja, n5, word, jmdict_kanji('玄関')).
pick(w_kaidan,     ja, n5, word, jmdict_kanji('階段')).
pick(w_kuni, ja, n5, word, jmdict_kanji('国')).
pick(w_machi, ja, n5, word, jmdict('1603990')).
pick(w_mura, ja, n5, word, jmdict_kanji('村')).
pick(w_kaisha,     ja, n5, word, jmdict_kanji('会社')).
pick(w_ginkou,     ja, n5, word, jmdict_kanji('銀行')).
pick(w_byouin,     ja, n5, word, jmdict_kanji('病院')).
pick(w_toshokan,   ja, n5, word, jmdict_kanji('図書館')).
pick(w_yuubinkyoku,ja, n5, word, jmdict_kanji('郵便局')).
pick(w_daigaku,    ja, n5, word, jmdict_kanji('大学')).

% --- Getting about --------------------------------------------------------
pick(w_densha,     ja, n5, word, jmdict_kanji('電車')).
pick(w_jitensha,   ja, n5, word, jmdict_kanji('自転車')).
pick(w_hikouki,    ja, n5, word, jmdict_kanji('飛行機')).
pick(w_kippu,      ja, n5, word, jmdict_kanji('切符')).
pick(w_denwa,      ja, n5, word, jmdict_kanji('電話')).
pick(w_tegami,     ja, n5, word, jmdict_kanji('手紙')).
pick(w_shinbun,    ja, n5, word, jmdict_kanji('新聞')).
pick(w_shashin,    ja, n5, word, jmdict_kanji('写真')).

% --- Doing things ---------------------------------------------------------
pick(w_ongaku,     ja, n5, word, jmdict_kanji('音楽')).
pick(w_eiga,       ja, n5, word, jmdict_kanji('映画')).
pick(w_ryouri,     ja, n5, word, jmdict_kanji('料理')).
pick(w_shigoto,    ja, n5, word, jmdict_kanji('仕事')).
pick(w_yasumi, ja, n5, word, jmdict_kanji('休み')).
pick(w_ryokou,     ja, n5, word, jmdict_kanji('旅行')).
pick(w_yakusoku,   ja, n5, word, jmdict_kanji('約束')).
pick(w_renshuu,    ja, n5, word, jmdict_kanji('練習')).
pick(w_shukudai,   ja, n5, word, jmdict_kanji('宿題')).
pick(w_shiken,     ja, n5, word, jmdict_kanji('試験')).
pick(w_imi,        ja, n5, word, jmdict_kanji('意味')).
pick(w_shitsumon,  ja, n5, word, jmdict_kanji('質問')).
pick(w_mondai,     ja, n5, word, jmdict_kanji('問題')).

% --- Eating ---------------------------------------------------------------
pick(w_yasai,      ja, n5, word, jmdict_kanji('野菜')).
pick(w_kudamono,   ja, n5, word, jmdict_kanji('果物')).
pick(w_niku, ja, n5, word, jmdict('1463520')).
pick(w_tamago, ja, n5, word, jmdict('1549140')).
pick(w_kome, ja, n5, word, jmdict('1508750')).
pick(w_shio, ja, n5, word, jmdict('1576630')).
pick(w_satou,      ja, n5, word, jmdict_kanji('砂糖')).
pick(w_gyuunyuu,   ja, n5, word, jmdict_kanji('牛乳')).
pick(w_ocha,       ja, n5, word, jmdict_kanji('お茶')).
pick(w_asagohan,   ja, n5, word, jmdict_kanji('朝御飯')).
pick(w_hirugohan,  ja, n5, word, jmdict_kanji('昼御飯')).
pick(w_bangohan,   ja, n5, word, jmdict_kanji('晩御飯')).

% --- Things you carry -----------------------------------------------------
pick(w_saifu,      ja, n5, word, jmdict_kanji('財布')).
pick(w_kaban, ja, n5, word, jmdict_kanji('鞄')).
pick(w_kutsu, ja, n5, word, jmdict_kanji('靴')).
pick(w_fuku, ja, n5, word, jmdict('1500940')).
pick(w_boushi,     ja, n5, word, jmdict_kanji('帽子')).
pick(w_megane, ja, n5, word, jmdict('1577670')).
pick(w_kasa, ja, n5, word, jmdict('1301940')).
pick(w_kagi, ja, n5, word, jmdict('1260490')).
pick(w_kami, ja, n5, word, jmdict('1311530')).
pick(w_enpitsu,    ja, n5, word, jmdict_kanji('鉛筆')).
pick(w_jisho,      ja, n5, word, jmdict_kanji('辞書')).
pick(w_zasshi,     ja, n5, word, jmdict_kanji('雑誌')).
pick(w_chizu,      ja, n5, word, jmdict_kanji('地図')).

% --- People ---------------------------------------------------------------
pick(w_kazoku,     ja, n5, word, jmdict_kanji('家族')).
pick(w_chichi, ja, n5, word, jmdict('1497610')).
pick(w_haha, ja, n5, word, jmdict('1514990')).
pick(w_ani, ja, n5, word, jmdict('1249900')).
pick(w_ane, ja, n5, word, jmdict('1307630')).
pick(w_otouto, ja, n5, word, jmdict('1581930')).
pick(w_imouto, ja, n5, word, jmdict('1524590')).
pick(w_kodomo,     ja, n5, word, jmdict_kanji('子供')).
pick(w_otoko, ja, n5, word, jmdict('1419990')).
pick(w_onna, ja, n5, word, jmdict('1344930')).

% --- Verbs ----------------------------------------------------------------
pick(w_kaku, ja, n5, word, jmdict_kanji('書く')).
pick(w_yomu,       ja, n5, word, jmdict_kanji('読む')).
pick(w_kiku, ja, n5, word, jmdict_kanji('聞く')).
pick(w_hanasu,     ja, n5, word, jmdict_kanji('話す')).
pick(w_au, ja, n5, word, jmdict_kanji('会う')).
pick(w_kau,        ja, n5, word, jmdict_kanji('買う')).
pick(w_uru,        ja, n5, word, jmdict_kanji('売る')).
pick(w_tsukau, ja, n5, word, jmdict_kanji('使う')).
pick(w_tsukuru, ja, n5, word, jmdict_kanji('作る')).
pick(w_matsu,      ja, n5, word, jmdict_kanji('待つ')).
pick(w_motsu,      ja, n5, word, jmdict_kanji('持つ')).
pick(w_aruku,      ja, n5, word, jmdict_kanji('歩く')).
pick(w_hashiru,    ja, n5, word, jmdict_kanji('走る')).
pick(w_yasumu,     ja, n5, word, jmdict_kanji('休む')).
pick(w_hataraku, ja, n5, word, jmdict_kanji('働く')).
pick(w_oshieru,    ja, n5, word, jmdict_kanji('教える')).
pick(w_oboeru,     ja, n5, word, jmdict_kanji('覚える')).
pick(w_wasureru,   ja, n5, word, jmdict_kanji('忘れる')).
pick(w_hajimaru,   ja, n5, word, jmdict_kanji('始まる')).
pick(w_owaru, ja, n5, word, jmdict_kanji('終わる')).
pick(w_hairu, ja, n5, word, jmdict('1465590')).
pick(w_deru, ja, n5, word, jmdict_kanji('出る')).
pick(w_kaeru, ja, n5, word, jmdict_kanji('帰る')).
pick(w_neru, ja, n5, word, jmdict_kanji('寝る')).
pick(w_okiru,      ja, n5, word, jmdict_kanji('起きる')).
pick(w_wakaru, ja, n5, word, jmdict_kanji('分かる')).
pick(w_shiru, ja, n5, word, jmdict_kanji('知る')).
pick(w_sumu, ja, n5, word, jmdict_kanji('住む')).
pick(w_noru, ja, n5, word, jmdict_kanji('乗る')).
pick(w_oriru, ja, n5, word, jmdict_kanji('降りる')).

% --- Adjectives -----------------------------------------------------------
pick(w_nagai,      ja, n5, word, jmdict_kanji('長い')).
pick(w_mijikai,    ja, n5, word, jmdict_kanji('短い')).
pick(w_tsuyoi,     ja, n5, word, jmdict('1236070')).
pick(w_yowai,      ja, n5, word, jmdict_kanji('弱い')).
pick(w_hayai, ja, n5, word, jmdict_kanji('早い')).
pick(w_osoi,       ja, n5, word, jmdict_kanji('遅い')).
pick(w_akarui,     ja, n5, word, jmdict_kanji('明るい')).
pick(w_kurai, ja, n5, word, jmdict_kanji('暗い')).
pick(w_hiroi,      ja, n5, word, jmdict_kanji('広い')).
pick(w_semai,      ja, n5, word, jmdict_kanji('狭い')).
pick(w_omoi, ja, n5, word, jmdict_kanji('重い')).
pick(w_karui, ja, n5, word, jmdict_kanji('軽い')).
pick(w_muzukashii, ja, n5, word, jmdict_kanji('難しい')).
pick(w_kantan,     ja, n5, word, jmdict_kanji('簡単')).
pick(w_shizuka,    ja, n5, word, jmdict_kanji('静か')).
pick(w_nigiyaka,   ja, n5, word, jmdict_kanji('賑やか')).
pick(w_kirei, ja, n5, word, jmdict_kanji('綺麗')).
pick(w_genki,      ja, n5, word, jmdict_kanji('元気')).
pick(w_yuumei,     ja, n5, word, jmdict_kanji('有名')).
pick(w_benri,      ja, n5, word, jmdict_kanji('便利')).

% --- Prerequisites a human has to state -----------------------------------
% The importer already draws two kinds of edge on its own: every imported
% word needs the kana, and a word written with a kanji the graph holds
% needs that kanji (import.p's imp_kanji_reqs -- 本 is in 日本, and that
% is not an opinion).  What it cannot work out is teaching ORDER between
% words, so the few that matter are stated here.
%
% These are the antonym pairs, where the second word of each is introduced
% AS the negation of the first and is close to meaningless before it.  It
% is the same judgment graph/ja/kana.pl makes about dakuten: か before が,
% because the second is the first with a mark on it.
pick_requires(w_mijikai, w_nagai).
pick_requires(w_yowai,   w_tsuyoi).
pick_requires(w_osoi,    w_hayai).
pick_requires(w_kurai,   w_akarui).
pick_requires(w_semai,   w_hiroi).
pick_requires(w_karui,   w_omoi).
pick_requires(w_uru,     w_kau).
pick_requires(w_owaru,   w_hajimaru).
pick_requires(w_oriru,   w_noru).
pick_requires(w_deru,    w_hairu).

% Meals are one pattern with the time of day changed, and the pattern is
% worth more than the three words: a student who has 朝御飯 gets the other
% two for the price of the time word.
pick_requires(w_hirugohan, w_asagohan).
pick_requires(w_bangohan,  w_asagohan).
