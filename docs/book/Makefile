# docs/book — "Pop-11 and the Robot Army"
#
#   make          build poplog-book.pdf
#   make clean    remove build artefacts (keeps the PDF)
#   make distclean also removes the PDF
#
# Needs tectonic (https://tectonic-typesetting.github.io):
#   brew install tectonic      /      cargo install tectonic
# Any other LaTeX engine works too; see README.md.

# a fixed timestamp keeps the PDF byte-identical across rebuilds, so a
# no-change build does not show up as a diff
export SOURCE_DATE_EPOCH := 1600000000

TEX      := tectonic
MAIN     := poplog-book
CHAPTERS := $(wildcard ch*.tex) preamble.tex
FIGURES  := $(wildcard figures/*.png) $(wildcard figures/*.jpg)

.PHONY: all clean distclean watch

all: $(MAIN).pdf

$(MAIN).pdf: $(MAIN).tex $(CHAPTERS) $(FIGURES)
	$(TEX) -X compile --untrusted $(MAIN).tex

watch:
	$(TEX) -X watch

clean:
	rm -f $(MAIN).log $(MAIN).xdv $(MAIN).aux $(MAIN).toc $(MAIN).out

distclean: clean
	rm -f $(MAIN).pdf
