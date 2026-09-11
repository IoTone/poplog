# Poplog and Pop-11 — A Working Introduction

An introduction to Poplog and Pop-11 — 27 pages of content, 29 with the title
page and contents. It covers the two-level virtual machine, a quickstart, the
core language, worked examples, the hosted front-ends (Prolog, Common Lisp,
Standard ML, Forth), how to host a language of your own, and the C interface.

    make            # -> poplog-book.pdf

## Building

The build uses [tectonic](https://tectonic-typesetting.github.io), which is a
single binary and downloads the TeX packages the document needs on first run:

    brew install tectonic          # macOS
    cargo install tectonic         # anywhere with Rust

Any other LaTeX distribution works as well — the document is plain LaTeX with
common packages (`geometry`, `listings`, `tcolorbox`, `hyperref`, `titlesec`,
`fancyhdr`, `booktabs`, `multicol`, `inconsolata`):

    latexmk -pdf poplog-book.tex

## Layout

| File | What it is |
| --- | --- |
| `poplog-book.tex` | Master file — document class, and the chapter includes |
| `preamble.tex` | Page geometry, palette, headings, listing languages, callout box |
| `ch00-title.tex` | Title page and colophon |
| `ch01-why.tex` … `ch08-next.tex` | The eight chapters |
| `ch09-appendix.tex` | Appendix A — cheat sheet, mishap decoder |
| `figures/` | Screenshots, cropped from `docs/images/` |

## On the examples

Every Pop-11, Forth, Prolog, Common Lisp and Standard ML listing in the book
was executed against this tree (Apple Silicon, macOS `arm64`) while the text
was written, and the transcripts shown are the outputs obtained. When a
listing changes, re-run it rather than assuming — several of the traps
documented in the text were found exactly that way.

Measurements quoted in Chapter 1 come from `BENCHMARKS.md`; the
compile-throughput and image-restore figures were measured directly and are
reproducible from the listings in §1.2 and §1.4.

## Publishing

`tools/gen-docs.sh` copies `poplog-book.pdf` into `dist/docs/` and links it
from the documentation-site index when the PDF is present, so a built book is
published with the site at <https://iotone.github.io/poplog/>. The PDF is
committed, so CI does not need a TeX toolchain.
