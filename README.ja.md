*日本語版 README — [English original](README.md)。翻訳が原文と食い違う場合は英語版が正となります。*

---

POPLOG は、フリーでオープンソースの多言語ソフトウェア開発環境です。
複数の対話型プログラミング言語のインクリメンタルコンパイラを備えています:

* Pop-11
    Poplog の中核言語。X ウィンドウシステムへの豊富なインターフェースと、
    強力なオブジェクト指向拡張 Objectclass(Steve Leach 開発、現在は言語の
    標準機能)を含みます。LISP に対する CLOS に相当する位置づけです。
* Prolog
    「エジンバラ構文」による標準的な Prolog。
* Common Lisp
    G.L. Steele『Common Lisp the Language, 2nd Edition』(CLTL2)の
    大部分に準拠。
* Standard ML
    強い静的型付けと多相型を備えた関数型言語。

すべての言語が(高速な)インクリメンタルコンパイラで実装されているため、
Poplog はマルチパラダイム開発をラピッドプロトタイピング環境として支えます。
Poplog を使った AI・教育向けの資料も豊富にあり、一部は本リポジトリに、
一部は別のパッケージリポジトリに、また一部はネット上に公開されています。

---

## 4 つの言語をライブで

4 つのインクリメンタルコンパイラは 1 つの仮想マシンと 1 つのセーブドイメージ
(saved image)を共有し、自由に相互運用できます。以下は Apple Silicon
(macOS)ビルドでのキャプチャです:

| Pop-11 — 中核言語 | Prolog — エジンバラ構文 |
| :---: | :---: |
| ![Pop-11 REPL](docs/images/repl-pop11.png) | ![Prolog REPL](docs/images/repl-prolog.png) |
| **Common Lisp — CLTL2** | **Standard ML — 型推論** |
| ![Common Lisp REPL](docs/images/repl-clisp.png) | ![Standard ML REPL](docs/images/repl-pml.png) |

## Forth — 第五の言語(このフォークで新規追加)

上の 4 言語はクラシックな Poplog です。このフォークは第五の言語として
**Forth** を Poplog の一級サブシステムとして追加しています。Poplog の
オープンスタック呼び出し規約を活かした設計のため、実装は小さく、
生成されるコードは正真正銘のネイティブコードです:

* **Forth のデータスタックは Poplog のユーザースタックそのもの**です。
  そのため Forth のプリミティブは通常のオープンスタック Pop-11
  プロシージャです(`+` は `define f_plus(x,y); x+y enddefine`)。
* **コロン定義は機械語にコンパイルされます。** `: name … ;` は Pop-11
  プロシージャへトランスパイルされ、Poplog のインクリメンタルコンパイラを
  通るので、Forth ワードはスレッデッドコードやインタプリタ実行ではなく
  本物のネイティブプロシージャになります。制御ワード
  (`if/else/then`、`begin/until`、`begin/while/repeat`、`do/loop`、
  `recurse`、`exit`)はコンパイル時に Pop-11 の構文へ写像されます。
* **一級サブシステム:** `.fth` はファイルタイプとして認識され、
  `uses forth;` で `pop11`/`lisp`/`prolog`/`ml` と並ぶ REPL に入れます。
  `bye` または `pop11` で Pop-11 に戻ります。

```
$ tools/forth.sh                 # 対話 REPL  (-t testbench, -b bench, -c '…')
forth> : sq  dup * ;
forth> 9 sq .
81  ok
forth> : fib  dup 2 < if drop 1 else dup 1 - recurse swap 2 - recurse + then ;
forth> 10 fib .
89  ok
```

現在のコアは、算術、約 40 のスタック/比較/ビット/入出力ワード、ネイティブな
コロン定義、上記の制御ワード、カウント付きループ(`do/loop/i/j/leave`)、
`variable`/`constant`/`@`/`!`、リターンスタック(`>r r@ r>`)、文字列リテラルを
カバーします。成熟した 4 言語よりも新しく軽量です(`+loop` /
`create does>` / `value` は未実装、大文字小文字を区別)。純粋な Pop-11 で
書かれているため **Poplog が動くすべてのプラットフォーム**で動作します。
組み込みの `testbench` は macOS arm64 と RISC-V(StarFive VisionFive)で
**21/21** です。実装は `pop/forth/src/forth.p`、例は `pop/forth/examples/`、
性能は [BENCHMARKS.md](BENCHMARKS.md#forth) を参照してください。

## 対応プラットフォーム

Poplog は拡大中のプラットフォーム群でネイティブにビルド・動作します
(2026 年 6 月時点のステータス):

| OS | アーキテクチャ | ステータス | 備考 |
| --- | --- | --- | --- |
| **Linux** | x86-64 | ✅ サポート | リファレンスプラットフォーム |
| **Linux** | AArch64 (ARM64) | ✅ サポート | **Raspberry Pi 5** と **MediaTek Genio 720**(MT8391、2×A78+6×A55、GlobalScale Cortadodeck 720)で検証・ベンチマーク済み — 全 4 言語+セーブドイメージ。汎用 `armv8-a` でコア固有チューニングなしのため、他の ARM64 ボード(Qualcomm Snapdragon 等)への展開も容易なはずです |
| **macOS** | Apple Silicon (arm64) | ✅ サポート | ネイティブ Mach-O 移植 — セルフホスティング、全 4 言語、ターミナル版 VED、C↔Pop コールバック、ネイティブグラフィックス |
| **Linux** | ARM32 (`armv6`/`armv7`) | ✅ サポート | 歴史ある 32 ビット ARM 移植(`pop/src/syscomp/arm`)。Raspberry Pi 1–3 ほか 32 ビット ARM Linux。本レポートではベンチマーク対象外 |
| **Solaris** | x86 (i386) | ✅ サポート | 上流の移植(W. Hebisch)。Solaris 10 でテスト(`CC=gcc`、ベンダリング済み `corepop_solaris.i386`)。ここではベンチマーク対象外 |
| **FreeBSD** | x86-64 | ✅ サポート | 上流の移植(W. Hebisch)。x86-64 でテスト済み。ここではベンチマーク対象外 |
| **Linux** | RISC-V (`riscv64`, RV64GC) | ✅ サポート | ネイティブ RV64GC/LP64D 移植。**StarFive VisionFive**(SiFive U74 ×2)でセルフホスティング — 全 4 言語、セーブドイメージ、ターミナル版 VED、FFI の浮動小数点 ABI。`tools/validate-riscv64.sh` = 14/14。さらにクラウド上の RV64 ホスト(Ubuntu 24.04)でも公開シード corepop からブートストラップし、`lib json`/`lib crypto` のテストスイートが全通過。`PORTING-RISCV64-LINUX.md` 参照 |
| **Windows** | x86-64 | 🚧 TODO | 未移植(当面は WSL2 で Linux ビルドを利用可能) |

「サポート」とはビルドでき動作することを意味します。上 3 行と RISC-V は
このフォークで検証・ベンチマークの*両方*を実施済みです。ARM32、Solaris/x86、
FreeBSD/x86-64 は既存の Poplog 移植(ARM32 は歴史あるもの、Solaris と FreeBSD
は W. Hebisch による近年の上流追加)で、ここで再テスト・ベンチマークを
していないだけです。残る 🚧 の行(Windows)は本当に未移植です。
[BENCHMARKS.md のプラットフォームカバレッジ表](BENCHMARKS.md#platform-coverage)
も参照してください。

プラットフォーム別の移植ノート: `PORTING-ARM64-LINUX-RPI5.md` と
`PORTING-ARM64-M-SILICON-OSX.md`。

## インストール

速い順に 3 つの方法があります。

**1. バイナリのワンライナー**(約 2 MB のダウンロード。
[pop11 Claude スキル](.claude/skills/pop11/SKILL.md) も同時に
インストールされます):

```sh
curl -fsSL https://raw.githubusercontent.com/IoTone/poplog/master/tools/install-skill.sh | sh
```

プラットフォームを自動判別し、最新の GitHub リリースから
`pop11-skill-<os>-<arch>.tar.gz` を取得します(まずは macOS arm64 と
Linux x86-64 から)。再配置可能なランタイム(`basepop11` とライブラリ)を
`~/.local/share/pop11-skill` に展開し、最後に実際に動かすスモークテストで
仕上げます。`POP11_SKILL_PREFIX` で配置先を上書きでき、
`POP11_SKILL_URL` でバージョンを固定できます(`file://` を含む、curl で
取得可能な任意の URL)。アンインストール:
`rm -rf ~/.local/share/pop11-skill ~/.claude/skills/pop11 ~/.cache/pop11-skill`。
tarball は `tools/release-skill-tarball.sh` がビルドし、チェックサム
(`SHA256SUMS.pop11-skill`)とともにリリースページで公開されます。

**2. ソースから** — [INSTALL](INSTALL) を参照してください。
`target/pop/corepop` をシードとして用意し(移植済み 4 プラットフォーム
向けのバイナリは `nix/seeds/` に同梱)、`./configure && make all` を
実行します。

**3. Nix** — 次のセクションを参照してください。

## エージェント: MCP サーバー

Poplog は [MCP](https://modelcontextprotocol.io) サーバーを同梱して
います。Pop-11 自身で書かれており(`pop/mcp/pop11_mcp.p`)、MCP 対応の
エージェントは **永続的でネイティブコンパイルされた Pop-11 セッション**
を 4 つのツールとともに利用できます。`pop11_eval`(状態とコンパイル済み
プロシージャは呼び出しをまたいで保持され、mishap は診断として返り、
セッションは生き残ります)、`pop11_help`(実際の HELP/REF/TEACH
コーパス)、`pop11_checkpoint`(セッション全体を約 200 KB のイメージへ
凍結。検証式による条件付けも可能)、そして `pop11_state` です。
実測値: エンジンの起動を含めて 100 回以上の eval ラウンドトリップが
0.04 秒。

Claude Code への登録(tarball 版インストールでは
`~/.local/share/pop11-skill/tools/pop11-mcp` にランチャーも同梱されます):

```sh
# このマシンの全プロジェクトで:
claude mcp add --scope user pop11 -- /path/to/poplog/tools/pop11-mcp

# または 1 プロジェクトだけ(コミット可能な .mcp.json を書き出します):
claude mcp add --scope project pop11 -- /path/to/poplog/tools/pop11-mcp
```

このチェックアウト自身の [.mcp.json](.mcp.json) は、ここで開始した
セッション向けに登録を行います。チェックポイントしたセッションの再開は
`pop11-mcp --restore image.psv`。スコープの意味と `.mcp.json` の形式は
[Claude Code の MCP ドキュメント](https://docs.claude.com/en/docs/claude-code/mcp)
に記載されています。他の MCP クライアントでも、同じ stdio コマンドを
それぞれの方法で設定できます。エンドツーエンドのプロトコルテスト:
`python3 tools/mcp/test-e2e.py`。

## エディタ: LSP サーバー

同じ発想をエディタに適用したものが、Pop-11 で書かれた Language Server
Protocol サーバーです(`pop/lsp/pop11_lsp.p`、`tools/pop11-lsp` が起動し、
tarball にも同梱されています)。サーバー自体が Poplog セッションである
ため、診断は **実際のコンパイラ** から得られます。バッファは
`pop_syntax_only` を設定した状態で検査されるので、VM は何もプラントせず、
ファイルの内容が実行されることもありません。ホバーはカーソル下の語に
対応する実際の HELP/REF/TEACH エントリを表示し、補完はライブの辞書から
引かれます。[Neovim プラグイン](editors/nvim/) は `pop11` バッファで
自動的に起動します。任意の LSP クライアントが同じ stdio コマンドを
実行できます。エンドツーエンドのプロトコルテスト:
`python3 tools/lsp/test-e2e.py`。

両サーバーは 1 つのトランスポート `pop/lib/lib/jsonrpc.p` の上に載って
います。行ベースと Content-Length のフレーミング、stdio と TCP の
エンドポイント、そしてハンドラの mishap を `-32603` に変換して処理を
続けるサーブループを備えます。これを切り出したことで 2 つのサーバーから
342 行が取り除かれ、後述の swank サーバーもこの上に構築されています。

## エディタ: ライブセッション

`pop/lib/lib/swank.p` はこの発想のもう半分であり、SLIME の swank と
同じ理由から同じ名前を冠しています。エディタが対話する相手として
興味深いのはコンパイラではなく **動作中のセッション** だ、という点です。
LSP サーバーはテキストについての質問に答えますが、こちらはライブな
ヒープについての質問に答えます。ある名前が *いま* 何に束縛されて
いるか、プロシージャが実行中に何を出力したか、落ちた時点でどのフレームが
スタックにあったか。

出力は最後にまとめて届くのではなく、生成されるそばからストリーミング
されます。mishap はスクレイピングすべきテキストの塊ではなく、データ
(`message`、`culprits`、`frames`)として返ります。暴走したループは
ハンドシェイクが渡す pid にシグナルを送ることで停止できます。これは
この一連の作業の中で `I_CHECK` を arm64 と riscv64 に実装したからこそ
動作します。

すでに使っているセッションから起動すれば、エディタはその中身ごと
そのセッションを受け取ります:

```pop11
uses swank;
swank_serve(4005);          ;;; 同じ発想なので SLIME のポートを使用
```

新しいセッションを起動する場合は `tools/pop11-swank` を使います。
テスト: `sh tools/test-libs.sh tools/tests/test_swank.p` — 別プロセスの
実サーバーに対する 56 個のチェック(割り込みを含む)。

[Emacs パッケージ](editors/emacs/) がそのクライアントです。
`M-x pop11-swank` でセッションを起動して接続すると、以降の編集コマンドは
そちらへ送られます。コードの実行に合わせて出力が REPL へストリーミング
され、mishap は実際のフレームを持つバックトレースバッファを開きます。
`C-c C-i` で値をインスペクトし、ハンドル経由でその構成要素へ辿れます。
`M-.` は動作中のヒープに名前の出所を問い合わせ、補完はライブの辞書を
読み、`C-c C-a` は暴走したループを停止します。

`TEACH SWANK` がその手引きです。エディタを介する前に、手動での接続、
出力がストリーミングされる様子、mishap の分解、暴走ループへの割り込み、
ライブな値のインスペクトを実際に体験できます。

[Emacs パッケージ](editors/emacs/) はさらに踏み込み、この発想のもう
半分にも手を伸ばします。`M-x run-pop11` は comint バッファに本物の
Poplog リスナーを置き、編集バッファには VED の `ENTER` コマンドが
Emacs のキーで割り当てられます — `C-x C-e` が `ENTER l1`、`C-c C-r` が
`ENTER lmr`、`C-M-x` が `ENTER lcp` — これによりプロシージャは、
ファイルを離れることなくバッファから動作中のイメージへ渡ります。
テスト: `emacs -Q --batch -l tools/emacs/test-e2e.el`。

## パッケージング(Nix)

自己完結した **Nix flake** が、システム全体 — 全 4 言語とそのセーブド
イメージ — をソースからビルド・ブートストラップします。シードや
ツールチェーンの手動セットアップは不要です。`x86_64-linux` と
`aarch64-darwin` でエンドツーエンドにテスト済み。`aarch64-linux` ビルドは
MediaTek Genio 720 にデプロイしてベンチマークを実施しています
(BENCHMARKS.md の **G720** 列は Nix プロファイルから動かした flake
ビルドです)。

```sh
nix build .#poplog          # ビルド後 ./result/bin/{pop11,clisp,prolog,pml,ved}
nix run   .#pop11           # REPL を直接起動(.#prolog / .#clisp / .#pml も可)
nix shell .#poplog          # 5 つのフロントエンドを $PATH に追加
nix develop                 # Poplog ソースをいじるための開発シェル
nix build .#poplog-gfx      # 実験的グラフィックス: macOS は Metal、Linux は SDL3+OpenGL3
```

flake はサポートする各システムに `packages`、`apps`、`devShell` を提供
します。macOS ではビルドはアドホック署名され、**entitlements は不要**です。

**初回ビルドのコスト:** Nix はツールチェーンのクロージャ全体をソースから
ビルドするため、初回は **約 1.1 GB** のキャッシュ済み依存を取得し、
ディスク上のクロージャは **約 1.2 GiB** になります(Poplog 自体の出力は
約 95 MB で、残りは共有依存)。ビルドには数分かかります。同じソースの
再ビルドでは何も取得しません。ユースケース、コスト、ブートストラップ
シードの仕組み、グラフィックス版などの詳細は
**[`nix/README.md`](nix/README.md)** を参照してください。

## ネイティブグラフィックス(実験的)

歴史的に Poplog のグラフィックスは X ウィンドウシステム(Xpw / `xved`)に
結びついていました。現在は [Dear ImGui](https://github.com/ocornut/imgui) を
基盤とする**オプションのネイティブグラフィックスバックエンド**があり、
ビルド時に `./configure --experimental-graphics` で選択します
(「X なし」を含意します):

* **Metal + Cocoa**(macOS)— X サーバーや XQuartz なしのネイティブ
  ウィンドウ。
* **SDL3 + OpenGL3**(macOS *または* Linux/Unix)— SDL3 が実行時に表示
  トランスポート(**Wayland**、X11、KMS/DRM)を選択するため、**X11 への
  ハード依存はありません**。CI 向けに Mesa ソフトウェアレンダリング
  (llvmpipe)による**ヘッドレス**描画も可能です。

**バックエンドはビルド時に選択**します:

```sh
./configure --experimental-graphics          # OS ごとの既定: macOS は Metal、他は SDL
./configure --experimental-graphics=metal     # Metal を強制(macOS のみ)
./configure --experimental-graphics=sdl       # SDL3 + OpenGL を強制(macOS または Linux)
```

`=sdl` には SDL3 が必要です(`pkg-config sdl3` — 例: `brew install sdl3`、
または `SDL3_CFLAGS=… SDL3_LIBS=… ./configure --experimental-graphics=sdl`
でビルドを指定)。動作中のバックエンド(と GPU)は `gfx_spec()` で確認
できます。下のバッジを参照してください。

macOS の **Metal** バックエンドの実働 — `examples/cube3d.p`。vsync 同期の
滑らかな回転に、バックエンド・GPU・実 FPS を示すステータスバッジ付き:

![macOS Metal バックエンドで回転する 3D キューブ](docs/images/cube3d-metal.gif)

クラシックなタートルグラフィックスライブラリ `rc_graphic` と `rc_mouse` も
移植済みのため、既存の Pop-11 グラフィックスコードはそのまま動きます。
グラフィックスは厳密に**オプトイン**です: 既定のビルド
(および `nix build .#poplog`)はコンソール専用です。

| macOS(Metal)での `rc_graphic` タートル | Linux でのヘッドレス描画(SDL3 + llvmpipe、ディスプレイなし) |
| :---: | :---: |
| ![macOS ネイティブグラフィックス](docs/images/graphics-macos.png) | ![Linux ヘッドレスグラフィックス](docs/images/graphics-linux-headless.png) |

右の画像は Linux 上で**ディスプレイも GPU もコンポジタもなしに**描画した
ものです(`tools/validate-gfx-headless.sh`)— グラフィックススタックの
再現可能な CI ゲートです。

実行可能なデモは [`examples/`](examples/) にあります(グラフィックス
ビルドで `pop11 examples/tenprint.p`)。たとえば古典の
[10 PRINT](https://10print.org/) 迷路や、小さな文字で描いた「POPLOG」:

| `examples/tenprint.p` | `examples/poplog_letters.p` |
| :---: | :---: |
| ![10 PRINT 迷路](docs/images/ex-tenprint.png) | ![文字で描いた POPLOG](docs/images/ex-poplog-letters.png) |

## パフォーマンス

Poplog のインクリメンタルコンパイラは、どのバックエンドでも高速な
ネイティブコードを生成します。クロスプラットフォーム/クロス言語の
ベンチマーク結果(x86-64、Apple M シリーズ、Raspberry Pi 5、
MediaTek Genio 720、RISC-V。比較用に Python と Perl のベースライン付き)は
**[BENCHMARKS.md](BENCHMARKS.md)** を参照してください。

## ドキュメント

ツリー内の全コーパス — 900 以上の HELP、TEACH、REF ファイル — は
**<https://iotone.github.io/poplog/>** で閲覧できます(AI アシスタント
向けの [`llms.txt`](https://iotone.github.io/poplog/llms.txt) も併せて
提供しています)。サイトはプッシュのたびに `tools/gen-docs.sh` によって
再生成されます。これは Pop-11 のプログラムです。つまり Poplog は CI 上で、
リリース済みのシード corepop から、生成処理 1 秒未満で自身のドキュメント
サイトをビルドしているということです。システム内部では、同じ内容が ved の
`help json`、`teach json`、`ref regexp` などとして利用できます。

## 学習資料

数十年分のオープンな Pop-11/Prolog 教材 — バーミンガム大学の AI コースの
TEACH ファイル、SimAgent ツールキット、Pop-11 Primer など — が
コマンド 1 つで手に入ります:

```sh
tools/fetch-learning.sh --all       # learn/ に取得(gitignore 対象)
```

教材は公開アーカイブからダウンロードされ、このリポジトリには一切
同梱しません。生成される `learn/learn.p` が Poplog 内の `teach`/`help` に
教材を組み込みます。パック一覧と使い方は **[LEARNING.md](LEARNING.md)** を
参照してください。

---

これは Poplog ソースの整理版で、現時点ではコア部分のみです。
ブートストラップに必要なバイナリと拡張(パッケージ)は含みません。
パッケージは別リポジトリにあります:

  https://github.com/hebisch/poplog_packages

ここで移植済みのプラットフォーム — x86-64 Linux、AArch64 Linux、
Apple Silicon macOS、RISC-V RV64GC Linux — 向けのブートストラップ
(`corepop`)バイナリは、チェックサム付きで本リポジトリのリリースページで
公開しています:

  https://github.com/IoTone/poplog/releases

(例: `releases/latest/download/corepop-aarch64-linux`。同じシードは Nix
flake ビルド用に `nix/seeds/` 以下にもベンダリングされています。)
より古い上流プラットフォームのブートストラップバイナリはこちら:

  https://poplog.fricas.org/corepops

Intel/AMD 64 ビット Linux 向けのビルド可能な tarball はこちら:

  http://fricas.org/~hebisch/poplog

(このビルド版にはリポジトリの最新の変更は含まれません。)

**AArch64 Linux** 移植(上のプラットフォーム表参照)は汎用の `armv8-a`
ベースラインで書かれており、命令キャッシュのフラッシュに `__clear_cache` を
使うため、他の ARM64 ボードへの移植は容易です。プラットフォーム固有の
主な調整点はカーネルの**ページサイズ**です(セーブドイメージはページ境界に
アラインされます。Pi 5 は 16 KB ページ)。詳細は `PORTING-ARM64-LINUX-RPI5.md`
(および同文書の「Portability to other AArch64 platforms」節)を参照して
ください。

より詳しいインストール手順は INSTALL を参照してください。
