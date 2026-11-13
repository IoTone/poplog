#!/usr/bin/env python3
"""check-portable-paths.py -- fail if the tree cannot be checked out on Windows.

    python3 tools/ci/check-portable-paths.py      (from the top of the tree)

Reads the tracked paths from git and reports, for each one that Windows
cannot hold:

  - a character Windows does not allow in a name: < > : " | ? * \\
    and the control characters
  - a reserved device name (CON, PRN, AUX, NUL, COM1-9, LPT1-9), with
    or without an extension
  - a name ending in a dot or a space
  - two paths that differ only in letter case (NTFS and APFS by default
    treat them as one file)
  - a symbolic link (needs Developer Mode or admin rights to check out)

Exit status 0 when clean, 1 when anything is found.  Standard library
only.  Why this exists: https://github.com/IoTone/poplog/issues/18
"""
import collections
import re
import subprocess
import sys

BAD_CHARS = re.compile(r'[<>:"|?*\\\x00-\x1f]')
RESERVED = re.compile(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$', re.I)


def tracked():
    out = subprocess.run(['git', 'ls-files', '-s', '-z'],
                         check=True, capture_output=True).stdout
    for entry in out.decode('utf-8', 'surrogateescape').split('\0'):
        if entry:
            meta, path = entry.split('\t', 1)
            yield meta.split()[0], path


def main():
    problems = []
    seen = collections.defaultdict(set)
    for mode, path in tracked():
        parts = path.split('/')
        for i, name in enumerate(parts):
            where = '/'.join(parts[:i + 1])
            if BAD_CHARS.search(name):
                problems.append('%s: a character Windows does not allow' % path)
                break
            if RESERVED.match(name):
                problems.append('%s: %r is a reserved name on Windows' % (path, name))
                break
            if name.endswith('.') or name.endswith(' '):
                problems.append('%s: a name ending in a dot or a space' % path)
                break
            seen[where.lower()].add(where)
        if mode == '120000':
            problems.append('%s: a symbolic link' % path)
    for spellings in seen.values():
        if len(spellings) > 1:
            problems.append('differ only in case: %s' % ', '.join(sorted(spellings)))
    for p in problems:
        print(p)
    if problems:
        print('%d path problem(s) that would stop a checkout on Windows.' % len(problems))
        return 1
    print('All tracked paths can be checked out on Windows.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
