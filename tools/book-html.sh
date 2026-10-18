#!/bin/sh
# book-html.sh — build the HTML5 edition of "Pop-11 and the Robot Army".
#
#   tools/book-html.sh [outfile]      default: docs/book/poplog-book.html
#
# One self-contained HTML5 file: no JavaScript, no external CSS, no web
# fonts, images inlined as data URIs.  It opens from a file:// URL, from a
# static host, or from inside a zip, and it prints.  That is the whole point
# of "pure HTML5" here -- the PDF is the typeset artefact, this is the one
# that survives being emailed, embedded in a Google Sites page, or read on a
# phone with no network.
#
# Needs pandoc.  The one TikZ figure (the two-level VM diagram) additionally
# needs tectonic + pdftocairo to render, but the rendered SVG is committed,
# so a plain `pandoc` box can still build the book.
#
# Why not tex4ht/make4ht, the usual LaTeX->HTML route: it wants a full TeX
# installation, and this tree builds the PDF with tectonic precisely so that
# it does not need one.  Pandoc reads the LaTeX directly, expands the book's
# own \newcommands (\code, \ghfile, \dq) on the way through, and turns
# booktabs tabulars into real <table>s.
set -e

repo="$(cd "$(dirname "$0")/.." && pwd)"
book="$repo/docs/book"
out="${1:-$book/poplog-book.html}"
build="${TMPDIR:-/tmp}/book-html.$$"
mkdir -p "$build"
trap 'rm -rf "$build"' EXIT INT TERM

command -v pandoc >/dev/null 2>&1 || {
    echo "book-html: needs pandoc (brew install pandoc)" >&2; exit 2; }

cd "$book"

# Derived web assets live apart from the print originals: docs/book/Makefile
# makes the PDF depend on figures/*.png and figures/*.jpg, so a resized
# cover sitting next to the original would make every HTML build dirty the
# PDF as well.  Committed, so building the book needs neither ImageMagick
# nor a TeX engine.
mkdir -p figures/web

# ---------------------------------------------------------------- version
# version.tex is the single source of the edition; parse rather than repeat.
edition="$(sed -n 's/.*\\newcommand{\\bookversion}{\([^}]*\)}.*/\1/p' version.tex)"
bookdate="$(sed -n 's/.*\\newcommand{\\bookdate}{\([^}]*\)}.*/\1/p' version.tex)"
[ -n "$edition" ] || { echo "book-html: no \\bookversion in version.tex" >&2; exit 2; }

# --------------------------------------------------------------- chapters
# poplog-book.tex is the single source of the running order, so read it
# rather than keep a second copy of the list here.  A hand-kept copy rots
# silently and did: edition 1.10 inserted ch09-counsel and renamed
# ch09-next/ch10-appendix, and this script went on naming the old files --
# which builds an HTML edition short one chapter, from two files that no
# longer exist, while the PDF is correct.  \mainmatter .. \appendix are the
# numbered chapters; whatever follows \appendix is the appendix.
chapters="$(sed -n '/^\\mainmatter/,/^\\appendix/{ s/^\\input{\(ch[^}]*\)}.*/\1/p; }' \
            poplog-book.tex)"
appendices="$(sed -n '/^\\appendix/,${ s/^\\input{\(ch[^}]*\)}.*/\1/p; }' poplog-book.tex)"
[ -n "$chapters" ] || { echo "book-html: no \\input{ch..} chapters in poplog-book.tex" >&2; exit 2; }
for ch in $chapters $appendices; do
    [ -f "$ch.tex" ] || { echo "book-html: poplog-book.tex names $ch.tex, which is missing" >&2; exit 2; }
done

# ---------------------------------------------------------- TikZ -> SVG
# Chapter 1's VM diagram is a tikzpicture.  Pandoc cannot draw it, so render
# it once with the same colour definitions the book uses and commit the SVG.
# Rebuilt only when the chapter is newer, so the usual build needs no TeX.
svg="figures/web/vm-diagram.svg"
if [ ! -f "$svg" ] || [ ch01-why.tex -nt "$svg" ]; then
    if command -v tectonic >/dev/null 2>&1 && command -v pdftocairo >/dev/null 2>&1
    then
        echo "book-html: rendering $svg from ch01-why.tex"
        {
            cat <<'PRE'
\documentclass[border=3pt]{standalone}
\usepackage{tikz}
\usetikzlibrary{decorations.pathmorphing,positioning,fit,calc,arrows.meta}
\usepackage{xcolor}
% the diagram's nodes use the book's own \code macro
\newcommand{\code}[1]{\texttt{\small #1}}
PRE
            sed -n '/^\\definecolor/p' preamble.tex
            printf '%s\n' '\begin{document}'
            # the tikzpicture only: from its \begin to its \end, inclusive
            sed -n '/\\begin{tikzpicture}/,/\\end{tikzpicture}/p' ch01-why.tex
            printf '%s\n' '\end{document}'
        } > "$build/vm.tex"
        ( cd "$build" && tectonic -X compile --untrusted vm.tex >/dev/null 2>&1 )
        pdftocairo -svg "$build/vm.pdf" "$svg"
    else
        echo "book-html: no tectonic+pdftocairo and no $svg -- figure 1.1 will be missing" >&2
    fi
fi

# -------------------------------------------------------- web-sized cover
# cover.jpg is 1600x1620 for print; the HTML column is at most ~670 CSS px,
# so inlining the print original spends ~600 KB of base64 on pixels no
# screen shows.  Half size is still 1.5x a retina column.  Committed, and
# only rebuilt when the original changes, so a box without ImageMagick can
# still build the book -- it just falls back to the full-size cover.
cover="figures/cover.jpg"
if command -v magick >/dev/null 2>&1; then
    if [ ! -f figures/web/cover.jpg ] || [ figures/cover.jpg -nt figures/web/cover.jpg ]
    then
        echo "book-html: resizing figures/web/cover.jpg"
        magick figures/cover.jpg -resize 1000x -quality 82 -strip figures/web/cover.jpg
    fi
fi
[ -f figures/web/cover.jpg ] && cover="figures/web/cover.jpg"

# ------------------------------------------------------- assemble the LaTeX
# Pandoc gets the book's macro definitions (which it expands) and the
# chapters, but not the real preamble: geometry, fancyhdr, titlesec and
# tcolorbox mean nothing in HTML and only produce warnings.
{
    cat <<'MACROS'
\newcommand{\code}[1]{\texttt{#1}}
\newcommand{\dq}{"}
\newcommand{\ghbase}{https://github.com/IoTone/poplog/tree/master/examples/robotarmy}
\newcommand{\ghfile}[1]{\href{\ghbase/#1}{\code{examples/robotarmy/#1}}}
\newcommand{\robotpick}{}
MACROS
    cat version.tex            # \bookversion and \bookdate, cited by the colophon
    printf '%s\n' '\begin{document}'

    # Front matter: the colophon out of ch00-title.tex, which is otherwise
    # pure page layout (the title, subtitle and authors are passed to pandoc
    # as metadata instead, so the template sets them; the cover goes in
    # --include-before-body, which the template puts ahead of everything).
    # Taken from the file rather than retyped here, so the copyright and the
    # authorship note cannot drift out of step with the PDF's.
    sed -n '/^\\vfill/,/^\\clearpage/p' ch00-title.tex \
        | sed -e '/^\\vfill/d' -e '/^\\clearpage/d' -e '/^\\noindent/d' \
              -e '/^{\\sffamily/d' -e '/^}$/d' \
              -e 's/\\par\\vspace{[0-9]*pt}//g' \
              -e 's/\\vspace{[0-9]*pt}//g' \
              -e 's/\\par$//'
    printf '%s\n\n' '\hrulefill'

    for ch in $chapters $appendices
    do
        # The PDF gets \appendix, which renumbers the last file as
        # "Appendix A".  Pandoc has no \appendix, so say it in the heading
        # and leave the heading unnumbered rather than let it come out as
        # one past the last chapter.
        apx=''
        case " $appendices " in
            # Its sections are starred as well: an unnumbered chapter does
            # not reset the section counter, so numbered sections inside it
            # would carry on from the last chapter as "10.5 Syntax".
            *" $ch "*) apx='s/^\\chapter{\(.*\)}/\\chapter*{Appendix A --- \1}/
                            s/^\\section{\(.*\)}/\\section*{\1}/' ;;
        esac
        # Per-chapter rewrites, all of them because pandoc reflows the
        # content of an environment it does not know -- which silently
        # destroys a listing's line breaks and curls its quotes:
        #
        #   pop/sh/repl   the book's lstnewenvironments.  As lstlisting
        #                 pandoc emits <pre><code> with spacing intact.
        #   callout       a tcolorbox.  Pandoc keeps the div and its class
        #                 and renders the title argument as a <span>; the
        #                 blank line makes that span its own paragraph so
        #                 CSS can treat it as the heading.
        #   tikzpicture   replaced by the SVG rendered above.
        #   figure/center stripped to their contents: floats and \\[3pt]
        #                 struts have no meaning here.
        sed \
            -e 's/\\begin{pop}/\\begin{lstlisting}[language=Pop11]/' \
            -e 's/\\end{pop}/\\end{lstlisting}/' \
            -e 's/\\begin{sh}/\\begin{lstlisting}[language=bash]/' \
            -e 's/\\end{sh}/\\end{lstlisting}/' \
            -e 's/\\begin{repl}/\\begin{lstlisting}/' \
            -e 's/\\end{repl}/\\end{lstlisting}/' \
            -e 's/\(\\begin{callout}{[^}]*}\)/\1\n/' \
            "$ch.tex" | sed -e "$apx"
        echo
    done
    printf '%s\n' '\end{document}'
} | awk '
    # Drop the tikzpicture body and put the pre-rendered SVG in its place.
    /\\begin{tikzpicture}/ { intikz = 1; print "\\includegraphics{figures/web/vm-diagram.svg}"; next }
    intikz && /\\end{tikzpicture}/ { intikz = 0; next }
    intikz { next }
    { print }
' > "$build/book.tex"

# ------------------------------------------------------------------- cover
# Ahead of the title block and the contents, the way a book opens.  Pandoc's
# --embed-resources inlines this src along with the rest.
cat > "$build/cover.html" <<COVER
<figure class="cover"><img src="$cover" alt="Cover: five robots, one for each
Poplog front-end -- Pop-11, Prolog, Common Lisp, Standard ML and Forth."></figure>
COVER

# ------------------------------------------------------------------- style
cat > "$build/style.html" <<'CSS'
<style>
/* The book's palette, from docs/book/preamble.tex -- one source of truth
   for the two editions, so the HTML looks like the PDF it came from. */
:root {
  --ink:    #16323C;  /* body, headings */
  --accent: #0E7C7B;  /* links, callout rule, section numbers */
  --warm:   #B85C38;  /* strings in listings, in the PDF */
  --grey:   #5A6B72;  /* captions, metadata */
  --bg:     #F4F6F5;  /* code and callout background */
  --rule:   #D3DAD8;  /* hairlines */
  --page:   #ffffff;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --ink: #E6ECEA; --accent: #4FB3B2; --warm: #E08E6B; --grey: #9FB0B5;
    --bg: #16242A; --rule: #2C3C43; --page: #0E1A1F;
  }
}
:root[data-theme="dark"] {
  --ink: #E6ECEA; --accent: #4FB3B2; --warm: #E08E6B; --grey: #9FB0B5;
  --bg: #16242A; --rule: #2C3C43; --page: #0E1A1F;
}
/* The background goes on html as well: body is a centred column, so on a
   wide screen its background would otherwise stop at the column edge and
   leave the gutters white -- glaring in dark mode. */
html { -webkit-text-size-adjust: 100%; background: var(--page); }
body {
  background: var(--page);
  color: var(--ink);
  font: 17px/1.62 Palatino, "Palatino Linotype", "Iowan Old Style", Georgia, serif;
  max-width: 42rem;
  margin: 0 auto;
  padding: 2.5rem 16px 6rem;   /* 16px side gutter at phone width */
}
h1, h2, h3, h4, nav { font-family: "Helvetica Neue", Helvetica, Arial, sans-serif; }
h1 { font-size: 1.9rem; line-height: 1.2; margin: 3.5rem 0 1rem; }
h1:first-of-type { margin-top: 0; }
h2 { font-size: 1.3rem; margin: 2.5rem 0 .6rem; }
h3 { font-size: 1.08rem; margin: 1.8rem 0 .4rem; }
h1 { border-bottom: 1px solid var(--rule); padding-bottom: .4rem; }
a { color: var(--accent); text-decoration-thickness: 1px; text-underline-offset: 2px; }
p { margin: 0 0 1rem; }

/* Listings.  The PDF marks code with a thick left rule rather than a box;
   keep that, it is the book's most recognisable visual habit. */
pre {
  background: var(--bg);
  border-left: 3px solid var(--rule);
  padding: .7rem .85rem;
  overflow-x: auto;
  font-size: .82rem;
  line-height: 1.45;
  margin: 1rem 0;
}
pre code { font-family: "SF Mono", Menlo, Consolas, "DejaVu Sans Mono", monospace; }
code {
  font-family: "SF Mono", Menlo, Consolas, "DejaVu Sans Mono", monospace;
  font-size: .88em;
}
p code, li code, td code { background: var(--bg); padding: .08em .3em; border-radius: 2px; }

/* Callouts: tcolorbox in the PDF -- background, 2pt accent rule, sans title. */
div.callout {
  background: var(--bg);
  border-left: 2px solid var(--accent);
  padding: .8rem 1rem .2rem;
  margin: 1.4rem 0;
  font-size: .95rem;
}
div.callout > p:first-child > span {
  font-family: "Helvetica Neue", Helvetica, Arial, sans-serif;
  font-weight: 700;
  color: var(--accent);
}
div.callout > p:first-child { margin-bottom: .5rem; }

/* Retheme pandoc's syntax highlighting to the book's palette.  Pandoc emits
   its own (pygments-ish) rules earlier in the head, so these win on order.
   Only the languages pandoc knows get spans -- bash, C, SML, Common Lisp,
   and Pop-11 via pop11.xml; the 36 `repl` transcripts stay deliberately
   plain, because a terminal session is output, not source. */
code span.kw, code span.cf { color: var(--accent); font-weight: 700; }   /* keyword */
code span.co, code span.cv, code span.do { color: var(--grey); font-style: italic; } /* comment */
code span.st, code span.ch, code span.vs, code span.ss { color: var(--warm); }       /* string */
code span.dv, code span.bn, code span.fl, code span.dt { color: var(--ink); }        /* number, word */
code span.fu, code span.bu, code span.ex { color: var(--ink); }
code span.op, code span.va, code span.at, code span.cn, code span.sc { color: var(--ink); }
code span.al, code span.er, code span.wa { color: var(--warm); font-weight: 700; }

table { border-collapse: collapse; margin: 1.3rem 0; font-size: .92rem; width: 100%; }
th, td { padding: .35rem .6rem; border-bottom: 1px solid var(--rule); text-align: left; }
thead th { border-bottom: 1.5px solid var(--ink); font-family: "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: .85rem; }
tbody tr:last-child td { border-bottom: 1.5px solid var(--ink); }

figure { margin: 1.6rem 0; text-align: center; }
figure.cover { margin: 0 0 2.5rem; }
figure.cover img { max-width: min(100%, 28rem); border: 1px solid var(--rule); }
img { max-width: 100%; height: auto; }
figcaption, p > em:only-child { color: var(--grey); font-size: .88rem; }

/* Table of contents, from --toc. */
nav#TOC { background: var(--bg); border: 1px solid var(--rule); padding: 1rem 1.2rem; margin: 2rem 0 3rem; font-size: .92rem; }
nav#TOC > ul { margin: 0; padding-left: 1.1rem; }
nav#TOC ul ul { font-size: .95em; color: var(--grey); }
nav#TOC a { text-decoration: none; }
nav#TOC a:hover { text-decoration: underline; }

header#title-block-header { border-bottom: 2px solid var(--accent); padding-bottom: 1.2rem; margin-bottom: 1rem; }
header#title-block-header h1.title { font-size: 2.1rem; border: 0; margin-bottom: .3rem; }
header#title-block-header p.subtitle { color: var(--accent); font-size: 1.05rem; margin: 0 0 .6rem; }
header#title-block-header p.author, header#title-block-header p.date { color: var(--grey); font-size: .95rem; margin: 0; font-family: "Helvetica Neue", Helvetica, Arial, sans-serif; }

hr { border: 0; border-top: 1px solid var(--rule); margin: 2.5rem 0; }

@media print {
  body { max-width: none; font-size: 11pt; }
  nav#TOC { break-after: page; }
  h1 { break-before: page; }
  h1:first-of-type, header#title-block-header + * h1 { break-before: avoid; }
  pre, div.callout, table, figure { break-inside: avoid; }
  a { color: inherit; }
}
</style>
CSS

# ------------------------------------------------------------------- build
# --embed-resources inlines the figures as data URIs, which is what makes
# the result a single file.  --resource-path lets it find figures/ from the
# build directory.
pandoc "$build/book.tex" \
    --from=latex \
    --to=html5 \
    --standalone \
    --embed-resources \
    --toc --toc-depth=2 \
    --number-sections \
    --wrap=preserve \
    --mathml \
    --syntax-definition="$book/pop11.xml" \
    --resource-path="$book" \
    --include-before-body="$build/cover.html" \
    --include-in-header="$build/style.html" \
    --metadata title="Pop-11 and the Robot Army" \
    --metadata subtitle="Poplog as the engine behind AI agents and the machines they command" \
    --metadata author="David J. Kordsmeier and Claude" \
    --metadata date="Edition $edition, $bookdate" \
    --metadata lang=en \
    --output "$out"

size="$(wc -c < "$out" | tr -d ' ')"
echo "book-html: wrote $out ($(( size / 1024 )) KB, edition $edition)"
