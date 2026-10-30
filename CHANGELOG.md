# Changelog

## Tapestry Stereo 1.0.0 (build 0): two tracks, one tape

- New plugin, `urn:mod-cookbook:nhe-tapestry-stereo`: the mono source built with two inputs (`plugins/nhe-tapestry-stereo`), Niels's face with a STEREO badge.
- One transport: wow and flutter shared (L/R pitch difference under 0.03 cents with 4.8 cents of warble). Per track: grain, hiss (L/R correlation −0.01), saturation, EQ.
- Head azimuth: the right track lags by 40 µs × Age/10 × (1⅞ ips ÷ speed), capped at 0.25 ms: 40 µs at Age 10 on a cassette, 80 on Pocket, 2.5 on Master (measured).
- Dropouts: same moments on both tracks, the right side's depth within ±15 % (its own generator, so the left stays the mono plugin's).
- Linked auto level (Pocket, Answering) and noise reduction (4-track): a hit on one side ducks the other (−20 dB on Pocket; 0 on Walkman).
- No leak between sides (below −140 dB). Left side = the mono plugin when fed the same source: bit-identical without -ffast-math; within −65 to −96 dB with it, as built.
- Gate: 21 tests pass natively and on the Duo build under qemu. CPU about 1.7× the mono plugin, 2.0× at worst (4-track, Noise 10).

## 1.0.8 (build 8)

- The engine now runs one or two tracks (for Tapestry Stereo). The mono plugin's output is unchanged: sample for sample identical to 1.0.7 across 27 runs (every format, switches mid-note, Age 10, Noise 10).
- `tools/gen_ttl.py` writes both bundles' TTL, presets and manifests from one table; `tools/check.sh` and `tools/check_stereo.sh` run the gates.

## 1.0.7 (build 7)

- New panel art with the knob labelled NOISE (Niels). Version bumped so MOD loads the new face.

## 1.0.6 (build 6): Noise

After a good stretch of playing: the fine rasp on held notes on the Walkman, 8-track and 4-track wasn't always wanted.

- **Hiss is now Noise**, and it owns the tape's grain (modulation noise) too. 0 = clean, no hiss, no grain. 1 = the format's grain, exactly as 1.0.5, still no hiss. 2 to 10 = the hiss fades in, 3 dB a step, to the format's real noise floor at 10 (where 1.0.5 had it at 5). The port symbol is still `hiss`, so saved presets and pedalboards load.
- **Pocket and Answering unchanged**: their grain stays at every Noise setting. Dropouts still belong to Age.
- Measured on a held low E: at Noise 0 the Walkman, 8-track and 4-track drop from about −42 to −44 dB of grit (re the note) to the measurement floor (−48 to −49 dB). Saturation, self-erasure and the compander were measured too and add nothing audible at guitar level.
- The archetype presets are set to Noise 1, so they sound exactly as before; Always on stays at 0.

## 1.0.5 (build 5): the LCD font, working

- Found why web fonts never showed in mod-ui: its main.css sets `* { font-family: "cooper hewitt", Sans-serif !important }` on every element. The face's LCD rule now carries `!important` too, and its class selector wins. Reproduced with mod-ui's own main.css: without it the LCD falls back to mod-ui's font; with it the LCD font is used.
- New LCD font: "lcd phone" (Grafito Design) in place of Poxel (non-commercial licence). Added minus, plus and full stop on its own 5 x 7 dot grid, gave it a standard Unicode map (it only had a Symbol one), and cut it to the LCD's characters: 3.3 KB.
- Refitted to the mockup: same cap height, format line to the pixel, value digits a touch tighter so "100" clears the divider.

## 1.0.4 (build 4)

- New slider cap art with transparent corners (Niels). Version bumped so MOD loads the new face.

## 1.0.3 (build 3): the face

- Custom face from Niels's artwork (650 x 400, 2x art): Drive / Level / Mix sliders with an LCD readout, a Format LCD, red and grey step buttons for Format and Tape, Tape lights (click a label to pick it), On/Off light and button, five knobs, and the machine's picture following Format.
- LCD text uses the Poxel web font, loaded from the plugin's resources with `url(/resources/poxel.woff2{{{ns}}})`. A relative url() resolves against mod-ui's page, which is the likely reason an earlier web font failed on a Duo.
- Knobs: a 65-frame strip where the knurl turns and the lighting stays, at a whole 64 px (mod-ui's film widget rounds half pixels and drifts).
- Recipe 630 KB (screenshot quantised to 256 colours, knob strip 65 frames).
- No DSP or port changes; version bumped so MOD loads the new face.

## 1.0.2 (build 2): 8-track and 4-track

- New **8-track** format: 3¾ ips endless-loop cartridge. Lurching wow (3.4 cents rms), fat 60 Hz bump, dull top end (−11 dB at 10 kHz).
- New **4-track** format: Portastudio-style cassette at 3¾ ips with dbx-style 2:1 noise reduction. Steadier and brighter than a Walkman; hiss vanishes in silence and breathes in under the playing; attacks get up to 2 dB of compander punch.
- **Self-erasure now follows tape speed:** the faster the tape, the higher the treble has to be before it squashes (cassette 2.5 kHz, studio reel 7 kHz, Master 10 kHz). Fast reels, Always on included, are a little more open than in 1.0.1.
- Two presets: 8-track cartridge, Bedroom 4-track.
- New formats are at the end of the Format list, so saved presets keep their format. No new ports.
- Gate: 49 tests pass natively and on the Duo build under qemu. CPU about 1.1× the Ouraverb.

## 1.0.1 (build 1): always on

After the first hardware test: great sounds, but nothing to leave on all night like a Deco.

- New **Master** format (30 ips mastering deck): steady (0.2 cents W&F), near flat, saturation forward. Added at the end of the list so 1.0.0 presets keep their format.
- New **Tone** (tilt around 800 Hz, ±4 dB) and **Level** (±12 dB output) controls.
- **Drive** now keeps a quarter of its gain (+4.5 dB at full) instead of being fully compensated.
- **Treble self-erasure:** hot highs compress before the body, in every format (6 kHz squashes 7.8 dB vs 1.4 dB at 200 Hz, played hard). Formats are a touch smoother when driven.
- New **Always on** preset.
- Ports added (Tone, Level): re-add Tapestry to the pedalboard after installing.
- Gate: 44 tests pass natively and on the Duo build under qemu. CPU now about 1.0× the Ouraverb (was 0.85×).

## 1.0.0 (build 0): first prototype

- Six formats, four tapes, seven factory presets; Drive, Wow, Flutter, Age, Hiss (off by default), Mix, in-plugin bypass.
- 2x oversampled tape saturation inside record pre-/de-emphasis; Drive compensated.
- Format/Tape switches mute for ~40 ms so they don't click.
- Gate: 37 tests pass natively and on the Duo build under qemu. Not yet played on hardware.
