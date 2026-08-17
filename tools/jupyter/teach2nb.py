#!/usr/bin/env python3
"""teach2nb -- convert a Poplog TEACH file into a runnable Jupyter notebook.

TEACH files have a wonderfully mechanical layout: prose is flush-left,
code the reader should try is indented four spaces, and sections are
ruled with `-- Section name ----`.  That maps straight onto notebook
structure: prose becomes markdown, each indented block becomes a code
cell, section rules become headings.

    tools/jupyter/teach2nb.py pop/teach/lists [outdir]

With --execute, the notebook is run through the pop11 kernel
(allow_errors: TEACH files sometimes show mishaps on purpose, and the
session survives them), so the committed outputs are genuine.
"""

import argparse
import os
import re
import sys

HEADER_RE = re.compile(r"^--\s+(.*?)\s*-{3,}\s*$")
TITLE_RE = re.compile(r"^TEACH\s+(\S+)", re.IGNORECASE)


def convert(path):
    import nbformat as nbf

    lines = open(path, errors="replace").read().splitlines()
    nb = nbf.v4.new_notebook()
    nb.metadata.kernelspec = {
        "name": "pop11", "display_name": "Pop-11", "language": "pop11"}
    nb.metadata.language_info = {"name": "pop11", "file_extension": ".p"}

    name = os.path.basename(path)
    m = TITLE_RE.match(lines[0]) if lines else None
    title = (m.group(1) if m else name).upper()

    cells = []
    md_buf, code_buf = [], []

    def flush_md():
        text = "\n".join(md_buf).strip("\n")
        md_buf.clear()
        if text.strip():
            cells.append(nbf.v4.new_markdown_cell(text))

    pending = []          # code carried across prose while a define is open

    # NB no "procedure": its typed-declaration use (`lvars procedure p;`)
    # has no closer and would hold the balance open forever.
    PAIRS = ["define", "if", "unless", "while", "until", "for", "repeat",
             "foreach", "forevery"]

    def define_balance(text):
        # TEACH files develop defines AND loops across several blocks;
        # count every opener/closer pair the language has.
        bal = 0
        for w in PAIRS:
            bal += len(re.findall(r"\b%s\b" % w, text))
            bal -= len(re.findall(r"\bend%s\b" % w, text))
        return bal

    def flush_code():
        text = "\n".join(code_buf).strip("\n")
        code_buf.clear()
        if not text.strip():
            return
        # Syntax TEMPLATES with <angle-bracket> placeholders are prose —
        # fence them BEFORE balance accounting, or a `define <name …>`
        # template opens the balance and swallows the rest of the file.
        if re.search(r"<\s*[a-z][^>\n]*>", text):
            cells.append(nbf.v4.new_markdown_cell("```\n" + text + "\n```"))
            return
        # Indented blocks that carry no statement machinery (no `;`, `=>`
        # or `->`) are prose or reference lists — fenced markdown.  So are
        # blocks that BEGIN with `->`: they are the second half of a
        # pedagogically split assignment, and alone they would pop junk
        # into the variable.
        # …and so are non-terminating demos: TEACH files use bare
        # `repeat`-forever loops to teach interruption, which a notebook
        # cell cannot do.
        # This classification runs BEFORE balance accounting (like the
        # template fence): the balance regexes match `if`/`for`/… as
        # plain English inside indented prose, and one such block used
        # to open the balance and swallow every later code block in the
        # file (TEACH DATABASE came out with zero code cells).
        never_ends = (re.search(r"\brepeat\b", text)
                      and not re.search(r"\bquit(if|unless|loop)\b|\btimes\b",
                                        text))
        # `........` is the TEACH convention for "the reader fills this in".
        # It is not Pop-11, and compiling an exercise stub leaves the
        # session in a state where the NEXT cell (which calls the procedure
        # the reader was meant to write) hangs rather than simply failing.
        is_stub = "......" in text
        # …and blocks that END with a colon are prose leading into a
        # list ("this has two elements:"), whatever punctuation they
        # contain.
        is_prose = (not re.search(r"[;]|=>|->", text)
                    or text.lstrip().startswith("->") or never_ends
                    or is_stub
                    or text.rstrip().endswith(":"))
        if is_prose:
            # never disturbs an open define accumulation
            cells.append(nbf.v4.new_markdown_cell("```\n" + text + "\n```"))
            return
        # TEACH files often develop ONE procedure across several indented
        # blocks with prose between (header … body … enddefine).  Those
        # fragments are not compilable alone, so accumulate while the
        # define/enddefine balance is open and emit a single complete
        # cell at the closing fragment.
        # A FRESH `define` while one is already open means the pending
        # fragments were pedagogical re-displays of a header, not a
        # development (TEACH STACK shows the same header repeatedly):
        # fence them and restart the accumulation from this block.
        if pending and re.match(r"\s*define\b", text):
            cells.append(nbf.v4.new_markdown_cell(
                "```\n" + "\n".join(pending) + "\n```"))
            pending.clear()
        if pending or define_balance(text) > 0:
            pending.append(text)
            if define_balance("\n".join(pending)) > 0:
                return
            text = "\n".join(pending)
            pending.clear()
        cells.append(nbf.v4.new_code_cell(text))

    in_contents = False
    for i, raw in enumerate(lines):
        line = raw.rstrip()
        if i == 0:
            continue                       # the TEACH banner line
        h = HEADER_RE.match(line)
        if h:
            flush_code(); flush_md()
            in_contents = False
            md_buf.append("## " + h.group(1))
            continue
        if re.match(r"^\s*CONTENTS\b", line):
            in_contents = True
            continue
        if in_contents:
            continue                       # the <ENTER> g index; menus not needed
        # 4-space indent = code for the reader.  DEEPER indents are the
        # nesting inside that code (a loop body, a define's statements), so
        # they are code too -- matching only `^    \S` exiled every body
        # line into the prose buffer and left behind loop headers with
        # nothing in them.  `until z > 20 do / enduntil;` with the two body
        # lines missing is an infinite loop, and one of those ran for three
        # days at 100% CPU before anyone noticed.
        if raw.startswith("    ") and raw.strip():
            if md_buf:
                flush_md()
            stripped = raw[4:]
            # TEACH files inline the EXPECTED output after `=>` lines using
            # the `** …` print convention.  In a live notebook the kernel
            # regenerates the real output, and `**` is Pop-11's power
            # operator, so these lines must not be compiled.
            # `> …` / `< …` / `!> …` / `!< …` lines are inlined EXPECTED
            # trace output (the trace prefix convention), same idea as
            # `** `.  A lone `<` never starts real Pop-11 code.
            if stripped.lstrip().startswith(("**", "> ", "< ", "!>", "!<")):
                continue
            code_buf.append(stripped)
        elif not line.strip():
            if code_buf:
                code_buf.append("")
            else:
                md_buf.append("")
        else:
            if code_buf:
                flush_code()
            md_buf.append(line)
    flush_code(); flush_md()
    if pending:      # a define the file never closed: keep it, unexecuted
        cells.append(nbf.v4.new_markdown_cell(
            "```\n" + "\n".join(pending) + "\n```"))
        pending.clear()

    intro = nbf.v4.new_markdown_cell(
        f"# TEACH {title}\n\n*Converted from the Poplog teaching corpus "
        f"(`pop/teach/{name}`) by `tools/jupyter/teach2nb.py`. Every code "
        f"cell runs in one persistent, natively-compiled Pop-11 session — "
        f"edit and re-run them freely; a mishap is survivable and often "
        f"intentional.*")
    nb.cells = [intro] + cells
    return nb


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("teach_file")
    ap.add_argument("outdir", nargs="?", default="examples/notebooks/teach")
    ap.add_argument("--execute", action="store_true",
                    help="run the notebook through the pop11 kernel")
    args = ap.parse_args()

    import nbformat as nbf
    nb = convert(args.teach_file)

    if args.execute:
        from nbclient import NotebookClient
        NotebookClient(nb, kernel_name="pop11", timeout=180,
                       allow_errors=True).execute()
        ncode = sum(1 for c in nb.cells if c.cell_type == "code")
        nerr = sum(1 for c in nb.cells if c.cell_type == "code"
                   and any(o.output_type == "error" for o in c.outputs))
        print(f"executed: {ncode} code cells, {nerr} with mishaps")

    os.makedirs(args.outdir, exist_ok=True)
    out = os.path.join(
        args.outdir, os.path.basename(args.teach_file) + ".ipynb")
    nbf.write(nb, out)
    print("wrote", out)


if __name__ == "__main__":
    sys.exit(main())
