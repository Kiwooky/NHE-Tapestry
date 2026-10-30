# Tapestry

**From first idea to final touches**

Whether it's that quick memo-recorder take of a great idea, or your final polished master ready to ship, New Horizon Electronics Tapestry adds as much or as little colour as you want. Nine tape machines and four tape formulations in one pedal, for MOD Duo, Duo X and Dwarf.

![Tapestry pedal face](bundle/nhe-tapestry.lv2/modgui/screenshot-tapestry.png)

## A whole shelf of tape

Pick the machine, then pick what's on the reels. A mastering deck you can leave on all night, the bedroom 4-track your first demos lived on, the 8-track in your uncle's car, or the answering machine that kept the message you never deleted. Each one wobbles, saturates and fades in its own way, because each one is built from how that machine actually worked.

## Why it sounds like nothing else

Most tape plugins model one good machine. Tapestry models the mechanisms, so the odd ones get just as much care as the classics:

- **Obscure formats, full character.** The 8-track lurches, because its endless loop drags out of the centre of the reel. The 4-track breathes: its noise reduction hides the hiss in silence and lets it creep back in under your playing. The answering machine squeezes you down a phone line, and its auto level control pumps.
- **Mix and match the impossible.** Any tape on any machine. Metal tape on a dictaphone. Bargain-bin ferric on a 30 ips mastering deck. Combinations no one could ever buy.
- **The wobble comes from the hardware.** Wow and flutter are built from each machine's capstan, reels, belts and motor, at the rates their geometry sets. A mastering deck barely moves; a pocket recorder never sits still.
- **Tape physics, not a filter.** Hot treble wipes itself off the tape first, so your pick attack smooths out while the body stays full. Every format gets its own head bump, the low end tape is loved for.
- **It ages.** Stretched belts, worn heads and thin oxide: more wobble, a duller top and the odd dropout.
- **Clean when you want it.** Noise at zero takes away the hiss and the grain. Turn it up for the rasp, then the hiss, all the way to each format's real noise floor. The pocket recorder and answering machine keep their grit whatever you do: that's who they are.

## Controls

| Control | How to use it |
| --- | --- |
| **Format** (red button) | Steps through the machines. The LCD names it and the window shows it. See the shelf below |
| **Tape** (grey button) | Steps through Type 0 (cheap), Ferric, Chrome and Metal. Or tap a label to jump straight to it. Cheaper tape saturates sooner, sounds duller and drops out more; Metal takes the most level and stays brightest |
| **Drive** (slider) | Recording level, −12 to +18 dB. Push it for glue, compression and saturation. It's mostly level-matched: full Drive is only about 4.5 dB louder |
| **Level** (slider) | Output, −12 to +12 dB. Match bypass, or push the amp |
| **Mix** (slider) | Dry to tape. The dry is delayed to match the tape, so blends don't comb |
| **Wow** | The slow, seasick drift: 0 to 200 % of the machine's own |
| **Flutter** | The fast shimmer: 0 to 200 % of the machine's own |
| **Age** | New to old. Belts stretch, heads wear, the top end dulls and dropouts creep in |
| **Noise** | Tape noise, in two stages. **0**: clean, no hiss, no grain. **1**: the tape's grain, the fine rasp it puts on every note, with no hiss. **2 to 10**: the hiss fades in, up to the format's real noise floor at 10. Pocket and Answering keep their grain at every setting |
| **Tone** | A tilt around 800 Hz: dark to the left, bright to the right, flat at the top |
| **On/Off** | Bypass, click-free; the dry passes at unity. The red light shows it's on |

The LCDs show Drive, Level and Mix in dB and %, and the machine's name. Drag a slider or press anywhere along its channel.

### The shelf

| Format | What it's like |
| --- | --- |
| **Studio reel** | 15 ips half-inch: steady, open, a gentle bump at 70 Hz |
| **Home reel** | 7½ ips quarter-inch: warmer, a fatter bump, a little more drift |
| **Walkman** | Cassette at 1⅞ ips: the classic wobble and soft top end |
| **VHS** | The linear audio track: muddy, steep at the top, wobbly |
| **Pocket record.** | Microcassette dictaphone: no lows, no highs, auto level pumping |
| **Answer machine** | Microcassette down a phone line: the narrowest, most squeezed of all |
| **Master reel** | 30 ips mastering deck: near flat, rock steady. The always-on one |
| **8-track** | The endless loop: lurching wow, a fat 60 Hz bump, a dull top |
| **4-track** | A double-speed cassette multitrack with noise reduction: bright, quiet in the gaps, breathing when you play |

Mono in, mono out. The tape adds 6 ms of latency (the wobble needs room to swing both ways). Changing Format or Tape mutes for about 40 ms while the machine swaps, so it never clicks.

### Tapestry Stereo

For stereo sources (a keyboard, a stereo chorus or reverb before it) there's a second plugin, **Tapestry Stereo**: upload `mod-plugin-builder/nhe-tapestry-stereo/nhe-tapestry-stereo.mk` the same way. Two tracks on one tape:

- **One transport.** Both sides wobble together, exactly as one capstan pulls both tracks. No accidental chorus.
- **Two tracks.** Each side has its own grain, hiss and saturation, so the noise has real width.
- **Head azimuth.** A worn, misaligned head reads the right track a few microseconds late, smearing the very top between the sides. It grows with Age and is bigger on slow tape: about 40 µs on a cassette at Age 10, 80 on the dictaphone, almost none on the mastering reel. Sum it to mono and you'll hear the classic dull, phasey worn-deck top end.
- **Linked level.** The auto level control and the 4-track's noise reduction listen to both sides, so a hit on one side moves both and the image never lurches.
- **Every format stays stereo**, even the ones that were mono in real life: impossible combinations welcome.

Same controls, presets and face (with its own STEREO badge). Patch one source into both inputs and the left side is the mono Tapestry. It uses about 1.7 times the CPU of the mono version, up to 2 times on the 4-track with Noise up.

## Factory presets

Presets set the machine, not the balance: loading one leaves your Mix where it is.

| Preset | Sound |
| --- | --- |
| **Always on** | Master reel with a little Drive. Glue, not grit: leave it on all night |
| **Walkman, cheap tape** | The mixtape from the petrol station: wobbly, dull, a bit worn |
| **Walkman, chrome** | The good tape: brighter and steadier |
| **Studio half-inch** | Driven into a 15 ips reel for warmth and weight |
| **Home reel-to-reel** | The 1970s living-room deck |
| **Pocket dictaphone** | That quick memo take of a great idea |
| **Answering machine** | Leave a message after the tone |
| **VHS linear** | The sound of a rented tape |
| **8-track cartridge** | Road trip, back seat, worn out |
| **Bedroom 4-track** | Chrome tape, pushed hard: where the first demos were made |

## Install

1. Connect your MOD by USB.
2. Open [builder.mod.audio](https://builder.mod.audio/buildroot) in Chrome and upload
   `mod-plugin-builder/nhe-tapestry/nhe-tapestry.mk` from this repo
   (or `mod-plugin-builder/nhe-tapestry-stereo/nhe-tapestry-stereo.mk` for Tapestry Stereo).
3. When the build finishes, click **Install**.

The builder fetches this repo at the commit named in the file (`NHE_TAPESTRY_VERSION`). After pushing a change, paste the new full 40-character commit hash there.

**MOD Plugin Store:** not yet.

## Build from source

Built with the [MOD plugin playbook](https://github.com/Kiwooky/MOD-plugin-playbook). With the playbook checked out next to this repo:

```sh
make                           # bin/nhe-tapestry.lv2 (make NAME=nhe-tapestry-stereo for the stereo one)
bash tools/check.sh            # mono: builds native, Duo and Duo X/Dwarf, checks the TTL, runs the tests, writes a test recipe to dist/ (not committed)
bash tools/check_stereo.sh     # stereo: the same, plus a comparison with the mono build; the same
python3 tools/gen_ttl.py       # rewrites both bundles' ports, presets and manifests from one table
```

Set `PB=` if the playbook lives somewhere else. `RENDER_FACE=1 bash tools/check_stereo.sh` also re-renders the stereo screenshot.

The design, the formats' numbers and what's been measured: [SPEC.md](SPEC.md). What changed: [CHANGELOG.md](CHANGELOG.md).

## Repository layout

| Path | Contents |
| --- | --- |
| `plugins/nhe-tapestry/` | DSP source (C++, DPF), for both plugins |
| `plugins/nhe-tapestry-stereo/` | Tapestry Stereo: its header (two inputs, name, URI) and a one-line source that includes the mono one |
| `bundle/nhe-tapestry.lv2/` | LV2 metadata, factory presets, pedal face (template, CSS, script, images, LCD font) |
| `bundle/nhe-tapestry-stereo.lv2/` | Stereo metadata and presets, plus its own panel, screenshot and thumbnail; the rest of the face is borrowed from the mono bundle at build time |
| `tests/` | Audio test suites, mono and stereo |
| `mod-plugin-builder/` | The package files for MOD's builder, one per plugin |
| `Makefile` | Top-level build: plugin, bundle, install |
| `dpf/` | [DPF](https://github.com/DISTRHO/DPF), as a git submodule |
| `tools/` | Gate scripts and the TTL generator |

## Licence

Code: GPL-3.0-or-later. Artwork: © New Horizon Electronics ([ARTWORK-LICENSE.md](ARTWORK-LICENSE.md)).

The LCD font is "lcd phone" by Raúl Pérez Canseco (Grafito Design, dibujosenlinea.com.mx), with minus, plus and full stop glyphs added and the character set cut down for the LCDs.
