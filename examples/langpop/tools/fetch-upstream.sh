#!/bin/sh
# tools/fetch-upstream.sh -- download the reference data the importer reads.
#
# Neither file belongs in the repository and neither is small: JMdict_e is
# about 10MB compressed and 63MB of XML on disk.  They are downloaded into
# a directory you name, used at build time, and never committed.  See
# examples/langpop/import.p for why the arrangement is shaped this way.
#
#     tools/fetch-upstream.sh ~/langpop-upstream
#
# JMdict and KANJIDIC2 are the property of the Electronic Dictionary
# Research and Development Group and are distributed under Creative
# Commons Attribution-ShareAlike 4.0:
#
#     https://www.edrdg.org/edrdg/licence.html
#
# Please read that licence before doing anything with the files this
# script fetches.  The project's own arrangement -- importing them into a
# build product that is never shipped, so the share-alike stays on
# upstream's layer -- is described in import.p's header, and it is the
# reason the generated graph files are gitignored.

set -e

DEST="${1:-}"
if [ -z "$DEST" ]; then
    echo "usage: $0 <directory>" >&2
    echo "  (a new or empty directory; the files are large and are not committed)" >&2
    exit 2
fi

mkdir -p "$DEST"
cd "$DEST"

BASE=http://ftp.edrdg.org/pub/Nihongo

for f in JMdict_e.gz kanjidic2.xml.gz; do
    echo "fetching $f"
    curl -fsSL -o "$f" "$BASE/$f"
    # -k keeps the .gz, so a re-run does not download it again
    gunzip -kf "$f"
done

echo
echo "fetched into $DEST:"
ls -l JMdict_e kanjidic2.xml

cat <<NOTE

Now import.  The kanji come from a rule, the words from the pick list:

  ./poplog basepop11 examples/langpop/import.p \\
      --source kanjidic --file $DEST/kanjidic2.xml --level n5 --jlpt 4

  ./poplog basepop11 examples/langpop/import.p \\
      --source jmdict --file $DEST/JMdict_e \\
      --picks graph/ja/picks/n5.pl

Run the kanji import FIRST: the word import draws an edge from a word to
each kanji it contains that the graph already holds, and cannot draw an
edge to a character that is not there yet.
NOTE
