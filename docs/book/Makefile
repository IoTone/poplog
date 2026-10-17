# docs/book — "Pop-11 and the Robot Army"
#
#   make          build poplog-book.pdf
#   make html     build poplog-book.html (one self-contained HTML5 file)
#   make all      both editions
#   make clean    remove build artefacts (keeps the PDF)
#   make distclean also removes the PDF
#
# Needs tectonic (https://tectonic-typesetting.github.io):
#   brew install tectonic      /      cargo install tectonic
# Any other LaTeX engine works too; see README.md.

# a fixed timestamp (2026-09-10, the book's date) keeps the PDF byte-identical
# across rebuilds, so a no-change build does not show up as a diff
export SOURCE_DATE_EPOCH := 1789041600

TEX      := tectonic
MAIN     := poplog-book
CHAPTERS := $(wildcard ch*.tex) preamble.tex version.tex
FIGURES  := $(wildcard figures/*.png) $(wildcard figures/*.jpg)

.PHONY: pdf all html clean distclean watch

# pdf is first, so a bare `make` still builds only the PDF and still needs
# nothing but tectonic.  `make all` adds the HTML edition, which needs pandoc.
pdf: $(MAIN).pdf
all: $(MAIN).pdf $(MAIN).html
html: $(MAIN).html

$(MAIN).pdf: $(MAIN).tex $(CHAPTERS) $(FIGURES)
	$(TEX) -X compile --untrusted $(MAIN).tex

# The HTML5 edition: one file, no JavaScript, images inlined.  Needs pandoc;
# see tools/book-html.sh.  ch00-title.tex is a dependency because the
# colophon is lifted from it, and pop11.xml because it is what highlights
# the Pop-11 listings.
$(MAIN).html: $(MAIN).tex $(CHAPTERS) $(FIGURES) ch00-title.tex pop11.xml \
              ../../tools/book-html.sh
	../../tools/book-html.sh

watch:
	$(TEX) -X watch

clean:
	rm -f $(MAIN).log $(MAIN).xdv $(MAIN).aux $(MAIN).toc $(MAIN).out

distclean: clean
	rm -f $(MAIN).pdf
