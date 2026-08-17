#!/usr/bin/env python3
"""Build the Z-machine demonstration notebook.

Each code cell is one turn of a game, played by a Z-machine written in
Pop-11 that is running inside the notebook's own kernel session.  Execute
with the pop11 kernel:

    tools/jupyter/make-cave-nb.py --execute

Needs a Poplog tree with LIB ZMACHINE; set POPLOG_ROOT to a checkout if
the installed skill predates it.
"""
import argparse
import os
import sys

import nbformat as nbf

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(REPO, "examples", "notebooks", "zmachine-cave.ipynb")

MD_INTRO = """# Playing interactive fiction inside a notebook

Poplog ships a **Z-machine** — the virtual machine Infocom shipped *Zork*
on in 1979 — written in Pop-11 (`LIB ZMACHINE`, about 1,500 lines across
seven files). It runs the same story files a 1980s home computer did, and
it passes the CZECH conformance suite for versions 3 and 5 without a
single failure.

This notebook plays a game in it. Not a recording of a game: the
interpreter is running in this notebook's kernel session, and each cell
below is one turn.

The story is *The Poplog Cave*, a miniature written for this project so
that something freely licensed ships with Poplog — every interactive
fiction actually worth playing belongs to somebody. Its source is
`examples/games/cave.inf`, about a hundred lines of library-free Inform 6.
"""

MD_HOW = """## How a turn works

`zplay_turn` looks like an ordinary procedure call, but the interpreter it
resumes is suspended *inside* the `sread` instruction, halfway through
executing the game's own code.

That is a Pop-11 **process** — a coroutine. The Z-machine runs inside one;
when the game asks for a command the process suspends, handing this cell
its output, and the next cell resumes it with the next command. Nothing
replays, nothing is re-entered, and the game's whole world — its object
tree, its stack, its program counter — simply waits between cells.

There is a pleasing circularity to this. Poplog's process machinery
depends on two assembly routines, `_ussave` and `_userasund`, which save
and restore the user stack. On arm64 they were unimplemented placeholder
stubs until a few days before this notebook was written; fixing them is
what made coroutines work on Apple Silicon at all — and therefore what
makes this cell work.
"""

MD_LOOK = """## Light first

The chamber ahead is dark. Games have been teaching players to pick up the
lamp before going in since 1976.
"""

MD_END = """## What just happened

Every line of prose above was produced by Z-code — the compiled game —
being interpreted a byte at a time by Pop-11: `sread` tokenised the typed
command against the story's own dictionary, the game's routines walked its
object tree, and `print_obj` and friends unpacked text that is stored
three five-bit characters to a sixteen-bit word.

The same interpreter runs the real thing. Point `zplay_start` at any v3 or
v5 story file you own — *Zork I*, *Adventure*, anything from the IF
Archive — and it plays.

- The interpreter: `pop/lib/lib/zmachine*.p`
- How it was built, and why it is written the way it is:
  [`docs/projects/zmachine-design.md`](../../docs/projects/zmachine-design.md)
- Agents can play too: the `pop11_play` tool on Poplog's MCP server.
"""

TURNS = [
    ("look", "The cave mouth, described again — `look` is the cheapest way to see the parser working."),
    ("take lamp", None),
    ("light lamp", None),
    ("north", None),
    ("north", "This is the dark chamber. With the lamp lit, it has a description."),
    ("north", None),
    ("take gem", None),
    ("inventory", None),
    ("score", None),
]


def build():
    nb = nbf.v4.new_notebook()
    nb.metadata.kernelspec = {
        "name": "pop11", "display_name": "Pop-11", "language": "pop11"}
    nb.metadata.language_info = {"name": "pop11", "file_extension": ".p"}

    cells = [nbf.v4.new_markdown_cell(MD_INTRO)]

    cells.append(nbf.v4.new_markdown_cell(
        "## Starting the game\n\n"
        "`zplay_start` loads the story, runs the machine up to its first "
        "prompt, and hands back everything it printed on the way."))
    cells.append(nbf.v4.new_code_cell(
        "uses zmachine_play;\n"
        "\n"
        ";;; the story ships with Poplog, so $usepop finds it in a checkout\n"
        ";;; and in an installed tree alike\n"
        "zplay_start('$usepop/examples/games/cave.z3') =>"))

    cells.append(nbf.v4.new_markdown_cell(MD_HOW))

    for i, (cmd, note) in enumerate(TURNS):
        if cmd == "take lamp":
            cells.append(nbf.v4.new_markdown_cell(MD_LOOK))
        if note:
            cells.append(nbf.v4.new_markdown_cell(note))
        cells.append(nbf.v4.new_code_cell("zplay_turn('%s') =>" % cmd))

    cells.append(nbf.v4.new_markdown_cell(MD_END))
    nb.cells = cells
    return nb


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--execute", action="store_true",
                    help="run the notebook through the pop11 kernel")
    args = ap.parse_args()

    nb = build()
    if args.execute:
        from nbclient import NotebookClient
        NotebookClient(nb, timeout=300, kernel_name="pop11",
                       resources={"metadata": {"path": REPO}},
                       allow_errors=True).execute()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        nbf.write(nb, f)
    print("wrote", os.path.relpath(OUT, REPO))


if __name__ == "__main__":
    main()
