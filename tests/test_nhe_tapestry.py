#!/usr/bin/env python3
"""Tests for Tapestry. Tags follow docs/effect-profile.md: [every], [buffer],
nonlinear, level-sensitive, [mix]. Then one test per promise in SPEC.md."""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
for d in (os.environ.get('PB_TOOLS', ''), os.path.join(HERE, '..', 'tools'), os.path.join(HERE, '..', '..', 'MOD-plugin-playbook', 'tools')):
    if d and os.path.exists(os.path.join(d, 'lv2test.py')):
        sys.path.insert(0, d); break
import numpy as np
from lv2test import (Plugin, check, done, db, rms, centroid, harmonic_pluck_train, pluck_train,
                     tick_count, max_step, warble_cents)

ORDER = ['format', 'tape', 'drive', 'tone', 'wow', 'flutter', 'age', 'hiss', 'mix', 'level', 'lv2_enabled']
DEF = dict(format=2, tape=1, drive=0, tone=0, wow=100, flutter=100, age=3, hiss=0, mix=100, level=0, lv2_enabled=1)
p = Plugin(ORDER, DEF, n_in=1, n_out=1)
NAMES = ['Studio reel', 'Home reel', 'Walkman', 'VHS', 'Pocket', 'Answering', 'Master', '8-track', '4-track']
STUDIO, HOME, WALKMAN, VHS, POCKET, ANSWER, MASTER, EIGHT, FOUR = range(9)
NF = len(NAMES)
CHEAP, FERRIC, CHROME, METAL = range(4)
sr = 48000
LAT = 0.006   # the tape path's centre

def sine(f, secs, a=0.1, rate=sr):
    t = np.arange(int(secs * rate)) / rate
    return a * np.sin(2 * np.pi * f * t) * np.minimum(1, t / 0.01)

def gain_at(f, **kw):
    """Small-signal gain (dB) at f, wow and flutter off, so the response is clean."""
    x = sine(f, 1.0, 0.01)
    c = dict(wow=0, flutter=0, age=0); c.update(kw)
    y = p.run(x, sr, **c)[:, 0]
    return db(rms(y[int(0.5 * sr):]) / rms(x[int(0.5 * sr):]))

# [every] Loudness: every format and tape at defaults within +-3 dB of bypass (RMS, guitar level)
x = harmonic_pluck_train(sr, 9.0)
worst = 0
for f in range(NF):
    for t in range(4):
        y = p.run(x, sr, format=f, tape=t)[:, 0]
        worst = max(worst, abs(db(rms(y[sr:]) / rms(x[sr:]))))
check('every format x tape within 3 dB of bypass (RMS)', worst < 3.0, 'worst %.2f dB' % worst)

# [every] Bypass: dry at exactly unity, no click on the way in or out
xs = 0.15 * np.sin(2 * np.pi * 220 * np.arange(2 * sr) / sr)
y = p.run(xs, sr, events=[(sr, 'lv2_enabled', 0)])[:, 0]
a, b = int(1.1 * sr), int(1.9 * sr)
check('bypass: dry at unity', np.abs(y[a:b] - xs[a:b]).max() < 1e-4, 'max err %.2g' % np.abs(y[a:b] - xs[a:b]).max())
step = max_step(y[int(0.98 * sr):int(1.05 * sr)])
check('bypass: no click', step < 1.5 * max_step(xs), 'max step %.4f vs %.4f' % (step, max_step(xs)))

# [mix] Mix 0 = the dry, delayed by the tape path's 6 ms (so blends don't comb)
y = p.run(xs, sr, mix=0)[:, 0]
n = int(round(LAT * sr))
check('mix 0: dry, 6 ms late', np.abs(y[sr + n:] - xs[sr:len(xs) - n]).max() < 1e-4)
# [mix] in bypass the dry is at unity whatever Mix says
y = p.run(xs, sr, mix=40, lv2_enabled=0)[:, 0]
check('bypass at mix 40: dry at unity', np.abs(y[sr:] - xs[sr:]).max() < 1e-4)

# Wow and flutter: the formats rank from studio to dictaphone; knobs at 0 are steady
tone = sine(1000, 6.0, 0.05)
wc = []
for f in range(NF):
    y = p.run(tone, sr, format=f, age=0)[:, 0]
    wc.append(warble_cents(y, sr, 1000, skip=1.0))
check('W&F ranks studio < home < walkman < pocket', wc[STUDIO] < wc[HOME] < wc[WALKMAN] < wc[POCKET],
      ' '.join('%s %.2f' % (NAMES[i][:4], c) for i, c in enumerate(wc)) + ' cents rms')
check('studio W&F under 1 cent rms (~0.05 %)', wc[STUDIO] < 1.0, '%.2f cents' % wc[STUDIO])
check('walkman W&F 1-4 cents rms (0.06-0.23 %)', 1.0 < wc[WALKMAN] < 4.0, '%.2f cents' % wc[WALKMAN])
check('master W&F steady, under 0.3 cents rms', wc[MASTER] < 0.3, '%.2f cents' % wc[MASTER])
check('8-track wobbles more than a walkman, 4-track less', wc[EIGHT] > 1.3 * wc[WALKMAN] and wc[FOUR] < 0.8 * wc[WALKMAN],
      '8-track %.2f, walkman %.2f, 4-track %.2f cents' % (wc[EIGHT], wc[WALKMAN], wc[FOUR]))
# (grain and dropouts still jitter the phase estimate a little, so compare with the moving case)
ys = p.run(tone, sr, format=POCKET, wow=0, flutter=0, age=10)[:, 0]
ym = p.run(tone, sr, format=POCKET, age=10)[:, 0]
cs, cm = warble_cents(ys, sr, 1000, skip=1.0), warble_cents(ym, sr, 1000, skip=1.0)
check('wow 0 + flutter 0: steady (pocket, Age 10)', cs < 0.1 * cm, '%.2f vs %.2f cents' % (cs, cm))
y0 = p.run(tone, sr, age=0)[:, 0]; y9 = p.run(tone, sr, age=9)[:, 0]
check('Age adds wow', warble_cents(y9, sr, 1000, 1.0) > 1.3 * warble_cents(y0, sr, 1000, 1.0),
      '%.2f -> %.2f cents' % (warble_cents(y0, sr, 1000, 1.0), warble_cents(y9, sr, 1000, 1.0)))
y2 = p.run(tone, sr, wow=200, flutter=200, age=0)[:, 0]
check('Wow and Flutter 200 % roughly double it', 1.6 < warble_cents(y2, sr, 1000, 1.0) / wc[WALKMAN] < 2.4,
      '%.2fx' % (warble_cents(y2, sr, 1000, 1.0) / wc[WALKMAN]))

# Frequency response per format
g = {f: [gain_at(fr, format=f) for fr in (60, 90, 150, 1000, 5000, 10000)] for f in range(NF)}
s = g[STUDIO]
check('studio reel: flat 150 Hz-10 kHz within 1.5 dB', max(abs(v - s[3]) for v in s[2:]) < 1.5, ' '.join('%.1f' % v for v in s))
w = g[WALKMAN]
check('walkman: head bump (90 Hz above 1 kHz)', w[1] > w[3] + 1.0, '90 Hz %+.1f, 1 kHz %+.1f' % (w[1], w[3]))
check('walkman ferric: top end rolling off by 10 kHz', w[5] < w[3] - 1.5, '10 kHz %+.1f' % w[5])
m = g[MASTER]
check('master: near flat 150 Hz-10 kHz (1 dB), a low bump', max(abs(v - m[3]) for v in m[2:]) < 1.0 and m[1] > m[3] + 0.5,
      ' '.join('%.1f' % v for v in m))
e8 = g[EIGHT]
check('8-track: fat low end, dull top', e8[0] > e8[3] and e8[5] < e8[3] - 6, '60 Hz %+.1f, 1 kHz %+.1f, 10 kHz %+.1f' % (e8[0], e8[3], e8[5]))
f4 = g[FOUR]
check('4-track (double speed) brighter than a walkman at 10 kHz', f4[5] - f4[3] > w[5] - w[3] + 0.5,
      '4-track %+.1f, walkman %+.1f dB re 1 kHz' % (f4[5] - f4[3], w[5] - w[3]))
pk = g[POCKET]
check('pocket: no lows, no highs', pk[1] < pk[3] - 15 and pk[5] < pk[3] - 20, '90 Hz %+.1f, 1 kHz %+.1f, 10 kHz %+.1f' % (pk[1], pk[3], pk[5]))
an = [gain_at(fr, format=ANSWER) for fr in (150, 1000, 5000)]
check('answering: phone band (150 Hz and 5 kHz well down)', an[0] < an[1] - 15 and an[2] < an[1] - 15, ' '.join('%.1f' % v for v in an))
gc = gain_at(10000, format=WALKMAN, tape=CHROME); gk = gain_at(10000, format=WALKMAN, tape=CHEAP)
check('chrome brighter than ferric, cheap duller', gk < w[5] < gc, 'cheap %.1f ferric %.1f chrome %.1f' % (gk, w[5], gc))
g0 = gain_at(5000, age=0); g10 = gain_at(5000, age=10)
check('Age dulls the top end', g10 < g0 - 2.0, '5 kHz %.1f -> %.1f dB' % (g0, g10))

# Drive is mostly compensated: it keeps a quarter of its gain (-3 dB at -12, +4.5 dB at +18)
lo = gain_at(1000, drive=-12); mid = gain_at(1000); hi = gain_at(1000, drive=18)
check('drive keeps a quarter of its gain', abs(lo - mid + 3.0) < 0.5 and abs(hi - mid - 4.5) < 0.5,
      '%+.2f / %+.2f dB' % (lo - mid, hi - mid))

# Level: +-12 dB on the output, exactly; Tone tilts around 800 Hz
lp_, lm_ = gain_at(1000, level=12), gain_at(1000, level=-12)
check('level +-12 dB', abs(lp_ - mid - 12) < 0.1 and abs(lm_ - mid + 12) < 0.1, '%+.2f / %+.2f' % (lp_ - mid, lm_ - mid))
tb = [gain_at(fr, format=MASTER, tone=5) - gain_at(fr, format=MASTER) for fr in (100, 800, 8000)]
td = [gain_at(fr, format=MASTER, tone=-5) - gain_at(fr, format=MASTER) for fr in (100, 800, 8000)]
check('tone +5: brighter, -5: darker, pivot near 800 Hz',
      tb[2] > 3 and tb[0] < -3 and td[2] < -3 and td[0] > 3 and abs(tb[1]) < 1.5 and abs(td[1]) < 1.5,
      'bright %s, dark %s dB' % (' '.join('%+.1f' % v for v in tb), ' '.join('%+.1f' % v for v in td)))

# Self-erasure: played hard, the treble compresses before the body does
def comp(f, **kw):
    return gain_at_level(f, 0.3, **kw) - gain_at_level(f, 0.01, **kw)
def gain_at_level(f, a, **kw):
    x = sine(f, 1.0, a)
    c = dict(wow=0, flutter=0, age=0); c.update(kw)
    y = p.run(x, sr, **c)[:, 0]
    return db(rms(y[int(0.5 * sr):]) / rms(x[int(0.5 * sr):]))
c200, c6k = comp(200), comp(6000)
check('treble compresses first (6 kHz 4 dB+ more than 200 Hz)', c6k < c200 - 4, '200 Hz %+.1f, 6 kHz %+.1f dB' % (c200, c6k))

# nonlinear: hot drive saturates (harmonics up), Metal has more headroom than Cheap
def thd(**kw):
    x = sine(200, 1.0, 0.15)
    y = p.run(x, sr, format=STUDIO, wow=0, flutter=0, age=0, **kw)[:, 0][int(0.5 * sr):]
    S = np.abs(np.fft.rfft(y * np.hanning(len(y))))
    fr = np.fft.rfftfreq(len(y), 1 / sr)
    h = lambda k: S[np.abs(fr - 200 * k).argmin()]
    return db(np.sqrt(sum(h(k) ** 2 for k in range(2, 8))) / h(1))
t0, t18 = thd(drive=0), thd(drive=18)
check('drive +18 saturates (THD up 15 dB+)', t18 > t0 + 15, '%.1f -> %.1f dB' % (t0, t18))
tc, tm = thd(drive=12, tape=CHEAP), thd(drive=12, tape=METAL)
check('metal has more headroom than cheap tape', tm < tc - 3, 'cheap %.1f, metal %.1f dB' % (tc, tm))
# nonlinear: no aliasing at full drive (a 4 kHz sine makes nothing below 3 kHz)
x = sine(4000, 1.0, 0.3)
y = p.run(x, sr, format=STUDIO, tape=CHEAP, drive=18, wow=0, flutter=0, age=0)[:, 0][int(0.5 * sr):]
S = np.abs(np.fft.rfft(y * np.blackman(len(y)))); fr = np.fft.rfftfreq(len(y), 1 / sr)
below = S[(fr > 150) & (fr < 3000)].max() / S.max()
check('no aliasing at drive +18 (4 kHz -> nothing under 3 kHz)', db(below) < -50, '%.1f dB' % db(below))

# level-sensitive: ALC lifts a quiet player on Pocket, not on Walkman
q = harmonic_pluck_train(sr, 6.0, level=0.02)
lw = rms(p.run(q, sr, format=WALKMAN)[:, 0][sr:]); lp = rms(p.run(q, sr, format=POCKET)[:, 0][sr:])
lq = rms(q[sr:])
check('ALC: pocket lifts a quiet player', db(lp / lq) > db(lw / lq) + 6, 'walkman %+.1f, pocket %+.1f dB' % (db(lw / lq), db(lp / lq)))

# Hiss: off by default (silence in, silence out), the format's floor at 5, louder at 10
z = np.zeros(2 * sr)
check('silence in, silence out (Hiss 0)', all(np.abs(p.run(z, sr, format=f, age=10)).max() < 1e-6 for f in range(NF)))
h5 = db(rms(p.run(z, sr, hiss=5)[:, 0][sr // 2:]))
h10 = db(rms(p.run(z, sr, hiss=10)[:, 0][sr // 2:]))
hs = db(rms(p.run(z, sr, hiss=5, format=STUDIO)[:, 0][sr // 2:]))
check('hiss 5 near the walkman floor (-72 dBFS +-6)', -78 < h5 < -66, '%.1f dBFS' % h5)
check('hiss 10 is 10 dB up', 8 < h10 - h5 < 12, '%+.1f dB' % (h10 - h5))
check('studio hiss far below walkman', hs < h5 - 12, '%.1f dBFS' % hs)

# 4-track noise reduction: hiss hides in silence and breathes in under the playing
from scipy.signal import butter, sosfilt
hpf = butter(4, 5000, 'highpass', fs=sr, output='sos')
hq = db(rms(p.run(z, sr, format=FOUR, hiss=5)[:, 0][sr // 2:]))
xt = 0.1 * np.sin(2 * np.pi * 200 * np.arange(3 * sr) / sr) * np.minimum(1, np.arange(3 * sr) / 480)
kw = dict(format=FOUR, age=0, wow=0, flutter=0)
hl = db(rms(sosfilt(hpf, p.run(xt, sr, hiss=5, **kw)[:, 0] - p.run(xt, sr, hiss=0, **kw)[:, 0])[sr:]))
check('4-track: hiss hides in silence, breathes in under signal', hq < -100 and hl > hq + 30, 'silence %.1f, under a tone %.1f dBFS' % (hq, hl))
# 4-track: the compander mistracks a little on attacks (punch), never a lot
xp = harmonic_pluck_train(sr, 9.0)
ya = p.run(xp, sr, format=FOUR, age=0, wow=0, flutter=0)[:, 0]; yb = p.run(xp, sr, format=STUDIO, age=0, wow=0, flutter=0)[:, 0]
pkf = lambda w_: [np.abs(w_[int((0.2 + 1.5 * k) * sr):int((0.2 + 1.5 * k + 0.05) * sr)]).max() for k in range(6)]
ov = max(db(a_ / b_) for a_, b_ in zip(pkf(ya), pkf(yb)))
check('4-track attack overshoot under 3 dB', ov < 3.0, '%+.1f dB worst' % ov)

# Switching Format or Tape mid-note doesn't click
xs = 0.15 * np.sin(2 * np.pi * 330 * np.arange(3 * sr) / sr)
y = p.run(xs, sr, events=[(sr, 'format', STUDIO), (2 * sr, 'tape', METAL)])[:, 0]
ref = max_step(p.run(xs, sr, format=STUDIO)[:, 0][sr // 2:])
st = max(max_step(y[int(0.98 * sr):int(1.1 * sr)]), max_step(y[int(1.98 * sr):int(2.1 * sr)]))
check('format/tape switch: no click', st < 1.3 * ref, 'max step %.4f vs %.4f' % (st, ref))

# [every] First run: a non-default format from sample 0, no fade-in or glide
x = sine(1000, 0.4, 0.05)
y = p.run(x, sr, format=STUDIO, wow=0, flutter=0, age=0)[:, 0]
early = rms(y[int(0.02 * sr):int(0.05 * sr)]) / rms(x[int(0.02 * sr):int(0.05 * sr)])
check('first run: full level from the start', abs(db(early)) < 1.0, '%.2f dB' % db(early))

# [every] No ticks with musical input, every format
xp = harmonic_pluck_train(sr, 9.0)
tk = [tick_count(p.run(xp, sr, format=f, age=6)[:, 0], sr) for f in range(NF)]
check('no ticks, every format at Age 6', sum(tk) == 0 and tick_count(xp, sr) == 0, str(tk))

# [every] Torture: every knob at its extreme, hot input, three rates: finite and bounded
for srt in (44100, 48000, 96000):
    xt = 0.9 * np.random.default_rng(1).standard_normal(int(3 * srt))
    ok = True; pk_ = 0
    for f in (STUDIO, POCKET, ANSWER, MASTER, EIGHT, FOUR):
        y = p.run(xt, srt, format=f, tape=CHEAP, drive=18, tone=5, wow=200, flutter=200, age=10, hiss=10, level=12)
        ok &= bool(np.isfinite(y).all()); pk_ = max(pk_, np.abs(y).max())
    check('torture %d Hz' % srt, ok and pk_ < 16.0, 'peak %.2f' % pk_)

# [every] Timing at every rate: the tape path's centre is 6 ms
for srt in (44100, 48000, 96000):
    x = np.zeros(srt); x[int(0.1 * srt)] = 0.5
    y = p.run(x, srt, format=STUDIO, wow=0, flutter=0, age=0, mix=0)[:, 0]
    t = (np.abs(y).argmax() / srt - 0.1) * 1e3
    check('dry path latency 6 ms (%d Hz)' % srt, abs(t - 6.0) < 0.05, '%.2f ms' % t)

# Format switch into and out of Master doesn't click
xs = 0.15 * np.sin(2 * np.pi * 330 * np.arange(3 * sr) / sr)
y = p.run(xs, sr, events=[(sr, 'format', FOUR), (2 * sr, 'format', EIGHT)])[:, 0]
st = max(max_step(y[int(0.98 * sr):int(1.1 * sr)]), max_step(y[int(1.98 * sr):int(2.1 * sr)]))
check('switch to 4-track and 8-track: no click', st < 1.3 * max(max_step(p.run(xs, sr, format=f)[:, 0][sr // 2:]) for f in (STUDIO, FOUR, EIGHT)), 'max step %.4f' % st)

# Moving Tone and Level mid-note doesn't click
xs = 0.15 * np.sin(2 * np.pi * 330 * np.arange(2 * sr) / sr)
ev = [(int(0.5 * sr), 'tone', 5), (int(1.0 * sr), 'tone', -5), (int(1.3 * sr), 'level', 12), (int(1.6 * sr), 'level', -12)]
y = p.run(xs, sr, format=MASTER, events=ev)[:, 0]
ref = max(max_step(p.run(xs, sr, format=MASTER, tone=t, level=l)[:, 0][sr // 2:]) for t in (5, -5, 0) for l in (12, -12, 0))
st = max_step(y[int(0.45 * sr):]) / ref
check('tone and level moves: no click', st < 1.1, 'max step %.2fx the loudest steady setting it passes through' % st)

# Factory presets: each one parses, sets only real ports, and lands within 3 dB of bypass
import rdflib
from rdflib.namespace import RDFS
LV2 = rdflib.Namespace('http://lv2plug.in/ns/lv2core#'); PSET = rdflib.Namespace('http://lv2plug.in/ns/ext/presets#')
gp = rdflib.Graph().parse(os.path.join(os.path.dirname(p.so), 'presets.ttl'), format='turtle')
presets = list(gp.subjects(rdflib.RDF.type, PSET.Preset))
x = harmonic_pluck_train(sr, 9.0)
res = []; ok = len(presets) == 10
for ps in presets:
    vals = {}
    for port in gp.objects(ps, LV2.port):
        vals[str(gp.value(port, LV2.symbol))] = float(gp.value(port, PSET.value))
    ok &= set(vals) <= set(ORDER) and 'lv2_enabled' not in vals and vals.get('hiss') == 0
    y = p.run(x, sr, **vals)[:, 0]
    d = db(rms(y[sr:]) / rms(x[sr:])); ok &= abs(d) < 3.0
    res.append('%s %+.1f' % (gp.value(ps, RDFS.label), d))
check('10 factory presets load, hiss off, within 3 dB of bypass', ok, '; '.join(res))

done()
