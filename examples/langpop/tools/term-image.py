#!/usr/bin/env python3
"""term-image.py -- put a picture in the terminal, if the terminal has one.

    term-image.py card.svg --cols 20

Writes an escape sequence to stdout and nothing else.  Exit status says
what happened, because the caller has to be able to fall back:

    0   the image was written
    2   this terminal has no image protocol
    3   no SVG converter on this machine
    4   the file is missing or unreadable

WHY A SCRIPT AND NOT POP-11.  The work is base64, PNG rasterisation and
two escape-sequence dialects, none of which langpop should carry in
Pop-11 for the sake of one view.  The Pop-11 side does what it does for
the microphone and the mora scorer: names a command, runs it, reads the
status.  Standard library only, like the two tools beside it.

THE TWO DIALECTS, and why both.

  kitty graphics protocol (kitty, ghostty, wezterm, konsole)
      APC _G<control>;<base64 payload> ST, in chunks of 4096.  The
      control keys used here are f=100 (the payload is PNG), a=T
      (transmit AND display now), c/r (how many cells to cover) and m
      (another chunk follows).  Chunking is not optional: a terminal is
      entitled to drop an APC string longer than its buffer, and a
      320x320 card is about 20KB of base64.

  iTerm2 inline images (iTerm2, and WezTerm also speaks it)
      OSC 1337 File=...:<base64> BEL, in one piece.

Sixel is deliberately not here.  It would mean quantising to a palette
and emitting the glyph as coloured runs, which is a second rasteriser to
be wrong in, and every terminal this project asks for speaks one of the
two above.

WHAT IT WILL NOT DO IS GUESS.  A terminal that announces nothing gets
exit 2 and no bytes, rather than a screenful of escape soup -- that is
the whole reason the status codes exist, and langpop prints its one-line
"this terminal cannot show pictures" on seeing it.
"""
import base64
import os
import shutil
import subprocess
import sys
import tempfile

CHUNK = 4096                 # base64 bytes per kitty APC string
CELL_W, CELL_H = 10, 20      # a guess at cell pixels, used only for rows


def protocol(env):
    """kitty, iterm, or None -- from the environment only.

    No querying the terminal: that means writing an escape sequence and
    reading a reply with a timeout, on a tty langpop does not own, in the
    middle of a question.  The env vars are what the terminals set for
    exactly this purpose.
    """
    term = env.get('TERM', '')
    prog = env.get('TERM_PROGRAM', '')
    if env.get('KITTY_WINDOW_ID') or 'kitty' in term:
        return 'kitty'
    # Ghostty speaks the kitty protocol and sets neither of the above.
    if prog == 'ghostty' or env.get('GHOSTTY_RESOURCES_DIR') \
            or env.get('GHOSTTY_BIN_DIR') or 'ghostty' in term:
        return 'kitty'
    if env.get('KONSOLE_VERSION'):
        return 'kitty'
    # WezTerm speaks both; iTerm2's own is the older and better tested.
    if prog == 'iTerm.app' or prog == 'WezTerm' or env.get('WEZTERM_PANE'):
        return 'iterm'
    return None


def to_png(path):
    """Rasterise, or pass a PNG straight through.  Returns bytes or None."""
    if path.lower().endswith('.png'):
        with open(path, 'rb') as f:
            return f.read()
    # rsvg-convert first: it is the smallest of the three and the only one
    # that does nothing but this.
    for cmd in (['rsvg-convert', '--zoom', '2', path],
                ['magick', '-density', '192', path, 'png:-'],
                ['convert', '-density', '192', path, 'png:-']):
        if shutil.which(cmd[0]) is None:
            continue
        try:
            out = subprocess.run(cmd, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, timeout=20)
        except (OSError, subprocess.SubprocessError):
            continue
        if out.returncode == 0 and out.stdout[:8] == b'\x89PNG\r\n\x1a\n':
            return out.stdout
    # qlmanage is on every Mac and writes beside the input, so it needs a
    # directory of its own rather than a pipe.
    if shutil.which('qlmanage'):
        with tempfile.TemporaryDirectory() as d:
            try:
                subprocess.run(['qlmanage', '-t', '-s', '640', '-o', d, path],
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=20)
            except (OSError, subprocess.SubprocessError):
                return None
            for name in os.listdir(d):
                if name.lower().endswith('.png'):
                    with open(os.path.join(d, name), 'rb') as f:
                        return f.read()
    return None


def png_size(png):
    """Width and height out of the IHDR, which is always the first chunk."""
    if len(png) < 24 or png[12:16] != b'IHDR':
        return (1, 1)
    w = int.from_bytes(png[16:20], 'big')
    h = int.from_bytes(png[20:24], 'big')
    return (w or 1, h or 1)


def emit_kitty(png, cols, rows):
    b = base64.standard_b64encode(png).decode('ascii')
    first = True
    out = []
    while b:
        piece, b = b[:CHUNK], b[CHUNK:]
        more = 1 if b else 0
        if first:
            head = 'f=100,a=T,c=%d,r=%d,m=%d' % (cols, rows, more)
            first = False
        else:
            head = 'm=%d' % more
        out.append('\x1b_G%s;%s\x1b\\' % (head, piece))
    # The cursor is left wherever the terminal chose to leave it, so the
    # rows are claimed explicitly.  Without this the next prompt prints
    # over the picture.
    out.append('\n' * rows)
    return ''.join(out)


def emit_iterm(png, cols, rows):
    b = base64.standard_b64encode(png).decode('ascii')
    return ('\x1b]1337;File=inline=1;width=%d;height=%d;'
            'preserveAspectRatio=1;size=%d:%s\x07\n'
            % (cols, rows, len(png), b))


def main(argv):
    args = [a for a in argv[1:]]
    cols = 20
    if '--cols' in args:
        i = args.index('--cols')
        try:
            cols = max(1, min(120, int(args[i + 1])))
        except (IndexError, ValueError):
            return 4
        del args[i:i + 2]
    if len(args) != 1:
        sys.stderr.write('usage: term-image.py <file.svg|file.png> '
                         '[--cols N]\n')
        return 4
    path = args[0]
    if not os.path.isfile(path):
        return 4

    proto = protocol(os.environ)
    if proto is None:
        return 2
    png = to_png(path)
    if png is None:
        return 3

    # From the image's own aspect, not from a guess that it is square:
    # the glyph card is square and the word card is 8:5, and a wrong row
    # count is a prompt printed over a picture.
    w, h = png_size(png)
    rows = max(1, round(cols * CELL_W * h / (CELL_H * w)))
    sys.stdout.write(emit_kitty(png, cols, rows) if proto == 'kitty'
                     else emit_iterm(png, cols, rows))
    sys.stdout.flush()
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
