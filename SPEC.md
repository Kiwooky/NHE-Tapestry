# Tapestry (New Horizon Electronics): spec

| | |
| --- | --- |
| Name / maker | Tapestry / New Horizon |
| URI | `urn:mod-cookbook:nhe-tapestry` (path A prototype) |
| Starting point | Reference sounds: tape machines as archetypes, built from published typical specs |
| Unit | MOD Duo (design budget), builds for Duo X / Dwarf too |
| I/O | Mono in, mono out |
| Traits | buffer (short modulated tape path), nonlinear (tape saturation), level-sensitive (ALC on Pocket/Answering), Mix knob. No tail, no feedback loop |
| Face | Custom, Niels's artwork (650 x 400, 2x): sliders + LCD for Drive/Level/Mix, Format LCD and picture, Tape step button and lights, five knobs, On/Off |
| Licence | GPL-3.0-or-later |

## The idea

One pedal, a whole shelf of tape. **Format** picks the machine (mechanism: speed, heads, capstan, transport). **Tape** picks the formulation on the reels (cheap ferric, ferric, chrome, metal). Turn them freely: metal tape on a dictaphone is allowed. Factory presets are the "fairly accurate" archetypes; the knobs are the lab.

## Signal flow

```
in -> [ALC: Pocket, Answering] -> Drive -> record pre-emphasis -> treble self-erasure
   -> tape saturation (2x oversampled) -> de-emphasis -> modulation noise (grain)
   -> tape path (wow + flutter modulate the read point)
   -> + hiss -> dropouts -> playback EQ (low cut, head bump, gap/spacing loss, format band)
   -> [4-track: dbx-style 1:2 decode; the 2:1 encode sits before Drive]
   -> makeup -> Tone (tilt) -> Mix with dry (dry delayed by the same 6 ms so Mix doesn't comb)
   -> Level -> bypass crossfade
```

Drive is mostly compensated: it keeps a quarter of its gain (−3 dB at −12, +4.5 dB at +18), so turning it up feels like more without becoming a volume knob.

**Treble self-erasure:** on real tape, hot high frequencies partly wipe themselves off the oxide, so the highs compress before the body. After pre-emphasis, everything above the format's erasure corner goes through a fast compressor (0.5 ms attack, 40 ms release) ahead of the saturator. Played hard, the pick's edge smooths while the body stays open: the "always on" feel. The corner follows tape speed (longer wavelengths erase less): 2.5 kHz × √(ips ÷ 1.875), so 1.8 kHz on a microcassette, 2.5 kHz on cassette, 3.5 kHz at 3¾ ips, 7 kHz on the studio reel, 10 kHz on Master [guess: physics says linear in speed; √ keeps some squash on the fast reels]. The plugin has 6 ms of latency (the tape path's centre point, so wow can swing both ways).

## Controls

| Control | Range | Default | What it does |
| --- | --- | --- | --- |
| Format | Studio reel, Home reel, Walkman, VHS, Pocket, Answering, Master, 8-track, 4-track | Walkman | Mechanism: wow/flutter profile, frequency response, headroom, ALC |
| Tape | Cheap, Ferric, Chrome, Metal | Ferric | Formulation: headroom, treble, grain, hiss, dropouts |
| Drive | −12 … +18 dB | 0 dB | Recording level: saturation and compression; keeps a quarter of its gain |
| Tone | −5 … +5 | 0 | First-order tilt around 800 Hz, ±4 dB at the ends, unity at the pivot |
| Wow | 0 … 200 % | 100 % | Scales the format's slow pitch drift (< 4 Hz) |
| Flutter | 0 … 200 % | 100 % | Scales the format's fast pitch movement (≥ 4 Hz) |
| Age | 0 … 10 | 3 | Wear: stretched belt (more wow), head wear (duller), dropouts, more grain |
| Noise (symbol `hiss`) | 0 … 10 | 0 | 0 = no hiss, no grain. 1 = the format's grain, no hiss. 2 to 10 = hiss fades in, 3 dB a step, to the format's real noise floor at 10. Pocket and Answering keep their grain at every setting |
| Mix | 0 … 100 % | 100 % | Dry/tape blend |
| Level | −12 … +12 dB | 0 dB | Output level (tape and dry), for unity or a push into the amp |
| Bypass | | | In-plugin, 10 ms crossfade, dry at unity |

Format and Tape changes mute the tape for about 40 ms (fade out, swap, let the 6 ms tape path flush, fade in), so they don't click.

## Format archetypes (all *guess*, from typical published specs; refine with measurements)

| Format | Speed | W&F target (rms) | Low cut | Head bump | Top end | Emphasis | ALC | S/N |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Studio reel | 15 ips half-inch | ~0.03 % | 22 Hz | +2 dB at 70 Hz | 22 kHz | 3.2 kHz, +6 dB | no | 68 dB |
| Home reel | 7½ ips quarter-inch | ~0.06 % | 30 Hz | +2.5 dB at 45 Hz | 16 kHz | 2.3 kHz, +8 dB | no | 62 dB |
| Walkman | 1⅞ ips cassette | ~0.1 % | 45 Hz | +2 dB at 90 Hz | 11 kHz (ferric) | 1.3 kHz, +10 dB (120 µs) | no | 52 dB |
| VHS | linear track, SP | ~0.13 % | 60 Hz | +1.5 dB at 100 Hz | 9.5 kHz, steep | 1.5 kHz, +8 dB | no | 44 dB |
| Pocket | 15/16 ips microcassette | ~0.2 % | 300 Hz, steep | none | 5 kHz, steep | 1 kHz, +10 dB | yes, 20 dB | 42 dB |
| Answering | microcassette + phone line | ~0.23 % | 330 Hz, steep | none | 3.3 kHz, steep | 1 kHz, +10 dB | yes, 24 dB | 40 dB |
| Master | 30 ips half-inch mastering deck | ~0.01 % | 18 Hz | +1.5 dB at 100 Hz | 24 kHz | 4.5 kHz, +5 dB | no | 72 dB |
| 8-track | 3¾ ips endless-loop cartridge, ¼" with 8 narrow tracks | ~0.2 %, lurching (the loop drags out of the reel's centre) | 50 Hz | +2.5 dB at 60 Hz | 8 kHz, steep (worn pressure pads) | 1.8 kHz, +9 dB | no | 45 dB |
| 4-track | 3¾ ips cassette multitrack (Portastudio-style), dbx-style 2:1 NR | ~0.09 % | 30 Hz | +1.3 dB at 110 Hz (the compander doubles it) | 22 kHz on tape, ~-2 dB at 10 kHz overall | 1.8 kHz, +5 dB | no | 50 dB on tape; hiss vanishes in silence |

New formats go at the end of the list so presets saved on a unit keep their format. It's the always-on deck: steady, near flat, saturation forward (−37 dB THD at Drive 0, −26 dB at +6, vs the studio reel's −44 / −32).

Wow and flutter are built per format from a capstan/flywheel sine, a reel/servo sine, random drift and band-limited flutter noise, at frequencies from each mechanism's geometry (capstan rotation = speed ÷ circumference).

## Tape formulations (*guess*)

| Tape | Headroom (drive ×) | Treble | Grain | Hiss | Dropouts |
| --- | --- | --- | --- | --- | --- |
| Cheap | 1.6× (saturates first) | 0.85× | 1.6× | +3 dB | 3× |
| Ferric (Type I) | 1× | 1× | 1× | 0 | 1× |
| Chrome (Type II) | 0.85× | 1.15× | 0.75× | −4 dB | 0.7× |
| Metal (Type IV) | 0.6× (most headroom) | 1.25× | 0.6× | −4 dB | 0.6× |

On reels, Ferric is "standard studio tape"; Chrome and Metal on reels are the experimental side.

## Factory presets

| Preset | Format | Tape | Drive | Wow | Flutter | Age |
| --- | --- | --- | --- | --- | --- | --- |
| Always on | Master | Ferric | +6 | 100 | 100 | 0 |
| 8-track cartridge | 8-track | Ferric | +2 | 100 | 100 | 5 |
| Bedroom 4-track | 4-track | Chrome | +4 | 100 | 100 | 2 |
| Walkman, cheap tape | Walkman | Cheap | +3 | 110 | 100 | 5 |
| Walkman, chrome | Walkman | Chrome | 0 | 100 | 100 | 2 |
| Studio half-inch | Studio reel | Ferric | +4 | 100 | 100 | 1 |
| Home reel-to-reel | Home reel | Ferric | +2 | 100 | 100 | 3 |
| Pocket dictaphone | Pocket | Ferric | 0 | 100 | 100 | 4 |
| Answering machine | Answering | Cheap | 0 | 120 | 100 | 6 |
| VHS linear | VHS | Ferric | 0 | 100 | 100 | 3 |

Noise is 1 in the archetype presets (their grain, no hiss) and 0 in Always on; Tone and Level are 0 in every preset.

## Sources

| What | Status |
| --- | --- |
| Speeds, cassette EQ time constants (120 µs / 70 µs) | documented (format standards) |
| Typical W&F, bandwidth, S/N per format | typical published specs, *guess* for each archetype |
| Head bump frequencies, emphasis gains, headroom, grain, dropouts | *guess*, tuned by ear and test |
| Saturation curve | rational tanh, a light stand-in for tape hysteresis (CHOWTape-style hysteresis is the reference if we want more) |
| Measurements of Niels's own machines | not yet: sweep, 3150 Hz tone and guitar through each would let presets be fitted |

## Measured (build 1.0.2, in tests; 1.0.0 was played on hardware)

**4-track noise reduction:** a 2:1 encode from the input's power (2 ms attack, 60 ms release), a 1:2 decode from the tape's playback power, gains at control rate. Whatever the tape does in between (EQ, saturation, self-erasure, wow) the decoder doubles in dB, so they never quite agree: the dbx breathing. The tape side is set flatter than a plain cassette to allow for it.

| What | Result |
| --- | --- |
| Loudness, every Format x Tape at defaults | within 1.3 dB of bypass (RMS, guitar level) |
| Factory presets | all within 1.9 dB of bypass (Bedroom 4-track +1.9, Always on +1.5) |
| Wow & flutter, 1 kHz tone, Age 0 (cents rms) | Master 0.2, Studio 0.5, Home 1.3, 4-track 1.5, Walkman 2.2, VHS 3.0, 8-track 3.4, Pocket 3.9, Answering 4.9 (0.1 % ≈ 1.7 cents) |
| 4-track hiss at Noise 10 | −111 dBFS in silence, −67 dBFS under a −23 dBFS tone |
| 4-track attacks vs studio reel | up to +1.9 dB (compander punch) |
| 8-track response | +0.8 dB at 60 Hz, −10.9 dB at 10 kHz |
| Self-erasure, Walkman, −10 dBFS vs −40 dBFS sine | 6 kHz compresses 7.8 dB, 200 Hz 1.4 dB |
| Tone ±5 | ±3.9 dB at 100 Hz / 8 kHz, 0.0 dB at 800 Hz |
| Drive −12 / +18 vs 0, small signals | −3.0 / +4.2 dB |
| Age 0 → 9 (Walkman) | 2.2 → 3.9 cents |
| Walkman head bump | +1.7 dB at 90 Hz vs 1 kHz |
| THD, 200 Hz at −16 dBFS, Studio | −44 dB at Drive 0, −14 dB at +18 |
| Aliasing, 4 kHz at Drive +18 | nothing above −79 dB below 3 kHz |
| ALC, quiet player (−34 dBFS peaks) | Pocket lifts it 12 dB more than Walkman |
| Noise 10 | lands on each format's floor (Walkman −72 dBFS) |
| CPU, Duo build under qemu | about 1.1× Ouraverb in every format (4-track 1.09×, 8-track 1.13×). Only the Duo's meter gives the real number |
