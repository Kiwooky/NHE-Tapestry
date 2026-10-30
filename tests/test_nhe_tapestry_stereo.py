#!/usr/bin/env python3
"""Tests for Tapestry Stereo (2 in, 2 out). Run with tools/check_stereo.sh.

The promise: two tracks on one tape. The left track is the mono Tapestry, sample for sample, and
the right is the same machine reading the second track: same wobble (one capstan), its own grain
and hiss, a head azimuth that grows with Age, and auto level and noise reduction that hear both.
Neither input leaks into the other output. That the left half is the mono plugin is checked
against a mono build of the same source when one is given (PB_SO_MONO for the native run,
PB_SO_MONO_ARM for the Duo build under qemu).
The DSP itself is tested in test_nhe_tapestry.py."""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
for d in (os.environ.get('PB_TOOLS', ''), os.path.join(HERE, '..', 'tools'), os.path.join(HERE, '..', '..', 'MOD-plugin-playbook', 'tools')):
    if d and os.path.exists(os.path.join(d, 'lv2test.py')):
        sys.path.insert(0, d); break
import numpy as np
from lv2test import Plugin, check, done, db, rms, harmonic_pluck_train, tick_count, max_step, warble_cents

ORDER = ['format', 'tape', 'drive', 'tone', 'wow', 'flutter', 'age', 'hiss', 'mix', 'level', 'lv2_enabled']
DEF = dict(format=2, tape=1, drive=0, tone=0, wow=100, flutter=100, age=3, hiss=0, mix=100, level=0, lv2_enabled=1)
p = Plugin(ORDER, DEF, n_in=2, n_out=2)
STUDIO, HOME, WALKMAN, VHS, POCKET, ANSWER, MASTER, EIGHT, FOUR = range(9)
sr = 48000

def sine(f, secs, a=0.1, rate=sr):
    t = np.arange(int(secs * rate)) / rate
    return a * np.sin(2 * np.pi * f * t) * np.minimum(1, t / 0.01)

def st(l, r=None):
    return np.stack([l, l if r is None else r], 1)

x = harmonic_pluck_train(sr, 6.0)

# The left track is the mono plugin, sample for sample (same source in both inputs)
mono_so = os.environ.get('PB_SO_MONO_ARM' if 'qemu' in os.environ.get('PB_HOST', '') else 'PB_SO_MONO')
if mono_so and os.path.exists(mono_so):
    # Built without -ffast-math the two are bit-identical (measured on all five settings). DPF builds
    # with it, which lets the compiler round the two-track loop differently: -65 to -96 dB re the
    # signal (the most at full Drive, where the saturator magnifies the last bits), so the bar is -60.
    # The 4-track only matches while both tracks are the same (Age 0, Noise 0): its noise reduction
    # hears both, so the right track's own hiss and azimuth move the shared gain, as on a real deck.
    m = Plugin(ORDER, DEF, n_in=1, n_out=1, so=mono_so)
    worst = -200.0
    for kw in (dict(), dict(format=POCKET, age=10, hiss=10), dict(format=FOUR, tape=0, drive=12, age=0, hiss=0),
               dict(format=EIGHT, age=10, hiss=1, tone=3, mix=60, level=-3), dict(format=MASTER, drive=18)):
        yl = p.run(st(x), sr, **kw)[:, 0]; ym = m.run(x, sr, **kw)[:, 0]
        worst = max(worst, db(rms(yl - ym) / rms(ym)))
    check('left track = the mono plugin (5 settings, incl. Age 10, Noise 10, ALC, NR)', worst < -60, 'worst %.1f dB re the signal' % worst)
else:
    print('(no mono build given: skipping the comparison with mono)')

# With nothing to tell them apart (Age 0: no azimuth, no dropouts; Noise 0: no grain, no hiss),
# both tracks play the same
y = p.run(st(x), sr, age=0, hiss=0)
check('Age 0, Noise 0: right = left', np.abs(y[:, 0] - y[:, 1]).max() < 1e-6, 'max diff %.2g' % np.abs(y[:, 0] - y[:, 1]).max())

# One transport: the wobble is the same on both tracks (a separate wobble per side would chorus)
tone = sine(1000, 6.0, 0.05)
y = p.run(st(tone), sr, wow=200, flutter=200, age=3)
from scipy.signal import hilbert
def inst_f(w):
    return np.diff(np.unwrap(np.angle(hilbert(np.asarray(w, np.float64)))))
dl, dr_ = inst_f(y[sr:, 0]), inst_f(y[sr:, 1])
from scipy.ndimage import uniform_filter1d
cents_diff = 1200 * np.log2(np.abs(uniform_filter1d(dr_, 480)[2000:-2000]) / np.abs(uniform_filter1d(dl, 480)[2000:-2000]))
wl = warble_cents(y[:, 0], sr, 1000, 1.0)
check('one transport: both tracks wobble together', np.abs(cents_diff).max() < 0.1 * wl,
      'warble %.2f cents, L-R pitch difference at most %.3f cents' % (wl, np.abs(cents_diff).max()))

# Each track has its own noise: hiss is uncorrelated between the sides
z = np.zeros((2 * sr, 2))
y = p.run(z, sr, hiss=10)
r = np.corrcoef(y[sr // 2:, 0], y[sr // 2:, 1])[0, 1]
check('each track its own hiss (L/R correlation near 0)', abs(r) < 0.1 and rms(y[sr // 2:, 1]) > 0, 'r = %.3f' % r)
y = p.run(st(x), sr, format=WALKMAN, hiss=1, age=0)
gd = db(rms(y[:, 0] - y[:, 1]) / rms(y[:, 0]))
check('each track its own grain', -60 < gd < -25, 'L-R difference %.1f dB re the signal' % gd)

# Azimuth: the right track lags the left, more with Age and on slow tape
def lag_us(**kw):
    t1 = sine(1000, 2.0, 0.05)
    y = p.run(st(t1), sr, wow=0, flutter=0, hiss=0, **kw)[sr:]
    a = hilbert(y[:, 0]); b = hilbert(y[:, 1])
    ph = np.angle(np.mean(a * np.conj(b)))
    return ph / (2 * np.pi * 1000) * 1e6
l0, l10, lp10, lm10 = lag_us(age=0), lag_us(age=10), lag_us(age=10, format=POCKET), lag_us(age=10, format=MASTER)
check('azimuth: none at Age 0, about 40 us at Age 10 on a cassette', abs(l0) < 0.5 and 35 < l10 < 45, '%.1f / %.1f us' % (l0, l10))
check('azimuth: more on slow tape, little on fast reels', 70 < lp10 < 90 and 0 < lm10 < 5, 'pocket %.1f us, master %.1f us' % (lp10, lm10))

# Neither input leaks into the other output
for f in (WALKMAN, POCKET, FOUR):
    y = p.run(st(x, np.zeros_like(x)), sr, format=f, hiss=0)
    check('no leak L -> R (%s)' % ['Studio', 'Home', 'Walkman', 'VHS', 'Pocket', 'Answer', 'Master', '8-track', '4-track'][f],
          np.abs(y[:, 1]).max() < 1e-7 and rms(y[sr:, 0]) > 0.01, 'R peak %.2g' % np.abs(y[:, 1]).max())

# Linked auto level: on Pocket a loud hit on the left ducks a steady tone on the right too
toneR = sine(330, 4.0, 0.02)
hitL = np.zeros_like(toneR); n0 = int(2.0 * sr); hitL[n0:n0 + int(0.6 * sr)] = 0.4 * np.sin(2 * np.pi * 196 * np.arange(int(0.6 * sr)) / sr)
def duck(f):
    y = p.run(np.stack([hitL, toneR], 1), sr, format=f, wow=0, flutter=0, age=0, hiss=0)[:, 1]
    return db(rms(y[n0 + int(0.2 * sr):n0 + int(0.5 * sr)]) / rms(y[int(1.4 * sr):int(1.9 * sr)]))
dp, dw = duck(POCKET), duck(WALKMAN)
check('linked auto level: a hit on the left ducks the right on Pocket, not on Walkman', dp < -6 and abs(dw) < 0.5,
      'pocket %+.1f dB, walkman %+.1f dB' % (dp, dw))

# [every] Loudness at defaults, every format, within 3 dB of bypass on both sides
worst = 0
for f in range(9):
    y = p.run(st(x), sr, format=f)
    for c in (0, 1):
        worst = max(worst, abs(db(rms(y[sr:, c]) / rms(x[sr:]))))
check('every format within 3 dB of bypass, both sides', worst < 3.0, 'worst %.2f dB' % worst)

# [every] Bypass: dry at unity on both sides, independently, no click
xs = 0.15 * np.sin(2 * np.pi * 220 * np.arange(2 * sr) / sr)
xr = 0.1 * np.sin(2 * np.pi * 330 * np.arange(2 * sr) / sr)
y = p.run(np.stack([xs, xr], 1), sr, events=[(sr, 'lv2_enabled', 0)])
a, b = int(1.1 * sr), int(1.9 * sr)
err = max(np.abs(y[a:b, 0] - xs[a:b]).max(), np.abs(y[a:b, 1] - xr[a:b]).max())
check('bypass: each side dry at unity', err < 1e-4, 'max err %.2g' % err)
step = max(max_step(y[int(0.98 * sr):int(1.05 * sr), 0]) / max_step(xs), max_step(y[int(0.98 * sr):int(1.05 * sr), 1]) / max_step(xr))
check('bypass: no click', step < 1.5, 'max step %.2fx the signal' % step)

# [every] Format switch mid-note doesn't click, either side
y = p.run(st(xs[:]), sr, events=[(sr, 'format', FOUR)])
ref = max_step(p.run(st(xs), sr, format=FOUR)[sr // 2:, 0])
stp = max(max_step(y[int(0.98 * sr):int(1.1 * sr), c]) for c in (0, 1))
check('format switch: no click', stp < 1.3 * ref, 'max step %.4f vs %.4f' % (stp, ref))

# [every] No ticks, silence in silence out, torture
tk = [tick_count(p.run(st(x), sr, format=f, age=6)[:, c], sr) for f in (WALKMAN, POCKET, EIGHT, FOUR) for c in (0, 1)]
check('no ticks (4 formats, both sides, Age 6)', sum(tk) == 0, str(tk))
check('silence in, silence out (Noise 0)', all(np.abs(p.run(z, sr, format=f, age=10)).max() < 1e-6 for f in range(9)))
for srt in (44100, 48000, 96000):
    rng = np.random.default_rng(1)
    xt = 0.9 * rng.standard_normal((int(2 * srt), 2))
    ok = True; pk = 0
    for f in (POCKET, FOUR, MASTER):
        y = p.run(xt, srt, format=f, tape=0, drive=18, tone=5, wow=200, flutter=200, age=10, hiss=10, level=12)
        ok &= bool(np.isfinite(y).all()); pk = max(pk, np.abs(y).max())
    check('torture %d Hz' % srt, ok and pk < 16.0, 'peak %.2f' % pk)

# Factory presets: the mono set, for this URI
import rdflib
from rdflib.namespace import RDFS
LV2 = rdflib.Namespace('http://lv2plug.in/ns/lv2core#'); PSET = rdflib.Namespace('http://lv2plug.in/ns/ext/presets#')
gp = rdflib.Graph().parse(os.path.join(os.path.dirname(p.so), 'presets.ttl'), format='turtle')
presets = list(gp.subjects(rdflib.RDF.type, PSET.Preset))
ok = len(presets) == 10 and all('nhe-tapestry-stereo#' in str(s_) for s_ in presets)
for ps in presets:
    vals = {str(gp.value(port, LV2.symbol)): float(gp.value(port, PSET.value)) for port in gp.objects(ps, LV2.port)}
    ok &= set(vals) <= set(ORDER) and 'lv2_enabled' not in vals
check('10 factory presets, for the stereo URI', ok, '%d presets' % len(presets))

done()
