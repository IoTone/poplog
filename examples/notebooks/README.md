# Pop-11 notebooks

Jupyter notebooks executed for real through the
[pop11 kernel](../../tools/jupyter/) — every output you see was
produced by the live engine, mishaps included (TEACH files use
deliberate errors to teach; red cells are usually the lesson).

Run them yourself: `tools/jupyter/install-kernel.sh`, then
`jupyter lab` and pick the **Pop-11** kernel.

- [pop11-live.ipynb](pop11-live.ipynb) — tour of the language and kernel
- [zmachine-cave.ipynb](zmachine-cave.ipynb) — **play interactive fiction
  in a notebook**: Poplog's Z-machine (the VM Infocom shipped *Zork* on)
  written in Pop-11, running a game live in the kernel session, one turn
  per cell

## The TEACH corpus, runnable

Converted from Poplog's classic teaching files by
[teach2nb](../../tools/jupyter/teach2nb.py); browsable originals at
[iotone.github.io/poplog](https://iotone.github.io/poplog/teach/teach.html).

Start here:

- [teach/lists.ipynb](teach/lists.ipynb) — lists, the heart of Pop-11
- [teach/arith.ipynb](teach/arith.ipynb) — arithmetic
- [teach/define.ipynb](teach/define.ipynb) — defining procedures
- [teach/stack.ipynb](teach/stack.ipynb) — the open stack
- [teach/arrow.ipynb](teach/arrow.ipynb) — assignment
- [teach/vars_and_lvars.ipynb](teach/vars_and_lvars.ipynb) — scoping

Then:

- [teach/matches.ipynb](teach/matches.ipynb) — the pattern matcher
- [teach/morematch.ipynb](teach/morematch.ipynb) — the matcher, deeper
- [teach/database.ipynb](teach/database.ipynb) — the classic AI database
- [teach/foreach.ipynb](teach/foreach.ipynb) — database iteration
- [teach/recursion.ipynb](teach/recursion.ipynb) — recursion
- [teach/percent.ipynb](teach/percent.ipynb) — list constructors and `%`
- [teach/trace.ipynb](teach/trace.ipynb) — tracing and debugging
- [teach/random.ipynb](teach/random.ipynb) — randomness

Some TEACH files are deliberately not here: interactive REPL tutorials
(CHAT0–2's Eliza needs a terminal conversation), read-the-source and
theory files. The full corpus lives on the
[docs site](https://iotone.github.io/poplog/).
