#!/usr/bin/env python3
"""mic-level.py -- is the microphone working, and at what level?

    mic-level.py recording.wav

Prints a meter and a diagnosis to stdout.  Standard library only, like
the scorer beside it.

WHY THIS EXISTS.  score-morae.py answers "was the held beat there?" by
looking for SILENCE inside a word, and that question is only answerable
if the recording has a usable level and a quiet floor.  A verdict of
`wrong` from a microphone that was not plugged in, or from a room with a
fan in it, is indistinguishable from a verdict of `wrong` from a learner
who dropped the beat -- unless somebody looks at the signal.

So this prints what the scorer sees, in the scorer's own units: the
floor it would use, the voiced span it would measure, and the gaps it
would find.  A level you cannot see is a level you cannot fix.
"""
import array
import math
import sys
import wave

FRAME_MS = 10
FLOOR_FRAC = 0.12          # must match score-morae.py
BLOCKS = ' ▁▂▃▄▅▆▇█'
WIDTH_MS = 20              # one column of the envelope


def dbfs(x):
    if x <= 0:
        return float('-inf')
    return 20.0 * math.log10(min(1.0, x / 32768.0))


def db_str(x):
    v = dbfs(x)
    return '  -inf' if v == float('-inf') else '%6.1f' % v


def read(path):
    with wave.open(path, 'rb') as w:
        if w.getsampwidth() != 2:
            raise ValueError('want 16-bit PCM, got %d bytes'
                             % w.getsampwidth())
        rate, n, ch = w.getframerate(), w.getnframes(), w.getnchannels()
        raw = array.array('h', w.readframes(n))
    if ch > 1:
        raw = array.array('h', raw[0::ch])
    return raw, rate


def envelope(raw, rate, frame_ms=FRAME_MS):
    step = max(1, (rate * frame_ms) // 1000)
    env = []
    for i in range(0, max(0, len(raw) - step), step):
        acc = 0
        for s in raw[i:i + step]:
            acc += s * s
        env.append((acc / step) ** 0.5)
    return env


def bar(value, peak, width=40):
    if peak <= 0:
        return '-' * width
    n = int(round(width * min(1.0, value / peak)))
    return '=' * n + '-' * (width - n)


def main():
    if len(sys.argv) < 2:
        print('usage: mic-level.py recording.wav')
        return 1
    try:
        raw, rate = read(sys.argv[1])
    except Exception as exc:                      # noqa: BLE001
        print('  I cannot read that recording: %s' % exc)
        return 1
    if not raw:
        print('  The recording is empty -- nothing reached the microphone.')
        return 1

    env = envelope(raw, rate)
    peak = max(abs(s) for s in raw)
    rms = (sum(float(s) * s for s in raw) / len(raw)) ** 0.5
    secs = len(raw) / rate
    # The floor is the quietest tenth of the frames: a room, not a voice.
    quiet = sorted(env)[:max(1, len(env) // 10)]
    floor_level = sum(quiet) / len(quiet)

    gate = max(env) * FLOOR_FRAC if env else 0
    # `v > 0` and not merely `v >= gate`: on a silent recording the peak
    # is zero, so the gate is zero, so EVERY frame counted as voiced --
    # and a dead microphone reported "the voiced part fills the whole
    # recording", which is both true and the opposite of useful.  That
    # is the case this tool exists for most of all.
    voiced = [i for i, v in enumerate(env) if v > 0 and v >= gate]
    span_ms = (voiced[-1] - voiced[0] + 1) * FRAME_MS if voiced else 0
    gaps, run = [], 0
    if voiced:
        for i in range(voiced[0], voiced[-1] + 1):
            if env[i] < gate:
                run += 1
            elif run:
                gaps.append(run * FRAME_MS)
                run = 0
        if run:
            gaps.append(run * FRAME_MS)

    print('  peak  %s dBFS  %s' % (db_str(peak), bar(peak, 32768)))
    print('  rms   %s dBFS  %s' % (db_str(rms), bar(rms, 32768)))
    print('  floor %s dBFS  %s' % (db_str(floor_level), bar(floor_level, 32768)))
    print('  heard %.2f s of %.2f s recorded' % (span_ms / 1000.0, secs))
    if gaps:
        print('  silences inside it: %s ms'
              % ', '.join(str(g) for g in sorted(gaps, reverse=True)[:4]))
    else:
        print('  silences inside it: none')

    # The envelope, so the shape of the word is visible.
    per = max(1, WIDTH_MS // FRAME_MS)
    cols, i = [], 0
    while i < len(env):
        chunk = env[i:i + per]
        cols.append(max(chunk) if chunk else 0)
        i += per
    top = max(cols) if cols else 0
    line = ''
    for c in cols:
        if top <= 0:
            line += BLOCKS[0]
        else:
            line += BLOCKS[min(len(BLOCKS) - 1,
                               int(round((len(BLOCKS) - 1) * c / top)))]
    print('\n  %s' % line)
    # Mark the silences INSIDE the word, which is what the scorer times.
    # Marking every column below the floor instead put dots under the
    # lead-in and the tail, where silence is expected and uninteresting,
    # and the two rows then looked misaligned because they were
    # measuring different things.
    if voiced:
        first_col, last_col = voiced[0] // per, voiced[-1] // per
        marks = ''.join(
            '^' if (first_col <= i <= last_col and c < gate) else ' '
            for i, c in enumerate(cols))
    else:
        marks = ''
    if marks.strip():
        print('  %s  <- silence the scorer times (longest %d ms)'
              % (marks, max(gaps) if gaps else 0))
    else:
        print('  %s  <- no silence inside the word' % (' ' * len(cols)))

    print('')
    notes = []
    if peak == 0:
        # Nothing else is worth saying, and every other note would be
        # measuring a file with no signal in it.
        print('  NOTHING REACHED THE MICROPHONE -- not one non-zero sample.')
        print('  Check the input device, the cable, and that the terminal')
        print('  has microphone permission.')
        # Zero, and deliberately: the meter RAN and reported a fact.  A
        # non-zero exit means "I could not read the recording", and
        # returning it here made the tutor say "I could not run the
        # meter" over a perfectly good report of a dead microphone.
        return 0
    if dbfs(peak) > -1.0:
        notes.append('CLIPPING -- turn the input gain down or sit further back')
    elif dbfs(peak) < -30.0:
        notes.append('too quiet -- the scorer will not find the word at all')
    elif dbfs(peak) < -20.0:
        notes.append('quiet, but usable')
    else:
        notes.append('level is good')
    if dbfs(floor_level) > -35.0:
        notes.append('THE ROOM IS NOISY -- a held beat is silence, and this '
                     'floor may bury it')
    if span_ms == 0:
        notes.append('nothing above the floor: no microphone, wrong input, '
                     'or nobody spoke')
    elif span_ms > (secs * 1000) * 0.95:
        notes.append('the voiced part fills the whole recording -- it may '
                     'have been clipped at one end')
    for n in notes:
        print('  %s' % n)
    return 0


if __name__ == '__main__':
    sys.exit(main())
