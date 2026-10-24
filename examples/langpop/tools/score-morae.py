#!/usr/bin/env python3
"""score-morae.py -- did the geminate get its beat?

The verdict command for langpop's `speak` channel, Stage 1 of
docs/projects/langpop-audio.md.  Reads a JSON request, writes a JSON
verdict, and uses the Python standard library and nothing else:

    score-morae.py --request req.json --out verdict.json

WHAT IT MEASURES, AND WHAT IT DOES NOT.  The plan this implements said
"beat boundaries, a duration per mora, a comparison against a count the
graph already computes".  The first half of that is wrong, and measuring
it is how we found out: an energy envelope finds VOICED RUNS, not beats.
がっこう comes back as two runs -- が, then っこう -- because こ and う are
one continuous voiced stretch with nothing between them to detect.  No
amount of threshold tuning produces four.

What the envelope does see is SILENCE, and one Japanese mora is made of
silence: the geminate っ is a held closure.  So this scores the question
`mora_sokuon` asks -- is the beat there? -- and declines the rest.

Measured over 188 words from one TTS voice, with the engine's own
lp_morae/1 for ground truth:

    geminate stops (っk, っt, っp)   6 of 6   gap/mora 1.33 - 1.55
    geminate fricative (っし)        1        gap/mora 0.00
    no geminate                    181       gap/mora 0.00 - 0.90

The threshold is the ratio of the longest internal silence to the word's
mean mora length, so it is normalised by the speaker's own rate and
needs no calibration utterance.  1.1 separates the populations with the
nearest non-geminate (くち, whose /tʃ/ closure runs 130ms) at 0.90.

っ BEFORE A FRICATIVE IS NOT A SILENCE.  いっしょ is [iʃːo]: the mora is
a lengthened [ʃ], which has energy all the way through.  The gap is
0ms and no threshold will find it, which is a fact about Japanese and
not a defect here.  The engine knows the following kana, so it declines
to ask rather than asking and abstaining -- but if one arrives anyway
the verdict is `near`, which in langpop's tier 5 means `I could not
tell` and moves the belief in neither direction.
"""
import argparse
import array
import json
import wave

FRAME_MS = 10
FLOOR_FRAC = 0.12          # of the peak; below this is silence
GEMINATE_RATIO = 1.1       # longest gap / mean mora length
MIN_VOICE_MS = 80          # shorter than this is not an utterance


def envelope(path, frame_ms=FRAME_MS):
    """RMS per frame, plus the frame size actually used."""
    with wave.open(path, 'rb') as w:
        if w.getsampwidth() != 2:
            raise ValueError('want 16-bit PCM, got %d bytes' % w.getsampwidth())
        rate, frames, channels = w.getframerate(), w.getnframes(), w.getnchannels()
        raw = array.array('h', w.readframes(frames))
    if channels > 1:
        raw = array.array('h', raw[0::channels])
    step = max(1, (rate * frame_ms) // 1000)
    env = []
    for i in range(0, max(0, len(raw) - step), step):
        acc = 0
        for sample in raw[i:i + step]:
            acc += sample * sample
        env.append((acc / step) ** 0.5)
    return env, frame_ms


def measure(path):
    """Total voiced span, the gaps inside it, in milliseconds."""
    env, frame_ms = envelope(path)
    if not env:
        return 0, []
    peak = max(env)
    if peak <= 0:
        return 0, []
    floor = peak * FLOOR_FRAC
    voiced = [i for i, v in enumerate(env) if v >= floor]
    if not voiced:
        return 0, []
    first, last = voiced[0], voiced[-1]
    total = (last - first + 1) * frame_ms
    gaps, run = [], 0
    for i in range(first, last + 1):
        if env[i] < floor:
            run += 1
        elif run:
            gaps.append(run * frame_ms)
            run = 0
    if run:
        gaps.append(run * frame_ms)
    return total, gaps


def score(sample, morae, detectable):
    """(outcome, confidence, detail) for one recording."""
    total, gaps = measure(sample)
    if total < MIN_VOICE_MS:
        return 'near', 0.0, 'I could not hear anything to measure.'
    if not morae or morae < 2:
        return 'near', 0.0, 'Nothing to time in a single beat.'
    if not detectable:
        return ('near', 0.0,
                'That one holds a fricative rather than a silence, '
                'so I cannot time it.')
    mora_ms = total / morae
    longest = max(gaps) if gaps else 0
    ratio = longest / mora_ms
    # Confidence is distance from the threshold, not a probability: it is
    # there so the engine can refuse a verdict it should not act on.
    confidence = min(1.0, abs(ratio - GEMINATE_RATIO) / GEMINATE_RATIO)
    if confidence < 0.15:
        return ('near', confidence,
                'That was borderline -- %d ms of silence where a beat is '
                'about %d ms.' % (longest, round(mora_ms)))
    if ratio >= GEMINATE_RATIO:
        return ('right', confidence,
                'The held beat is there: %d ms of silence against a %d ms '
                'mora.' % (longest, round(mora_ms)))
    return ('wrong', confidence,
            'The held beat is missing or too short: %d ms of silence where '
            'it wants about %d ms.' % (longest, round(mora_ms)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--request', required=True)
    ap.add_argument('--out', required=True)
    args = ap.parse_args()
    with open(args.request, encoding='utf-8') as fh:
        req = json.load(fh)
    try:
        # 'no' and not False: a JSON false is dropped by some generators
        # -- langpop's own among them -- so the request carries the fact
        # positively and anything that is not an explicit 'no' is taken
        # as measurable.
        outcome, confidence, detail = score(
            req['sample'], req.get('expect'),
            str(req.get('detectable', 'yes')).lower() != 'no')
    except Exception as exc:                      # noqa: BLE001
        # A scorer that raises is a tutor that crashes mid-question, so
        # every failure becomes the verdict that means "I could not tell".
        outcome, confidence, detail = 'near', 0.0, 'I could not read that: %s' % exc
    verdict = {'outcome': outcome, 'confidence': round(confidence, 3),
               'detail': detail, 'task': req.get('task'),
               'item': req.get('item')}
    with open(args.out, 'w', encoding='utf-8') as fh:
        json.dump(verdict, fh, ensure_ascii=False)
        fh.write('\n')


if __name__ == '__main__':
    main()
