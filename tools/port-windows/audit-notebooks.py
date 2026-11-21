#!/usr/bin/env python3
"""audit-notebooks.py -- re-run every code cell of the example notebooks in a
plain Pop-11 and compare what it prints with the output stored in the
notebook.

The notebooks under examples/notebooks were produced with the Jupyter kernel
(tools/jupyter), which needs the pop11 skill and uv.  This needs neither: it
is a check on the ENGINE, not on the kernel.  Each notebook runs in one
Pop-11 process, cell by cell, so definitions carry over as they do in a
notebook, and a mishap in one cell does not stop the rest.

    python3 tools/port-windows/audit-notebooks.py [notebook.ipynb ...]

Run it from the repository root, with ./poplog and target/pop/basepop11
built.  Exit status is the number of notebooks with a differing cell.

Stored and fresh output are compared after removing what cannot be expected
to match: the kernel's timing line, trailing blanks, blank lines, and the
FILE / LINE NUMBER / DOING context lines of a message (the message itself
and its INVOLVING line are compared).
"""
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

DRIVER = r'''
;;; run one cell: a mishap prints its message and then calls interrupt,
;;; which here abandons the cell and lets the next one run
define run_cell(file, n);
    lvars file, n;
    define dlocal interrupt(); exitfrom(run_cell) enddefine;
    pr('\n@@CELL '); pr(n); pr('@@\n');
    pop11_compile(file);
enddefine;
lvars i, dir = systranslate('AUDIT_CELLS'), count = strnumber(systranslate('AUDIT_COUNT'));
for i from 1 to count do
    run_cell(dir dir_>< ('cell_' >< i >< '.p'), i);
endfor;
pr('\n@@END@@\n');
'''


def norm(text):
    out = []
    for line in text.replace('\r', '').split('\n'):
        line = line.rstrip()
        if not line or line.startswith('\U0001f308'):
            continue
        # where a message came from differs by construction: the file is a
        # temporary one and the calling chain includes the runner
        if (line.startswith(';;; FILE') or line.startswith(';;; PRINT DOING')
                or line.startswith(';;; DOING') or line.startswith(';;; \t')
                or 'LINE NUMBER:' in line):
            continue
        out.append(line)
    return out


def stored(cell):
    parts = []
    for o in cell.get('outputs', []):
        if o.get('output_type') == 'stream':
            parts.append(''.join(o.get('text', [])))
        elif o.get('output_type') in ('execute_result', 'display_data'):
            parts.append(''.join(o.get('data', {}).get('text/plain', [])))
        elif o.get('output_type') == 'error':
            parts.append('\n'.join(o.get('traceback', [])))
    return norm('\n'.join(parts))


def audit(path, timeout):
    nb = json.load(open(path, encoding='utf-8'))
    cells = [c for c in nb['cells'] if c['cell_type'] == 'code']
    with tempfile.TemporaryDirectory() as tmp:
        for i, c in enumerate(cells, 1):
            with open(os.path.join(tmp, f'cell_{i}.p'), 'w', encoding='utf-8', newline='\n') as f:
                f.write(''.join(c['source']) + '\n')
        driver = os.path.join(tmp, 'driver.p')
        with open(driver, 'w', newline='\n') as f:
            f.write(DRIVER)
        env = dict(os.environ, AUDIT_CELLS=tmp + '/', AUDIT_COUNT=str(len(cells)))
        try:
            p = subprocess.run(['./poplog', 'target/pop/basepop11', driver],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, env=env, timeout=timeout)
            raw = p.stdout.decode('utf-8', 'replace')
        except subprocess.TimeoutExpired as e:
            raw = (e.stdout or b'').decode('utf-8', 'replace') + '\n@@TIMEOUT@@\n'
    got = {}
    for m in re.finditer(r'@@CELL (\d+)@@\n(.*?)(?=\n@@CELL \d+@@|\n@@END@@|\n@@TIMEOUT@@|\Z)', raw, re.S):
        got[int(m.group(1))] = norm(m.group(2))
    finished = '@@END@@' in raw
    diffs = []
    for i, c in enumerate(cells, 1):
        want, have = stored(c), got.get(i)
        if have is None:
            diffs.append((i, c, want, ['(cell not reached)']))
        elif have != want:
            diffs.append((i, c, want, have))
    return len(cells), diffs, finished


def main():
    paths = sys.argv[1:] or sorted(glob.glob('examples/notebooks/**/*.ipynb', recursive=True))
    verbose = os.environ.get('AUDIT_VERBOSE')
    bad = 0
    for path in paths:
        n, diffs, finished = audit(path, int(os.environ.get('AUDIT_TIMEOUT', '300')))
        state = 'same' if not diffs else f'{len(diffs)} differ'
        print(f'{path}: {n} cells, {state}{"" if finished else "  (DID NOT FINISH)"}')
        if diffs or not finished:
            bad += 1
        for i, c, want, have in diffs[: (None if verbose else 4)]:
            src = ' '.join(''.join(c['source']).split())[:100]
            print(f'    cell {i}: {src}')
            print(f'        stored: {" | ".join(want)[:200]}')
            print(f'        now:    {" | ".join(have)[:200]}')
    return bad


if __name__ == '__main__':
    sys.exit(main())
