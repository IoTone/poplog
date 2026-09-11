# docs/book — "Poplog and Pop-11: A Working Introduction"
#
#   make          build poplog-book.pdf
#   make clean    remove build artefacts (keeps the PDF)
#   make distclean also removes the PDF
#
# Needs tectonic (https://tectonic-typesetting.github.io):
#   brew install tectonic      /      cargo install tectonic
# Any other LaTeX engine works too; see README.md.

TEX      := tectonic
MAIN     := poplog-book
CHAPTERS := $(wildcard ch*.tex) preamble.tex
FIGURES  := $(wildcard figures/*.png)

.PHONY: all clean distclean watch

all: $(MAIN).pdf

$(MAIN).pdf: $(MAIN).tex $(CHAPTERS) $(FIGURES)
	$(TEX) -X compile $(MAIN).tex

watch:
	$(TEX) -X watch

clean:
	rm -f $(MAIN).log $(MAIN).xdv $(MAIN).aux $(MAIN).toc $(MAIN).out

distclean: clean
	rm -f $(MAIN).pdf
