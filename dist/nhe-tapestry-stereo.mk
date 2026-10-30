# Upload this file at https://builder.mod.audio/buildroot with a MOD unit
# connected over USB. Assembled by tools/assemble_recipe.py (MOD plugin playbook).


NHE_TAPESTRY_STEREO_VERSION = 61d38eb638449647fb8395a35c5b8dab7e981ba7
NHE_TAPESTRY_STEREO_SITE = https://github.com/DISTRHO/DPF.git
NHE_TAPESTRY_STEREO_SITE_METHOD = git
NHE_TAPESTRY_STEREO_BUNDLES = nhe-tapestry-stereo.lv2

define NHE_TAPESTRY_STEREO_SRC1
#ifndef DISTRHO_PLUGIN_INFO_H_INCLUDED
#define DISTRHO_PLUGIN_INFO_H_INCLUDED

// Tapestry Stereo: the same source as plugins/nhe-tapestry, built with two inputs:
// two tracks on one transport.
// Rename these together with the TTL (see docs/lv2-and-mod-rules.md).
#define DISTRHO_PLUGIN_BRAND       "New Horizon"
#define DISTRHO_PLUGIN_NAME        "Tapestry Stereo"
#define DISTRHO_PLUGIN_URI         "urn:mod-cookbook:nhe-tapestry-stereo"
#define TAPESTRY_LABEL             "TapestryStereo"
#define TAPESTRY_DESCRIPTION       "Stereo tape machines from studio reel to answering machine: two tracks on one transport, wow, flutter, saturation and tape's low end."
#define TAPESTRY_UNIQUE_ID         d_cconst('n', 'T', 'p', 'S')
#define TAPESTRY_VERSION           d_version(1, 0, 0)   // = lv2:minorVersion 2, microVersion 0

#define DISTRHO_PLUGIN_HAS_UI       0
#define DISTRHO_PLUGIN_IS_RT_SAFE   1
#define DISTRHO_PLUGIN_NUM_INPUTS   2   // stereo: two tracks, one transport
#define DISTRHO_PLUGIN_NUM_OUTPUTS  2

// Control ports, in TTL order (indices start after the audio ports).
// The bypass port is always last. Formats only ever get APPENDED.
enum Parameters {
    kFormat = 0,
    kTape,
    kDrive,
    kTone,
    kWow,
    kFlutter,
    kAge,
    kHiss,
    kMix,
    kLevel,
    kBypass,
    kParameterCount
};

#endif
endef

define NHE_TAPESTRY_STEREO_SRC2
#!/usr/bin/make -f
# DSP-only LV2 build. NAME = the bundle name; the binary is <NAME>_dsp.so.
# The source is the mono plugin's (included by TapestryStereoPlugin.cpp).
NAME = nhe-tapestry-stereo
FILES_DSP = TapestryStereoPlugin.cpp
include ../../Makefile.plugins.mk
TARGETS = lv2_dsp
all: $$(TARGETS)
endef

define NHE_TAPESTRY_STEREO_SRC3
// Tapestry: a shelf of tape machines in one pedal. Format picks the mechanism
// (studio reel, home reel, Walkman, VHS, pocket dictaphone, answering machine);
// Tape picks the formulation on it (cheap, ferric, chrome, metal). Mix them freely.
// Archetypes from typical published specs, every number marked [guess] until
// measured against real machines. Face: Niels's artwork (modgui/).
//
// The same source builds Tapestry Stereo (plugins/nhe-tapestry-stereo): DISTRHO_PLUGIN_NUM_INPUTS 2
// gives two tracks on one transport. Shared: wow and flutter (one capstan), the dropouts' timing,
// and linked auto level and noise reduction. Per track: saturation, grain, hiss and EQ. Stereo
// adds head azimuth: the right track lags the left by a few microseconds, more with Age and on
// slow tape. With one input the build is the mono plugin, sample for sample.
//
// Traits (docs/effect-profile.md): [every], [buffer] (a short modulated tape path),
// nonlinear (tape saturation), level-sensitive (ALC on Pocket and Answering), [mix].
// No tail and no feedback loop: Tails and the wet limiter were dropped from the template.
//
// Signal flow:
//   in -> [ALC] -> Drive -> record pre-emphasis -> treble self-erasure (the highs
//      compress first, like oxide does) -> saturation (2x oversampled)
//      -> de-emphasis -> /Drive (mostly compensated: Drive keeps a quarter of its gain)
//      -> grain (modulation noise: set by Noise, except on Pocket and Answering)
//      -> tape path: wow + flutter move the read point around a 6 ms centre
//      -> + hiss -> dropouts -> playback EQ (low cut, head bump, gap loss, band)
//      -> [4-track only: 2:1 dbx-style encode before the tape, 1:2 decode here]
//      -> makeup -> Tone (tilt) -> Mix with the dry (delayed 6 ms too, so Mix doesn't comb)
//      -> Level
#include "DistrhoPlugin.hpp"

#include <cmath>
#include <cstring>
#include <cstdint>

START_NAMESPACE_DISTRHO

static const float kPi    = 3.14159265f;
static const float kTwoPi = 6.2831853f;

static inline float clampf(float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }
static inline float onePoleCoef(float hz, float sr) { return 1.0f - std::exp(-kTwoPi * hz / sr); }
static inline float msCoef(float ms, float sr) { return 1.0f - std::exp(-1.0f / (ms * 0.001f * sr)); }
static inline float dbToLin(float d) { return std::pow(10.0f, d * 0.05f); }

// rational tanh: slope 1 at 0, flat at +-1 beyond |x| = 3, no libm call
static inline float softClip(float x)
{
    if (x >  3.0f) return  1.0f;
    if (x < -3.0f) return -1.0f;
    const float x2 = x * x;
    return x * (27.0f + x2) / (27.0f + 9.0f * x2);
}

// parabolic sine of a phase in [0, 1): an LFO, not audio
static inline float parSine(float p)
{
    const float u = 2.0f * p - 1.0f;
    return 4.0f * u * (1.0f - std::fabs(u));
}

// xorshift32 -> uniform in [-1, 1)
struct Rng {
    uint32_t s;
    inline float next() { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return (float)(int32_t)s * 4.6566129e-10f; }
};

// ---------------------------------------------------------------- filters

struct Biquad {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
    inline float process(float x)
    {
        const float y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y + 1e-18f;
        return y;
    }
    void clear() { z1 = z2 = 0.0f; }
    void identity() { b0 = 1; b1 = b2 = a1 = a2 = 0; }
    void set(double B0, double B1, double B2, double A0, double A1, double A2)
    {
        b0 = (float)(B0 / A0); b1 = (float)(B1 / A0); b2 = (float)(B2 / A0);
        a1 = (float)(A1 / A0); a2 = (float)(A2 / A0);
    }
    void lowpass(double f, double q, double sr)
    {
        const double w = 2.0 * M_PI * f / sr, c = std::cos(w), al = std::sin(w) / (2.0 * q);
        set((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al);
    }
    void highpass(double f, double q, double sr)
    {
        const double w = 2.0 * M_PI * f / sr, c = std::cos(w), al = std::sin(w) / (2.0 * q);
        set((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al);
    }
    void peak(double f, double gainDb, double q, double sr)
    {
        if (std::fabs(gainDb) < 0.01) { identity(); return; }
        const double A = std::pow(10.0, gainDb / 40.0);
        const double w = 2.0 * M_PI * f / sr, c = std::cos(w), al = std::sin(w) / (2.0 * q);
        set(1 + al * A, -2 * c, 1 - al * A, 1 + al / A, -2 * c, 1 - al / A);
    }
};

// first order: H(s) = (1 + s/wz) / (1 + s/wp), bilinear with the zero's frequency pre-warped
struct Shelf1 {
    float b0 = 1, b1 = 0, a1 = 0, z = 0;
    inline float process(float x)
    {
        const float y = b0 * x + z;
        z = b1 * x - a1 * y + 1e-18f;
        return y;
    }
    void clear() { z = 0.0f; }
    void set(double fz, double fp, double sr)
    {
        const double K = 2.0 * M_PI * fz / std::tan(M_PI * fz / sr);   // pre-warp at the zero
        const double nz = 1.0 / (2.0 * M_PI * fz), np = 1.0 / (2.0 * M_PI * fp);
        const double B0 = nz * K + 1.0, B1 = 1.0 - nz * K;
        const double A0 = np * K + 1.0, A1 = 1.0 - np * K;
        b0 = (float)(B0 / A0); b1 = (float)(B1 / A0); a1 = (float)(A1 / A0);
    }
};

// ---------------------------------------------------------------- archetypes

struct FormatDef {
    // wow and flutter: rms pitch deviation in %, at a frequency in Hz [guess]
    float sineHz, sinePct;     // reel / flywheel / servo eccentricity
    float capHz, capPct;       // capstan once-around (speed / circumference)
    float randHz, randPct;     // random drift (motor, tension)
    float flutHz, flutPct;     // band-limited flutter noise
    float ageSens;             // how much Age adds to wow and flutter
    // response
    float hpHz; int hpStages;  // low cut, 2nd order per stage
    float bumpHz, bumpDb;      // head bump
    float lpHz; int lpStages;  // gap loss / format band, 2nd order per stage
    float emphHz, emphDb;      // record pre-emphasis (zero), undone after the tape
    float g0;                  // drive into the tape at Drive 0 (headroom)
    float grain;               // modulation noise, rms fraction of the signal
    float snDb;                // hiss below the reference level, at Hiss 5
    float dropFmt;             // dropout rate factor
    float alcMaxDb;            // auto level control's most gain; 0 = no ALC
    float makeupDb;            // output trim so formats match bypass loudness (measured)
    float hissCalDb;           // hiss trim so Hiss 5 lands on ref - S/N after the playback EQ (measured)
    float nc;                  // 1 = dbx-style 2:1 compander around the tape (4-track), 0 = none
    float ips;                 // tape speed: sets where self-erasure starts (longer wavelengths erase less)
};

// New formats go at the end, so presets saved on a unit keep their format
enum { kStudio = 0, kHome, kWalkman, kVhs, kPocket, kAnswer, kMaster, kEight, kFour, kNumFormats };

static const FormatDef kFormats[kNumFormats] = {
    //  sine        cap         rand        flutter     age   hp      bump        lp         emph        g0    grain    sn   drop  alc   makeup hissCal
    { 0.6f, 0.012f, 4.8f, 0.015f, 0.8f, 0.008f, 25.f, 0.020f, 0.3f,  22.f,1,  70.f,2.0f,  22000.f,1, 3200.f, 6.f, 2.0f, 0.0015f, 68.f, 0.1f,  0.f, 0.0f, 5.2f , 0.0f , 15.0f }, // Studio reel, 15 ips
    { 0.4f, 0.030f, 2.4f, 0.030f, 0.7f, 0.020f, 12.f, 0.040f, 0.6f,  30.f,1,  45.f,2.5f,  16000.f,1, 2300.f, 8.f, 2.5f, 0.0030f, 62.f, 0.3f,  0.f, 0.0f, 7.2f , 0.0f , 7.5f }, // Home reel, 7.5 ips
    { 1.3f, 0.060f, 6.0f, 0.050f, 0.6f, 0.050f, 15.f, 0.050f, 1.0f,  45.f,1,  90.f,2.0f,  11000.f,1, 1300.f,10.f, 3.0f, 0.0060f, 52.f, 1.0f,  0.f, 0.0f, 9.8f , 0.0f , 1.875f }, // Walkman, 1 7/8 ips
    { 0.25f,0.060f, 5.0f, 0.050f, 0.6f, 0.080f, 10.f, 0.070f, 1.0f,  60.f,1, 100.f,1.5f,   9500.f,2, 1500.f, 8.f, 3.0f, 0.0070f, 44.f, 1.5f,  0.f, 0.0f, 9.3f , 0.0f , 1.31f }, // VHS linear, SP
    { 0.8f, 0.120f, 3.2f, 0.100f, 0.5f, 0.100f, 20.f, 0.080f, 1.2f, 300.f,2,   0.f,0.0f,   5000.f,2, 1000.f,10.f, 3.0f, 0.0100f, 42.f, 1.5f, 20.f,-3.5f,16.3f , 0.0f , 0.94f }, // Pocket, microcassette
    { 0.7f, 0.100f, 3.0f, 0.100f, 0.4f, 0.150f, 18.f, 0.100f, 1.3f, 330.f,2,   0.f,0.0f,   3300.f,2, 1000.f,10.f, 3.0f, 0.0120f, 40.f, 2.0f, 24.f,-2.5f,16.3f , 0.0f , 0.94f }, // Answering machine
    { 0.5f, 0.004f, 9.6f, 0.005f, 0.8f, 0.004f, 30.f, 0.008f, 0.2f,  18.f,1, 100.f,1.5f,  24000.f,1, 4500.f, 5.f, 3.0f, 0.0008f, 72.f, 0.05f, 0.f, 0.0f, 4.0f , 0.0f , 30.0f }, // Master, 30 ips half-inch
    { 0.6f, 0.080f, 6.3f, 0.060f, 1.0f, 0.120f, 20.f, 0.100f, 1.3f,  50.f,1,  60.f,2.5f,   8000.f,2, 1800.f, 9.f, 3.0f, 0.0080f, 45.f, 2.0f, 0.f, 0.0f, 9.1f, 0.0f , 3.75f }, // 8-track cartridge, 3 3/4 ips endless loop
    { 2.6f, 0.040f, 12.f, 0.040f, 0.6f, 0.030f, 15.f, 0.040f, 0.8f,  30.f,1, 110.f,1.3f,  22000.f,1, 1800.f, 5.f, 2.4f, 0.0050f, 50.f, 1.0f, 0.f,-1.0f, 8.0f, 1.0f , 3.75f }, // 4-track cassette, 3 3/4 ips, dbx-style NR (the compander doubles the tape's EQ errors in dB, so the tape side is set flatter)
};

struct TapeDef { float sens, emphOffDb, lpMul, grainMul, hissOffDb, dropMul; };
enum { kCheap = 0, kFerric, kChrome, kMetal, kNumTapes };
static const TapeDef kTapes[kNumTapes] = {
    { 1.60f,  2.f, 0.85f, 1.60f,  3.f, 3.0f },   // cheap ferric
    { 1.00f,  0.f, 1.00f, 1.00f,  0.f, 1.0f },   // ferric, Type I
    { 0.85f, -2.f, 1.15f, 0.75f, -4.f, 0.7f },   // chrome, Type II
    { 0.60f, -3.f, 1.25f, 0.60f, -4.f, 0.6f },   // metal, Type IV
};

// ---------------------------------------------------------------- oversampling

// 2x: one 32-tap low-pass (Kaiser beta 8, 19 kHz at 96 kHz: -0.6 dB at 15 kHz, -90 dB from 28 kHz), polyphase.
// Tape saturation is gentle, so 2x holds the aliasing test (4 kHz at Drive +18) and costs half of 4x.
static const int kOS = 2;
static const int kTaps = 32;
static const int kPhaseTaps = kTaps / kOS;
static const float kFir[kTaps] = {
    1.982244163e-05f, -1.591625691e-04f, -5.177915255e-04f, 2.078883849e-04f,
    2.411495894e-03f, 2.023139882e-03f, -4.832176006e-03f, -1.009897156e-02f,
    1.642017314e-03f, 2.398762230e-02f, 1.880409856e-02f, -3.252861063e-02f,
    -7.017276657e-02f, 3.777339310e-03f, 1.960618931e-01f, 3.693741617e-01f,
    3.693741617e-01f, 1.960618931e-01f, 3.777339310e-03f, -7.017276657e-02f,
    -3.252861063e-02f, 1.880409856e-02f, 2.398762230e-02f, 1.642017314e-03f,
    -1.009897156e-02f, -4.832176006e-03f, 2.023139882e-03f, 2.411495894e-03f,
    2.078883849e-04f, -5.177915255e-04f, -1.591625691e-04f, 1.982244163e-05f
};

static const uint32_t kBufSize = 2048;          // [buffer] 21 ms at 96 kHz: 6 ms centre + swing
static const uint32_t kBufMask = kBufSize - 1;
static const int      kCR = 16;                 // control rate block
static const float    kCentreMs = 6.0f;
static const float    kSwingMs  = 5.0f;
static const float    kRef = 0.1f;              // tape reference level (-20 dBFS rms) for hiss
static const float    kAlcTarget = 0.25f;
static const int      kCh = DISTRHO_PLUGIN_NUM_INPUTS;   // 1 = mono, 2 = stereo

#ifndef TAPESTRY_LABEL
#define TAPESTRY_LABEL        "Tapestry"
#define TAPESTRY_DESCRIPTION  "Tape machines from studio reel to answering machine: wow, flutter, saturation and tape's low end."
#define TAPESTRY_UNIQUE_ID    d_cconst('n', 'T', 'p', 's')
#define TAPESTRY_VERSION      d_version(1, 0, 8)   // = lv2:minorVersion 2, microVersion 8
#endif

// one track on the tape: everything that happens to it alone
struct Track {
    float buf[kBufSize], dry[kBufSize];
    float up[2 * kPhaseTaps], dn[2 * kTaps];
    int   upPos = 0, dnPos = 0;
    Shelf1 pre, de, hissDe, tilt;
    Biquad hp1, hp2, bump, lp1, lp2;
    Rng   rng { 0x9e3779b9u };                // grain, then hiss, each sample
    float grLp = 0.0f, grHp = 0.0f, erLp = 0.0f, erEnv = 0.0f;

    inline float saturate(float v)
    {
        up[upPos] = up[upPos + kPhaseTaps] = v;
        const float* h = &up[upPos];   // h[0] is the newest
        upPos = (upPos + kPhaseTaps - 1) % kPhaseTaps;
        for (int ph = 0; ph < kOS; ++ph) {
            float xo = 0.0f;
            for (int k = 0; k < kPhaseTaps; ++k) xo += kFir[k * kOS + ph] * h[k];
            dn[dnPos] = dn[dnPos + kTaps] = softClip(xo * (float)kOS);
            dnPos = (dnPos + kTaps - 1) % kTaps;
        }
        const float* q = &dn[dnPos + 1];
        float yd = 0.0f;
        for (int j = 0; j < kTaps; ++j) yd += kFir[j] * q[j];
        return yd;
    }
    inline float read(uint32_t w, float d) const
    {
        const float rp = (float)w - d + (float)kBufSize;
        const uint32_t ip = (uint32_t)rp;
        const float t = rp - (float)ip;
        const float xm1 = buf[(ip - 1) & kBufMask], x0 = buf[ip & kBufMask];
        const float x1  = buf[(ip + 1) & kBufMask], x2 = buf[(ip + 2) & kBufMask];
        const float c1 = 0.5f * (x1 - xm1);
        const float c2 = xm1 - 2.5f * x0 + 2.0f * x1 - 0.5f * x2;
        const float c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1);
        return ((c3 * t + c2) * t + c1) * t + x0;
    }
    void clearFilters()
    {
        pre.clear(); de.clear(); hissDe.clear();
        hp1.clear(); hp2.clear(); bump.clear(); lp1.clear(); lp2.clear();
        erLp = erEnv = 0.0f; tilt.clear();
    }
    void reset(uint32_t seed)
    {
        std::memset(buf, 0, sizeof(buf)); std::memset(dry, 0, sizeof(dry));
        std::memset(up, 0, sizeof(up)); std::memset(dn, 0, sizeof(dn));
        upPos = dnPos = 0;
        clearFilters();
        grLp = grHp = 0.0f;
        rng.s = seed;
    }
};
static const uint32_t kSeeds[2] = { 0x9e3779b9u, 0x7f4a7c15u };   // the left track keeps the mono seed

class TapestryPlugin : public Plugin
{
public:
    TapestryPlugin()
        : Plugin(kParameterCount, 0, 0)
    {
        fParams[kFormat] = (float)kWalkman;
        fParams[kTape] = (float)kFerric;
        fParams[kDrive] = 0.0f;
        fParams[kTone] = 0.0f;
        fParams[kWow] = 100.0f;
        fParams[kFlutter] = 100.0f;
        fParams[kAge] = 3.0f;
        fParams[kHiss] = 0.0f;
        fParams[kMix] = 100.0f;
        fParams[kLevel] = 0.0f;
        fParams[kBypass] = 0.0f;
        for (int f = 0; f < kNumFormats; ++f) fRandNorm[f] = fFlutNorm[f] = 1.0f;
        reset();
    }

protected:
    const char* getLabel()       const override { return TAPESTRY_LABEL; }
    const char* getDescription() const override { return TAPESTRY_DESCRIPTION; }
    const char* getMaker()       const override { return DISTRHO_PLUGIN_BRAND; }
    const char* getLicense()     const override { return "GPL-3.0-or-later"; }
    uint32_t    getVersion()     const override { return TAPESTRY_VERSION; }
    int64_t     getUniqueId()    const override { return TAPESTRY_UNIQUE_ID; }

    void initParameter(uint32_t index, Parameter& p) override
    {
        p.hints = kParameterIsAutomatable;
        switch (index) {
        case kFormat: {
            p.hints |= kParameterIsInteger;
            p.name = "Format"; p.symbol = "format";
            p.ranges.min = 0.0f; p.ranges.max = (float)(kNumFormats - 1); p.ranges.def = (float)kWalkman;
            static const char* const names[kNumFormats] = { "Studio reel", "Home reel", "Walkman", "VHS", "Pocket", "Answering", "Master", "8-track", "4-track" };
            ParameterEnumerationValue* v = new ParameterEnumerationValue[kNumFormats];
            for (int i = 0; i < kNumFormats; ++i) { v[i].label = names[i]; v[i].value = (float)i; }
            p.enumValues.count = kNumFormats; p.enumValues.restrictedMode = true; p.enumValues.values = v;
            break;
        }
        case kTape: {
            p.hints |= kParameterIsInteger;
            p.name = "Tape"; p.symbol = "tape";
            p.ranges.min = 0.0f; p.ranges.max = (float)(kNumTapes - 1); p.ranges.def = (float)kFerric;
            static const char* const names[kNumTapes] = { "Cheap", "Ferric", "Chrome", "Metal" };
            ParameterEnumerationValue* v = new ParameterEnumerationValue[kNumTapes];
            for (int i = 0; i < kNumTapes; ++i) { v[i].label = names[i]; v[i].value = (float)i; }
            p.enumValues.count = kNumTapes; p.enumValues.restrictedMode = true; p.enumValues.values = v;
            break;
        }
        case kDrive:
            p.name = "Drive"; p.symbol = "drive"; p.unit = "dB";
            p.ranges.min = -12.0f; p.ranges.max = 18.0f; p.ranges.def = 0.0f;
            break;
        case kTone:
            p.name = "Tone"; p.symbol = "tone";
            p.ranges.min = -5.0f; p.ranges.max = 5.0f; p.ranges.def = 0.0f;
            break;
        case kWow:
            p.name = "Wow"; p.symbol = "wow"; p.unit = "%";
            p.ranges.min = 0.0f; p.ranges.max = 200.0f; p.ranges.def = 100.0f;
            break;
        case kFlutter:
            p.name = "Flutter"; p.symbol = "flutter"; p.unit = "%";
            p.ranges.min = 0.0f; p.ranges.max = 200.0f; p.ranges.def = 100.0f;
            break;
        case kAge:
            p.name = "Age"; p.symbol = "age";
            p.ranges.min = 0.0f; p.ranges.max = 10.0f; p.ranges.def = 3.0f;
            break;
        case kHiss:
            p.name = "Noise"; p.symbol = "hiss";   // symbol kept from 1.0.x so saved presets still load
            p.ranges.min = 0.0f; p.ranges.max = 10.0f; p.ranges.def = 0.0f;
            break;
        case kMix:
            p.name = "Mix"; p.symbol = "mix"; p.unit = "%";
            p.ranges.min = 0.0f; p.ranges.max = 100.0f; p.ranges.def = 100.0f;
            break;
        case kLevel:
            p.name = "Level"; p.symbol = "level"; p.unit = "dB";
            p.ranges.min = -12.0f; p.ranges.max = 12.0f; p.ranges.def = 0.0f;
            break;
        case kBypass:
            p.initDesignation(kParameterDesignationBypass);   // TTL: lv2_enabled, lv2:designation lv2:enabled
            break;
        }
    }

    float getParameterValue(uint32_t i) const override { return i < kParameterCount ? fParams[i] : 0.0f; }
    void  setParameterValue(uint32_t i, float v) override { if (i < kParameterCount) fParams[i] = v; }

    void activate() override
    {
        fSr = (float)getSampleRate();
        fCr = fSr / (float)kCR;
        fSmooth  = onePoleCoef(1.0f / (kTwoPi * 0.010f), fSr);   // 10 ms
        fSwCoef  = onePoleCoef(1.0f / (kTwoPi * 0.003f), fSr);   // 3 ms switch fade
        fAlcAtk  = msCoef(3.0f, fSr);
        fAlcRel  = msCoef(700.0f, fSr);
        fAlcGainC = msCoef(15.0f, fSr);
        fEraseAtk = msCoef(0.5f, fSr);
        fEraseRel = msCoef(40.0f, fSr);
        fNcAtk = msCoef(2.0f, fSr);                 // compander RMS detectors [guess]
        fNcRel = msCoef(60.0f, fSr);
        fGrainHp = onePoleCoef(100.0f, fSr);
        fGrainLp = onePoleCoef(4000.0f, fSr);
        fGrainNorm = std::sqrt(3.0f * (2.0f - fGrainLp) / fGrainLp);
        fCentre = kCentreMs * 0.001f * fSr;
        fSwing  = kSwingMs * 0.001f * fSr;
        fDryDelay = (uint32_t)(fCentre + 0.5f);
        fDropAtk = onePoleCoef(1.0f / (kTwoPi * 0.004f), fCr);
        fDropRel = onePoleCoef(1.0f / (kTwoPi * 0.025f), fCr);
        // unit-variance scaling of the random wow and flutter noise, per format, by simulation
        for (int f = 0; f < kNumFormats; ++f) {
            const FormatDef& d = kFormats[f];
            Rng r { 0x1234567u };
            const float a = onePoleCoef(d.randHz, fCr);
            float s1 = 0, s2 = 0, ic1 = 0, ic2 = 0; double accR = 0, accF = 0;
            float g, k; svfCoefs(d.flutHz, fCr, g, k);
            const int n = 40000;
            for (int i = 0; i < n; ++i) {
                s1 += a * (r.next() - s1); s2 += a * (s1 - s2);
                accR += (double)s2 * s2;
                const float bp = svfBand(r.next(), g, k, ic1, ic2);
                accF += (double)bp * bp;
            }
            fRandNorm[f] = (float)(1.0 / std::sqrt(accR / n + 1e-20));
            fFlutNorm[f] = (float)(1.0 / std::sqrt(accF / n + 1e-20));
        }
        reset();
        fFirst = true;
    }

    void run(const float** inputs, float** outputs, uint32_t frames) override
    {
        const int   fmtT   = (int)clampf(fParams[kFormat] + 0.5f, 0.0f, (float)(kNumFormats - 1));
        const int   tapeT  = (int)clampf(fParams[kTape] + 0.5f, 0.0f, (float)(kNumTapes - 1));
        const bool  bypass = fParams[kBypass] > 0.5f;
        const float mixT   = clampf(fParams[kMix] * 0.01f, 0.0f, 1.0f);
        const float actT   = bypass ? 0.0f : 1.0f;
        const float driveT = dbToLin(clampf(fParams[kDrive], -12.0f, 18.0f));
        const float wowK   = clampf(fParams[kWow] * 0.01f, 0.0f, 2.0f);
        const float flutK  = clampf(fParams[kFlutter] * 0.01f, 0.0f, 2.0f);
        const float age    = clampf(fParams[kAge], 0.0f, 10.0f);
        const float hissK  = clampf(fParams[kHiss], 0.0f, 10.0f);
        const float tone   = clampf(fParams[kTone], -5.0f, 5.0f);
        const float levT   = dbToLin(clampf(fParams[kLevel], -12.0f, 12.0f));
        // Drive keeps a quarter of its gain: +18 dB of drive is +4.5 dB louder [guess, by ear]
        const float driveOutT = dbToLin(0.25f * clampf(fParams[kDrive], -12.0f, 18.0f));

        if (fFirst) {                    // controls arrive with the first run()
            fFirst = false;
            applyFormat(fmtT, tapeT, age);
            updateLevels(age, hissK);
            fAlcGain = fAlcGainT = 1.0f;
            fSw = 1.0f; fSwT = 1.0f;
            fMix = mixT; fAct = actT;
            fDrive = driveT; fDriveOut = driveOutT;
            fLev = levT;
            fToneSm = tone; setTilt(tone);
            fAzimA = fAzimB = fAzimT;
            computeMod(wowK, flutK, age);  // two steps, so the first block's glide is real
            fDispA = fDispB;
            computeMod(wowK, flutK, age);
        }

        for (uint32_t i = 0; i < frames; ++i) {
            // ---- control rate: switches, ageing, modulation, dropouts, ALC gain
            if (fCrCount == 0) {
                fCrCount = kCR;
                const bool want = (fmtT != fFmt) || (tapeT != fTape);
                if (want) fSwT = 0.0f;
                if (want && fSw < 0.001f) {          // silent now: swap the machine
                    applyFormat(fmtT, tapeT, age);
                    clearFilters();
                    fSwHold = (int)(0.015f * fCr);   // let the old machine's sound leave the tape path
                }
                if (!want) {
                    if (fSwHold > 0) --fSwHold;
                    else fSwT = 1.0f;
                }
                if (std::fabs(age - fAgeApplied) > 0.02f) setResponse(fFmt, fTape, age);
                updateLevels(age, hissK);
                if (std::fabs(tone - fToneSm) > 0.005f) {      // glide Tone over a few ms
                    fToneSm += 0.15f * (tone - fToneSm);
                    if (std::fabs(tone - fToneSm) < 0.005f) fToneSm = tone;
                    setTilt(fToneSm);
                }
                fDispA = fDispB;
                computeMod(wowK, flutK, age);
                stepDropouts(age);
                fAlcGainT = fAlcOn ? std::fmin(fAlcMax, kAlcTarget / (fAlcEnv + 1e-4f)) : 1.0f;
                if (kCh > 1) {                       // azimuth glides with Age
                    fAzimA = fAzimB;
                    fAzimB = fAzimT;
                }
                if (fNcOn) {
                    // 2:1 encode from the input's power, 1:2 decode from the tape's playback power.
                    // The tape's EQ, saturation and wow sit in between, so they never quite agree:
                    // that mistracking is the breathing
                    fNcCA = fNcCB; fNcEA = fNcEB;
                    fNcCB = std::pow(kRef * kRef / std::fmax(fNcPin, 1e-8f), 0.25f);
                    fNcEB = std::sqrt(std::fmax(fNcPout, 1e-8f)) / kRef;
                }
            }
            const float frac = 1.0f - (float)fCrCount / (float)kCR;
            --fCrCount;

            fMix   += fSmooth * (mixT - fMix);
            fAct   += fSmooth * (actT - fAct);
            fDrive += fSmooth * (driveT - fDrive);
            fDriveOut += fSmooth * (driveOutT - fDriveOut);
            fLev   += fSmooth * (levT - fLev);
            fSw    += fSwCoef * (fSwT - fSw);
            fAlcGain += fAlcGainC * (fAlcGainT - fAlcGain);

            // read every input before writing any output: the host may hand the same buffers
            float x[kCh];
            for (int c = 0; c < kCh; ++c) x[c] = inputs[c][i];

            // ---- record side: auto level and the noise reduction see both tracks (linked)
            float v[kCh];
            for (int c = 0; c < kCh; ++c) v[c] = x[c];
            if (fAlcOn) {
                float a = std::fabs(v[0]);
                for (int c = 1; c < kCh; ++c) a = std::fmax(a, std::fabs(v[c]));
                fAlcEnv += (a > fAlcEnv ? fAlcAtk : fAlcRel) * (a - fAlcEnv) + 1e-18f;
                for (int c = 0; c < kCh; ++c) v[c] *= fAlcGain;
            }
            if (fNcOn) {                         // noise reduction encode (2:1)
                float pw = v[0] * v[0];
                for (int c = 1; c < kCh; ++c) pw += v[c] * v[c];
                pw *= 1.0f / (float)kCh;
                fNcPin += (pw > fNcPin ? fNcAtk : fNcRel) * (pw - fNcPin) + 1e-18f;
                const float gc = fNcCA + frac * (fNcCB - fNcCA);
                for (int c = 0; c < kCh; ++c) v[c] *= gc;
            }
            const float g = fG0 * fDrive;
            const float d = fCentre + fDispA + frac * (fDispB - fDispA);   // one transport
            float y[kCh];
            for (int c = 0; c < kCh; ++c) {
                Track& T = fTr[c];
                float u = T.pre.process(v[c] * g);
                // self-erasure: hot treble partly wipes itself off the oxide, so the pick's
                // edge is smoothed before the body clips. Knee 0.5 of tape full scale [guess]
                T.erLp += fEraseSplit * (u - T.erLp);
                const float hi = u - T.erLp;
                const float ah = std::fabs(hi);
                T.erEnv += (ah > T.erEnv ? fEraseAtk : fEraseRel) * (ah - T.erEnv) + 1e-18f;
                u = T.erLp + hi / (1.0f + 2.0f * T.erEnv);
                u = T.saturate(u);
                u = T.de.process(u) / g * fDriveOut;

                // grain: the oxide isn't even, so the level shimmers with the signal
                const float n = T.rng.next();
                T.grLp += fGrainLp * (n - T.grLp);
                T.grHp += fGrainHp * (T.grLp - T.grHp);
                u *= 1.0f + fGrainAmt * (T.grLp - T.grHp);

                T.buf[fW] = u;
                T.dry[fW] = x[c];

                // ---- tape path: read point swings around the centre; the right track sits
                // a little behind the left when the head's azimuth is off
                y[c] = T.read(fW, c == 0 ? d : d + fAzimA + frac * (fAzimB - fAzimA));

                // ---- playback side
                if (fHissAmp > 0.0f) y[c] += T.hissDe.process(fHissAmp * T.rng.next());
                y[c] *= 1.0f - fDropEnv * (c == 0 ? fDropDepth : fDropDepthR);
                y[c] = T.hp1.process(y[c]); y[c] = T.hp2.process(y[c]);
                y[c] = T.bump.process(y[c]);
                y[c] = T.lp1.process(y[c]); y[c] = T.lp2.process(y[c]);
            }
            if (fNcOn) {                         // noise reduction decode (1:2), linked
                float pw = y[0] * y[0];
                for (int c = 1; c < kCh; ++c) pw += y[c] * y[c];
                pw *= 1.0f / (float)kCh;
                fNcPout += (pw > fNcPout ? fNcAtk : fNcRel) * (pw - fNcPout) + 1e-18f;
                const float ge = fNcEA + frac * (fNcEB - fNcEA);
                for (int c = 0; c < kCh; ++c) y[c] *= ge;
            }
            const uint32_t rd = (fW - fDryDelay) & kBufMask;
            for (int c = 0; c < kCh; ++c) {
                Track& T = fTr[c];
                float o = y[c] * (fMakeup * fSw);
                // Tone: a first-order tilt, unity at 800 Hz
                o = fTiltGain * T.tilt.process(o);
                const float active = fLev * (fMix * o + (1.0f - fMix) * T.dry[rd]);
                outputs[c][i] = fAct * active + (1.0f - fAct) * x[c];
            }
            fW = (fW + 1) & kBufMask;
        }
    }

private:
    static void svfCoefs(float hz, float sr, float& g, float& k)
    {
        g = std::tan(kPi * clampf(hz, 0.1f, 0.45f * sr) / sr);
        k = 1.0f / 1.5f;   // Q 1.5
    }
    static inline float svfBand(float x, float g, float k, float& ic1, float& ic2)
    {
        const float a1 = 1.0f / (1.0f + g * (g + k));
        const float v1 = a1 * (ic1 + g * (x - ic2));
        const float v2 = ic2 + g * v1;
        ic1 = 2.0f * v1 - ic1 + 1e-18f;
        ic2 = 2.0f * v2 - ic2 + 1e-18f;
        return v1;
    }

    void applyFormat(int fmt, int tape, float age)
    {
        const bool alcChanged = (kFormats[fmt].alcMaxDb > 0.0f) != (kFormats[fFmt].alcMaxDb > 0.0f);
        fFmt = fmt; fTape = tape;
        const FormatDef& F = kFormats[fmt];
        const TapeDef& T = kTapes[tape];
        const double ez = F.emphHz, ep = F.emphHz * std::pow(10.0, (F.emphDb + T.emphOffDb) / 20.0);
        for (int c = 0; c < kCh; ++c) {
            fTr[c].pre.set(ez, ep, fSr);       // pre: zero at ez, pole at ep (treble lift)
            fTr[c].de.set(ep, ez, fSr);        // de: the exact inverse
            fTr[c].hissDe.set(ep, ez, fSr);    // hiss gets de-emphasised like it does on tape
        }
        setResponse(fmt, tape, age);
        // self-erasure corner: 2.5 kHz at cassette speed, rising with sqrt(speed) [guess: physics says
        // linear in speed, but sqrt keeps some treble-first squash on the fast reels]
        fEraseSplit = onePoleCoef(std::fmin(2500.0f * std::sqrt(F.ips / 1.875f), 0.4f * fSr), fSr);
        fRandA = onePoleCoef(F.randHz, fCr);
        svfCoefs(F.flutHz, fCr, fSvfG, fSvfK);
        if (alcChanged) { fAlcEnv = kAlcTarget; fAlcGain = fAlcGainT = 1.0f; }
        resetNc();
    }

    // levels that follow the format, tape and knobs (control rate)
    void updateLevels(float age, float hissK)
    {
        const FormatDef& F = kFormats[fFmt];
        const TapeDef& T = kTapes[fTape];
        fG0 = F.g0 * T.sens;
        // Noise: 0 = no hiss, no grain. 1 = the format's grain, no hiss. From 2 the hiss fades in,
        // rising 3 dB a step to the format's real noise floor at 10.
        // Pocket and Answering keep their grain at every setting: their grit is the machine
        fHissAmp = hissK <= 2.0f ? 0.0f
            : kRef * dbToLin(F.hissCalDb - (F.snDb + T.hissOffDb) - 3.0f * (10.0f - hissK)) * std::fmin(hissK - 2.0f, 1.0f) * 1.7320508f;
        const float grainK = (fFmt == kPocket || fFmt == kAnswer) ? 1.0f : std::fmin(hissK, 1.0f);
        fGrainAmt = F.grain * T.grainMul * (1.0f + 0.1f * age) * fGrainNorm * grainK;
        fAlcOn = F.alcMaxDb > 0.0f;
        fAlcMax = fAlcOn ? dbToLin(F.alcMaxDb) : 1.0f;
        fMakeup = dbToLin(F.makeupDb);
        fNcOn = F.nc > 0.5f;
        // azimuth (stereo): a worn, misaligned head reads the right track a few microseconds late.
        // The offset on the tape is fixed, so slow tape turns it into more time: 40 us at Age 10 on
        // a cassette, a few us on the fast reels, capped at 0.25 ms [guess]
        fAzimT = kCh > 1 ? std::fmin(age * 0.1f * 40e-6f * (1.875f / F.ips), 0.25e-3f) * fSr : 0.0f;
    }

    void setResponse(int fmt, int tape, float age)
    {
        const FormatDef& F = kFormats[fmt];
        const TapeDef& T = kTapes[tape];
        const double nyq = 0.45 * fSr;
        // 4th order (two stages) uses Butterworth Qs; 2nd order uses 0.707
        const double qa = F.hpStages > 1 ? 0.5412 : 0.7071, qb = 1.3066;
        // head wear and oxide shed: Age dulls the top end, corner down to 45 % at 10 [guess]
        const double lp = std::fmin(nyq, F.lpHz * T.lpMul / (1.0 + 0.12 * age));
        const double la = F.lpStages > 1 ? 0.5412 : 0.7071;
        for (int c = 0; c < kCh; ++c) {
            Track& K = fTr[c];
            K.hp1.highpass(F.hpHz, qa, fSr);
            if (F.hpStages > 1) K.hp2.highpass(F.hpHz, qb, fSr); else K.hp2.identity();
            K.bump.peak(F.bumpHz, F.bumpDb, 1.0, fSr);
            K.lp1.lowpass(lp, la, fSr);
            if (F.lpStages > 1) K.lp2.lowpass(lp, qb, fSr); else K.lp2.identity();
        }
        fAgeApplied = age;
    }

    // displacement of the read point (samples) at the next control step
    void computeMod(float wowK, float flutK, float age)
    {
        const FormatDef& F = kFormats[fFmt];
        const float randPct = F.randPct + F.ageSens * age * 0.1f * 0.15f;   // stretched belt, worn pinch roller
        const float flutPct = F.flutPct + F.ageSens * age * 0.1f * 0.04f;
        const float kS = F.sineHz < 4.0f ? wowK : flutK;
        const float kC = F.capHz  < 4.0f ? wowK : flutK;

        fPhS += F.sineHz / fCr; if (fPhS >= 1.0f) fPhS -= 1.0f;
        fPhC += F.capHz / fCr;  if (fPhC >= 1.0f) fPhC -= 1.0f;
        fR1 += fRandA * (fRngMod.next() - fR1);
        fR2 += fRandA * (fR1 - fR2);
        const float bp = svfBand(fRngMod.next(), fSvfG, fSvfK, fF1, fF2);

        // rms pitch (fraction) -> displacement (seconds): p / (2 pi f); sines carry sqrt 2 for their peak
        float s = 0.0f;
        s += kS * 1.4142136f * F.sinePct * 0.01f / (kTwoPi * F.sineHz) * parSine(fPhS);
        s += kC * 1.4142136f * F.capPct * 0.01f / (kTwoPi * F.capHz) * parSine(fPhC);
        s += wowK * randPct * 0.01f / (kTwoPi * F.randHz) * fRandNorm[fFmt] * fR2;
        s += flutK * flutPct * 0.01f / (kTwoPi * F.flutHz) * fFlutNorm[fFmt] * bp;
        fDispB = clampf(s * fSr, -fSwing, fSwing);
    }

    // random dips in level where the oxide is thin or the tape lifts off the head
    void stepDropouts(float age)
    {
        const FormatDef& F = kFormats[fFmt];
        const TapeDef& T = kTapes[fTape];
        if (fDropHold > 0) {
            --fDropHold;
            fDropEnv += fDropAtk * (1.0f - fDropEnv);
            return;
        }
        fDropEnv += fDropRel * (0.0f - fDropEnv);
        if (age <= 0.0f) return;
        const float a3 = age / 3.0f;
        const float rate = 0.05f * F.dropFmt * T.dropMul * a3 * std::sqrt(a3);   // per second [guess]
        const float u = 0.5f * (fRngMod.next() + 1.0f);
        if (u < rate / fCr) {
            fDropDepth = 0.3f + 0.3f * (0.5f * (fRngMod.next() + 1.0f));     // -3 .. -8 dB
            fDropHold = (int)((0.015f + 0.06f * 0.5f * (fRngMod.next() + 1.0f)) * fCr);
            // stereo: the whole tape lifts, so both tracks dip together, the right a little
            // more or less (own generator, so the left stays the mono plugin's)
            fDropDepthR = kCh > 1 ? fDropDepth * (1.0f + 0.3f * fRngSkew.next()) : fDropDepth;
        }
    }

    // tilt: H(s) = (A s + w0) / (s + A w0): lows 1/A, highs A, exactly 1 at 800 Hz.
    // As a Shelf1 (DC gain 1, HF gain A^2) with zero at f0/A and pole at f0 A, times 1/A.
    // Tone +-5 = +-4 dB at the ends [guess, by ear]
    void setTilt(float tone)
    {
        const double A = std::pow(10.0, 0.8 * tone / 20.0);
        for (int c = 0; c < kCh; ++c) fTr[c].tilt.set(800.0 / A, 800.0 * A, fSr);
        fTiltGain = (float)(1.0 / A);
    }

    void resetNc()
    {
        fNcPin = fNcPout = kRef * kRef;          // start at unity gain both ways
        fNcCA = fNcCB = fNcEA = fNcEB = 1.0f;
    }

    void clearFilters()
    {
        for (int c = 0; c < kCh; ++c) fTr[c].clearFilters();
    }

    void reset()
    {
        for (int c = 0; c < kCh; ++c) fTr[c].reset(kSeeds[c]);
        fW = 0; fCrCount = 0;
        fPhS = 0.0f; fPhC = 0.37f; fR1 = fR2 = fF1 = fF2 = 0.0f;
        fDispA = fDispB = 0.0f;
        fDropEnv = 0.0f; fDropDepth = fDropDepthR = 0.0f; fDropHold = 0; fSwHold = 0;
        fAzimA = fAzimB = fAzimT = 0.0f;
        fAlcEnv = kAlcTarget; fAlcGain = fAlcGainT = 1.0f;
        resetNc();
        fRngMod.s = 0x2545F491u; fRngSkew.s = 0x6c8e9cf5u;
    }

    float fParams[kParameterCount];
    Track fTr[kCh];
    int   fCrCount = 0;
    uint32_t fW = 0, fDryDelay = 288;
    Rng   fRngMod { 0x2545F491u }, fRngSkew { 0x6c8e9cf5u };
    float fAzimA = 0.0f, fAzimB = 0.0f, fAzimT = 0.0f, fDropDepthR = 0.0f;

    int   fFmt = kWalkman, fTape = kFerric;
    float fAgeApplied = -1.0f;
    float fSr = 48000.0f, fCr = 3000.0f, fSmooth = 0.0f, fSwCoef = 0.0f;
    float fAlcAtk = 0.0f, fAlcRel = 0.0f, fAlcGainC = 0.0f, fAlcEnv = kAlcTarget, fAlcGain = 1.0f, fAlcGainT = 1.0f;
    float fGrainHp = 0.0f, fGrainLp = 0.5f, fGrainNorm = 1.0f;
    float fCentre = 288.0f, fSwing = 240.0f;
    float fPhS = 0.0f, fPhC = 0.0f, fR1 = 0.0f, fR2 = 0.0f, fF1 = 0.0f, fF2 = 0.0f;
    float fRandNorm[kNumFormats], fFlutNorm[kNumFormats];
    float fDispA = 0.0f, fDispB = 0.0f;
    float fDropAtk = 0.0f, fDropRel = 0.0f, fDropEnv = 0.0f, fDropDepth = 0.0f;
    int   fDropHold = 0, fSwHold = 0;
    float fG0 = 3.0f, fHissAmp = 0.0f, fGrainAmt = 0.0f, fAlcMax = 1.0f, fMakeup = 1.0f;
    bool  fAlcOn = false;
    float fRandA = 0.001f, fSvfG = 0.01f, fSvfK = 0.667f;
    float fEraseSplit = 0.3f, fEraseAtk = 0.04f, fEraseRel = 0.0005f;
    bool  fNcOn = false;
    float fNcAtk = 0.01f, fNcRel = 0.0003f, fNcPin = 0.01f, fNcPout = 0.01f;
    float fNcCA = 1.0f, fNcCB = 1.0f, fNcEA = 1.0f, fNcEB = 1.0f;
    float fTiltGain = 1.0f, fToneSm = 0.0f, fLev = 1.0f, fDriveOut = 1.0f;
    float fMix = 1.0f, fAct = 1.0f, fDrive = 1.0f, fSw = 1.0f, fSwT = 1.0f;
    bool  fFirst = true;

    DISTRHO_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(TapestryPlugin)
};

Plugin* createPlugin() { return new TapestryPlugin(); }

END_NAMESPACE_DISTRHO
endef

define NHE_TAPESTRY_STEREO_FILE4
@prefix lv2:  <http://lv2plug.in/ns/lv2core#> .
@prefix pset: <http://lv2plug.in/ns/ext/presets#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .

<urn:mod-cookbook:nhe-tapestry-stereo>
    a lv2:Plugin , lv2:SimulatorPlugin ;
    lv2:binary <nhe-tapestry-stereo_dsp.so> ;
    rdfs:seeAlso <nhe-tapestry-stereo.ttl> , <modgui.ttl> .

<urn:mod-cookbook:nhe-tapestry-stereo#always-on>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "Always on" ;
    rdfs:seeAlso <presets.ttl> .

<urn:mod-cookbook:nhe-tapestry-stereo#walkman-cheap>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "Walkman, cheap tape" ;
    rdfs:seeAlso <presets.ttl> .

<urn:mod-cookbook:nhe-tapestry-stereo#walkman-chrome>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "Walkman, chrome" ;
    rdfs:seeAlso <presets.ttl> .

<urn:mod-cookbook:nhe-tapestry-stereo#studio-half-inch>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "Studio half-inch" ;
    rdfs:seeAlso <presets.ttl> .

<urn:mod-cookbook:nhe-tapestry-stereo#home-reel>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "Home reel-to-reel" ;
    rdfs:seeAlso <presets.ttl> .

<urn:mod-cookbook:nhe-tapestry-stereo#pocket-dictaphone>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "Pocket dictaphone" ;
    rdfs:seeAlso <presets.ttl> .

<urn:mod-cookbook:nhe-tapestry-stereo#answering-machine>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "Answering machine" ;
    rdfs:seeAlso <presets.ttl> .

<urn:mod-cookbook:nhe-tapestry-stereo#vhs-linear>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "VHS linear" ;
    rdfs:seeAlso <presets.ttl> .

<urn:mod-cookbook:nhe-tapestry-stereo#eight-track>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "8-track cartridge" ;
    rdfs:seeAlso <presets.ttl> .

<urn:mod-cookbook:nhe-tapestry-stereo#bedroom-four-track>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "Bedroom 4-track" ;
    rdfs:seeAlso <presets.ttl> .
endef

define NHE_TAPESTRY_STEREO_FILE5
@prefix lv2:    <http://lv2plug.in/ns/lv2core#> .
@prefix modgui: <http://moddevices.com/ns/modgui#> .

<urn:mod-cookbook:nhe-tapestry-stereo>
    modgui:gui [
        modgui:resourcesDirectory <modgui> ;
        modgui:iconTemplate <modgui/icon-tapestry.html> ;
        modgui:stylesheet <modgui/stylesheet-tapestry.css> ;
        modgui:javascript <modgui/script-tapestry.js> ;
        modgui:screenshot <modgui/screenshot-tapestry.png> ;
        modgui:thumbnail <modgui/thumbnail-tapestry.png> ;
        modgui:brand "New Horizon" ;
        modgui:label "Tapestry Stereo" ;
        modgui:port
        [ lv2:index 0 ; lv2:symbol "format" ;  lv2:name "Format" ; ],
        [ lv2:index 1 ; lv2:symbol "tape" ;    lv2:name "Tape" ; ],
        [ lv2:index 2 ; lv2:symbol "drive" ;   lv2:name "Drive" ; ],
        [ lv2:index 3 ; lv2:symbol "tone" ;    lv2:name "Tone" ; ],
        [ lv2:index 4 ; lv2:symbol "wow" ;     lv2:name "Wow" ; ],
        [ lv2:index 5 ; lv2:symbol "flutter" ; lv2:name "Flutter" ; ],
        [ lv2:index 6 ; lv2:symbol "age" ;     lv2:name "Age" ; ],
        [ lv2:index 7 ; lv2:symbol "hiss" ;    lv2:name "Noise" ; ],
        [ lv2:index 8 ; lv2:symbol "mix" ;     lv2:name "Mix" ; ],
        [ lv2:index 9 ; lv2:symbol "level" ;   lv2:name "Level" ; ] ;
    ] .
endef

define NHE_TAPESTRY_STEREO_FILE6
@prefix doap:   <http://usefulinc.com/ns/doap#> .
@prefix foaf:   <http://xmlns.com/foaf/0.1/> .
@prefix lv2:    <http://lv2plug.in/ns/lv2core#> .
@prefix rdf:    <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs:   <http://www.w3.org/2000/01/rdf-schema#> .
@prefix units:  <http://lv2plug.in/ns/extensions/units#> .

<urn:mod-cookbook:nhe-tapestry-stereo>
    a lv2:Plugin , lv2:SimulatorPlugin ;
    doap:name "Tapestry Stereo" ;
    doap:license <http://spdx.org/licenses/GPL-3.0-or-later.html> ;
    doap:maintainer [ foaf:name "New Horizon" ] ;
    rdfs:comment "Stereo tape machines from studio reel to answering machine: two tracks on one transport, wow, flutter, saturation and tape's low end." ;
    lv2:minorVersion 2 ;
    lv2:microVersion 0 ;
    lv2:optionalFeature lv2:hardRTCapable ;
    lv2:requiredFeature <http://lv2plug.in/ns/ext/options#options> ,
                        <http://lv2plug.in/ns/ext/urid#map> ;
    lv2:extensionData <http://lv2plug.in/ns/ext/options#interface> ;
    lv2:port [
        a lv2:InputPort , lv2:AudioPort ;
        lv2:index 0 ;
        lv2:symbol "in_l" ;
        lv2:name "In L"
    ] , [
        a lv2:InputPort , lv2:AudioPort ;
        lv2:index 1 ;
        lv2:symbol "in_r" ;
        lv2:name "In R"
    ] , [
        a lv2:OutputPort , lv2:AudioPort ;
        lv2:index 2 ;
        lv2:symbol "out_l" ;
        lv2:name "Out L"
    ] , [
        a lv2:OutputPort , lv2:AudioPort ;
        lv2:index 3 ;
        lv2:symbol "out_r" ;
        lv2:name "Out R"
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 4 ;
        lv2:symbol "format" ;
        lv2:name "Format" ;
        lv2:default 2 ;
        lv2:minimum 0 ;
        lv2:maximum 8 ;
        lv2:portProperty lv2:integer , lv2:enumeration ;
        lv2:scalePoint
            [ rdfs:label "Studio reel" ; rdf:value 0 ] ,
            [ rdfs:label "Home reel" ; rdf:value 1 ] ,
            [ rdfs:label "Walkman" ; rdf:value 2 ] ,
            [ rdfs:label "VHS" ; rdf:value 3 ] ,
            [ rdfs:label "Pocket" ; rdf:value 4 ] ,
            [ rdfs:label "Answering" ; rdf:value 5 ] ,
            [ rdfs:label "Master" ; rdf:value 6 ] ,
            [ rdfs:label "8-track" ; rdf:value 7 ] ,
            [ rdfs:label "4-track" ; rdf:value 8 ]
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 5 ;
        lv2:symbol "tape" ;
        lv2:name "Tape" ;
        lv2:default 1 ;
        lv2:minimum 0 ;
        lv2:maximum 3 ;
        lv2:portProperty lv2:integer , lv2:enumeration ;
        lv2:scalePoint
            [ rdfs:label "Cheap" ; rdf:value 0 ] ,
            [ rdfs:label "Ferric" ; rdf:value 1 ] ,
            [ rdfs:label "Chrome" ; rdf:value 2 ] ,
            [ rdfs:label "Metal" ; rdf:value 3 ]
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 6 ;
        lv2:symbol "drive" ;
        lv2:name "Drive" ;
        lv2:default 0 ;
        lv2:minimum -12 ;
        lv2:maximum 18 ;
        units:unit units:db
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 7 ;
        lv2:symbol "tone" ;
        lv2:name "Tone" ;
        lv2:default 0 ;
        lv2:minimum -5 ;
        lv2:maximum 5
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 8 ;
        lv2:symbol "wow" ;
        lv2:name "Wow" ;
        lv2:default 100 ;
        lv2:minimum 0 ;
        lv2:maximum 200 ;
        units:unit units:pc
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 9 ;
        lv2:symbol "flutter" ;
        lv2:name "Flutter" ;
        lv2:default 100 ;
        lv2:minimum 0 ;
        lv2:maximum 200 ;
        units:unit units:pc
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 10 ;
        lv2:symbol "age" ;
        lv2:name "Age" ;
        lv2:default 3 ;
        lv2:minimum 0 ;
        lv2:maximum 10
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 11 ;
        lv2:symbol "hiss" ;
        lv2:name "Noise" ;
        lv2:default 0 ;
        lv2:minimum 0 ;
        lv2:maximum 10
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 12 ;
        lv2:symbol "mix" ;
        lv2:name "Mix" ;
        lv2:default 100 ;
        lv2:minimum 0 ;
        lv2:maximum 100 ;
        units:unit units:pc
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 13 ;
        lv2:symbol "level" ;
        lv2:name "Level" ;
        lv2:default 0 ;
        lv2:minimum -12 ;
        lv2:maximum 12 ;
        units:unit units:db
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 14 ;
        lv2:symbol "lv2_enabled" ;
        lv2:name "Enabled" ;
        lv2:default 1 ;
        lv2:minimum 0 ;
        lv2:maximum 1 ;
        lv2:portProperty lv2:integer , lv2:toggled ;
        lv2:designation lv2:enabled
    ] .
endef

define NHE_TAPESTRY_STEREO_FILE7
@prefix lv2:  <http://lv2plug.in/ns/lv2core#> .
@prefix pset: <http://lv2plug.in/ns/ext/presets#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .

<urn:mod-cookbook:nhe-tapestry-stereo#always-on>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "Always on" ;
    lv2:port
        [ lv2:symbol "format" ; pset:value 6.0 ] ,
        [ lv2:symbol "tape" ; pset:value 1.0 ] ,
        [ lv2:symbol "drive" ; pset:value 6.0 ] ,
        [ lv2:symbol "tone" ; pset:value 0.0 ] ,
        [ lv2:symbol "wow" ; pset:value 100.0 ] ,
        [ lv2:symbol "flutter" ; pset:value 100.0 ] ,
        [ lv2:symbol "age" ; pset:value 0.0 ] ,
        [ lv2:symbol "hiss" ; pset:value 0.0 ] ,
        [ lv2:symbol "mix" ; pset:value 100.0 ] ,
        [ lv2:symbol "level" ; pset:value 0.0 ] .

<urn:mod-cookbook:nhe-tapestry-stereo#walkman-cheap>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "Walkman, cheap tape" ;
    lv2:port
        [ lv2:symbol "format" ; pset:value 2.0 ] ,
        [ lv2:symbol "tape" ; pset:value 0.0 ] ,
        [ lv2:symbol "drive" ; pset:value 3.0 ] ,
        [ lv2:symbol "tone" ; pset:value 0.0 ] ,
        [ lv2:symbol "wow" ; pset:value 110.0 ] ,
        [ lv2:symbol "flutter" ; pset:value 100.0 ] ,
        [ lv2:symbol "age" ; pset:value 5.0 ] ,
        [ lv2:symbol "hiss" ; pset:value 1.0 ] ,
        [ lv2:symbol "mix" ; pset:value 100.0 ] ,
        [ lv2:symbol "level" ; pset:value 0.0 ] .

<urn:mod-cookbook:nhe-tapestry-stereo#walkman-chrome>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "Walkman, chrome" ;
    lv2:port
        [ lv2:symbol "format" ; pset:value 2.0 ] ,
        [ lv2:symbol "tape" ; pset:value 2.0 ] ,
        [ lv2:symbol "drive" ; pset:value 0.0 ] ,
        [ lv2:symbol "tone" ; pset:value 0.0 ] ,
        [ lv2:symbol "wow" ; pset:value 100.0 ] ,
        [ lv2:symbol "flutter" ; pset:value 100.0 ] ,
        [ lv2:symbol "age" ; pset:value 2.0 ] ,
        [ lv2:symbol "hiss" ; pset:value 1.0 ] ,
        [ lv2:symbol "mix" ; pset:value 100.0 ] ,
        [ lv2:symbol "level" ; pset:value 0.0 ] .

<urn:mod-cookbook:nhe-tapestry-stereo#studio-half-inch>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "Studio half-inch" ;
    lv2:port
        [ lv2:symbol "format" ; pset:value 0.0 ] ,
        [ lv2:symbol "tape" ; pset:value 1.0 ] ,
        [ lv2:symbol "drive" ; pset:value 4.0 ] ,
        [ lv2:symbol "tone" ; pset:value 0.0 ] ,
        [ lv2:symbol "wow" ; pset:value 100.0 ] ,
        [ lv2:symbol "flutter" ; pset:value 100.0 ] ,
        [ lv2:symbol "age" ; pset:value 1.0 ] ,
        [ lv2:symbol "hiss" ; pset:value 1.0 ] ,
        [ lv2:symbol "mix" ; pset:value 100.0 ] ,
        [ lv2:symbol "level" ; pset:value 0.0 ] .

<urn:mod-cookbook:nhe-tapestry-stereo#home-reel>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "Home reel-to-reel" ;
    lv2:port
        [ lv2:symbol "format" ; pset:value 1.0 ] ,
        [ lv2:symbol "tape" ; pset:value 1.0 ] ,
        [ lv2:symbol "drive" ; pset:value 2.0 ] ,
        [ lv2:symbol "tone" ; pset:value 0.0 ] ,
        [ lv2:symbol "wow" ; pset:value 100.0 ] ,
        [ lv2:symbol "flutter" ; pset:value 100.0 ] ,
        [ lv2:symbol "age" ; pset:value 3.0 ] ,
        [ lv2:symbol "hiss" ; pset:value 1.0 ] ,
        [ lv2:symbol "mix" ; pset:value 100.0 ] ,
        [ lv2:symbol "level" ; pset:value 0.0 ] .

<urn:mod-cookbook:nhe-tapestry-stereo#pocket-dictaphone>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "Pocket dictaphone" ;
    lv2:port
        [ lv2:symbol "format" ; pset:value 4.0 ] ,
        [ lv2:symbol "tape" ; pset:value 1.0 ] ,
        [ lv2:symbol "drive" ; pset:value 0.0 ] ,
        [ lv2:symbol "tone" ; pset:value 0.0 ] ,
        [ lv2:symbol "wow" ; pset:value 100.0 ] ,
        [ lv2:symbol "flutter" ; pset:value 100.0 ] ,
        [ lv2:symbol "age" ; pset:value 4.0 ] ,
        [ lv2:symbol "hiss" ; pset:value 1.0 ] ,
        [ lv2:symbol "mix" ; pset:value 100.0 ] ,
        [ lv2:symbol "level" ; pset:value 0.0 ] .

<urn:mod-cookbook:nhe-tapestry-stereo#answering-machine>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "Answering machine" ;
    lv2:port
        [ lv2:symbol "format" ; pset:value 5.0 ] ,
        [ lv2:symbol "tape" ; pset:value 0.0 ] ,
        [ lv2:symbol "drive" ; pset:value 0.0 ] ,
        [ lv2:symbol "tone" ; pset:value 0.0 ] ,
        [ lv2:symbol "wow" ; pset:value 120.0 ] ,
        [ lv2:symbol "flutter" ; pset:value 100.0 ] ,
        [ lv2:symbol "age" ; pset:value 6.0 ] ,
        [ lv2:symbol "hiss" ; pset:value 1.0 ] ,
        [ lv2:symbol "mix" ; pset:value 100.0 ] ,
        [ lv2:symbol "level" ; pset:value 0.0 ] .

<urn:mod-cookbook:nhe-tapestry-stereo#vhs-linear>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "VHS linear" ;
    lv2:port
        [ lv2:symbol "format" ; pset:value 3.0 ] ,
        [ lv2:symbol "tape" ; pset:value 1.0 ] ,
        [ lv2:symbol "drive" ; pset:value 0.0 ] ,
        [ lv2:symbol "tone" ; pset:value 0.0 ] ,
        [ lv2:symbol "wow" ; pset:value 100.0 ] ,
        [ lv2:symbol "flutter" ; pset:value 100.0 ] ,
        [ lv2:symbol "age" ; pset:value 3.0 ] ,
        [ lv2:symbol "hiss" ; pset:value 1.0 ] ,
        [ lv2:symbol "mix" ; pset:value 100.0 ] ,
        [ lv2:symbol "level" ; pset:value 0.0 ] .

<urn:mod-cookbook:nhe-tapestry-stereo#eight-track>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "8-track cartridge" ;
    lv2:port
        [ lv2:symbol "format" ; pset:value 7.0 ] ,
        [ lv2:symbol "tape" ; pset:value 1.0 ] ,
        [ lv2:symbol "drive" ; pset:value 2.0 ] ,
        [ lv2:symbol "tone" ; pset:value 0.0 ] ,
        [ lv2:symbol "wow" ; pset:value 100.0 ] ,
        [ lv2:symbol "flutter" ; pset:value 100.0 ] ,
        [ lv2:symbol "age" ; pset:value 5.0 ] ,
        [ lv2:symbol "hiss" ; pset:value 1.0 ] ,
        [ lv2:symbol "mix" ; pset:value 100.0 ] ,
        [ lv2:symbol "level" ; pset:value 0.0 ] .

<urn:mod-cookbook:nhe-tapestry-stereo#bedroom-four-track>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry-stereo> ;
    rdfs:label "Bedroom 4-track" ;
    lv2:port
        [ lv2:symbol "format" ; pset:value 8.0 ] ,
        [ lv2:symbol "tape" ; pset:value 2.0 ] ,
        [ lv2:symbol "drive" ; pset:value 4.0 ] ,
        [ lv2:symbol "tone" ; pset:value 0.0 ] ,
        [ lv2:symbol "wow" ; pset:value 100.0 ] ,
        [ lv2:symbol "flutter" ; pset:value 100.0 ] ,
        [ lv2:symbol "age" ; pset:value 2.0 ] ,
        [ lv2:symbol "hiss" ; pset:value 1.0 ] ,
        [ lv2:symbol "mix" ; pset:value 100.0 ] ,
        [ lv2:symbol "level" ; pset:value 0.0 ] .
endef

define NHE_TAPESTRY_STEREO_FILE8
/9j/4QAYRXhpZgAASUkqAAgAAAAAAAAAAAAAAP/sABFEdWNreQABAAQAAABBAAD/4QOPaHR0cDov
L25zLmFkb2JlLmNvbS94YXAvMS4wLwA8P3hwYWNrZXQgYmVnaW49Iu+7vyIgaWQ9Ilc1TTBNcENl
aGlIenJlU3pOVGN6a2M5ZCI/PiA8eDp4bXBtZXRhIHhtbG5zOng9ImFkb2JlOm5zOm1ldGEvIiB4
OnhtcHRrPSJBZG9iZSBYTVAgQ29yZSAxMC4wLWMwMDAgNzkuNDMzMmFhZSwgMjAyNi8wOC8xNy0x
MzozOTo0MyAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8x
OTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIg
eG1sbnM6eG1wTU09Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9tbS8iIHhtbG5zOnN0UmVm
PSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvc1R5cGUvUmVzb3VyY2VSZWYjIiB4bWxuczp4
bXA9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC8iIHhtcE1NOk9yaWdpbmFsRG9jdW1lbnRJ
RD0ieG1wLmRpZDo1YTE2N2VmMC01YWM4LTRlYmUtYThkYS03ZTc5ODBjYzJhY2IiIHhtcE1NOkRv
Y3VtZW50SUQ9InhtcC5kaWQ6ODZERkFEQ0NDQkQ5MTFGMTg3MDZFQjYyQjY3REYwMzQiIHhtcE1N
Okluc3RhbmNlSUQ9InhtcC5paWQ6ODZERkFEQ0JDQkQ5MTFGMTg3MDZFQjYyQjY3REYwMzQiIHht
cDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIDI3LjEwIChNYWNpbnRvc2gpIj4gPHhtcE1N
OkRlcml2ZWRGcm9tIHN0UmVmOmluc3RhbmNlSUQ9InhtcC5paWQ6MTdhNGVlMTktOTUzZS00Y2Yx
LTk0NTUtMzM1M2U5Zjg2NGZlIiBzdFJlZjpkb2N1bWVudElEPSJhZG9iZTpkb2NpZDpwaG90b3No
b3A6NjczYzZiYTktOTQxMi0xYzQ2LWE4NjEtY2VjMTRjOWNmNWQyIi8+IDwvcmRmOkRlc2NyaXB0
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
PoT5Q89A+PT6E+UPPQPj0+hPlDz0D49PoT5Q89A+PT6E+UPPQPj0+hPlDz0E+PD6E+UPPQPjw+hP
lDz0D48PoT5Q89ByR5thPdig7XnVQelBdRTgFhBQdhAQEBBKoIgIPaQVAQRyDruFCg8vMXTobcMY
aOkNK9jnQfsHg9wo0Nw60bY611jb2+Q1Lfwsud64Y2cWvWt3mQQRuq3rQD3b+WtRUBfLPeafpNZw
ayS+is4wYt7+rtsVcuhbsY4uYzZzdyK08tcvMn28eS5Hpw8S7KYV+Lblv2zD9cKedPt48jI7bdf2
RFfELn+J90p58+3jyMqHiBZD/YLn+J90nnT7ePIyOM8RLIf8vufLZ56vnT7ePIysDxIsh/y658tn
np50+3jyMrjPEuyH/Lbn1TPPTzZ9vHkZWJ4nWQ/5Zc+qYr5s+3jyMqHihZfNlz6piebPt48jKx/W
jZfNlx6piebPt48jKfrSsvmu49WxPNn28eRlT9adl813Hq2J5s4ceRlT9all813Hq2J5s+3jyMqf
rVsvmu49WxPNn28eRlP1q2XzVcerYnmzhx5GVP1rWXzVcerYnmz7ePIyp+tey+arj1bE82cOPIyp
+tiy+arj1bFfMnDjyMp+tiy+arj1bE8ycOPIyn62bL5quPVsTzJw48jKfrYs/mm49WxPMnDjyMh+
tiz+abj1bE8ycOPIyr+tez+abj1bE8ycOPIyqOKtn81XHq2KebOHHkZWQ4p2R/5XcerYnmz7ePIy
MxxQsj/yu59UxPNn28eRkU8T7If8sufVMTzZ9vHkZHBJxXso+XFXHq2J5s4ceRkfKOL0ekdd4h93
cYtltdRNO7ehjG3MbuYiRoq4dLXbCvn0L741K4tTEUfl60t5LdskD3B/UuLQ8chANKhevDk50EKD
V9XZF8EMdjE7dM4LpiOXcGwDySg0hAQEBAQEBAQEBAQenhMg/H38bw77zIQyZvMWk0r9ryoPpNUC
qDy83dOgtgxho6Q0r2OdB+vOD3CfQ/DvR1jrXWNvb5DUt/Cy53rhjZxaiVu8yCCN1W9aAe7fy1qK
gL5Z7zTpsms4NZJfSI+LuLe/q7bF3JhGxji5jdnpRWnlrl5s+3jyXI9ODiPZTAf8OuW+Sw/XCnnT
7ePIyO43XVkR7yuvKZ90p58+3jyMiHXdkP8AYbrymfdJ58+3jyMjjdxAsh/sFz/E+6Tzp9vHkZHG
eIlkP+X3Pls89Xzp9vHkZGB4kWQ/5dc+Wzz086fbx5GRgeJdkP8Altz6pnnp50+3jyMqHiZZD/lt
z6pnnp5s+3jyMrE8TrL5sufVM89XzZ9vHkZU/WfZfNlz6piebPt48jKn60LL5suPVMTzZ9vHkZU/
WjZfNlx6piebPt48jIn60rL5ruPVsTzZ9vHkZT9adl813Hq2J5s4ceRlT9all813Hq2J5s+3jyMq
frVsvmu49WxPNn28eRlT9a1l81XHq2J5s4ceRlP1rWXzVcerYnmz7ePIyp+tey+arj1bE82cOPIy
p+tiy+arj1bFfMnDjyMp+tiy+arj1bE8ycOPIyn62bL5quPVsTzJw48jKn62bL5puPVsTzJw48jK
frZsvmm49WxPMnDjyMp+tmy+abj1bE8ycOPIyn62bL5puPVsTzJw48jIfrZsvmm49WzzlPMnDjyM
h+tmy+abj1bPOTzJw48jIfrZsvmm49Wzzk8ycOPIyH62bL5puPVs85PMnDjyMh+tmy+abj1bPOTz
Jw48jIfrZsvmm49Wzzk8ycOPIyH62bP5puP6RiebOHHkZF/WxZ/NNx/SMV8ycOPIyL+tez+arj1b
FPNnDjyMijirZH/lVx6tiebOHHkZGY4p2Z/5XcerYnmz7ePIyMhxQsj/AMsufVMTzZ9vHkZFPFCy
H/LLn1TE82fbx5GR15OLFi3Y7FXFDsPdsUnvJmN3HkZHwjjfidKattHZqDHx47JAVhvWRtjl3wO9
lLAOsaf4XJzLl2d90XTEtXRFH5xt2vbCA/lbsK9VyctUBBCabUHhZG+lkkba2w3pHmgaEG0aZ4fS
ZCE5DISRx2rT98u5yeqBHKGN5ZCPK7SDYpcZoWyHVOvruZ7dhdA2ONnkAtd5qDrmHQ/s2S8uP3NB
xluhh/PZHy4/c0AN0Mf57I+XH7mgz6rQ/s2S8uP3NA6rQ/s2S8uP3NA6rQ/s2S8uP3NA6rQ/s2S8
uP3NA6nQ3s2S8uP3NA6rQ/s2S8uP3NBDFof2bJeXH7mghj0OB69kfLj9zQcddDA067JeXH7mgyA0
Mf57I+XH7mgyDNDnkmyXlx+5oL1Wh/Zsj5cfuaB1WiPZsj5cfuaB1Wh/Zsj5cfuaB1Wh/Zsl5cfu
aB1Wh/Zsl5cfuaB1Wh/Zsl5cfuaCdXof2bI+XH7mgdXof2bI+XH7mgbmiPZsl5cfuaB1eh/Zsj5c
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
endef

define NHE_TAPESTRY_STEREO_FILE9
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
endef

define NHE_TAPESTRY_STEREO_FILE10
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
gg==
endef

define NHE_TAPESTRY_STEREO_FILE11
<div class="mod-pedal tapestry{{{cns}}}">
    <div mod-role="drag-handle" class="mod-drag-handle"></div>

    <!-- LCD 1: Drive, Level, Mix values (LCD web font; "DB DB %" are in the panel art) -->
    <div class="tp-lcd tp-val tp-val-drive" tp-show="lcd-drive">0</div>
    <div class="tp-lcd tp-val tp-val-level" tp-show="lcd-level">0</div>
    <div class="tp-lcd tp-val tp-val-mix" tp-show="lcd-mix">100</div>

    <!-- LCD 2: the format's name ("TAPE FORMAT" is in the panel art) -->
    <div class="tp-lcd tp-fmt" tp-show="lcd-format">WALKMAN</div>

    <!-- sliders: script-driven, drag or press anywhere along the channel -->
    <div class="tp-track tp-track-drive" title="Drive: -12 to +18 dB" tp-slider="drive"><div class="tp-cap"></div></div>
    <div class="tp-track tp-track-level" title="Level: -12 to +12 dB" tp-slider="level"><div class="tp-cap"></div></div>
    <div class="tp-track tp-track-mix" title="Mix: 0 to 100 %" tp-slider="mix"><div class="tp-cap"></div></div>

    <!-- step buttons: red steps Format, grey steps Tape -->
    <div class="tp-btn tp-btn-format" title="Format: next machine" tp-step="format"></div>
    <div class="tp-btn tp-btn-tape" title="Tape: next formulation" tp-step="tape"></div>

    <!-- Tape lights (off state is in the panel art); each label + light is also a click zone -->
    <div class="tp-led tp-led-0" tp-led="0"></div>
    <div class="tp-led tp-led-1 on" tp-led="1"></div>
    <div class="tp-led tp-led-2" tp-led="2"></div>
    <div class="tp-led tp-led-3" tp-led="3"></div>
    <div class="tp-pick tp-pick-0" title="Type 0 (cheap tape)" tp-pick="tape" tp-value="0"></div>
    <div class="tp-pick tp-pick-1" title="Ferric" tp-pick="tape" tp-value="1"></div>
    <div class="tp-pick tp-pick-2" title="Chrome" tp-pick="tape" tp-value="2"></div>
    <div class="tp-pick tp-pick-3" title="Metal" tp-pick="tape" tp-value="3"></div>

    <!-- On/Off: red light and the silver button -->
    <div class="tp-onoff-led on" mod-role="bypass-light"></div>
    <div class="tp-onoff" title="On/Off" mod-role="bypass"></div>

    <!-- knobs: 65-frame strip, knurl turns, lighting stays -->
    <div class="tp-knob tp-wow"     title="Wow"     mod-role="input-control-port" mod-port-symbol="wow"></div>
    <div class="tp-knob tp-flutter" title="Flutter" mod-role="input-control-port" mod-port-symbol="flutter"></div>
    <div class="tp-knob tp-age"     title="Age: new .. old" mod-role="input-control-port" mod-port-symbol="age"></div>
    <div class="tp-knob tp-hiss"    title="Noise: off .. 10 (hiss and grain)" mod-role="input-control-port" mod-port-symbol="hiss"></div>
    <div class="tp-knob tp-tone"    title="Tone: dark .. bright" mod-role="input-control-port" mod-port-symbol="tone"></div>

    <!-- the machine's picture follows Format -->
    <div class="tp-tape tp-tape-2" tp-show="picture"></div>

    <div class="mod-pedal-input">
        {{#effect.ports.audio.input}}
        <div class="mod-input mod-input-disconnected" title="{{name}}" mod-role="input-audio-port" mod-port-symbol="{{symbol}}">
            <div class="mod-pedal-input-image"></div>
        </div>
        {{/effect.ports.audio.input}}
    </div>
    <div class="mod-pedal-output">
        {{#effect.ports.audio.output}}
        <div class="mod-output mod-output-disconnected" title="{{name}}" mod-role="output-audio-port" mod-port-symbol="{{symbol}}">
            <div class="mod-pedal-output-image"></div>
        </div>
        {{/effect.ports.audio.output}}
    </div>
</div>
endef

define NHE_TAPESTRY_STEREO_FILE12
iVBORw0KGgoAAAANSUhEUgAAIIAAAACACAMAAAByfB4uAAAWfmNhQlgAABZ+anVtYgAAAB5qdW1k
YzJwYQARABCAAACqADibcQNjMnBhAAAAFlhqdW1iAAAAR2p1bWRjMm1hABEAEIAAAKoAOJtxA3Vy
bjpjMnBhOmE2OGRlMDExLWE1ZjktNDYwZS1iNTFhLWUyOWZkMTY1MWExMwAAAAOTanVtYgAAAClq
dW1kYzJhcwARABCAAACqADibcQNjMnBhLmFzc2VydGlvbnMAAAAAuGp1bWIAAABEanVtZGNib3IA
EQAQgAAAqgA4m3ETYzJwYS5pbmdyZWRpZW50LnYzAAAAABhjMnNo7nnzFGGK6AuxQKNazuIi5gAA
AGxjYm9yo2lkYzpmb3JtYXRpaW1hZ2UvcG5namluc3RhbmNlSUR4LHhtcDppaWQ6OTlhYmFkYWMt
NDE2My00NzhkLWI2OTAtYWRlNjJlZmIwMDY4bHJlbGF0aW9uc2hpcGhwYXJlbnRPZgAAAeJqdW1i
AAAAQWp1bWRjYm9yABEAEIAAAKoAOJtxE2MycGEuYWN0aW9ucy52MgAAAAAYYzJzaHtU0s1nh/qw
ISDfzkZB+woAAAGZY2JvcqJnYWN0aW9uc4KiZmFjdGlvbmtjMnBhLm9wZW5lZGpwYXJhbWV0ZXJz
oWtpbmdyZWRpZW50c4GiY3VybHgtc2VsZiNqdW1iZj1jMnBhLmFzc2VydGlvbnMvYzJwYS5pbmdy
ZWRpZW50LnYzZGhhc2hYIJjofNpMRJm+eIZVujC2UHUdrGjnnnHpzL4bkLhdnZ0IpGZhY3Rpb254
HWNvbS5hbnRocm9waWMuY2xhdWRlLnByb3ZpZGVkanBhcmFtZXRlcnOheB9jb20uYW50aHJvcGlj
Lm9yaWdpbi1jb25maWRlbmNlZ3Vua25vd25rZGVzY3JpcHRpb254ZkNsYXVkZSBwcm92aWRlZCB0
aGlzIGZpbGUgYXQgdGhlIHJlcXVlc3Qgb2YgYSB1c2VyIGFuZCBtYXkgaGF2ZSBjcmVhdGVkIG9y
IG1vZGlmaWVkIHRoZSBmaWxlIGNvbnRlbnRzLm1zb2Z0d2FyZUFnZW50oWRuYW1lZkNsYXVkZXJh
bGxBY3Rpb25zSW5jbHVkZWT1AAAAyGp1bWIAAABAanVtZGNib3IAEQAQgAAAqgA4m3ETYzJwYS5o
YXNoLmRhdGEAAAAAGGMyc2gXOZ7TuTufYAU7cBoZw0xQAAAAgGNib3KlY2FsZ2ZzaGEyNTZjcGFk
TQAAAAAAAAAAAAAAAABkaGFzaFgg/9Ry7j69UHfz3/gVCuPOFlY7/vh1KD+XsX6b6RDKM2JkbmFt
ZW5qdW1iZiBtYW5pZmVzdGpleGNsdXNpb25zgaJlc3RhcnQYIWZsZW5ndGgZFooAAAI+anVtYgAA
ACdqdW1kYzJjbAARABCAAACqADibcQNjMnBhLmNsYWltLnYyAAAAAg9jYm9ypWNhbGdmc2hhMjU2
aXNpZ25hdHVyZXhNc2VsZiNqdW1iZj0vYzJwYS91cm46YzJwYTphNjhkZTAxMS1hNWY5LTQ2MGUt
YjUxYS1lMjlmZDE2NTFhMTMvYzJwYS5zaWduYXR1cmVqaW5zdGFuY2VJRHgseG1wOmlpZDowYzA1
Y2Y3Yi0xY2ExLTQ1ODktYjI1YS1hYWRhZjI4ZDk0MTRyY3JlYXRlZF9hc3NlcnRpb25zg6JjdXJs
eC1zZWxmI2p1bWJmPWMycGEuYXNzZXJ0aW9ucy9jMnBhLmluZ3JlZGllbnQudjNkaGFzaFggmOh8
2kxEmb54hlW6MLZQdR2saOeecenMvhuQuF2dnQiiY3VybHgqc2VsZiNqdW1iZj1jMnBhLmFzc2Vy
dGlvbnMvYzJwYS5hY3Rpb25zLnYyZGhhc2hYIIZad0WBsyisu9AkwYUTNx43Eqqf9u2M3QeiDmfc
OIiyomN1cmx4KXNlbGYjanVtYmY9YzJwYS5hc3NlcnRpb25zL2MycGEuaGFzaC5kYXRhZGhhc2hY
IAgNSiZ1ARUb1ezQdVGdSpMbjmZYicBOli8mefUkwRt/dGNsYWltX2dlbmVyYXRvcl9pbmZvo2Ru
YW1lb0FudGhyb3BpYyBGaWxlc2d2ZXJzaW9uZTEuMC4wa3NwZWNWZXJzaW9uZTIuNC4wAAAQOGp1
bWIAAAAoanVtZGMyY3MAEQAQgAAAqgA4m3EDYzJwYS5zaWduYXR1cmUAAAAQCGNib3LShFkCEqIB
JhghWQIKMIICBjCCAY2gAwIBAgIUQOWgCu7COdC+uIP6BkIFPWdVEwAwCgYIKoZIzj0EAwMwSTEX
MBUGA1UEChMOQW50aHJvcGljLCBQQkMxLjAsBgNVBAMTJUFudGhyb3BpYyBDb250ZW50IENyZWRl
bnRpYWxzIFJvb3QgQ0EwHhcNMjYwODA3MTg0MzU2WhcNMjgwODA2MTk0MzU2WjBEMRcwFQYDVQQK
Ew5BbnRocm9waWMsIFBCQzEpMCcGA1UEAxMgQW50aHJvcGljIENsYXVkZSBDb250ZW50IFNpZ25p
bmcwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASYegpry1AYBRTVNL1CpTlbROnY3dey+UrsF9C3
phYrATN3ZHf93Mo8RQN0KOUuOn19P4oWNFWe5n2/She9N7eTo1gwVjAOBgNVHQ8BAf8EBAMCB4Aw
FQYDVR0lBA4wDAYKKwYBBAGD6F4CATAMBgNVHRMBAf8EAjAAMB8GA1UdIwQYMBaAFM5R4gSBTmRb
I/jjxM+aPpzB11zCMAoGCCqGSM49BAMDA2cAMGQCMDFzHRSeAXrSy1WOzkbhPZ6Km2wGTmZ/2gK1
8k8BQGXyqz88Rdrz6CTX9flAnYNVxgIwcF9c3fVhqmJKpi+UhasNUMko69cyX6STPfta3Q8EjyzD
jzoyrol46FP6VFHhvUcJoWNwYWRZDZ4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD2WEBKRwWhLiBvutO6KLg4esHMGbH8BxW6
QgyEmxvNPxNVXQIcvM+l6kC4pEpWv+A0k0Wko3v9DUvzcKFBssUYlG+m9Xgi9wAAAwBQTFRFAAAA
JCQkBQUFGBgYNjY2RkZGVlZWZ2dnh4eHd3d3lpaWfn5+VVVVpqamOjo6BQUFqampt7e3/v7++/v7
xsbGGBgYBgYGl5eXJycnBwcHuLi4Z2dnBwcH6OjoFhYWBAQE1tbWSEhIiYmJFRUVBgYGp6ent7e3
FhYWFRUVFRUVt7e3d3d3mZmZuLi4uLi4yMjIqKioxcXFaGhoNzc3JiYmxcXFxsbGh4eHJiYmJycn
R0dHR0dHuLi4Nzc3x8fHqKioV1dXl5eXJSUll5eXt7e3JiYmZ2dnqKioxMTE19fXNzc3V1dXiIiI
qKioR0dHODg4aGhod3d3iYmJNzc3RkZGqKioV1dXZ2dnd3d3FBQUd3d3mJiYRkZGZ2dneHh4VVVV
xcXFSEhINTU1d3d3KSkpWFhYmJiYhYWFl5eXaWlph4eHh4eH5eXl1NTUVFRU09PT1dXV1NTU4+Pj
0dHR0tLS4ODg4uLiAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQq3ZLwAAAQB0Uk5TAP7+/v7+/v7+/v4EBP0G1Af6Af/5
EZUQDnIQC1H/K7f8CxNRLtaQctOS09LVMG0SkdfT1iova82O0XjVUVVQL9CVcyuvUJZukBAqlJVT
KnRSliqMirUqKlW4drNVcSpzra6tsbRRbatMtnBTEFGzLWjZUY+nN3UAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAABnwmi4AAQAASURBVHja7L2JnxzFlS5aUZFrbVSVul2a6pGnu20JkJBaMJaEfWVkGWyp
PTAYPNi+gwd7NuwfiAszd/n7X8a+nYiMzIysnt+brvcu9hjQl3Ei4pzvLHHOZHL9u/5d/65/17/r
3/Xv+nf9u/5d/65/17/r3/Xv+nf9u/5d/65/17/r3/Xv+nf9u/5d/65/17/r3/Xv+nf9u/5d/65/
17/r3/Xv+nf9u/5d/65/17/r3/Xv+nf9u/5d/65/17/r3/Xv+nf9u/5d/65/17/r3/Xv+nf9u/5d
/65/17/r3/Xv+nf9u/5d/65/17/r3/Xv+nf9u/5d/65/17/r3/Xv+nf9u/5d/65/17/r3/Xv+vff
+Defr9dz+lsv5vNr/AP/ttf4En99jf/fHX97jf/fF39xvf7/jviLq8SfXPH6/4vhXwX/Wlyl/ZmY
5+9K+OfiavnXYr2i+Isrw59fHf5Erf8q5L+dzLcLuv+rq8JvcFcEnuzD5Er0/2K+F+u/Mv23WpH/
nBxeAFTueyKB9eLw8Nvmp/jPdr49+AfMJ+z+76/m/DcXoFn/qtl+tv9Xo/8IPNV/2ytQAETuq/l+
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
/81h8dcu8r8Y0/8e8e34y9H2/3LtJH92YPvLDrz+ywPjZ/+u+Ov1i8Puv0PHfxf5R8RfHlr+7JeA
Px7/cMx/Zf+u+l8fev3Xv275fxH4B4+/mwPLvzkw/xzx/OmAv/135j8HPn/8IvDH9D8Hjr9u/Ctb
HlT+F9mI8r84KL4j/zls/GnWf5wk/Pqw+Yf1L4P/H9j/b0b8AYc+f7w4rPy1D7q6OD9Ff8Xp6fnF
1XKZjYufmfGr3pfVqL/gxoT/rqkUjeJ+2r+UlP/udPvmpr77tRixBrmh8OH0dHtxM6/XfzHaEiwo
/UNe41e9P2Ou/3pJ4e/kP3/zrtp9o+Kvb24p+7vbyZ+Nib+q1p/Ch7u77e3ViNF/UeGvFzcXW2r/
7fBHPP0tWvu73Rr8z+J5NvL36o0B/9ViOa78Zv93+2687N+qxj+7frWzP3QSQK3/bPTP6P9vRgx/
i2Zj0/u/ws/GpB+r6h6WWf71cnT7P5z8tQN+ZZZ/ZPzK/5n4z9jiL9bG/T/6/lub+d/o+rft/+yw
+HvQv3n9D6v/UeN/y7/M54/R/Z/R/96+OrD9j+5/Dm3/NvzN8rD2N7b/sfjfQ+OPH383V//a/v/f
HX9t0f9B49/462/F/zeX/1/d/x8af2z+sbbhH3j9Nwfdf+PzLyv/Pqj93b7aHJj/H5p/jo6/PvT+
uzrs+XNzWPzlofmHRf7lYe3/Zr04LP6h+cdm7PVfW/LP80PKf+j8zz7W/7D7/9Dnr/XBz5/1j1jf
PL44f/r0tP2ePj2/eLHbe/sAr/EzHf/xjnuPjr/o5L9S8W8fX2XLPcm/3Oj63+Evm+aH+fj4uv63
F2+vssVmT+u/VOT/8OH89sXNZr4WV2mcb1UHgexVj39X4T+t8LPlWTZ290srf4W/ffr0bsC/ePGu
Mb9VNjoFyC7XN29vz59+6OR/+mFbyb+vb2fhr15ctPjVT9jhV/t/fb2X7b/7NjX+01r8u7u7nf3t
/N96D+bXmdfVi9vzDx922IP/u9lcLvaj/0eXm53/236Q/c/NcrHemwno/ufxq2W2B//T61/Cr9b/
Zg/SNz0I1xss/t2sN3vA7+y/9j8yfpbtbf2XV49vNfmz9Z7iT+X/EP3vTf7rNbr+e5Mf5X+PrzZZ
drD9X/O/w/LP/a0/gb/O1ofU/83e0Ndr1P7W6339Amz/7eL/5pD6f7FH+XH8PYr/r2l/e8NHzp8V
/9tsDoq/N/+DnX9r/M1B7S9bH9r/7s8CD7r+h45/6/W/ZPzPDhz/90j//iXl/9XwLwr/0P5vfWD/
c1D+tzt/rX/N/HOP8q8J+fe3/Q7MP9frg+6/5aH594bgP4eOfwf2/5vD2n82ev7fZP8vrg7OPw58
/s6WiwOu/4u9xr+rf0n+f9D9ty//txD1sN754p3fWe8z9zykIXZfQ/rX18v9w1+32JXdr7OH+8Lt
9H9Za79KBq2X2XL/+A/revemYh3XWVd6nO9R/7tfsqxq8dfZ+jJbftz/g9V+8C93+LuIt9n9z04l
jz7WtsfI38fr7HJZwdfzLrpHVxb72//ry53t1Rful/PLdbZv+bOHD2sDvL4+hPOpnc7l5VI7c+5N
/oeDy1sultcP967/Frtpe1nuadeJb6vsvH6DvdsDlx/vTeL2Bzys7K7qeVvvnN/l5f7tbzlfZ5ud
B9z9ns0+az/dd72oGGd76lzuXQE7lbfYm2yf1L/HX2ci7v4JyEC6DuMA18J/ZuvlAX7Auv9fNstD
KWBdkbB9lp4k+at9vz6M/ivHP6xA9uv7xDXfHPJn1N/ygNiVH96//dWwLfwh4l+z+Zr9f6CV32zW
B9t5SxH6QPbXxsH1wbSwFijIAeTu3NBB9l/j9usUyCHi3xIhI4cgQFos2Df8+vDiH+QHrA+8/BQX
yA69Fr8S+aX1P2T8aXOwhzp/1SRouTzImq+bQ8gh+NdyvR4I6OYwNl9Tj/q/lwfgv1nLgA/Df5Yd
9TqQ71mKRndQ/9eeww/GQA/l/9YyB9m//Yu/5TD+rzv8H4B/C4qvqhAHwN8MWjhA/Fn2We96A1we
auvXwi8P4f+b6vOmPQAeYAcul5tfY+Lv+O2/zPgL+ObdM+UH0n+NvfqVWMXiX80oK8UvFofF/7V4
hVXTBLA64PovDqzyo/89fsfv+B2/43f8jt/xO37H7/gdv+N3/I7f8Tt+x+/4Hb/jd/yO3/Eb7Vv+
quH/RX7C0foO/s0PqIHFgeqxi34F5odT+fKANrA47v2jAz4k/tH+jt/xO37H7/gdv+N3/I7f8Tt+
x+/4Hb/jd/yO3/E7fsfv+B2/43f8jt/xO37H7/gdv+N3/I7f8Tt+x+/4Hb/jd/yO3/E7fsfv+B2/
43f8jt/xO37H7/gdv+N3/I7f8Tt+x+/4Hb/jd/yO3/E7fsfv+B2/43f8jt/xO37H7/gdv+N3/I7f
8Tt+x+/4Hb/jd/yO3/E7fsfv+B2/43f8jt/xO37H7/gdv+N3/I7f8Tt+x+/4Hb/jd/yO3/E7fsfv
+B2/43f8xvj+/8dhT6KnepZeAAAAAElFTkSuQmCC
endef

define NHE_TAPESTRY_STEREO_FILE13
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
fEatxnEdlAEAAA==
endef

define NHE_TAPESTRY_STEREO_FILE14
iVBORw0KGgoAAAANSUhEUgAAAGMAAAAjCAMAAAC3vUTLAAACN1BMVEUAAAAB/wEA/wUA/wUA/xIA
/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA
/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIA/xIB/xO4
/732//dJyABRxABEywBOxgBWwgBDzgBJywBVxgBSyABPywBZxgBdxABI0ABC1AA/1wBdyAE+2QAz
3wBE1wBS0AA63QBazQJjygFhyQ093wAA/wBX0gVI2wBQ1wME/wBezhQ/4gA65QA06QBrzQUM/wAt
8ABS3AYz7QA76QAl9QBM4QIS/wBd0x5k0B5H5QEV/wBwzRgY/wBb2B8c/gE+7QBD6gRV3Rgc/wAx
9QE68QAg/wBU4hMo/ANc2yZy0SIv+QUk/wRX3yQn/wNU4iNL6RdP5h5c4RZ11hE0+BA59RNB8RNG
7hlJ7B0u/wV60itz1jAz/RFh5B5E9hI6/wKA1i962j1q6CY9/yZL/wOH2UBJ/ztT/yOK3ztj/wJy
7T2O3U6G4kpg/yhX/0Zd/zeW4Vl88kps/zJf/1dm/0eR6GFw/0id5GSF91h4/1Nx/2iH/j57/2Gj
6nGH/2KD/4Ck8HqK/3aU/2iT/3Ow8IeU/42c/3qb/4Ot9oqj/4i59JSm/5Ou/5m4+pqx/6O7/6C9
/6rC/7HA/7vK/7jQ/8LU/8ra/9Lh/9rm/9/p/+Tx//D5//j///8RPiucAAAALXRSTlMA98HGAQIE
BQcJCw4QExYZHB4gJiotMTQ2ODpBRkxRUlxjbXFyeoWNk5ZpxPdWktS/AAADnklEQVR42r2XT4sc
RRiHn/o/s7Odcd1IEEJ0IRLEqyB48RBy8ODV76AX9zv4XfwS8e4pH0AQEl1QdF027p/Z6a7qLrtf
qptdVkMCk/n1200fmufhrZmuqlYAFkWpDSWXSiBYq1BDxLI5Qx5CTqCwPV5LiWYDKYJOKicUruf3
MUqyGYek7frkHFFWDQJjtN3QcJWB6tq2r8GSlNVGG9sfWqv5WqmNtDG7yl3Xpjb1ni4pp42x1pne
tNGxGrqIKfWtROV6hXO2+rn7kjeLh4DHY5gBCwAuLy/qFcBT/eg8NYOkd1jrrLdHXwVeL1YX6gID
rFHAnDWgyKc5tPHiFODHB70jphSV7x3B2udfe14ZDVUCw1ygqLGoAeikmtPFed7Tf62ApwcpNr2j
6R3OBec+qvz/oCv+E71W19AJySVc2NOggz8GeB5jHePgcOJ46Bc30Tp4YQt8BKPWTGyBFzQ0oDhL
9XyVfPXeEcALccRGBetdqNoPdgCC1XjjEXoNwLsAHANLENEKIgCpsM+nAVvH3GZm9t5lAn4153Vs
Uj04vHf+wU6FZ8RTF16EacwTE/iqtFKjRROnp1rd4hZ38wr4rYlNIw4njoN9b/CJsQEFYripOANQ
RbKa3urGMKUlqPnd/RfAkThicXj3aN8BJ0uGK/o6PENNInBFJAPQIKehAyiGAGAJ2E921S/HcBSb
G45Pl38uOQHQEPGFXkNKdAh7DS0gYDPeeDA4MewCPASWIcafbjs+V6dExu4HNGlCQ1uImPHGj+iJ
TAXOAHbJ1dXLZ7ccj/9oBragbczXB6RjhENAsgsLKrjDO+Bx4EGM0pdP1Gd/P7vpcP6L318aINFl
Mi1AllPgauBmdm9xcYWLwVLuNLRtfXHyw/SbW3F8dtH8gwBTmwNoAOYMTPak8LAA5khmRq6ICDQK
pQEFQG5T/X35747v4MfLFSR51Cfug+BcoQQpPBaFAVOgaMVwCFsO5ILKZA7LOzjOJR/aSt7x2cI7
zDi+FgxiwiowKF3oGlXg6hpdUWSSb8tcMs6JB2DxBL/XSwxeg0NjMGgwwzkQNeU6wgtZFfaNfFPm
xGlufwKSneq+t1hm4EAPEgfg0YKWBrSwpUb07Ryuytw+rVGPKbHvL+4EbGaGzwHdBWlRobUGLeSi
eHW+uyxr1LW19skkmd/DMHMEcHi8wQpdaQT/OjnMeVxrt7Fn2MbeZxt7uC3sRbexp97Ot8FWvnHe
fv4FtHMXQhGNMj0AAAAASUVORK5CYII=
endef

define NHE_TAPESTRY_STEREO_FILE15
iVBORw0KGgoAAAANSUhEUgAAAGcAAAAnCAMAAAAlx6anAAABtlBMVEUAAAD/AAD/AAD/AAD/AAD/
AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/
AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/
AAD/AAD/AAD/AAD/AgL/AwL/DAzoBAXhBwn3AAD7AADtBgb/AADYEhP/BAH1CAf9BgXWGBn/CAX6
CwnYGxv5Dgz/DAnhGhr+EA73ExHyFxTpGxj/ExDvGhjVJSTZJCLJKyntHRvpIB3dJiPlIx/iJCL/
GBTaKSfdKCXxIiH/HRr1IyLNNTLgLyz9IyHHPDjoLy3/JiPbNzTQPTn/KirtNDL/LSfRQj7vNjXi
PTn/NDDSSET0OjnWTEjnRUH9PTjZT0v+QjzrSkf/Q0PaVE//R0bwUU7fWVX/TEf/UkzeYl31WVbl
YV3/WlPoZ2P9YF3rbmr+Z2b/aF//amntdXH/c2zzfHj/e3b0gn7/hH76hoP0iYb+i4f7j4z9ko//
lZP/mJP+m5j/oZ7/pqP/qab/rav/tLKMmY6CAAAAMnRSTlMAAQIDBAUGCAoLDA4QExUYGh4hIycr
MDM0OUFGSUpQVVlfYmdsbnN3e32BipGW97/D9wdyP5EAAAL+SURBVHjavZdZc9sgFIXvhtw46fr/
f1eXmT70uQ+d1LsRSzlghTbjbolGR3AxfjgfXEmAmKq4V6bnK6NMtQNwMeo8pNxCRsn4MdmyAKOd
NMN8QIgApQriipFaGKCZOJkSFUSqhTIoYGhDVerzOS1bDRLRgCMibAKxEs90fwAqBCigIWZW0VJE
lJWZZ+IUxRxTTCmWmDOzKNRQSN0ceStKRYUQUixKhaNqWqog6kSZgQT/kAJijIVj4tTUzL1MN/Sf
EilBCdFavnM80EVH2Y4hFMqYQmZRB4rZ6xX9swz2zb3Z6wTKpy096LQJAaQxJhZzZmrOrW/+7v7I
XjtIWpP4sEs06XgYx4IJYygcZ7hsePPn5CDYo8HDngnSabkJp23n0L0vkLFUcFyhOLd6eQ1BZiVQ
hDGsr82BEpE7XkCHnQg9aHuulLFw1AZghuHuCgWeldBZzVqrfVGgiyLF2vXaObTzHiAfIjjI2jDc
0h8k/QaBoJN/QJ3gUBalrr33yFzlIG+ucNb0RKUJMU2061A4I/IW2dp8Vg6cuXUYz20+oXKcDi9s
Ho6QkUk1O/hwH04+jjNyxGBupo6MnCCb43G/+do5T80brEleUfc2ZSMSJRZKeRw3x/3nnrffPQep
3dmuAWVFGDTB+WJNRkLVu7QlKAlzzmPwu+3uY38Orj7XMbEjyJRuMVr07ogAQJfgzvBu5ozYthQE
zime/X5z/6E/19fe0yyr2kNYYegmpKbgwFWAqQx0+lmpVFxQ4ZwL531/T6+sO8PNnYPpCyAEKCUU
uCNAgiKMiMCIoLQmx3A+7b5vPk3rzpV1VNbveMWwA0XRKEGu2qMC2VrAEH89ZOYUgz9vdt++9HW0
7wu3bTEb1rfO11lc3CFrtf/R5/XQdOH04Y/H/Zdt3xf6Pve2vmRrMlMPs26rE4MUlr3+TimM3p/u
v/V97ud9m99hlCBRPuH2PHIbJtRfFSmeDl9z37eXOocsdq5a6py40Ll3qXP8Ut8lC31nLfjduNh3
8DL6ARTAPEa+Rb1MAAAAAElFTkSuQmCC
endef

define NHE_TAPESTRY_STEREO_FILE16
iVBORw0KGgoAAAANSUhEUgAAAG8AAABxCAMAAADsxw25AAAB3VBMVEUAAAAREBAWFRUYGBgcHBsd
HRwgICAhISEhISEjIyItLS0vLy86Ojo+PTw+PT1FRURGRkZHR0dNTU1VVVV7e3sVFBMZGBcbGhkf
Hh0mJCIpJyYtKyouLS0wLiwvLy8zMC4zMjEzMzM2NTQ3NzY5OTk+PTxGQ0FIRkROS0hRTktTUE1W
Uk9XVFFbV1RZWVlfWldhXVpjYFxmYV5pZGFrZmNtaWVuamdxbGh0b2t2cW15c296dXB8d3J+eHR+
enWBeXWBenWCfHeDfXmDgHmGf3qGgHyJgnuJgn6Ig32Lg3+JhICLhH6LhX+LhYGMhoCNh4KOiIKP
iYORiYKRiYWQioSQi4aSjISTi4eTjImUjYaTjoeWjomVj4qXj4uWkYmYkIqWkYyYkY2ZkouZkoyY
k46ak42bk4+blI2ZlY+clY+clZGclpGdlo+bl5Cel5Ofl5GemJGfmpOhmZOhmZSbm5ufmpaimpOc
nJyim5WhnJWjm5eknJajnpmlnpiloJinn5qmoJuooZqnoZ2poZ2oo52qo5yppJ2ro5+qpZ+spZ6t
paGsp6Gvp6KuqKKwqaOwqqSxrKWzq6ayrae1rae0r6m3r6q2saq6sqy6tK68trC/uLPAurPDvbfH
wbrOycInFDFIAAAAFXRSTlMA6YR4PJYPWd+v8tnCq3KWAxwrXA3coAh2AAAaAElEQVR42u2ayZMd
15Xe75xz5pvnejUAVQABcBDJlmxaCi+6t/57e+GNFLa7JTclkgBBAAWg5jdPOY93cMALh23Ua1Fe
OaL5vdVb/fI79557Im9+4Bf9ol/0b0YQ3KtarBhSoAU+CIGfKQk+aA2gLKHt/3xePWAtBBAEEIK/
WUoBJQXYlN7u5/GYoi2AIfrwQ+hvB0qgpJSVECtY/gyehlv/E0Q13anVHAUAwD8PJMAHlSXI83ib
5RVfiuKv8WpJF2GEsOHUrTv8H+abp/pNuemepOtNbBzPQTnOjG120pzfkmD4E/tkWrKSIaUZ5E6w
3AUR5CAfbrzu3byUWTG1/H+Vx3CTIITNelJSLwAV1lHJtAwBIApqh8DMJCIskzQrKQJmpSSgEuBS
aEoqhSTHSiElIfAMUKRBhW7E/1bTj0pVk02CMfNwJQWWUOi0dDAsmkZE+jGtgQoMOZD1eg4MaBjC
y5QFAALYFVJi16wgkTrkpkRaGUdCGVjZmZnv54k2wciAiBdQ1ySlBn0KzVqg1wyNy97xFpSN41hm
CoFHUEomdA12bKFMxD0MKoMr05SqX0AKlBCKCiKRExV7eVrnA44jCpFGAdc+8fxasUr+Yxn+uqbT
1qpuUm1rEj34O3GphqmStMJWkXtmWCP5MY9lQ+tETss3ZIExhRIpAJS3lXt4jFgYa1JHEGgISKuT
bcEqb7P58VkhoHOJkvwprtqqhyTILB30WWC0UlpJyNnTRXYWqIMHS1cGgjgZFRICKBCUuBGI+/cL
7WPMGAQQqUGe4YcZVCdXY98joBv/M2oUYyzzRasyd2B03W//QbW0TOHMtrOt5JmDBQCffitbgSya
cJoZIBcQiyqXYBLe66/hYUx0qBBg/aSm6VmLWtYGPplExoKNGk/uVLMWtTXYb9V+bz3zFwzoA7g6
tTKsuS4DIyVE3UHcbd8FqOfrXogQEUAIaEfiPl5hY0IpZEAq4VY4puN+K33YBZ0rcCIa6L0zpnoL
FgFsbMDhq/MHCf0SSnBxdNEYQr3Doo7rvEeujtAhH45SvMJIqzDBQIjwPl5N6QQDBCuiQdZM0rMB
CvWMwNQ4bJv2dRfzfv7asTCFsdukN73P3JRgu3ZYnB+7jhlfWOymf7LihKet0+kmSSpgCSUA4EKm
5T08XofK0ktFO3nlnH7qwCKDBrk2275d/ufTRtRE0ocW+MOoz+ucPGm/8LzniyMtdLy3WvTDCVw8
06Tem/WcwfKyymnayxIJOSJSCpaJj3nQhFQnCuq505JpTRuOnXfOwMiYU6XHoRFSDThUlkm3YFoW
QL0FNgZP3TSivll2eNkWB/EdO0Y/wUFLGIfresz+Qd9IDHJZxvJjnq5BAyNoQI5qX0zP79KumAxL
Q857GGqhxBz5mlBme0Fy3+Usi7EWJZ3CNH6066txScE7DdjIXoON094slbfJHfAWdmJZCS6Lj3nE
QBoRUhFHT2eP7PI3V/Dw3PTmBxqE0z5b1QtgU4JNz0c9nVbfwlHUOCjTFltSb1wVUGtQFTLfrUbO
xVFzscAy2wiHO2lZyYgDAP6v2V0ogLBGMZdIP9w+/k+6GNXxWKNGPH07QJNesXHKiKPVLnJZtsue
nd2WVqqKt/HXj3/4USriENxIDbvYLaP3zKqOSMPAX5t+ZqgPlI/9dRXSKIRYaWjUia34ph0bJaKM
xa6DsVk4NDfERUsTiv8UO/lAZRbZcvOHTiNP2aF17qEfuu2IQI0peBOOLfUsXUhOOIwrmVYf80yk
McwVdQpU3T55+fp31U1xGBKgLJ5yU0rEUs1sVcLe1Z2GRReXRxve//OvPsVRcFpbkqNU2Skx4zlt
WqHTm53jRZ2mvrTjvAIs+phnIWJolUYTgqoHg96V2/AcjW62ro6RMd96MOVsrsILEDTrk7wOw385
3dksMQPfsd7GszaO1Vxr2fgH1muTN/NmbWF0WI22+K5SKvyYZwNgUIA5PhjoV769UukENlNdx3e2
wU3vnRfl7o41a3dtLXndY3LltsFVm0+zh9ZkzUfJelr7hK7D6mCwsBMyEnpyO9X777QgEErew7MA
0WBFpOkFBMb5k0e9JsOFZZxToIcm4JXWQakeNjt34++H3fms/az6/XDg6DvmC/ug9/3iH4zdBGW4
g57j2qWtxzQyEVDxruL38kyIDaawruE0/byVPzmvHATsilR17U0/0dwXQ7LJ/Uopnhha/o4/21xm
adfIze97PTN482wos/92cJDa19NTbt46o3CEHl2XJ/Yuq+7l2ZDZCELqRpjPvzJfKq7BiFJkZHwM
qPjzw7sctnJZQJ8ehI5uy00/qicmfOWe3RFjxwqN13Q+D542MqLaHlxPTrc3VqHgtry/nohouFQC
CjxeXepng4HaNN7xu/UJwXm6Ng6adzdeMxtU6SkKace5OjbgaFZDpJ3aW09tlLEj7XetNtVQkF11
lkq3dom3Nif71g9qhsQagzWtNYiOW+udXZt3FHokSVaqdq6zOmlUSVUevfCaL3p0MTuycrQxW0VC
C2fVbone7fnXzVlkFdtp2yXMfQ0erX0N+1yB4J56KsgIUS7rPpyve4ffdpygZhVMkwnYuoV2KUvL
fLkZnudQdr/PrbfqyWRbNhbTON0G3dyWteRtM6mzK8C4KWlcV293zElMc1qWSgX31ZMyQrkw0evm
17OrJRn7ifvGM7YsqJol6bJbbjXz88Pl9GR6dSrOF3Ugi56Zj4p5aqXmxFg8f3Q8zXrOPBk6EqmL
HCej652LlvxenomIZWUYK91ioHGyPM+awKpMBiB92aMoiI1XjNFhtztAb37Dl8dw1t7mJjE8r+cl
HnyzftoBRiXhopeajsxEz/Jbr5SxaUyr+/0BzeGVBkSW5b6Dwi8/dYUm6YLadudyuvUb6ai1Uown
haOtmenl02LQiOcZQ9Eyalat3TmdE/JD3aF2KDJBK3pDYGz//U87cS/PhhhrTBFM00fH4fNvesWP
0Aa6Y793+fwLgDtVa21657dqcDFYXpcDsWs0xNV6VG03mOVH7p3/8PP0clCGcRPmVjOdJJy2qRZd
Z3zv+tFS1iU2k1KO++HrF+O6/w7G0/b7CcOjPzr4Bqri0MpagXRUhGubjVsTeOYctLa19Y9nxxY2
HTC3aK50sINeKcCsGlyIrNrjDxpYKeEk7e6VMXx+87TS+tn04NURvWFxW78xV7t029rhOLFa2qK9
QJ1+KU4CQ2oKCS/Q7eRFMipbnVlNg/N1WzPeB7i7JiCo9uwXZBAJtUyd1KZhvTt+0XRA0w1rCx2K
xuFda3fd7tXHzw3r+0fFvM2KXd834XJ4qH83eRK9PoET83g9LS8Tx1+XmkluzCt4Vtv1dts99YS6
qUodCzPwv561NymrD0QIozenzqZuQzr75OBSG4cNHGntieBQbP3H5sT7yQ9hY0FXXbXDdrA9zKGH
vHHocm0SjbJQ5kF0P88BhJoYI/oNAzXrXdAhjL27QujT8I3eNF6bzY2sQv8dOssTUnbX79QDiHK6
ATf5Kb8sf3vOB2TZjsxjUrNKIK4cstbKIGijWSb2+CMUKgDgzFSbzdC4ajSyKjiNWvOrs+D7Rtp2
1ytTf+rSbLoSo9HB0U/RxD/MHCfuX2St/L2lI+G5kZfJHyjQrsqtpwTNMxyIfeeLwZCEWkPm6ZBQ
kv1am24Oxo0J/tww0jNjMmJmM7xq7b4VzrAUyqiUW2u6y8lnQn4p5mMSp/XvHuO3RmyP9NteHdWt
G6rFZhnuOV+gRhGioDQ0UCTq4Nmr/9I5qW+37Ai/yA7X25NkzVrzi1xTuLs8Qv+468f8NH9BVcyz
7g/VaOnUVGfhDyHrTKq+XLZv1gXj8CBcyz31RFRRBVs1v8lylCxXT50fxtWLo+Aff+PpN5J/719s
UriqP8j6zStHtG/QCkFsOg9xOh9Yf/nUsl512jO9a6M3u/wuaSKtWnMD5PH9/eBAaFNOEMS0d/uk
+2iMZPgZZxmVk6MfJtcQfdZdoNE3db+38sGoEHjROLzbApHgzY7Vh8ZdVNR8A+O0AssHroYWdmWm
Bo232b5+wAZGBHDt01kkNkadXmxMsRvZFROPw8OTAwa2tdG3KMHTsNVVBePBE3pH8y//bPLMlGZz
m3T+5e5pNbWIcUCsadz3g5SpfhjIPeunY0Iq6oRq9mVB5LuDOYg2eDuOGg6NOrf49e7I4s+38tQM
Dy+mbXSlGUGa46g6JBWuZh2Mzn8NZ81aGbPsx7RhWJuEd9g6L/fVE+iwwJ4Wy9rVs/bOyQ+6l6Cu
4CS6BsZLp8kMidPj9a9q5Wfvb/ht5qOSOIEeanJcbpd2uTip0+GiSVeJ2SC5kk1H6cmCtNflnnpC
kwi9wPViiLqosyIih3CRz3/XuozW+NFV7EZq5Tcv3rYh551+wL142Bjs6hFcrQmjpBF3f//jN0z2
sz/Rg01BRBJTWzXDzZ71A0jXuYRcVKhxES2HSaLP9XJ8AMKo9ZmTp2mtPHV8Z9Gp/um4ViyPHk8b
YJrgMuz2pedKMy8nX2Estjxs964WpB4XZdCue6vdHh4kzCiwDRpaGHsPmpNJpze/cR/l/xVvTtk7
O+1e35CGv/0iB+5SpHayA+3/Xlfb7IllvJnErrP2auogvFotj3pJ1RJbHt+SwuhuVvv6nWFBTCAG
HH/T+Mu8qlPROWriN9BqRRb+y2lr+uWrG8/v2M4ZmdQ6/lVZGuOyGh1c56PmqP+ilkSTQjccFeS+
gYKaG2klN/OrlO+Zf0hHAgkAKzxw3ti/hVV32vSqJqscywbpcD7IJ7J5otrTNVkZyMi9M126gr7d
DG46+OWZtVCf61eDduwP3PVOYZU8cTaBqtJyjz/KNMgpwWZ1mf/dwo7pW9NI8iF4bWvL7Rffn4k/
G2T3IHlRgNwk4EXyO3ghJ42LDAcsL4PVtK6T1oiLrR5PvYcCZPAuxejLu6jct34aVQ7EOOIDEXW3
Rl+vkJzIJTrqvHVNQBed+eDk8rX8JLd956V3rM4jTCKGs8aTBLcdXVTifJ3js8aSPcGlYB9OBC8O
9s1bpGkIIqq51rHRa80y0ABMjhUSA8kbMKzkRnsy02T1zCz53U3r+O6S1mSAHte3/56o9mVb3/L8
eMaZqnau/dJOnPLGOsleO+u95xnDlaIykati0SoDe+US/1KVj9bn2Ilnbv+2N3Tn82O5Maam/qtt
qXoGTKOex+7+tD24hSYzLbPR0IIkl9NxnDQCoKZa7SLft1+ATSsLZ3SYNnw4bi0tWB4PW+7F5nPx
+xxmqy8yIJ7DaIX7BlOvjh9NR/NsFO1Ez49pdDLI8rtWctkvazCKRq2FUBtBUXG22Yh9/UAIEdx1
vZILNevPtKaTbm19fVjdmF5rsdrd3jbEzP76fWw1BvO7TV28tUc7Gy6FhaVcGDeqnmd+b7b8dTsE
cSVZ5S5130/2+SMaBJXW50XaIs1W8eV3zJ2XywtpfJf36nRrOVpu/kpOh1UI9XVWxA9WkV2N88IM
wbhYp/mDVmNrw227U8tvqRjMqbeOPbbI9vgD2EBcx4nInzx+TrFoHD2vHbi9lbksn4zzP4IxOeuf
d5tswu1aDD31lHRV4Jh21JRn9a0Lrp6xV6sHYdL1/rh0wh2zdoKdTJDc5w9hRoWDqmZxcgeIeRjG
454/y/vV+ktVhiid9OTLch3ToVMYXnR96m4KFR3f7A7OzequbcW2usM7YPans193d0/lLpG2JKkJ
/o9+QOB/SSGiUFoa9cY5+lL4OJtfbsqDOOl8ZmwmJ1/QXiMukDsOgLNbOxlR6uaSWymSWbu8BpBx
wrXRk4pK3VmvSdUCWjTzFxbl/P77chMCjUqAxRp81YrM9U+PikyynFgSvy9nrneFx8tvfOk+vIud
o1Jf3MVrp2HIFtOH/gDVBBpeVxkfBsCl2zv7LnKaYSzG+irdc346ChGNAsQkScv14ekJLHZ9+X7X
T76tnsCl1jq+e/Vk9HzGXX2VTP1/503rfaNQNXJD5Aa/ni3q8QN8e6KX+Faypkd320L7arfE3Bd7
+p3qAGDc16sM1OXO3kKHKYfKS/3Qbh/eWtX08e35J6JDDLjpo5d5r7DC9y6DxcJFPblRgTRF36P+
KuQecmBgz1HrNXPZrtrTf9BEBQWRxA8k4nR47aXx4PzMPerdIEDB7i4ZnX/iTfPdZf3op87gRtm7
TqBNAozSB+9aD0ZkXDlJtbbjcQgTI+qMy+XWLlEaVPvmu8GkAAgMyLrzqL5N8G4Il4eEbM3XfWN2
UsWHa27i6QZc8wdRZUz1Q4hsTpQ4EeePs5tHZebXZhJTKzkeZVWySo940lLbcE89MaVKMUqxbWYX
PE+g6aLnp3KZFQ1DFFHmdJb5nNoF7z24ON7xRPPdddGq7wTOYh4tQyTyq+qknc6PB7PJtje9axTu
0hBpvvf9VqMV0krIy7Z0ehBz8r42ihNrjLLIANMjeRt9Dt83OuO2p2ZIx/2wMk1V71pLj07r8O4x
236VXR0txOHb7RfyA1/2o0d8u2/+AQaULjEUIsXf4D/pF09MbY1OZfpK03VrabR8OIgP7Qn79hT4
HVoear31BTLEbhNx7+lENreOacp3w8ffFc/Ie3xyaTsxmiySPf4AYQhgiFrA0Z7W/2I+8PWaZ8O8
ISLB2j95h4Q5d3BOYIoFiOFMvs9zkzbkNl+VjxsvvN6sGKufyLCrXWR6vVQ5dDdb0JqlQonwPn+M
UQBMUhzxgv10bC8Zz1FdfdfNdOoLt+3nNvforrUZt2beZuCGX7l2yx/ZV49OQiCWp6uBqCjVGn++
/Lp3Hexk6Oeth5cHi1Ttua8DGpRAEJD9/SrRr6+ObtafrbdVI0ItXZvXDO1q08vqR/+sHuRzf0hX
B2tvcuWPXmVm5vTCHgZxmDi18kfxoHweGUNircumn9Eo2XffiizFGcCd4D226yE8ajv9+OoQvezC
t+SU0Y01ky7/ffrb9A+fom0NHhZXaRmwlvPdTRHH/OYoZX9nTvhAzSoh2q4bQxxn5oZnfA8PawYg
Ok8NyHfxsffmtP+Kn7m2EU6Rh9EuOIRJUvUev7X9rdOd6aXkR3Eytl8PadQzWRkO9GSx+yTfWuBA
ruHVDFKCoIiyvf4oBQQgzeN8MLqtj4utBkpJIhbrh0lKqu1MA5a5rG26w9Xu4eZNOrJ1W67QM608
tsyjdxdClqfB++ip/b1dEMSTAOs7JatKiuhengaVUEQ1PncPumtSz//Yq4vFPz01dZnlrIGJTVcy
Kw/JNP5Mv3iw2T0FLwTfHG1v6+lcre2S1t3ldd693o4TuNbXjvJLIEEkxLb6mJeZiCEIKFLJNQ/n
zZtgqN+Io216chFHI7Fzr6ZxAzp8yRr+O+4adbME1RUvP4mvSS0oxV3nrJJZSGudMm1VO+CPEmLw
hhaFUsb83u9VTClYQUbKuMhSRy20aFWvXL9HLpWxfF0bxdCIe8HqVuEkOoE/kvy81uhdlaasaBrX
aVozr+BDx7S2QQJZ4aukgLo1S6Uqyo95lCEGEYaEA/o0qnSNgs1Z/bzov9bgs9AtyKlxVcq3pbes
jMdx6q9yvG5LlJEjL2Airfo4NaGx2OQzEbXEovS2Okg1uMoKJariY540oaJIUcUBozFCXK7tKifV
7mtrLsikdQiX2VDgomJPe+frjKAROapKFvWXXshF8Xn0/ovopdNJM75zcpgD5UDm2GmYcCll9jEP
GwphACEiCgXGA7HxqWR6jSyPXt8W/ASt9EoVS50hPijOa5WqJhowlmsP9/hkqx935mpGlpFxhOIM
2FA3c1EWMolBpISs7uG5OxNSCBBEDGC4zFKXJHYRHA3LpVsH1rvMj/NQJDv4OL9gd/A4jp6tZ3qe
iKPdDJrs9aYqIfbMGcMR6d4FBawIEr18x6XwUf4xL0cmxFgBAAFTFeYGLmtsHa/NuW3H2/crh2/L
hG571XUQc0NN8eOCL0kF8rcy7Tffh9ADvOZLGuqbRIsQEDmVwszXUsgqAB/zQA0BiBBUSEiglNLT
WsloLPLYXOpJZ7h2T678incjv4gTNy2QvxB6XkpKIuRsggIeiTVaKzfJtCzT09zxUGYvFkKpLc3v
4+W5ARFWmChSQVRCi+5yATRTrj48Jgu27QBSD24AN+uhjiuvLLmAfBSkNMOCMWGuAcuLVQXtChek
xmIOkkQJIfz78xM0NlSFEVBSg4IpLbFEfshTnBrK3gWWeFuMxdr3jMS1fGSXYV2LSsXWJfGgtGOV
BAdJgXNdVammASgzIIKdkmKnp/fzBNEBEFQBCFQFQKKk0uOdHjXTIpWyQMjaJRDKUiU+UzmQmcCC
0dTQ0zDNPZ5VgmM3AibOVZFIqOWhr6SUcLMvjyILHQKhkASapBJpUitzKFhRaBnXDAAziHVaSh1I
JYCEAOeQJNDgEDKRC6AKDGKFOK7BymyKIAyVFCLe7c/beJEGgIAQSQalgAQJSYkwMDhQpQsSoEFQ
0ApRpSecQsSRrJSbcwmV5PhRVlq5xKbIbZpo5SbMPuACLd3Py91IB4CLCnApJMElREKvuJbA+g5n
wgF5Q0FcVAiXpKWcXPQEUVKZUEr8wSQXmg6FHmRys0mEklIE+vpfz4O5BlRQQWRCgAhAQFGWYgSg
AgoBhZxtqSEBlaSqAkQgiKEUVAGpONYF4EBgVEnOFQRSSBVD/6/lzxppDUAFAQQSYQGRREgiCBQA
QgGIJQASSQSQlAoqgIFAEIAPfxESGEgJMcQCICWA2Bmbn5Gvq0kbAAUggAgBgAXAAkL1gQA4wgqK
ChBJkYJSAoUhh0BQIABEJSZAAQmwUkoCgQO0+3n5QaaLGoQSAwTBfZII7NcHIpBqR9Hub8hHIq6k
auyJR/6VgOQWIkjk3nzkftUI+H8Q93+Juf6iX/T/pf4H3eilUUGOYjYAAAAASUVORK5CYII=
endef

define NHE_TAPESTRY_STEREO_FILE17
iVBORw0KGgoAAAANSUhEUgAAAG8AAABxCAMAAADsxw25AAACH1BMVEUAAAA3NTNFQ0FNS0lWVVRY
VVNaWllcXFtcXFxfXV1iYmFjYmFwbm10cnF2dnZ6eXh+fn5+fn6Ih36Ni4qMjIyXlJKXl5eenJqr
pJ6zsrC4uLjHx8bHx8fIyMjLy8vMzMze3t7h4eHr6+vs7Ovx7u3++vYvLSs8ODZBPjtGQ0BNSUZS
TkxVUk9UVFReWldjX1xnYl9rZmFuaWVwa2dzbWp1cGt2cWx4c256dHB8dnJ9eHOAeHR+enWBenaC
fHeDfXmGfnmFgHmFgXyIgXyIgnyJg4CLg36KhH6LhYGMhn+OhYGNh4KNiIKPiIGQiISOioOQiYOP
ioaSioaRjIWTjISRjYaTjIiUjYaTjYmTjomWjoqVj4iUkIqWj4qWkIyYkIqYkI2WkoqYkYqakY2Z
kouYko6YlIuZk46bk42bk4+blI2ZlY+blJCclY+dlZGclo+blpKbl5Ccl5KelpKel4+fl5OfmJGf
mJSemZShmZKgmZWgmpOhmpaim5Ojmpahm5ehnJaknJWknJijnZainZmlnZmknpmkn5emnpekn5qn
n5unoJimoJuloZupoJyooZunopuno56qop2qo5yqo5+ppJ2rpJ+tpZ6spaGrp6GupqKup6CuqKKv
qaKxqqOwqqazq6SyrKa0rai1rqe3r6q3sKq4sqq6sq27tK68trC/t7K/ubLAurTDvLbFv7nLxL3O
yMHTzMXe19D27eP///9//hvuAAAAJnRSTlMAk+V5r/3i8Q8eOtFtiqJQArnToluPeeWxlFOsrCGx
swbSDeLy/aixB9AAABwASURBVHja7drHjyRZfh/wF95nREak95WVWb6r/Ux3jydnF7taJwgSAUGA
AEk3nkQBuulv0EoHCZAE8CAQEiRAWnJJUUuON90zPd3VrrrLV2ZWpbdhMrzV9CywAtHZ3NXyIoDz
PUQGwrwP3ov3Q77DA9/m23ybvzWBFl8WXBbHEOin4LfIH0SB6+m48pt7lED/W/A3yB/8NAL/XNOt
38wj4+xPwd8wURRC4e/L9m/gJYR/81sAC8A5E/1T9dd5AvWffvWG5QiBQ0FeaHBYFNgOxnggICMo
dCk4tGCbe5LIGz7qowhAEKCGuMsAGw6AXnSIf/mvvQBz1H/lKX+tR6b/Hfgm6v/E3/rjwIJXmYNy
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
A3CniRjHokhiAAAAAElFTkSuQmCC
endef

define NHE_TAPESTRY_STEREO_FILE18
iVBORw0KGgoAAAANSUhEUgAAAooAAAGQCAMAAAAeD7HeAAADAFBMVEUXFxcnJycDAwM1NjXY2KVG
SEZWV1VmZ2Z1dnX8/Pzm5rGYlpGJiIa4tomNAADIx5caIRnIyMg8QjuoqKe1tbQiIxyKiXOqp41n
Z0/6+skdHiCopXhyAACXlnBCRTjW1tYeISHo6OcGdwKinJX8AADz87oHaAJ2dlEPhQJSAADR0Z09
QUKHhVovAAChnnQDRQIDWQPg3qw7OBMEOAJnZDrAvpBcYlqapKpYVS07PkGVnKVZXGJ+gXivAADs
6sYQ/gCCfHbe4Ky4xNLK1+giGxXIx61SxwF7g4pyeYIjiAmAdTbyFxQv+AZdYmYDtgdAPjsElQGB
fVRHRB2vuslJ5xFO1Qj0KCZ9gFx9cjT7MjBhXTXLAADX5faeoJz5amc46AD1V1Q73ACq/JBBPhhm
ywuzsXy+wIy7/qv5dHHh3dqR/nPZFRXX/86N41XK/rnvIB7/qaZI9Q910yrbJiPUOjbCvLHrSkb7
ioZa2iNO/ixhXlZz/Uz4YVz9lpMBpwRn/DCboneh7HLDzuIAAAAXFxcXFxcJwgbyQj5z0xV1/2WX
kVyX/4bUSkYA5AIqKiosLCw5OTk7OztT4iKF2D2E/V6krcDcVlL6gX3/oZ1bt2Bd/1Nv4iCAbziF
j6GfssSN3Uyc5GOgn6G+wbG7zuK/0eHRQz/dYFv/srAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAADbuH2nAAABAHRSTlP+/v/+////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////
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
rkJggg==
endef

define NHE_TAPESTRY_STEREO_FILE19
function (event, funcs) {
    // Tapestry face script. ES5 and small on purpose: if a face script throws,
    // mod-ui silently disables it.
    //  - LCDs: Drive / Level / Mix values and the Format name, as text in the LCD web font
    //  - red button steps Format, grey button steps Tape; the Tape labels/lights are click zones too
    //  - Drive, Level, Mix sliders: drag or press anywhere along the channel
    //  - the machine's picture follows Format
    // mod-ui doesn't echo a script's own set_port_value back, so we redraw after setting.
    var icon = event.icon;
    var d = event.data;
    var NAMES = ['STUDIO REEL', 'HOME REEL', 'WALKMAN', 'VHS', 'POCKET RECORD.', 'ANSWER MACHINE',
                 'MASTER REEL', '8-TRACK', '4-TRACK'];
    var NFORMAT = 9, NTAPE = 4;
    var CAP_TRAVEL = 207.5, CAP_HALF = 36.5, TRACK_H = 280.5;   // CSS px
    var RANGE = { drive: [-12, 18, 0.5], level: [-12, 12, 0.5], mix: [0, 100, 1] };   // min, max, step
    var DEF = { format: 2, tape: 1, drive: 0, level: 0, mix: 100 };

    function clamp01(x) { return x < 0 ? 0 : (x > 1 ? 1 : x); }
    function num(v, def) { v = parseFloat(v); return isNaN(v) ? def : v; }
    function idx(sym, n) { return Math.max(0, Math.min(n - 1, Math.round(num(d[sym], DEF[sym])))); }
    function dbText(v) { v = Math.round(v); return v > 0 ? '+' + v : '' + v; }

    function draw(sym) {
        var all = !sym;
        if (all || sym == 'format') {
            var f = idx('format', NFORMAT);
            icon.find('[tp-show="lcd-format"]').text(NAMES[f]);
            var pic = icon.find('[tp-show="picture"]');
            for (var i = 0; i < NFORMAT; i++) pic.removeClass('tp-tape-' + i);
            pic.addClass('tp-tape-' + f);
        }
        if (all || sym == 'tape') {
            var t = idx('tape', NTAPE);
            icon.find('[tp-led]').each(function () {
                var el = jQuery(this);
                if (parseInt(el.attr('tp-led'), 10) == t) el.addClass('on'); else el.removeClass('on');
            });
        }
        for (var s in RANGE) {
            if (!all && sym != s) continue;
            var r = RANGE[s], v = num(d[s], DEF[s]);
            var pos = clamp01((v - r[0]) / (r[1] - r[0]));
            icon.find('[tp-slider="' + s + '"] .tp-cap').css('top', (CAP_TRAVEL * (1 - pos)) + 'px');
            icon.find('[tp-show="lcd-' + s + '"]').text(s == 'mix' ? '' + Math.round(v) : dbText(v));
        }
    }
    function set(sym, v) {
        d[sym] = v;
        funcs.set_port_value(sym, v);
        draw(sym);
    }
    function pageY(e) {
        var o = e.originalEvent || e;
        if (o.touches && o.touches.length) return o.touches[0].pageY;
        if (o.changedTouches && o.changedTouches.length) return o.changedTouches[0].pageY;
        return e.pageY;
    }
    // act on press; ignore the emulated mouse events that follow a touch
    function press(e) {
        e.preventDefault(); e.stopPropagation();
        if (e.type == 'touchstart') { d.lastTouch = new Date().getTime(); return true; }
        return !(d.lastTouch && new Date().getTime() - d.lastTouch < 1000);
    }

    if (event.type == 'start') {
        var ports = event.ports || [];
        for (var i = 0; i < ports.length; i++) d[ports[i].symbol] = ports[i].value;
        draw();

        icon.find('[tp-step]').each(function () {
            var btn = jQuery(this), sym = btn.attr('tp-step'), n = sym == 'format' ? NFORMAT : NTAPE;
            btn.on('touchstart mousedown', function (e) {
                if (!press(e)) return;
                btn.addClass('down');
                set(sym, (idx(sym, n) + 1) % n);
            });
            btn.on('click', function (e) { e.preventDefault(); e.stopPropagation(); });
            btn.on('mouseup mouseleave touchend touchcancel', function () { btn.removeClass('down'); });
        });

        icon.find('[tp-pick]').each(function () {
            var z = jQuery(this), sym = z.attr('tp-pick'), v = parseInt(z.attr('tp-value'), 10);
            z.on('touchstart mousedown', function (e) {
                if (!press(e)) return;
                if (v != idx(sym, NTAPE)) set(sym, v);
            });
            z.on('click', function (e) { e.preventDefault(); e.stopPropagation(); });
        });

        // sliders: the cap's centre follows the pointer; the panel may be zoomed, so
        // measure the track as drawn
        icon.find('[tp-slider]').each(function () {
            var tr = jQuery(this), sym = tr.attr('tp-slider'), r = RANGE[sym];
            function apply(e) {
                var h = tr[0].getBoundingClientRect().height || TRACK_H, z = h / TRACK_H;
                var y = (pageY(e) - tr.offset().top) / z - CAP_HALF;
                var v = r[0] + (1 - clamp01(y / CAP_TRAVEL)) * (r[1] - r[0]);
                v = Math.round(v / r[2]) * r[2];
                if (v != d[sym]) set(sym, v);
            }
            // a press sets the value where you press; moving only drags once past 3 px,
            // so a slightly wobbly click or tap lands where it was aimed
            var y0 = 0, dragging = false;
            function move(e) {
                e.preventDefault();
                if (!dragging && Math.abs(pageY(e) - y0) < 3) return;
                dragging = true;
                apply(e);
            }
            function up() { jQuery(document).off('.tpdrag'); }
            tr.on('touchstart mousedown', function (e) {
                if (!press(e)) return;
                y0 = pageY(e); dragging = false;
                apply(e);
                jQuery(document).on('mousemove.tpdrag touchmove.tpdrag', move)
                                .on('mouseup.tpdrag touchend.tpdrag touchcancel.tpdrag', up);
            });
            tr.on('click', function (e) { e.preventDefault(); e.stopPropagation(); });
        });
    } else if (event.type == 'change') {
        d[event.symbol] = event.value;
        draw(event.symbol);
    }
}
endef

define NHE_TAPESTRY_STEREO_FILE20
iVBORw0KGgoAAAANSUhEUgAAAEYAAACSCAMAAADPX0yPAAAWfmNhQlgAABZ+anVtYgAAAB5qdW1k
YzJwYQARABCAAACqADibcQNjMnBhAAAAFlhqdW1iAAAAR2p1bWRjMm1hABEAEIAAAKoAOJtxA3Vy
bjpjMnBhOjUwNjQ4ZjVkLTQ5ZTQtNDEzZi05MDBkLWZmYTU0MDI2MDE0ZQAAAAOTanVtYgAAAClq
dW1kYzJhcwARABCAAACqADibcQNjMnBhLmFzc2VydGlvbnMAAAAAuGp1bWIAAABEanVtZGNib3IA
EQAQgAAAqgA4m3ETYzJwYS5pbmdyZWRpZW50LnYzAAAAABhjMnNohfjLFTyAVSjlHSz/MerfWQAA
AGxjYm9yo2lkYzpmb3JtYXRpaW1hZ2UvcG5namluc3RhbmNlSUR4LHhtcDppaWQ6OTZkYWRhNTYt
M2RlYy00OTk0LTk5ODMtMmNkYjdhOGYxMzE3bHJlbGF0aW9uc2hpcGhwYXJlbnRPZgAAAeJqdW1i
AAAAQWp1bWRjYm9yABEAEIAAAKoAOJtxE2MycGEuYWN0aW9ucy52MgAAAAAYYzJzaD4J2K26xbpg
7eL3b5SgUygAAAGZY2JvcqJnYWN0aW9uc4KiZmFjdGlvbmtjMnBhLm9wZW5lZGpwYXJhbWV0ZXJz
oWtpbmdyZWRpZW50c4GiY3VybHgtc2VsZiNqdW1iZj1jMnBhLmFzc2VydGlvbnMvYzJwYS5pbmdy
ZWRpZW50LnYzZGhhc2hYIF2x7qyaKWgSJKOsBBgoVotd3a16yPf3D0QQ6oib68cSpGZhY3Rpb254
HWNvbS5hbnRocm9waWMuY2xhdWRlLnByb3ZpZGVkanBhcmFtZXRlcnOheB9jb20uYW50aHJvcGlj
Lm9yaWdpbi1jb25maWRlbmNlZ3Vua25vd25rZGVzY3JpcHRpb254ZkNsYXVkZSBwcm92aWRlZCB0
aGlzIGZpbGUgYXQgdGhlIHJlcXVlc3Qgb2YgYSB1c2VyIGFuZCBtYXkgaGF2ZSBjcmVhdGVkIG9y
IG1vZGlmaWVkIHRoZSBmaWxlIGNvbnRlbnRzLm1zb2Z0d2FyZUFnZW50oWRuYW1lZkNsYXVkZXJh
bGxBY3Rpb25zSW5jbHVkZWT1AAAAyGp1bWIAAABAanVtZGNib3IAEQAQgAAAqgA4m3ETYzJwYS5o
YXNoLmRhdGEAAAAAGGMyc2i03NI/wBRQBgeSzwRyyTJeAAAAgGNib3KlY2FsZ2ZzaGEyNTZjcGFk
TQAAAAAAAAAAAAAAAABkaGFzaFggjIXdV5yTlyb70tYK1Rqu99tra2UHY1qMIpDyn/X6VP1kbmFt
ZW5qdW1iZiBtYW5pZmVzdGpleGNsdXNpb25zgaJlc3RhcnQYIWZsZW5ndGgZFooAAAI+anVtYgAA
ACdqdW1kYzJjbAARABCAAACqADibcQNjMnBhLmNsYWltLnYyAAAAAg9jYm9ypWNhbGdmc2hhMjU2
aXNpZ25hdHVyZXhNc2VsZiNqdW1iZj0vYzJwYS91cm46YzJwYTo1MDY0OGY1ZC00OWU0LTQxM2Yt
OTAwZC1mZmE1NDAyNjAxNGUvYzJwYS5zaWduYXR1cmVqaW5zdGFuY2VJRHgseG1wOmlpZDozM2Nj
N2U2Yy05ZTk5LTQ5ZDUtYmE3Mi05OTc0N2VlYmYzNmFyY3JlYXRlZF9hc3NlcnRpb25zg6JjdXJs
eC1zZWxmI2p1bWJmPWMycGEuYXNzZXJ0aW9ucy9jMnBhLmluZ3JlZGllbnQudjNkaGFzaFggXbHu
rJopaBIko6wEGChWi13drXrI9/cPRBDqiJvrxxKiY3VybHgqc2VsZiNqdW1iZj1jMnBhLmFzc2Vy
dGlvbnMvYzJwYS5hY3Rpb25zLnYyZGhhc2hYIOVjLmVot/ANYEfy4N6rEqLQ7G4h4LToMEEAjyqI
Qk7pomN1cmx4KXNlbGYjanVtYmY9YzJwYS5hc3NlcnRpb25zL2MycGEuaGFzaC5kYXRhZGhhc2hY
IFQ18G+Gd+/iZ59prwliY0Ku5hv5xRqFEcWLYyYWE/8BdGNsYWltX2dlbmVyYXRvcl9pbmZvo2Ru
YW1lb0FudGhyb3BpYyBGaWxlc2d2ZXJzaW9uZTEuMC4wa3NwZWNWZXJzaW9uZTIuNC4wAAAQOGp1
bWIAAAAoanVtZGMyY3MAEQAQgAAAqgA4m3EDYzJwYS5zaWduYXR1cmUAAAAQCGNib3LShFkCEqIB
JhghWQIKMIICBjCCAY2gAwIBAgIUQOWgCu7COdC+uIP6BkIFPWdVEwAwCgYIKoZIzj0EAwMwSTEX
MBUGA1UEChMOQW50aHJvcGljLCBQQkMxLjAsBgNVBAMTJUFudGhyb3BpYyBDb250ZW50IENyZWRl
bnRpYWxzIFJvb3QgQ0EwHhcNMjYwODA3MTg0MzU2WhcNMjgwODA2MTk0MzU2WjBEMRcwFQYDVQQK
Ew5BbnRocm9waWMsIFBCQzEpMCcGA1UEAxMgQW50aHJvcGljIENsYXVkZSBDb250ZW50IFNpZ25p
bmcwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASYegpry1AYBRTVNL1CpTlbROnY3dey+UrsF9C3
phYrATN3ZHf93Mo8RQN0KOUuOn19P4oWNFWe5n2/She9N7eTo1gwVjAOBgNVHQ8BAf8EBAMCB4Aw
FQYDVR0lBA4wDAYKKwYBBAGD6F4CATAMBgNVHRMBAf8EAjAAMB8GA1UdIwQYMBaAFM5R4gSBTmRb
I/jjxM+aPpzB11zCMAoGCCqGSM49BAMDA2cAMGQCMDFzHRSeAXrSy1WOzkbhPZ6Km2wGTmZ/2gK1
8k8BQGXyqz88Rdrz6CTX9flAnYNVxgIwcF9c3fVhqmJKpi+UhasNUMko69cyX6STPfta3Q8EjyzD
jzoyrol46FP6VFHhvUcJoWNwYWRZDZ4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD2WEBw+O8KcV6D35dgVyTbBQXAZwbevTec
dLw89oyUwUauo/YJykk6iAWAm4qSxiVH2jxZ2/neMU0CIn1mRVPP3q8s85wWnAAAAwBQTFRFAwQE
FRcYJignMjU2RUlLHCEjUVVVPEJEIyIcGx0hmqWpq7W4IhkOoqqtOT1BHCAdk5iZZGhoW2Fks7vC
WF1ik52hYVxXusPHAAAAOkE+b3Z4Y2NaFhYMmqGdKyomODYvXWBbo6Keh42QusK9xMvKHBkRIyMW
ISEcMCsjMzMzTEk+RUVFDA4IFBENGBYRHiAaIhkLIBgLNjYyREI7Wl1UW11YfwAAf39teXyEeoKE
ztHSAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
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
endef

define NHE_TAPESTRY_STEREO_FILE21
/* Tapestry - New Horizon Electronics (650 x 400 CSS px). Artwork by Niels.
   Images are 2x, drawn at their 1x size; positions measured from the v1 mockup.
   The LCD font is loaded from the plugin's own resources. Two things make a web font work in mod-ui:
   - mod-ui injects this stylesheet into the page, so a relative url() resolves against the page:
     every url() must be /resources/<file>{{{ns}}}, which carries the plugin's URI.
   - mod-ui's main.css sets  * { font-family: "cooper hewitt", Sans-serif !important }  on every
     element, so the face's font-family needs !important too (its class selector then wins).
   lcd.woff2: "lcd phone" (Grafito Design), with minus, plus and full stop added on its own 5 x 7
   dot grid, a standard Unicode map instead of its Symbol one, cut down to the LCD's characters. */
@font-face {
    font-family: 'TapestryLCD';
    src: url(/resources/lcd.woff2{{{ns}}}) format('woff2');
    font-weight: normal;
    font-style: normal;
}

.tapestry{{{cns}}} {
    position: absolute;
    width: 650px;
    height: 400px;
    background-image: url(/resources/background.jpg{{{ns}}});
    background-size: 650px 400px;
    background-repeat: no-repeat;
    border-radius: 4px;
}

/* LCD text: 15.625 px gives the mockup's 12.5 px cap height (the dots fill 0..800 of 1000 units) */
.tapestry{{{cns}}} .tp-lcd {
    position: absolute; top: 48.45px; height: 16.5px;
    font-family: 'TapestryLCD', monospace !important; font-size: 16.25px; line-height: 16.5px;
    color: rgb(60, 57, 20); white-space: nowrap; overflow: hidden;
    -webkit-font-smoothing: antialiased;
    pointer-events: none; z-index: 20;
}
.tapestry{{{cns}}} .tp-val { width: 36px; text-align: right; letter-spacing: -0.6px; margin-right: 0.6px; }   /* tighter, so "100" clears the divider */
.tapestry{{{cns}}} .tp-val-drive { left: 24px; }      /* right edges 60, 100, 137.5 px (fitted to the mockup) */
.tapestry{{{cns}}} .tp-val-level { left: 64px; }
.tapestry{{{cns}}} .tp-val-mix   { left: 101.5px; }
.tapestry{{{cns}}} .tp-fmt { left: 229px; width: 162px; text-align: left; letter-spacing: 1.05px; }   /* the mockup's tracking */

/* sliders: 35 x 73 cap in a 280.5 px channel, so it travels 207.5 px (top = max) */
.tapestry{{{cns}}} .tp-track { position: absolute; top: 95px; width: 40px; height: 280.5px; cursor: pointer; z-index: 21; }
.tapestry{{{cns}}} .tp-track-drive { left: 22.25px; }   /* channel centres 42.25, 84, 126 px */
.tapestry{{{cns}}} .tp-track-level { left: 64px; }
.tapestry{{{cns}}} .tp-track-mix   { left: 106px; }
.tapestry{{{cns}}} .tp-cap { position: absolute; left: 2.5px; top: 124.5px; width: 35px; height: 73px;
    background-image: url(/resources/slider-cap.png{{{ns}}}); background-size: 35px 73px; pointer-events: none; }
/* defaults until the script runs (and for the screenshot): Drive 0 dB, Level 0 dB, Mix 100 % */
.tapestry{{{cns}}} .tp-track-level .tp-cap { top: 103.75px; }
.tapestry{{{cns}}} .tp-track-mix .tp-cap   { top: 0; }

/* step buttons */
.tapestry{{{cns}}} .tp-btn { position: absolute; left: 156.5px; width: 52.5px; height: 54px; background-size: 52.5px 54px; cursor: pointer; z-index: 22; }
.tapestry{{{cns}}} .tp-btn-format { top: 21px; background-image: url(/resources/format-btn.png{{{ns}}}); }
.tapestry{{{cns}}} .tp-btn-format.down { background-image: url(/resources/format-btn-down.png{{{ns}}}); }
.tapestry{{{cns}}} .tp-btn-tape { top: 72px; background-image: url(/resources/tape-btn.png{{{ns}}}); }
.tapestry{{{cns}}} .tp-btn-tape.down { background-image: url(/resources/tape-btn-down.png{{{ns}}}); }

/* Tape lights: lit art centred on the panel's unlit bars */
.tapestry{{{cns}}} .tp-led { position: absolute; left: 158.25px; width: 49.5px; height: 17.5px; background-size: 49.5px 17.5px; background-repeat: no-repeat; z-index: 20; pointer-events: none; }
.tapestry{{{cns}}} .tp-led.on { background-image: url(/resources/led-green.png{{{ns}}}); }
.tapestry{{{cns}}} .tp-led-0 { top: 146px; left: 158px; }
.tapestry{{{cns}}} .tp-led-1 { top: 184px; }
.tapestry{{{cns}}} .tp-led-2 { top: 222.25px; }
.tapestry{{{cns}}} .tp-led-3 { top: 260.75px; }
/* click zones: each label + its light */
.tapestry{{{cns}}} .tp-pick { position: absolute; left: 157px; width: 52px; height: 37px; cursor: pointer; z-index: 23; }
.tapestry{{{cns}}} .tp-pick-0 { top: 129px; }
.tapestry{{{cns}}} .tp-pick-1 { top: 167px; }
.tapestry{{{cns}}} .tp-pick-2 { top: 205.25px; }
.tapestry{{{cns}}} .tp-pick-3 { top: 243.75px; }

/* On/Off: the red light is lit while the effect runs (bypass-light is not inverted) */
.tapestry{{{cns}}} .tp-onoff-led { position: absolute; left: 156.5px; top: 308px; width: 51.5px; height: 19.5px; background-size: 51.5px 19.5px; background-repeat: no-repeat; z-index: 20; }
.tapestry{{{cns}}} .tp-onoff-led.on { background-image: url(/resources/led-red.png{{{ns}}}); }
/* the button: pressed art only while it's held down (the light shows the state, as in the mockup) */
.tapestry{{{cns}}} .tp-onoff { position: absolute; left: 155px; top: 324px; width: 55.5px; height: 56.5px;
    background-image: url(/resources/onoff.png{{{ns}}}); background-size: 55.5px 56.5px; cursor: pointer; z-index: 22; }
.tapestry{{{cns}}} .tp-onoff:active { background-image: url(/resources/onoff-down.png{{{ns}}}); }

/* knobs: 64 x 64 frames, 65 frames in one horizontal 2x strip. Whole pixels on purpose:
   mod-ui's film widget reads the strip height with parseInt and the element width with
   Math.round, so a 63.5 px knob would drift by a fraction of a frame per step */
.tapestry{{{cns}}} .tp-knob {
    position: absolute; width: 64px; height: 64px;
    background-image: url(/resources/knob.png{{{ns}}}); background-size: auto 64px; background-repeat: no-repeat; background-position: 0 0;
    cursor: pointer; z-index: 21;
}
.tapestry{{{cns}}} .tp-wow     { left: 227.25px; top: 97.75px; }
.tapestry{{{cns}}} .tp-flutter { left: 319.25px; top: 97.75px; }
.tapestry{{{cns}}} .tp-age     { left: 227.25px; top: 196.75px; }
.tapestry{{{cns}}} .tp-hiss    { left: 319.25px; top: 196.75px; }
.tapestry{{{cns}}} .tp-tone    { left: 227.25px; top: 300.25px; }

/* the machine's picture, one per Format */
.tapestry{{{cns}}} .tp-tape { position: absolute; left: 427px; top: 31.5px; width: 126px; height: 336.5px; background-size: 126px 336.5px; background-repeat: no-repeat; z-index: 19; pointer-events: none; }
.tapestry{{{cns}}} .tp-tape-0 { background-image: url(/resources/tape-0.jpg{{{ns}}}); }
.tapestry{{{cns}}} .tp-tape-1 { background-image: url(/resources/tape-1.jpg{{{ns}}}); }
.tapestry{{{cns}}} .tp-tape-2 { background-image: url(/resources/tape-2.jpg{{{ns}}}); }
.tapestry{{{cns}}} .tp-tape-3 { background-image: url(/resources/tape-3.jpg{{{ns}}}); }
.tapestry{{{cns}}} .tp-tape-4 { background-image: url(/resources/tape-4.jpg{{{ns}}}); }
.tapestry{{{cns}}} .tp-tape-5 { background-image: url(/resources/tape-5.jpg{{{ns}}}); }
.tapestry{{{cns}}} .tp-tape-6 { background-image: url(/resources/tape-6.jpg{{{ns}}}); }
.tapestry{{{cns}}} .tp-tape-7 { background-image: url(/resources/tape-7.jpg{{{ns}}}); }
.tapestry{{{cns}}} .tp-tape-8 { background-image: url(/resources/tape-8.jpg{{{ns}}}); }

.tapestry{{{cns}}} .mod-pedal-input,
.tapestry{{{cns}}} .mod-pedal-output { top: 170px; }
endef

define NHE_TAPESTRY_STEREO_FILE22
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
endef

define NHE_TAPESTRY_STEREO_FILE23
/9j/4AAQSkZJRgABAQAAAQABAAD/2wCEAAYGBgYHBgcICAcKCwoLCg8ODAwODxYQERAREBYiFRkV
FRkVIh4kHhweJB42KiYmKjY+NDI0PkxERExfWl98fKcBBgYGBgcGBwgIBwoLCgsKDw4MDA4PFhAR
EBEQFiIVGRUVGRUiHiQeHB4kHjYqJiYqNj40MjQ+TERETF9aX3x8p//AABEIAqEA/AMBIQACEQED
EQH/xACuAAABBQEBAAAAAAAAAAAAAAAAAQIDBAUGBxAAAQMCAwUDCAkDAgUDBQAAAQACAwQRITFB
BRJRYXETIoEGMjNCUnKRsRQjNFNikqHB0RUkQ8LhFmNzgrIlVPAHg6Li8QEBAAMBAQEAAAAAAAAA
AAAAAAECAwQFBhEAAgECBQIEBAQFAwUAAAAAAAECAxEEEiExQVFxBRMiMlJhgZEjQrHBFCRygqEz
NHNDY6LR8P/aAAwDAQACEQMRAD8A8SATkAIJQAozdANThcIB6RAFkgKAchACS6AEIBEIBEIASoAQ
gBCAEiAEICRCAEiAEqASwQgBFkAIQAhACQoAQgBNQAhACEAIQAhACEAXQgJAhAIhACEAIQAhACEA
IQAkKARNJQCgpUAJEAIQAhACRACEAIQEqEAFIgFRZAIhACQoBAlQCIQAkQAiyAEIAQgEQgAFCAS6
VACEAIQEqEAiEAqEAiEAJEAJEAiEAIQBdCARCAEIAQgBCATVKgBCAEICRCAEl0AqEAiEAIQCFIgB
CAEIBEIAQgBCAEhQAhACVACEAiEBIhACEABCAEXQCEoBQCIQAhACMEAiEAIQAhACRACCgBCAEIAS
ICVCAaXBoJJWXLXOJ3Yh4oCHcrX2JLlIyirX5OPxKAtM2PtJ9rOH5ipx5PbWd67fzFASDyZ2yfXZ
+Ypw8l9s+2z8zkAv/C+2fbZ+ZyP+F9s+2z8zkAn/AAvtr22fmcj/AIX2z7bPzOQCf8L7Z9tn5nJp
8mdse2z8zkAh8m9rj12fmKT/AIc2v7bPzFAIfJ3a/tt/MUh8ntre238xQDf6BtT22/mKP6DtT22/
mKAT+g7U9tv5ig7C2r7Y/MUAn9D2p7Y/MUx+x9pMFy4fmKApl9XAe+CQr8E7JRzQFhCAE1ATJEBk
V85J3AcBmq8VTFA24F3lAIayV5xkPgrUM7rj65yA1opJ7D696vMfUi39y78yXBZaawgWqX/mUtq/
7+T4oAttD/3EnxR/f/8AuJPigEtX/wDuJPzItX/fyfmQAfp/38nxUR+n/fyfFANP0779/wAUwit+
+f8AFAIfpv3z/imE1n3z/igEP0z75/xTSKv75/xQCWrPvn/FJar+9f8AFAJ/d/ev+KaRVayvQET4
3PFni/NZL4TBKCEBotNwCnIBCUiAkQcigOXneTIcc3FRjecc0BeiY7DH9FrQwvOgPVqhko0ooHDJ
jP1CvMZKBg0fNLIFhpItvQsPQ2UjX0wxLpoj8Qq5WC1EDIR2NZDIeBNirBNTF6WkJHtMxCo5yiCW
KeiebOu02yOB+BWpHRQSi7Hgq0akXzZizHnZR9gqI7Kd7BWhBGdlHgojswhANOyzwKYdlu4IBh2W
72U07Ld7IQDP6YfZCQ7MI9UIBP6b+FRnZ34UBE/Z3Jc7tmkMUQegKTAeyBQgEQgJU0nA9CgOXkF3
jqVJEy5GCA2KeLLBblNTXIwKhkm1FTYDAq6ym5IWJvogIyCpT0wbfBAYtTAx2YHiFnieppvQVMrM
cmPKOzJLLfKHabBabsJ2gf5Ygf1bYq7TbdoJHgOo3QyXzhmFvyvsCsJ0U/aRY6GLb8tIB/chzSPM
qmGHwD8WFdHReU+xp5xTVEzIJ8O48ixvwdexSnKcbRkroNJnUikidkRkmGibyXQrMoMNCmGh6IQR
GiBTDRDgECGfQR7KYaDHzSgRGaAeyUw0TOCBkD6BtlxvlVSBlEw29dCTkQAKZvQKBACSyAlSHI9C
gOZIvJ4lW4Gi6Eo36SMYYLqKWEEDA5KCUb0MAsMCrzKdl8kJRIYAAclk1kNiUJOaqWYFZM7Hs7Mt
ZZrmXFszY7puVJKMp7Xk4G4+KrYWxY1wtkRcISXqSsnpbmCpbE0k70TRdjuT2m4sr8VdA+J0Vfsq
B4IuHQWYQ46luSq0Q0bmwn1sTQ3Ye2I5XY3oKjhnZrH/AOkruaLy5gjkdFteifSPYbPeLyw/Ed5n
iq6p/PoV7noNLU0VXDHLFJG6N47r2u3mno4Ky+ni1srpplGmiA00HBRmCD2T8FJACBgGDCmGAatK
AiMATDAeCAgfTE6BcH5awFuzo8P8iBHmrsIAqt0JC6LoCVI7JyA5sYyeJV+nGKEo6SibiF1lIwYY
hQSjfgjwGIV9jDghKCVtgc+Kwa5wAOWRQscrUOBB5rNqQ801I8HutdLFI4erI528AbaObkpJMl3e
JsBmeqifGQcQVDJIi3PPJSbwJGFhbX5khQQShsLzGJ2ksDgHboBcG8R0XQU1dXwEsLm1UW87s2y4
TFmlnhS0mRoy/s6pihkDtl1s1HUOfjCWj9WnuSAr0TZXllvyR01cwUs990Ok9BM4+y//ABuPByzt
JPQq7Hd09XHNI6E70c7POhkG68fyOYVzsic2haJ3KNNEoiBHmhMMQGgUkETmNOqiLEBWkAt5jV55
5dttsyPut9LogR5Q+3YeIVTBCQQgJEjsj0QHPMLRLiAcTx/ZatM6nviw5oDq6AbPLml0j24Y2suy
oqKlkZ3a9mWrf4Qk6GPZFeBeOOOYWJ+qcCbDPBNacSN03BsVBYrTyWBsSuZrX7xIJBQscvM8Cx5m
/JZcsr2ucWlpBZuuY7J7PZcBmPkpJKL3xkvIDmNAG60nfPTewTDkcQbqLkjQTccL4qUWI0QBZzSC
0kG4tYq3T1Aa6zyWsJG8GgH4N/hEQX5HxOaO0DQ24u8+bbmf5WtA97Y3wvjEjAAHRzHAxu4OxIHI
3arS2Ks39mbYqaTdpS19fSMbcUcjrVVO326eTNzV6PszbwmpzPS1Dq+mb5/dtVQcpGarPXcrpszp
6etiqIhJDIHsPrAqUvvxV0UZEbWz/VRkniPigGPJAzC868viTsyPAelQHjz/AEPiFVQkQlCAlSOy
PRAc4PSHHUq9T5+cUJR0VHa4+sGfsldLTMbgSYT1a6/6KCxtU4ewncLctHn91vw7WdIWR17i5hAb
2h04E6gjioZaxWrN+N5YQN4AY728DzaeC46teCSLNOHioRYwJpN4gRseSSd0MbvnngMVkSbzibEO
NsVbgFUkA2xHVA3A8b4cW3726d0kcAcgUAlzgbA4nqpo8bWPeBFr4fqgLTTY2cCDwItfnwKsNY1w
ZZt7k+PhogLUYfES+J7sMrcPFWIXR3ZubsRByseydzsMYzzbgpKF9jwQyKoYe/dzA43Lvxt3Mz+N
lncQtilmqIXiZkz2zgCSKsZ3pmNZmHtbhNEdS3EahCjPRdmbRg2gYZouzp62VlwWG8FQBqLYXXRt
qHhxa9ga4ZghVKsnDrjIILQVYEbgV515fD/0xmfpUCPHpD9UeoVVCQQgJEOyPRAc2PSK7ADcYISj
oqQPuO6ukpmyYfVlQWWxrscQBdpCbPKN0gnQqGXVyfZ1S6ppK6meS6SmYJobatyc391zNbIN08xg
oLaMxHTysk7SGV8clj32PLXAHzsRxWXLmBoMkIGbxaQQ4F1z3XN3vmmHdAOeWYF0DHbryCc+hvb+
FPGbNvgeSsB7CQRYjM90i4V2nBJOUbtLnueDs2lEDTYyWIFpBDx6uZcOIGTk8RxSNBuGuvcHT46d
CpKAzfhc6OWNrmON3h2TuBwxB4OGKvQTyxbnZySPjJ3nDzpW217vn29od5WRSRsR1NPIySaGWJjp
DvPeHFsMx4u3PMf+NviunpfKeWntTbSbJJG2zXyvLRPTuOQk3cHsOkjVWSsiq5NY7fFJIDUlppHu
DY61vmBx9SYf43cDkV0baoHXFQncMV0oIzXnvl4QdmM73+VSEeQvH1PiFVQkEICRNdkehQHOj0iu
wDHRCUdBSAYYLpqYDDA5cVBZGsHuDcC7JUp5iARh4qrLrgj2HUiPbTMDZ9NMx55FhWRVEOij71jb
PRRyWMGVrzfIi4HUquRYG97j4KyGvBCScrYaaoALr7udsERDuF2OJ7oa7CzgbEActbq8SSwFwEh0
fk745FSBGMe70Y7UDNoFpG9W6+CuU5JcHMDXC+Ry8eCA1GPYGbjTvNuLxOxA9w5tSXi/xude3eje
Bvfw/wCaIpZj4X9xkbQCy53WaX4NcfNPIp+6wBxaT3XAOGLSx3MZsI4hWRVh9IIe5737snrS+q//
AKzRr+MeK0op4JYhFLTd9jMYyRvBr/YdkWnlgVPAW5Ypqs7MfhMH0cjSwSObvBo+6qGetHzzC6Sl
2hLsyIPhhe6gjbeaAOMslIDlJGf8lP8Aq1ZLSdiGdjBWRzxRyRyB7HtDmPabtcDqCM1xnly4nZkf
/VVyp5K8/UqshIIQDroOLT0KA59gBlOGpWpTMaSMDmoZZHUUUERIuD+VdXS0VMbXIHVpVWWiXn0M
RA3XjPDGyyaqikJNnHLqq3NlG5T2ZDNTz11Q6xLKZzG6Ou7C6zq2NxYRYeaMjmq31LqLsc7MQHni
FWcXixzWiM2RG3AjokMZcMg4DMjMeClEMc2WUNLCQ9u8LscLOBHA5hWonteTuktdc912HwORUkFg
RRF4EhMbhY4DLmrpka1w7cvfYdyphI7Xo++DxyKAsOcDH2rw10dwDVRAhoPCVubHDngke0GwlaHN
9V7dRxRFRO1B9Lazsp2C9v8AqM9YDlipd4sMTrhrnAmOSN2+xzRwJzHFpxCsikhHua8tsAHW7pB7
rvcP+lLFM4Nax2+5rD3NzB8Z1MZP6tOBUhF6Od7NwkgtkBs8DuS9Rm1w1CtUlZLQ7kkUjzDE4uDW
ekgJzdHxadWLOauXcTfo60Ur3TULA+ne0yyU0PmOGs9L/rjUXlZWQ1OyKeWJ4ex7w5jwcCEi7oyP
N3kdiqt1YAhAABSnI9EBhR+lPUrVpjjmc1DLI6ygJBFnFdhSEhnnnpuqrLotPeeIKyKmQNaTawvm
s2bwJHxGmiijJImljD3g5tgOLbni8424LGnsXHAWsVQ1MSVkTza5y1CpS0jC0kA3/RWiykkZhikb
fu4cQVGQHHTJaoyZIXF1g4b+Opx+Kc2IyWERD3E+ifYP8NHKxUdFPKLx7olaw96GTB7ehzaf0WjA
4SOJp7ucB3oXYStHTJ45hATwPBe2amkME+TO8A1w1Zc/J2CmDmOe6MRCmmv3oH92Fzjwv6Iu09Uo
VAiVpe0xuFiBJE/BwPAjTkVEA+IODG70b3Avif5pPHDJw9oKyIH2IY51yYrjeLvVJyLxp7ye09oM
fic+jv5VgPsY94EEggb3hlfnwKkZUFjhiTidx2vR2l/ms2WWyNKgniilMfbiB0kjXtF92Iy6EO/x
vPtDA6qj5QPdFTyPju1pmP0mmta0oze1vqu9puRzCz2n8mUnuYBIdTtIIIIBBVdalAQgJEjsj0QG
DH6U9StWmGIyzUMsjq6FuXmldTA27QQ1vxVGXRLKCALscLLOBa+YF190ObhpniTyAWTN4jp5XyyT
zPdvOkeTfksuUgA4ZlQzbcznEknJQ64HFExYUhrwC9gcPaBsVFJRMmHcG862AODviroykZz6R7cj
f8JFnKHsSbt3b2zBHeH/AM4haIycSyHF4ayZnbADunetKz3H69CmS0wMJma8zwMylaN2WH325j3h
grFWPNWJD/dOBJyqmNvvf9Vo873hitJscsoEcsM0rN0hkkQ7Qho1jcLhzeLShBoQ7I2+8iIbNqpm
tYezeyJwNuDN/K2rCqEzJaSbsnsfDL7DmFh+ByKsitxIjvvD2SCOUXDr63zaWnAg8FKyON0e9CMB
ffZ7PTizlmFJIocALEi3Hh/IUL3loIuLa/wVRlkMMmNnEOaQRiMwdHBR7QrDLSRxSkuewtbDPqWj
KKTju+o7wUMiSuipYimbhbAYKBWMgQgH2Q7I9EBgx+lWrTE30zUMsjqqIkEZLpIX4YsblmqMvEWW
UAHA9FHvlsdhg55LcfZ1WTOiJBKQQBYWAwWfKAcLnNVNkUJWvbfBQAOBOOilEMcMzcEKW41GHFSi
kkWgztBuuAkFjYHP4pj9nNnAMTe1I/xk7sjTxY5aGRnSUhO8d0v7w3yG7sjTb125HqMUxkD2yRzi
Qtz3JmH9D/BVkygTCkheQYWyVbvTxtduUwDvXk4O5BL/AFesopnxtDnyMuOwBNPEGn2GMzB4nNTs
ipBUVz6ynbM03jYSSBLKHQudnvguP58lpU+3dqMpnwz1L6ujb50FUPpLWjjo9vVpTM7jKrak7Y9l
bQMYpJzS1RNo6eof2kMvKGYcdA5VHCWOVzJY5IpozZ7Hiz2Hn/KvcjXkCTbAWI84fuP4SAnDAZH4
KpZFOQboOGF7C/yKytoOvFjfP4jnzUclpe1lxhJo48T5rcyolY5wQgJUjsj0QGAz0p6latNnlqoL
Lg6ekOWC3on2A87JUkaxB31srI2vtfMkZNGLj4BD5RJK54BtbdZyasTogQvNibEqq8myoaIqvtck
E34qLd5YcVJJI2Mm9nXFvNKURG9hgr3MmWGMIIwLTbBaA3ZMKgEO0lbmFYzZbli33A1jQ8W+rqo8
z14rMqqR8JAaGGSRhl34z3XRA7oc9ujyURDOcqInQvEJbiQXPa4XE3GRh9ccswqZLHxMie174mC8
VnXkhHGJ2rfwrRGZUljmgljmZOA9wPZVDBZsg1BBydoWlTxnfIkpmmKdgvJA3/zh5cW6ILkZfHM0
viY0F2M1N/jeB68dv1C26fakFVEyOumk3ImgQ1XnzU7TkyT7yLnmFIsEsUsDgC5u+QC17Hb7HA5F
h1BVcylwyANzvD91Fy9iIkEHArJ2gSIgLC1xZERL2svR/Yovdb8lEVc5wQgJUhyPRAYLPSnqVp0x
xy1UFkdHSuOGC2mPwGB5LORrEUVIbSzNAs+oe0Nd/wAlhyHvOzPABNDg0WBOAWTOqCQ2RxwxVRzy
TnhcqhoiM3P+6VmBzIxRBl5paT3gOoVtjAQLDfAHirrYwkWWRA3DTceyfOTgwY2UlGSwCRrwyM4S
EDdIuLanwCoRuE756uCHCV5fFGcjBD3GDoc1IKM9JA+FzIY3SwB28aUmz4T7cTtLcFz1TTPjaJN8
Pjc7uT+aHO4SD1X89VMXwVsUw931jTGx4dhLEcA+2vJ/AhZ8zN1zXtlNg7uTZPa7Rr+B5q5Uc2Uy
EutuTi7nDLePtM58Qn9o5zxNESx4xO6P1A5+sELbl+mq/qiwxHshdzohj2d85IvwnVqmkaWuB3mu
3hdjx5rhxRhEJOtgs7aBvGOqIP2l2M/2UXut+SjWhzAhCGSIJwKEmFH6U9StOnJvkM1BZcHQUziL
d1hw1C0wQ4BgiYC/BrgTh4LORtDgmJidLvd4BgaxmuAzTixg7zXD8N8PBYS3OqJBK2YjJUy4glpa
QRooNEF7k6qQdNEKslYSCO8csldicCRjuu0KvmMpF4SbxG+Dn54+as7zCQJzh6s7Rj48URRkVWJ4
qZ25btKginheMi6bz3j3WqhO2MODYnujETQyJ3BrcBccMFYgY6USvAlIjqBk8ea7/ZVpWb7nkMa2
e31jHejnHNQwjmqumbGC+MERgAFjj3oT7LuLeBVAl7dBcgAg5Pb7LuPIrRO5BTexoDSCd0Huu1Ye
H+6cHucbnCTNwHLX+VJFgJIIe0kOBvgcuY5FaVNVAtc0sBaTvvjA19tnDmoYJntsAWuDmnJwyKy6
/wBGM80Ql7S/H9ji91vyUa1OYEIQyRIcihJhx+lPUrRgOKhlkblOb2WnHIbSEDE3iaSfFxCzkbQL
LO6BYaCyHOJ0CwludUSLfItYkcUx7w4C4BUGliPcY7JxaeaUiRhG809UKMliBeO7jyVlhIscwdFZ
FWaMdnDA9WlTMcYWucLbtjdhF2+KlbmbInuvVuYwPDaSHGI5CpnF3WOtmKo6zo+1ZdzR5wA7zPBS
UKxDbAHzeRxHMKNxDgGSOG8PMf8AshZFWUFxvcCQAgE4hw4Hkueq4AwFzG2j9Zn3Z/dqsgygSQTz
A3h7Q4KBzSDcHXun9lcoPa84uGFs+V/2QHbpDmkixFrZtPJEDTp52yB4IAtjI0ZC/rs5HVVNotLW
WuMwnI/Ky5H9ii91vyTFocw1CAmSHIoDCYbSFX4HWKgsjYilIGFr6BasABIsRusBY08ScXOWcjem
Xg4X+SYQsZcnVEjeCSmEj/dUWxoMN75lPa94HdJtdWKMsNZE+2G466lBc0jtL5echRk7TiDgMc1O
2obGd+UgNjBlc7QhmNj1yUlCo8ytpIY5HkTyl1RKeMkp3j8BgoxOXydoHBk2ROj+TlYhoa/ccC6N
ha4G0kR9Xm3kqT3mxwBCCIwvuA1x91yrSAutj3sR1HAorkmBPCGOBbfdJw/CeCrYG4x5j91czejI
jdpuACf/ACCcC0DWxCkgVr5GOYWEBzTdp/Y8ipquVs1MwtHd3stWO9npwU9CHyjQjv8ARIvdaolo
c4JEIROmk4HoUJMFptIVciNjooZZGtC82uDjkB+J38BbcQDGhgGDRYLJm8CwDz0KfvLGW51QIiSD
mmEgnJVNB1iSMEgBAzUmbJmnCxCnbKQLGxup5IYp1LO8LZJwaKgMpsdyd4fLyggN3Dq5ystyjIK2
ft6maQu3m71gQMraqqcxe2WBvmoAolLrXcd5ozTHuDgeOoUkFRxIBzsmk3GWNk5JK0rA8YjTFYks
ZY8C5yu08QrRZSRCe8MkwEA43AKuUHWzB0UEziAT7Vg8cVKIlsb8ZvRxY+q35KNaHMxCUiEk6Q5H
oUBgA98qzG6x0zUMvE2Ke2+32YxZvM6lbMbhhisWzogWAQQkuMVizpiIT0OCZe+iEj2k2JwIupGZ
jjbBCGSEAjTMIuRdCBd8gd21ycOpV9kjYqWuq2DFwFLCeIizPi8qyZRmC1xYGgk4DxRcWy7vD+EB
G4myYXkoiRjiDjYqMkgoBCVTniDm254HgVYhoySLE3BzN0x4Nyfj/K0MRATYch+ign8wKUVlsdBF
9ih9xvyTFoc4iRAT3CR1rHoUBzxNnnqVYiJuTwy6qrLxNan7oAWo04YlYyOmG5Za4jROD7khZM6E
OLuQTeWCEitvhirQcH2v5yEMaSQMRhbNBeDa5yGHJCBu9K0PdGA543WxtOTnyHdarO1zHDJS0Mch
MdNGPHQHxNyrIo9zMLy/M962ahDzlfG6AYXAjPD5JpKEjd7WxskOQ6KwIwbBDtcAgM2pZa79NVSw
xFvDkrIynuRm7XC3h0UU1gwdVdGctjfiP9lD7jfkmXWhzhdIgJbJDkeiAwdwuebAKaEi/wAlVl4m
vCCLLRYCSALkLKR0wLFwON064OoyzWLOhbCnRMve45hCWSNeRdTBwtgdMkIDfBGabvDSyEF/ZjGP
rY3veBHTxmof181n8rEfUGeSWoN96V5fbg31R8FYqtxpdiUOIeCCELEQfa90lxhic0IYhKYSBqhA
Gw1KZe4tkgGvALSsqVhYRngrxZnPYicLg55FVpT3VojKWxvxfYofcb8kxaHOCEBMkJwPQoDCawPe
QSbXWhBStccZSMeSynNRNacXLZXN6m2YHkWqXjDSMOXSU3k3tGWEvhDHjcuXHuLn82L0Tu+h1qCg
ryTS+ZRqdibZpo+1fs+d8eskYEgH5VlsfG4kAjevi3Jw8Cl0zZRZKQScsgksTfggsKCdEpd8UDG7
+PNDTcgYZ4oihoTyin2GfvtoTA9Ih/sFibwsMlZkIbvZI3gCMdEJB/eA3c0wOBBy5qCGFzwKaTni
pDEGmCQoQIbWVWoYSCQMslK3IlsUBmqs4IA4aLVHNLk34vscPuN+SYtTAbdF0BOkOR6IDDb6Q9Vd
hAuuWvuz0cJtE3aUC4wXS0Us8JDoaiaJ2jmPLSvErSlF5k7NH1GEtKOWUFJPdNXR01NtrabHhzpm
ynUvbZx6ubZarq3YG0wIts7IieDh2vrN6PbZwWEMfVhO79SvsbV/BqNWm3hvw520je6ZzkvkZPUU
/wBJ2XUB2Li6knddzAT3GiVuZsuPeyaKd9PPC+GoZ50Ugs4W+YXt0qkKsFKJ81WpSpVJU5KzjpJD
CCSmuJtkL3FloZjCRc4aqaGJ0744Gk3meIvA4ud4NRGY/bdUJtpysZhFTsELBpfNyyyf91ZhbACP
4RexyRkg02TXAB1+JxUACTbMppF9dFKIYeBQeuqEDb9U14KBmbI0teeGnQqnUjuDqtonNPk3Ivsc
PuN+SYVqc4iRCGTpCcD0KEmKxrnSHdF8StCCGUnJni8Bc9WLd2d2GnCKV7/RXOio6OrfbcjY7pKz
+VvspK6Fu9JQ1DW+1uEt+Lbrx8RQnq0rn0eCxWHuouooN8Si4luCWN5s14J4a/BX2m2hyXi1ItOz
Vj6aneyJIpZYJRLBK+KQEWe02+PFbclfsna8H0TblIwlzu5VM7u4T6182ldOCxMqM0m7xejODxTA
fxdPPTX48F6W/wAy+FnC7f8AJuv2GRK9xnoXkBlUBiw6Nlt+jlz1szhay+jTTimtmj41DLWI5hau
zJRSx1+0XgEUsZji5yvz+GAVkUmc23eA77ruJJeeLjiUt7HmjAoBAywTidUAgOeKeCCM9FKBGCQL
FCARHihUbkUHE5IGU6hoAJWbPfcWkODCpybcRtRw+435KNbnKF0iEInSHLwKEmGwNMhu4DE6XV+B
kBOL356Rrnq2u7ux3YZzSSjBfV2N+lgonEb07m4a09/kV01DA9jgaLalOH6Bs76d/wAH2C8uqtbw
qWZ9DhqtRRtVwrnT5cbVPujflqtpwtH9UoWTx6OqovlNEnxR7NnH9vUuo5DlDVO34H+5OMv+5efN
RqNwq+mXEj2MOlTpqtg26tH81FSv38vlNfCRTw1FNMIamF0MpFw12TxxY4YOHRRG3BcMoShJxkel
CpCpCM6bvGSumSxVU0cApzI8wgksYTfs3HC4BwI0LTguc2psfsGGspBenIJkiZiI+Lma7vFui9Tw
/FPWnP6Hzvi+CSl58NFJ+tcZnz9TBJ3GueLGzbjmrG1T2Gztl0QIs+8svMjHHqSvZiz5yRhk2J+S
MwcFJBI06HglBQAbg68kAgYgFAD897hmktcZ5FSVDFNQAbkJuOKBjJBdpwWNUggeK0gY1Njaj+yR
e435KNbnICEBMgnAoDDaWCQ3F8TrZX4HMOVMHY/jPyXPV3elztw6eVevKrm9TTUzQO0ohnpJIxdF
TnZkzSL1MX5KhvwwK8qv5f5o2+Z9Hg1iVaVKtCpbiX7SidBs6HaEIJ2XWiYetHTPIf8A90EmalZU
UNTviph+jSgkPnpo+7f/AJ9Of9K4Z6aVNYPaXQ9el+JOdSjDy8VC3mU5aKa6S/aSJg6s2fTMjkFP
VbOmPdbcvpJD+B2cMiifTRmKSekfJLDH6aKT7RT+9bz4/wAYVZwc4uEn6oq8X1RtGpBS86Cap1JW
rQe8Km12uHxL7lMhTU9TLTPJaTum+839xzXFCTjJSW6N61KFWnOnLaSscvt7ZbKWKSopgBSSjFoy
hcT/AOJUHlbGP6nRzNFo56W7RpduYX09GoqkKcuqZ8LXpypznGW8ZWZzATgchbRbmAXKeTvAIB1y
RpkkUohjgcLckwEgkahCANroxQMaMzgjXJCBDYgjiCsitGA5lXhuUqe1mrH9ki91vyTF0HEIkQE6
DkeiAxojKJDuHXiP3WjAZr/a2tx+8/hYVc2utjroZNPRmfS1zoqGSvBb2W0Gk6NE4H/mF0IlrY2g
12zYpGavkg3PhJCvNreYk3bNE9zCrCOUV6qFR+2Xsbf6MvxM2XUhro530rwRuic9rDfg2ZneZ4rT
mnqGPjh2vSyS928MwcBUBvGGYYSt5OXnyUFHNHWH5o9D34eZJwp1Wo1o60K0VpLqrfqhAJ6Fr6ml
qI56WUhkryw9k8/d1UR813NVZRTdqDTxyxM3PRvdvbhObGuzczhdc9ZuMcnH5X8jqpXnN1UlFtZK
1Pf1R2f2+6IikOnVcpuSQvbZ8EgBikwIOQJ/lUNs7Lkq9nughBM9O8z0442Hfj8RkvV8PqpWi9k/
8PQ+Z8aotTzr/qR/zE86Dg9rXN80i6W2K9o8HckxJKc0qQKBYnFGvihDC4OhskdcEfqgEOWiLIVE
1CNVYATgsyvB3B1Ux3RSp7ZF+L7JF7rfkmroOFiFNQktJpyPRAYJvv5DM5lWos8JWDwus5U1J67G
0K0oJJK7NukiDwR9IhJtgC0hbtMNr0Te1ihnYwZyUr+0aOrR+4XJUwlTWVOfZHp4fxKmkoVqd4Pf
S6NeDaVLUuJqYu/kailAZJ/3x+a9a8U0tHS5Q1WzpX2c25+judzGcEq8mW7mlaS90fkfS0ZRyxoy
m/Lk15U93Ca1Ub/p9h5kZFK51HUzbssRY8Pwla05xS6P5OUJsAOi82o05ae1bHrU1KylOEVUaWdx
2dhpsQcQAASXE2AA1JUMcsM0TJoZWyRuvuubru59EUJuDmleKdm/mQ6kFONNytJq6XVCmxGS0aZz
5jHaQMkY4AO5+r8clthXaqujujg8UpqWElLmDUl+h595RUDaPabnxsDYKsOljb7DxhIzwKw8Dfgv
pE7xi+qPjXo2ujHC46p1iAMQrEjylNrXRkMQJXebnpdCAAuE1AIbC2aEIEuqFdjGOqvH3IpP2Mux
2+iRe635KNbo4gQpIZMg5HohJzkt94dSkaDfMoC3GXgiziFtUG16+je10chwPQ/FAd1SVexPKE7t
UDTV1u7VRACT/vblIP1UUzdp7DrOwncGPniO7MzvQVUetr521BxC4MdQzR8yCtOK1fWJ7HhOLUJu
hU1pT2XRksVWC6OCJnazOADY72a0e1K4+a1S/S3TU9JJB2cQmndC+eXvxU7xhp5wcfNK8OOFj6ZT
5lqvk07H1U/EJ2qKCu0vd89m/pcgqxPU0L462JlFGJGsqJ394OfGb/27BndSMq4ajaD3wB/14d9L
iLCwwSR+ZK7Qbw0WvlryZKnJeUlJuT5btb7WMPOl/EQlUT85yhFRjskt7loKWCURygnzHd145H+F
56bi0+jR6laHmUpw+KLX3RB5SUZn2VOWXMlM7t475ndweOhC83Fji3L9l9NSt5aPhJJ5hwAwTrAr
VEDsTfHLNKL4oVDQpRYjNQCMaDgnEYlSGJbNIgYhVGtxj8Qrx3RSftZbYf7SP3WqNbo4RLoUkFgp
CcChJz0mLwlYEBcYFZDUAoDmkOaSHA4EFeo+Tu2aPbtDLsTa93XG9G8eeHDKWPhI39Qg10sc7X01
RsWvqKartJaNoqd3Bs8DvMmYrcJMclJTl30qWKAPphN3aeGFuDZC0ekcNF41SOSUlbRXu+Uo9Po7
H1GHmqqi1LV2yrhuW6fZo1YoQJhUSSOnqPv5NPcbk0KxvPkJFy8nhjcrxas3OV3otorhI+mo0o0o
W53lLqxj2uabOBBsMCmGxBCzNDeiMctFDKWjec14lGYO4d1w5Xabrx6amfSz1FKb/UTOjvyGX6L6
LCSvRj2R8Ti4ZMTWjwqk0u1xgSrqRzChKNM80ZUOOYSg5qANOZHQpTdSBumiFKIGm1ziqVb6MdVa
PuRSftZaYf7WP3WqNbo4gSKSEWUhtY9ChJz7/PT2IC5GFbAwQCkJjJJYJY5onlsjHBzXDQhAel7W
qW7b8nabacTB9JogXkDWIm00XRp7wXLUMkcDxHDTySyvbcAOxDAci52TeS8/GQbdlKykvU/lE9nw
qrGN21dwn6V85aHQRVUz4oywRRSmtFLJv/XNiPHDO6ce0qXSMB2nWlhc14YW0sG8zNq8qNKFOT20
b9cle3Csj6GWInVhF6tZU1BO13u9RtGadu8ynJ7CWCOqgYXb24HXY9tzwcrt1zYhSVVuW7377M7s
G4uglF3Sbt2NzYrozFXRSAWLo3AcXOuxeb+UMe5tZ5+9gikPUdw/JergZXow6pNHzXicLY6t0bi/
/Exgl8V3I88BYE55JRckoyopJvzskBAINxmUAjhiMdMUHTDRCGJe4zRqcFYDScc1RrPRjHVTHdFJ
e1ltn2WP3WqJdBxAhCETpCcD0KEmA/z/ABKkYgL0attQClQvQHS+S1eIX1FO8/VuIJHJ3cf+hWRA
W08vZyvs1hmpZXcB6pKwxEbwXW52YKeWpLpb9GjZo5WOpYqUVMj42bl46SltvmPEFz3Wx4lb0sEt
VFWh8LIzJWMqIoZXbzQfXEm5o86BePXnCnNN2XqzKN7vVq7Z9PhaNSpTaTk/RlztWVkrKxMyB4lb
LJJFdsLoo44Y+zija83PElTE5LzatRTldKySstbs9ahSdKDTd23dsv7MJNRKwC5dEDbLzHBy5Pyt
awVlFIy269lQG9A+4H6r1PD3enb5s+e8XVsX3hH90csAUDqV6SPKFzOiXInDRGVEsEt8fEKAI7Aj
qUhyClBhdGoxViBpsqNZjGFMd0Unsy0z7NH7rVGug4WCRCSdBy8CgMB/n+JUjEBcjKuNOCAUnBRP
KAkoJCypJ4scFeMhNfWkayB3xaDisMSr0n3R14J2xEezNumr4GACStiby3/4WzHtWgfExrZXybl7
dnBI7PwAXz9XC1ZSvkyrq3Y+vw+KoqMUs0pLhK4j6ir9O2mDKT6RDF9dG4TOD8C8aAA5K2bgkcyF
hWp04KGR34k+G10OvDVq1R1VVSTTTSXCZZo3BtS24JDo5G9CRgVz/lWWOGz3MYIx21Q0MvfCw1Xf
4fbJp8TPF8Y/3MP+JfqzkQheoeMxQbm6Dn4fFCAJSEhAOcmogwNykw4nNSiBCc8FRrPRgX1CtHdF
Je1lln2aPo1R3XQcTESIC0mnIoDCd5ycwoC5GVaBQCkqF5QCQm0pP4T+qtub2hqd0h5e9uF7Du2u
1Y13aKfGZHThY5qj65XobUEpj70RfR9aVszfzNW7SVG0JpaTd2n2tp4zJuVDWM7L1rxOAN15s4wt
JuOfR678dD36Tq6a5FeOlrc9SQsphU7td24qHVbzCyYyCMgOvHuerkr5vc3zubry8VnzQTtkt6Ld
D28HkcJNK02/W+rLNFb6ZDhexJ5ePJcv5TvJGyxcYyVTvC4Xb4d7fqzxvGX/ADEf+JfqzmL5ouMM
8gvUPGYtrkIuTqhAaJRa4QCE5YI0AUoAbJL8lIGEnUqnWejHVTHdFJe1llh/tmdGqNdBxDUIC0mn
IoDBf546lKwoC2wqwDggFJUTigEY4NufH4K7TAxxRgtc573YMAxc44rnxGsYx6s68G8s5S6L9Tpa
GVjHhrnPgeTg2XuX6OyK6OSJsjGtqadj+Hax/Ir5/EqdOalFvXaS2Z9jgZQq03GSV1vFkLaVzHMZ
HOG0japtQKctLi0tbbda4nBvJWOKyrVfNyO1mlr82dOHw/keYlPMm9Pki5RA9s91z3Izfx4rjPKR
4NVQxWPcoi8//dfdeh4cvRf5s8Hxh/zPaETBuL4AIH7hekeQKLX8UuqADkgZjhdSgIb3CCQpAEg2
SXuUIY2/IX0VKstuBTHdFZe1liP7NH0ao10HEKkQFhITgUBgyecOqGnFAWWFTgoALlESgHwhz5AB
pYnoteOOV5mLHNBA7GNxNgXHF+PFctZrPtdJHoYWL8vezct+yOgpo2sP0aRlVFTOjlNVDOBJGyJr
b9pG/wBpaDL01PDK9+0aESMaWzTOFVBK05GT2SuCbU7pOElLi2kn+zPWpJws2pqS5T2X7ovxySmW
pgmjjZLAWb5jJ7N7ZBdpAOLeYUh6LyKsYxm1HbRrrZ6n0VCc50oufu1TfW2hagaRBIQO9I8RN/dc
BtucTbar3A3ax7YWnlELL2cBG1Fdr/dnzHis82LqfJpfaJmXTgu080UHAJdT1CgIEgNipRIE2IRf
FSQwJxySZ3QDCcCLaKnWn6sYaqY7opLZk7PszOgUa6DjBCAspDkeiAwJfOCa0oCw0qUOQCF4AzTG
3e4BouTkEbSTuSk20luzapqckhjLX3S57sgANStCmpKeR4LoQ4kX3Se6b624ryqtWcLzTtc96hQp
ztTauo2OnpaeaFgFPU2b9xOO1hPK+bU6Omp3yPo5IaihDojPNFFLv000MR3nHkuGFbM5uP8AqWu1
bSdue56lSj5UYZ53pN6PmDZPSOfLE+pkBD6yU1BHssOEbfBqnJsCbLjrW82aWydvtoelhV/L0ly1
d/U0S9lI2Rz7EUdO6aT3rb1uq8iYXuYC4kuddzjzdiV7+GhkopfJHyGLqZ8RUlw5Sf3Y8EcE8EkE
LdnOO0FkoAsM8lCJAo4qQxBYk4pL3tggDUJL5oBmY44qnW+iGWamPuRSXtZOz7NH0CYt0cYIUgs3
TXHA9EBz8xsR1KjDggJRIE4SEmwBQEsUEspGGF8ytunp94u7NrRYDfecGtHMrlrSzSUI7cnfhqah
F1Jq/Tr9DVp6Z1S9tLSsLgTvEuw37evJwYOC6SkpRUSw0dGQ5oLnumcLbx9ed/CNowauOs7x059K
PYwscsrz2gnUqfN8I0GNjL5RTmSSNoc9ry2zjE3DtHjQKOopqapjDJ4GSN0ORHIEaFeK5TpVM0HZ
p6M+gyRnTyVEm2lminezZK4lxJNunRDHRML5piOyhaZZLnRunicEpQlUqwj8UkiK040aFSfEIOxl
slln8nPKeST08shJ/wC4b1hyAC4MEOY02wLQV9Ola/c+Hbbf0JAnXOHRQQP0CXQoiwccEXICkDAc
CeScgG3zx1SEmxQDeCpVp+rHvKY+5FJe1k7Ps0futTV0HGCEBMSonOwPRAYrxc65lIGNJzVW2XjG
6JmRRnVaNPSOcQYoXE8f9ysZSm9Dqpwpw1lbQ0WQxN9JJvn2Iz83aLVpqKeqiD3FkNKw+ecIm9NX
uXNJpelfVnfTi/TUknv6IcybN+kpJKkmjoYS2O29K6Q7pcB69Q71WDRq1xuFjdn0DXzCd4D3gbr6
x40t6sLVwVZt6x3fph+7Paw1KMWozekPxa8uL7pFiUbu7s2jIqJJpWiokZh9IlGUTP8AlR6lV5xA
yUxwydoIxuSTA92aW/eLBo1uQ4rnrKORviNoR/c7aTqXjpZzTqTXKT0jH/7oQG2JWbtibdDKAW7p
bNUkau9SPwzKt4dDPXzcQVzi8Zq5MJlTs5ySXZalbZVS2OrfE+5ZM0d3QuH8hctWUT6Grlpc2t78
L/bjdkvfR8pfVEDc728E4Z4hVZZEgtc/NBthmoZYCNMUjyLnRSBbEWSHqhFxE12QQDRrhqqNacAO
XzUx9yKT9rLLPs0futTF0HICEBKSEwgEHogMoAl+BAxKsRxzkmwB+Czlc1hlsrmlBT1ptYBvi0LS
ZQucR29bEOQcZD8AuapLe87HfQjG68um5S4sakENJE9oihM0lxumUfKNufiuibsuQOZNtSofEbXj
iAD53DgyMYRjmVw1JqV0vTBbvqezRpSpSi5JSryXohxFde3Vl+MT1rXUVJTshp2EPkj3u4Lf5KmU
5p/ahg+h7NEkslR3JJw20tQPYiHqRcTquVycvXzL0010R6apwj+E3eEfxMRN8ve379gcWUcUlPTy
NdUPYY6ioZ5sbdYYP9TlTADQAAAAMAuevJXUFtDS/Vm1JStKpNWnN3tylwiKepFHAKiwdI4ltNGc
nv1efwsXKEnG7y9xJc5x9YnNx5lex4bScKGZ7zdz5nxmv5mKyLamrfV6saL6GxBBB4ELYrKYbY2a
JY2htVCTuj8frM6PzC9A8g4oPDmAi/McOSeCQCeSo0XTuStA46BAxOaguAwBOOSaQS8IQwBvpqg2
4IQBPNMJ73QBCUJfAc1mVZBGuJVo7lJ+1l1n2aP3Qmrc5AQgFIN08g2PRAZbA0vO9fPRXIooScZH
DH2FhUtqdVHNZWSfd2NqmpqQkXqHnpD/ACVvws2VEMYaqTD15BC3x3V59WVNP4j2sNHFzsoqEF1u
5v6I6LZztpzgN2XRdi3V8DN0kfimkU8dJs+l3jVTmok9anpnYX/5sx/Zck7u0qukFtHlnrUFGnKd
LDPzMRK3mVZepQ/q/aJMw1O1Y3RQmlgoqcB7mh25Tw8HP1kcUj6mGGOaCgLwyQWmq3DdmnHstHqR
8sysXUah5ktJvSC6I38uOb+HV3CDUqs3vOb1y/uyi0BrQ0AAWtZI98UUBnnJ7IEAAedK72GfuVz0
4Sq1Iw5kzXEV40KNSq9orbqzmKqpmqZ3zSkb1g0NHmxsGTG8uPFVTcr6mKSSS2SSPhJzlNylLdu7
HA5cNFYoqn6LOJbEsI3ZANW/7KxUi8oaBsMpr4wDDMR21tHHKTo7VYIFiRhmokTHlDiRkgmyoX3F
ddotjgceqYCc+JQsLc2KLhLAQk45JlwSOJKLYhgSQCVlVJuArx3M57M0GfZo/dCbitjlESIC2QkO
RQGQwgPN2A4q7BJT3xiH5yFhU50uddBSsrVLM3KaegAF6Xe6zO/ZdNQTyuIFFsqHf0e2Eyu+L159
SUr2hDU9qhSeS9fFNQ5SagbktNtKe39Tro4W57tRLvHwjjU0b9j04HY001bIMnVA7OAcxG3E+K4q
mWEs9V55raJ6lCU6lNU8JDyaPNW1n2gnz82Q1E0tVL21Q4PfYAWaGNaBkGtHBQkjFcE5OUnJ7tnp
QjGEIwjslaKIqiaOmaDK0ucR3IQbOdzdwaudqamaeUSTSbzgCG2FmsbwYNAva8Ow2WHmy3lsj5fx
nGKpVVCGsYb/ADZUOZQvUPFC2KCbk/JGQbOzZ45InUFS0Pje1waDq05s/cLk6mjkoamSkkx3AHRu
9uM5FHfUlbkIzStsTexwVC4xxJIGOeaU6hQWA62RdGQISVGL97BEGMlJGuizJySPFXgZT5NNn2aP
3QmrY5wTUILhKacihJkMLmyGxIxK0IJ5gcJNeAWFRtNnXQjCSWlzepq2rFrTEdAFtMqauUWfVTOb
w3zZeXXq1OrR72Dw9BNPy4t/NXLsLWtyAV5pXkzue/Tu0iVrHuaXWDWAYvJs0KpNWsiH1B3nfeuG
A9wfuV14HCOtJTkvw1/lnneKeIxw0HSpv8WS3+FGFK9xcSSSSbuJNyTxKqkEg5c19Ej4/d/PliWs
Tgk0OGqEjSbXFwgZoBw3gQWjvAghatVTjbGz2dkB9KhJdAePtRnroq8ok45jw8A48wRkdQnF1ha+
FyqsvuNBsOpRpkc8FCJYXNwi+SMgjJuM9bJbD4KQVJH81RlPdzWkTOfJqMP9tH7oTFoc4IQgtIJw
PRCTHB75xGZVyEEnJc9VO7OzDuKsr2NumY8kd0rfhikaAXljBxe9rV5lWlUm7Rge5QxFCmk51Io0
ojDdt5gQdWYqwauBgBZHd1z38/0Sj4deSlW2+EYnxpKLhh7/ANbKM1XLM67iRhgOHTQKi4uNzje5
uvWjGMUkj5+UpSbk93yRlhuFGQLGwCkgiOuCjc7hmhZBS0dfXl4oaCoqgw2e6NvcaeBccLpkjKmm
n+j1NPNBL91K0tJ6aFCt1ckvhnmpoJzBLvXNri/8qpYj27TCN/8AUYwBFM4NqGj1JNHdHLBJAcQo
ZMQvjml45KCwgsBY3ukJwUIDbg4gafApshsBicVZEMovNyVBOTYZZq63M5bGiw/20fRqRaGAl0XQ
gtXTCTYoSYxcGvxaDiVNHNGDjDro5QyyNWCqpyLGKYcw4EfAq2GUryNx7d+xdulu674G4+CoaIvU
k+4d0k9m4/qtposTnlmhIbmaaRYmwQEbwSM1HINwEuOCAoSzNsXPO60f/LcyV2uxPIiariFZtkup
KLd3uwLt2WQcZD6o5JortkerRJXb0selUpnfBDFs2JlHQsbZjizF4/AzQcys3auz2bbgn2TXhrKl
o7SkqGjUeu3pqFmpzzKT9snZLobyo0UpwjrVprNKV7p23S7Hir46imqJ6aqYGVEDyyVnA+0ORzCW
wsTbBXMt0jRo6ljo5KeZu+x7SwtPrN/kaLlqmkfQ1D6WQ3b50T/bZp4oFuR2IuEgsqGgE9MvBNJy
z4BAGFjoBqqsrzjgcVKKsg0KgmyHFaLczexps+zx9AmK5iIhCC2mkixQkxH+d4lK0clBZF6IDBak
bI3N3XsDmk/DodFRmiLkTXPuwkuc1pJ/G32hzHrBa1HMZGCF1t9nmO5cEJZdIcTfBG5njqhBDO4R
xl4GoAWdBT1u0axtNSwuqap+UYyaPaefVClDY9V2R5M7O2A6Cqr7Vu1T6GJguGcom/6iumfFG+em
dtaeIzSvP0elLvqw4Y2HtuCo/VLJ+Ve7/wBG0b0aXnPSc9Ka5S5kbBJJxVCupPpMbCwhs8R34H+y
7h0KmazRa5MKU/Lqwlwnquq2ZwnlVsg7Zov6rRxAV9I0sqIdZGDNnUZtXl7ZmvjY5rgQ4AtRNSjF
roauDhKcHw9H1QXNw4E72hWhUwDalCGtFp4iXQnnq3oUKnKNd2jQbEG5Dm68wpLkaoaIYTh+yBne
2aAjeQAQBgBiqpNyUKMac/moJr2VkUexps+zs6BMVzBiFCBFlIb2PRCTFf53iU5guVDLI0IRyWtC
xptgM1VmiL4iY5oFyw3BY8DFruPTimDftfBkjTZzQcWuH7HMKqJN2Gpinia9oDX3s9g4p1nuvgLe
0SpBNT7Kn2rWUlDTvLXyvJklOUcTM3W1dwXqez6Om2ZG/Zuw6YNLT/cVkmNnfiOb3qspNJKPueiL
0acJybqO1OCzS6vokbVHQwUlyHOfK/0s7zd7/wCByXn1TEyo2jVTVxZNV9s+I7Pm7loL9w0rj65A
vfVXpxUVZGNapKrUc3u+OElskdps172xmmmq+2kYGvbvi04if5vbD2tL6rRJUmZkVgfST/1CFpOA
FUweszR45tXlXljsKPZ9T/U6QA0FY653copna+65Zq6co/3I6pPNTpVN/wAkn22OUBFsc9VZgnMU
ozs5SiGQbbpBFIK9je5I4Nnb7L9H+KxCSEJjygzJ64oc618s8ELFN7rk49VFf4qDJgbW1KgluRjx
V1uQ9jTaSYGdAmK5gwTUCLaQnA9EJMV+Lk9igsjQiBJGS1IWvw7zRzJVWaI0YmCzS6Y2tgA0kqZ9
KXNBiDzKBaz3Ado32Bz4KpJDTVJgljqIrObbUZjLLiNVviz2h7CC12RP8KQzd8lKmKl8paV8jsJo
HwB50cSHNHivRdnF1JU1NBKCHOldNE72w7PxVJaSpvi7X3NIWlTrx5yqS/t3X2ZrlYm0q+ftX0FH
CXVZg32SlodHBvEtY99+Y0Wi3OU5yGtrdkCOii2KX19W4u3zUtlMr9ZZTnuBdXBX0k7zAyrp5J2N
BkZG8Gx1w4KzRBbvY5LnZaWlhEuzalgfs+t3msvkxzvU5cWrOejjLpv2Z0UG5KpS+JXXeOp4vtbZ
dVsbaElDOS4tbvQy/exaHqMiqgOAOCkRd0atFMyRj6aYBzHNIN9WrlKmmfR1L6d1zbGJx9ZmiBaS
GAAXw0VWR5BKgm+hBfEYBF8lJUbqcNFFJdwAGZOAVluVlsaTRaBgvoEy6sYsLpEJLSQ5HogMZ3nJ
7BioLI0oBjmFqwty72iqzRGnEGA+cSeRV9kQIFoje2ZVSStWxBodUNcLEgzxtF8sO1H+oKOkqhTv
dE/0Lj+Vykng1JGFwLHE5A3bh0cF6TsfaL9u0Bp5ZGs2pRgPa8eu3STx1USTlFx6k05+XOE+IvVd
VszqKKr+l04eW7sgJbKz2XhZ+1aaMPZXNrxRTRtMfbkNLHMdjuPDrA8kg8yUuplWh5dScOE9H1Rz
9JTQ7T2NVz0FU+WsqHN+kST/AFcjw037F275jCMrLT2RsSgoQKr+nspJtx14xLvxxA57mQF1q9DM
tQVstf2M9BLCaTfcJHPY8Ofu6xHAW4FXamniqaeWCUdx4x5HQjoqSSaaezLQnKE4yjvFpr6HKbW2
SduUL9n1Lms2lR9+mm9rgejsnLxv61rpGSxlkjHlkkZzY8ZhUg24q+60fdHTUjGNSSj7XaUez1Q4
kggtON8Fqz042rQMsQ2ojuYz+Lh0OquikkcW97gS17S0tJBadHDRVyTc4quzI3QmBtkksrAbcAHP
LFar6EwU15B3yR2vBjR6nX2lKKSIiQ6MEDAqFWMmCRCS2kOR6IDGd5yew4qCyNKFwByWvC8C3dCq
zRcGnFLKQBh8lbDZHgA3KqSPcGMJLngLHmjYxwMQcYSAIsMnfd3/AFajCNKgqHvtTSTAWH1bz8it
SnqJaCrjq6X7RCTa5sHA5sPIqQz0yOvp6iGLblBd0Txu1UWotgbj2m6rQrtmUW1RD9Ic6am3biC9
o3k+s62JI0VYXjOUfqvqWreulSqX2vBv+nZ/YxqBva1ssdPK+UQiSCavDtx1m5RnMSSM9rILSr9l
Gu2dHSGuk7r2OMrg1/a7uNpBgHNOq0OdGFLtjatNPI6ahqRSUUTgXNjZEyctGLyXHusHqtGJXWU8
pnp4ZezfH2jGv3HjvNuL2dzU6BFWvppZWslgIbVQkmJxydxYeRXnnldslu0KX+vUMJ7Vg3a2H1iG
a+8xZ7Tae0tfqjo1lQhLd05ZX81LVHnbDdoIINwCDyUsNTJTvDmHC4upDErqFlfDHV00jO2dcPYT
a5ByPPgVy72PikMcjCx7Ti1wsVJTYS5tkmgOLgxoLnOPdaBck9EQbOp2XsScVEbHtH0tx7kdxaD8
cmm8NBpmVHt+rpXRspKI3poj3pfv5NX4+qNFdaIpdmOPQt6BRoUBCAtJpOB6IDHdcu8SnsBvkoLI
0oA+4sAteFktsA3xKozRGlEx+tTG3H3lZAp3C75pZBqGtsoJJQ6JgG5TNbiO843/AEUNRUtex0c8
29G8d6NvcDlN0DJIfk/zhiH5F49sf6ua0aeqfKTHO8l480gecBp1UMHReT+2Tseve6UAUNRYVTPY
dkJf2cvToSNnVQpXOH0aY3pn6NcfUVZaOEujs+zNKSzqrT5lG8e8SvtXYYrCDBJFTbxP0m0VzO0e
o8gg2UGxdqsdsyWqrNo05iEhDHWbF2ceTQ8A2DjbJbbo5Wae0aKPaVEIu3LWl8cjJGWcCWEObngQ
q1fWy7M2cHFxqqokMiaW2dPIT5oDUXQMhoNq3ooZa2UCaWqMQiDCDHI7KG2pbq5TVIfQ1RrmC8Lw
BVs+Uo6arOpolLlO5vhrObg9prL9Xs/ueR+Vewf6NWRyU1voFU4mFwyjecTH0ObVyrybjBWYTdkn
uh8FRLA5xYAQ4d9pycP2K3T/AE2ugHYSRulA+y1JaJG4YWJwc3pirRtcrLY6ui8jPJuanpnzbFre
0dEC8Ned3f1yOSoO2RQ7GY51RXUlAXYCOP62cjh3cSrwUXe9+yMnc5at2m2SJ9NRwmCnf6RxFp5B
wJHmtPALna02iAsLXCrJ3ZbgYPQt8FGhQEICykIwPRAYz/OTmE3yUFkX4TyK1Ib2Foyqs0Roxtl0
jAHMqyDJ60rQFUsLeLG5dLx0Si7TgGM5nEoQiOSIPw7R++CCx5yY7pwORVIggkNBY9hHd1Y7h04c
kQRswzxVERJB32mz2aHn0K7jyW2kKmA7Br8BYmik5D1PeZpyUtKSaezCcoOM47xaa+h21BUyv7Sm
qMKiCwd+NujwsTa+xql1aK2kmY2R1mntYo3RQNsS6XvJTbaV+z7ojERjGpJR9rtKPaWpNsYVAgpI
qUvFDEHfXTNtJUXxBjbhux3OBWrW0QqHU8we9k1O5z4nMIGYsWm4Is5X5MTjZT5Rw1sM0v0KTaM5
Ipqcb0gii9bgGNGr8yu3ZUU0r5I454ZHNHfY1wdbqEdiTFqNn0skM2x6xu9RVIIgdqx2e51GbV4f
tLZ1XsuvnoarGWPFrxlJGcnhZw0WX4dDqqu81PiolL67Mok/FNewG4cGmxPMKxmyMMa3BtxyBITm
RhpJsN4+tr8VK2BLjbPQKhWm7B1UkPYYPQt6BMUmIJEBbSE4HogMZ/nJWKCyL8V+JWnEDh3lVmiL
7IgfxeJV9kLyLhv6aeKqXJSwADfeG4YXN/0SB0AJsJZMTk2wRbFWSBtToIoW6m+84qGeifOCYRLJ
PrwewepyOrVIuZ0cz4nNmicTh+YcDzC2zNFJHG+FzmuuHRP9ZjxkfAoNz0rZm037coI6qMBm1KEh
s0fH/wDV66anqIaymErACx4Iew6HVpCqvTUa+LVdy07yw8HzTllfaWqM6rdBsjZpFNGGB0jWRgvO
4x0hsCS69mtVTZ1YyjkdRbQ2g2WufN5+9cPuO7Zowj90rXdHOyxtnZ8s9PM+kjb9JcI2yd7s3TQs
dcxb+bbqDYuwqCgIqY6R9NM9jmdi6UPEQcbloIS+hBdnl2bXmo2d9LYZm5ta76yNwxuByXNbc2O/
ygoJIZAxm1qEkxv0kB/0vWbvGon1Vvqjph68POL3pvMuz0Z4ud8FzS0tcxxY9hHea4Zgo4forFUK
G3v80uSsBSSSeKoVtuzGGqEPYYPRN6BMUmIhuhAWkhOBQGO/zk5gN1BZF+EG+YWtDvi1nN+CqzRG
lE15t9ecOAzVxtODmXucAcST8lUsWRTRNGEIHvHFSYAekFr6BCCIywRkkgHhdV5KqQsws1txi47o
QixmT33nz+q8gzENsGn2+h9ZOglMEjg6+6TZwGY6FSDboq6t2bWxV9MDdgAfF99Fqzrq1erMq6Zo
i2tRu36KqAM4Gn4+RGqrU2zcx1NqCTm6fFRZX33T+5vEMc04BzHDqHArhavZMOzQWS1Na6gu0x0r
Hb8lRNfftgAQAtUcjNvY20pasudUl7Jp2iWKIgCMRf8ALcPOz7xVra1A+rghMJYJ6eZs8O+LsL26
O5Ea6JyGcq80VdtJ1K6N8EtW5z+zOE9HVsbffZxa4DMYFakdRVV1QJKJ0cstDGGPqr2FQ/142tHq
8+KrUTcXbdarujWhUjCqnL2u8ZdpaM5Lyx2LDWU//EOz2aWrYhnZvrdW6rzhmYIcDcYHkoi1KKkt
mWcJQlOEt4uz+g5xJJuNUnirXIAA2VGt9GOqIh7EQP1TeiYrGIIQFlGh6IDHf5yewi6gsjQheARi
taKUC2Sqy6LzJzYd4+AU/wBKwOP6qpogFSSLXGWNmlxSF8jrkteR+N24PgEDIH1EbCN+YNuT3Yhj
0viU9sVY870dIWa785sP1QqONNEXAyzPqMfMb3I7cCc3KGSmMT2NsGtlc7sfwkf4j/pKki5Zpqlj
YixwN2WOenMrf8mPKWLZ9e6lqbGgq37r8LMhldr0dqis9GVd1sen0pdQVIoJSeyku6lkP6xrUmj7
WGaLeLd9jm72ouLKtPSOXmLsa4lJzVVbVIqX12a+5wrIq3Z0sNNR0lBHXMhaN50jrStOBELXWG9h
dy7WkNU6mhNU1gn3B2oYe6HcltI5iKtoIa6IRSuc1pI3y3BzmasLsw12tlxOy9mOLoxBNQQOpaqR
zy3uVEMbZDeNwGBYR7ShPQlnQMq4GO/qdKDJQ1Li2oBbYYHd7YA5tOvELy3yq8nv6LXMdAB9BqnE
wEYiN5xMfQ6LOGjlHo7rszpqPNGlUW7WWXeOn6HL4XIBQBhmrFBCRbXJZ1Z6ME2zUoh7DQbwt6BM
VjEEiAsoN7FAYz/O8SlaeRUMsuC7FrgcALq/GXC1opDwICqy8S8xs5IApHk87D5lW2RVQA7lNHj6
0n7NVDREwgncLOrN3DKOMn5qQUUB7zu2kOm/Jr0alyGWWs7AHdbFALDEAA/FQuqIC4d98rr6Y5cy
pRBnzbXa3CMNDh6rO+7mb5BY01bLIHg2G9a7id5/HDgrEFyKpFQCSAJABvjMH8Q66qRwDgQ4XBBu
EIZ6d5IbYZtWiOwq6U/SYW71JMc3Mbz9pq72gq3zsfFMA2phIbK3j+MciqPSomtpK31RqvXh5Re9
OWZdpaMvFrHFt2glpu24y6LJ2oNmVNA+aYtlZCHPY5hDi0gW3gL2JHArU5iDZG26atc2kfUxOqmx
hx3DdsrPvGHgeGYWfUU1Vtt9SIYaaKOKqLHb/f8ApBhw3Jmix3dRimxBLs6t2ztGt7MGkbRQOLZZ
oWlzZiMDEzf0GpCo7SggqfJbb9O4g09KJHU0g03O+AOhVJ2VSFvmdVG7oVk9k4Nd72PG2jeEZtYu
AzOpCQiwPL5qShEcAXEiyilpZX0wqJBuRbwDW6uPNSistiqTdijVjIEICygnA9EBjvPe8SnsIuoL
IuxPaLXK0ons1LrW4FVZeJoxvi9l+ePdVoVLG5Qlo4uc0KtjQgftSJmPaU7eQJf8lUftXeGDp3H8
LRG3DmVKQZQfXSEksjibyJMh/VVpHyTHvyPfhqf2CEEQNxa490DBBGVzYcEIL9AwlpNxiXNsczbF
XLYDHwUrchgJZmSRSwyGOWN4fFIMN1wXtWytq/1ygi2nTMDNoUvcqYfa4joc2qtRNxdt1qu6LUZR
hVjm9rvGXaWjOppqmKpgjniPcePyngeigfszZkkhkfQU5cTi4xturJppNbMznCUJyhLeLaZzVXVx
bOqpKeg36Zj6i00n0ftImP3N7uNbj3kQs2fX0k9dWzPp3OeYqn6LM5sVSW5EDVWbUU5PZEQhKc4w
iruTskagifPSjtLbP2bEzCLBjiwe0fVC838p/KmCvpzszZkYi2eCBJJ5pmto0aNWMLtuctG9l0R0
1ZRSVGm/RB+p/FM4l7gSeqAWAXfjhl+60Mi5QULqgiqnBbTg90+3yZx6pu3qvfiY2wAB7jRoE5Rn
J3ZgjGJvQKNXKAhAWkhyPRAY0maQEjUqCyJ2PeLWe4Kds033kmWQcoZdDrvcLkvI5uJRYeyPEfyq
FkOBOhPgP4SEEk3ByGJNsfFCwYau+ATg1zh5mFhiSgY052vrkEgcACQ0X5oip1FE8w+T9bTTMY59
TJDNCSO/E7e88Hm1VCALrToZjL58f2Wlsfa9Vsavir4GlzQA2eIH0kX8hNizVz2dtXTw9ltOleJN
n1gaZLeo4+v/ACuiGlje4FisoaSlHo7rszWv6oUqvxLLLvExK00hr4XwQGeujHdDXENbwMmhtfDg
qO06/ZuxAK3a1QaisIPYwtxPSNunVRfzJW3hF/doul/D0v8AuVI7/DF8/U8n23t7aW3JN6rfuQjF
lKw9xvAv9pyxHG4BB1WjOcjc5rGlzyAFrUOzO1Y2prmubDcGOHWThvcuSlESkT7Q2ibgutcA7jBk
1clWvc8bzjckqIr8xmIPRN6BMVwCEBaSHI9EBjyZjqUwBQyyJW6KcAkZDNQy6JQ0YE7uSXADzgqM
0Q+4JPee4W01TTb2D1JQDu0e3zbAW0UZuc+KBiWAByzuVpbP2e6sJkex5pmusbDGR3sMVkm2Zs6H
abRC+OkuDLGA+oOjJDlGPdCySxxJ4XVyBRGAHYZEXU+AGiA6fyV8oItkyS0lcR/Tqk4g49k86+6d
V6bFTTmmDKbbEX0O3deCCQz3ljUpyk4uM8r2fY3o1owzKdHPG6kl0aOT2r5Y0GzY30ewwyWUYSVT
u8wHl7bl5lLLJLM+eeZ8s0nnSvN3O/gcleKiopLYzk5TlKc3eTepWJ3iBokJDSLA3uBlrwHEqXYg
26TZ7Kd7Z6yPfn86ODAhnN/NMr9pOLiCd6T9GqN/SZmCXlxJJuSqtTiwZK5UQeiamIARdAWUh1QG
RJmOpTFDLIlb0UoAvkoZdEgtcYBSAnkqMuLY3ABKCN3MjS6EkbpI2nzwtqi2BtquaJI6QxQk+nm+
rZ4XzV4wcnZFJTUTsKHyHjaWOlD655yjbeGK/U4la+1Kyl2WTBTFkteAA3c+z0jSNOLgury1Sjrr
J8dDmU3UmcO2JoBzJuSSTcuJ4phDf/4sDcQhoAxOI7/XhzRiBgDZQSG4McslF2ELQLRi18tPgoBG
X2ADBawzSEWBc8hCxMyCSWRsTIy95GEYNj1edAtumgZSB0l2yT2IM3qR8owq6GcnfQyqvaJcXMh1
PefqVkWKmKsVHBijq4wIhhqrEFbKMJiAEICyg6oDHkzSAHkoZZEoB5KVt9XNGPFQXQ8WH+aO+mZ+
S16TY21K0gU1NVS82Qu3fi6yixOaKN2PyC228t7d8FM3Xtpm735I7ldFQ/8A07oC4GSpq6sg4thZ
2Uf5nLaFCTV3aK6sylWjsjtoNgeT+xoBMKSloiP8s5D38yN66xavys2LFKX0cE9dMDhK/CPAYYuW
0XGCdn/dyzHLKo0m7LocvWeUO1687jqgRNdkyE2PQuWMBugbowssp1HM3jBRRETcn9U0tOFiFmWE
3LAEA5ZpHEDRARF44aJCHvBJNlFiWOAia0m43AMXnQ8FYp6KV1qie8MdgGPeO+7kxn7qrfBDZemk
gpIjHuCNpAJZ/kf75XP1NZLOcg1ujQkVfsijKoHJSsYScirkF6KHLulG0YgKYYahAYZNmqNACEBZ
QdUBRihbK8gg5rRg2bC91i05+0mhGp0NJ5P7PeRvRDxeV1dJsHYcQBdFRDm/H/yK0jbpcrdnTQVX
k5QsANdSx21iay/TuhPn8sPJoNtv1NRbQNdb9VZXXSJFpS5b7GTN5esYCKLZAbb15HD5BYFX5X+U
dXvD6b2I4QtDf1KpKpfi76l40kmc29z5X78sj5H+09xe79Uhz1y8Fldtm2g+MlrmkAYEFPuDjc31
UlWKS3gSmEa80QIHPI97imWkcdciiJGksaDYFx14DxU8FJU1PeAAjB9I/Bg6cUk3shexqxQUkAEr
PrXt/wA8os1vuNWdVbVbvkwufJJrK/8A0jRVSuVMR73PcXOcS46koA6K5UnZFfRaUNP+FAasNMR6
qo7ZiLaZuHrIDlXDunqokAIQFi6TQ9EBmHztcypoyb5u+KEovxDmfzFXmxscQSwFG5Fi5GxrbWaw
Cx0VjecSM1UkR7XHXJJui2eKABuDXTBKACDiLqOQBwJ7zctDdDwWghwGCsCIySE2aOSUMIuXHBEB
LgAmwtfFxNgPipYqOpqQC1p7MDz33ZH/AC5Q30INGKCkgA7gneNThG3oFWq9rNBO9aWQHBv+Nvgo
SRUwqmrnqXXkd4aKsArogkay6txQAoDShpAbYFasVIQR3SgLzYXNGRWNt3eFK33kBxrz3T1UKAMU
ICyg2seiAyz5ymZooZKL8V75FaMeiFi2wusP4UzGvJwJQkCC0AXGutky7L4lQwITgbNJNzdJ3yRg
M1AELADi7IqcB7gMHEWAB0UuxLInSsa7c7TvXwbGN96tsoquRjS6IUzfvJu9Ib8GqrbeiKZiyynp
4SHiMzPA9LNkOgyCpVO04sbyGZ98vUClJEGNPWTzHEkN9kKuByKsQPDXHQqwyF50KkF6KlebYLUi
pssCgNFkLQBi5WWtA0PwQCktHD4Ln9uuH0ZvvIDjnHA9VEgC6LoCwkOqAzDg5TMJ4lQyUaEBPtFa
DA8jF7kLFloI9c2U24wWBN8MkJHGIB3djOKXcIvcBg/EQs3OCF0BMAaLygu4NBd8k8CY+ipJ5OHd
3B+qjNJ7KyKuQCCtAHdpqYXzcd9ykGzw8B0slTPj7jFKi37iupKaukowWxyMiNsohvO+KzJ9rBzi
YosT68h3j8FZIGZNUTzm8sznctPgoQrgka0nRWWREnJAXY6Z2Hd/VaMVIRoEBoxwEWwCuMiI9YfB
ATWGjz8EE2zJQDDJhmue26/+2YLDzkBxzx3T1USAEICzZIbIChKwNccMLqeJsRth+qgGrBHTYXv+
ZasUVASN4X/7yq5UC+yPZYGMYPLecVbb/TibCmJOoa0/qoyRBKWUxALNnPN+LU0kR3tSU8XNxCJR
W0CWV37RYwY18LeUbLlZ8u1aPhUTnm7cHwVrMgoP2m8EmKGKK/LeP6qlLUTzekmc7kTgpSsCEN6J
waeCkEgj5KdkIOiAuR019CrsdIRbulAX46ZwtgVcZEW6OQFgBwGqQh41QDCx5GYSWI0QAXBcltmp
E0zImWO6f1QGLUtDLN1VRACVAWEIBrmBwVJ7JYTdoJagJY657eKus2tK0YWUWBYbt6rAwlISu29W
uzq5R0wSwK79pyv8+olPiVCamMnElAAqI0fSIuJUgO3i4lPE8XEoB4nh4lSiem4n4ICwyqpPad8F
aZWUQ9Z3wQFpu0aIeu74Kdu1aNvru+CAlG2KEav/ACpw2zQcXflQC/1nZ3E/lR/W6Lj/APiUAn9b
o9JD+Uprtu0ukj/yoDNqNsTTkR07X3cbDig0X0GEz1Z+tcO6zVAc1LIZHlx4qNACEBaQgBPY8A4h
AWWM2a83ljHy+SsCDYVvRn8zkIYvY7C9g/FyTsth+wfi5Ag7LYnsH4uSdnsT7s/FyEidlsX7s/mc
js9i+wfi5CBCzY3sH4uRu7I0Yfi5AxLbJGh+JR/6VwPxKAL7L4H4lLvbL4H4lCQDtmcD8Sjf2Zz+
JQBv7N5/Eo39m8/iUIYb2zefxKbv7O5/EqEEG9s3n8SnNfswHEE/FSSXWbcp6RhFJTNDvbOawaqr
nqpC+V5JKAqoQBZCAs3SIAQgBCEMQpEJBCAEIQhqEJEQhCEsiyEhZCAEIAQgBIgEQgBCAEXQFhCA
EIBEiAEIAQgBNuhCBIgYIQkEIBLougFSXQAkQCpCUAiEAIQBZFkBOhACEAWSIAQgBCEMaUiEghCG
CEJBIgBCAEiAEiAEIAQgBIgBOQEyEAIQBdIhCEQhIJLoQwSISKU1ACEAIQAkQAkQAhCGCRCQQgBC
AE5ATIQAhCGIhCQQgBNQhAkQIEISCRACEAiRACMUAiEAIQAhACEAJUBOhACEAEJEAIQhjUISCRCE
IhCQQgBCAEIQwTUJBIgBCAEIAQgBOQEyLoBEoKEICUiEghCENukQkEIQhEISCEAiVACEIQJqEhdC
ALougC6LoAQgBCAmQgBCEIahCQSIQwQhIJEIQIQkEIAQgBCEIahCREuiARCAEIASoAQgP//Z
endef

define NHE_TAPESTRY_STEREO_FILE24
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
kF7gEAAAAFAAA//Z
endef

define NHE_TAPESTRY_STEREO_FILE25
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
endef

define NHE_TAPESTRY_STEREO_FILE26
/9j/4AAQSkZJRgABAQAAAQABAAD/2wCEAAYGBgYHBgcICAcKCwoLCg8ODAwODxYQERAREBYiFRkV
FRkVIh4kHhweJB42KiYmKjY+NDI0PkxERExfWl98fKcBBgYGBgcGBwgIBwoLCgsKDw4MDA4PFhAR
EBEQFiIVGRUVGRUiHiQeHB4kHjYqJiYqNj40MjQ+TERETF9aX3x8p//AABEIAqEA/AMBIQACEQED
EQH/xADDAAABBQEBAQAAAAAAAAAAAAAAAQMEBQYCBwgQAAEDAwEEBQgFCQYEBQUBAAEAAgMEBREh
BhIxcRMyQVFyBxQiMzRhgZEjUnOhsRUWQkRTgpKysyQ2Q2LB0SZjdeEXJVR0owiDosLwkwEBAAID
AQEAAAAAAAAAAAAAAAEEAgMFBgcRAQABAgIHBAYHBQcFAQAAAAABAgMEEQUxMjM0cXISQYGxBhMh
IlGCFCQ1YWNzwVJ0kaGyFSNCYmSiwkWSo9HS8P/aAAwDAQACEQMRAD8A8SAXSAQSgE2coOV0MhB2
kQGEgKDpCASZQCECIQIhAJUAhAIQCRAIQOIQCRAJUCYCEAjCAQgEIBIUAhALlAIQCEAhAIQCEBlC
BwIQIhAIQCEAhAIQCEAkKBFySgUFKgEiAQgEIBIgEIBCB1CAKRAqMIEQgEhQIEqBEIBIgEYQCEAh
AiEAChAmUqAQgEIHUIEQgVCBEIBIgEiBEIBCAyhAiEAhAIQCECdqVAIQCEDiEAkygVCBEIBCBCkQ
CEAhAiEAhAIQCQoBCASoBCBEIHEIBCACEAjKBCUAoEQgEIBGiBEIBCAQgEiAQUAhAIQCRA6hByXB
oJJVVNXnJEY+KCMHVUp0c5PspKx3Bx+ZQSGWq4uxhw/iKfFiup/TH8RQOfm7d/rt/iK6GzV3+uz+
IoFGzV47Hs/icj82bx9dn8TkB+bV5+uz+JyPzZvH12fxOUCJU2a50270jx6XDDj2KJ5lW/X+8rVV
eopmYlctYK9doiunLKSeZ1n1/vKPM6z6/wB5SL9CasBfopmqezlA8zrPrH5lIaSs+sfmVPrqGiix
XXVFMax5rV/XPzKTzar+ufmVHr6Fj+z7/wDldCjrCOv95S+ZVn1/vKyi7Sq1Wq6appnXDg0tW39I
/Mrgw1LR1z81EXqM8m6MHeqoiqNUkZUzxnUkhWkE7JR71siYlXqoqpnKdaQhSxC5QPJEFRX1BJLA
dBxVY1xzwQSmPlIABICnRCfT6RyCyiFVj1r1MYKz9s9A8BW/tn/NdgVv7Z/zQL/bv28nzSg1x/x5
PmgXFf8At5PmkxXft5PmoSqrl53mLfmedD2qqPT/ALRyrXOx25zdXDdv1NGUzEEPT/tHJB0/13LC
Ozmzu+s9XXnX7Mh9P+0ckPT49Y5Zz2clKz2vWRlORPp/ruSfTfXKx91e/vf2zjenx6xyX6f9o5Zx
2cnOuZ9urPXmbf0+R9I5N/S9risZ7K5a7fq6fblDgtJGoSRgxShbLcq+KicqZldNOQCulvUiEpED
iDwKDMTkvkOvFxXTI8lBb01NnGiv6aiJxogu4LcSBorSO16dVBKFqOOC6/JJ+qoSX8lYHBcG1EcA
gdba979HVL+ST9VBmr9bzG6n04hyzppD3LnX68rkvSYCz2sJanmQ0iQUmvBY03PbDZibOVm5yKaR
NupcBZ1V+xysLR2r9EOfNvcuTTe5Ydt2PUH2UhLeCU0i3RV7sOHfpyu18zMtNghMmmWua/a6eHs5
2bfJwab3KJWwljGvW2zVnUp4+32Yp8U6MEwtd3gJVdcgiEDq5J0PIoM3jMvxKn00WSOaDUUVNkhb
GiogcaKJTDU01uBA0V1FbARwQTm2sY4Ls2wY6qDkW0HGiQ2xoBO6EHAtmDkYypIt7XNBwiYYXa2i
3H0enZJ/osaaYdy42Kryv1PcaItdrR9mebg0w7kNphrotNFfvQ2Y61lhr3SU0w7k2+mAA07Vvrr9
2XA0fRni7fiZNOO5IacLT23pJspUVMNwcyujTDuVmir3YeTxVOWIu9UolRTYI0UYwLTVV70u/g7W
eGtcnBgVfeYd2macdqsYarOtzdMUZUW/E2wAUcfhamV04ebCTCkOpDwPIoKCIZlPMq6pI8u4dqDa
W6AEhb+3UuQNFCYaZlM9s1EASA6Uh3vw0la2CiHd2JImiiGBouxRAnggzt3dUU12slPE8NZUzSCQ
fWDW5V1JSg8GjiiYMGkweGXHgFJZQBjdQN48US8725pg2Sg8Mn+iwJh9y89jZyxNyOT6JoKjPReH
nq83BiHckbEM8Fpt1e9CxpKjLB3+kpi04Jl8Wg07VZuVe48voqnPG2/E30Q7lyYlX7T1s20yCIdE
OacMIPYrdE+7DxGMjLFXuuUGqi1bp2FRDEO5aK596XqMBRng7PI2Yvcqu/xgUbPEFaws++5GnqMq
LXiqhpSR8mqPldmHkZGUZQOpHcHIKSmGZjzWhomZcEG9tceS3Rek2qAHd0UJaYwYq7Z9s7+mVtIY
Bj4pImiAABKIW6aImGI2jp9/aPZId1TOT8I1qpImDiAo+CTsFHu/SPGpHojuCHxAk6JI8v2+jAlt
3hl/0XnZYF5zHT9aueD6b6PxnonDfN5uCwLhrNeC02596lv0nH1G/wBLosTcjNBzKsXJ9yXldEcf
a5SY3AuSwKtm9jVSnQM+iCcLAr1E+7DwWO4u/wBcoFWz0m6dhUItVauffl6zR8fUrHS5LAqnaRn9
iZ4grWD3ji+kUZW7PzM9p5ozk1R9F3YeMCEDiR3A8kFNRjM55rT0I9JB6DaWglq9LtgHoqEtK8AV
tp+2k/plbWFug0RMJWmo04JMIli7+4fnPsnj9rVf0lr4IQ8mV40z6A/1UdwfkIUR54qB5bt/663e
CX/RecntXnMdxVzwfTvR/wCyMN83m4KRvFaLe3SsaV4DEdJSm5DlgVq5sPKaH4+1yq8jB4LkqrD2
cp8GOiCcOFeo2YeAx3F3+uUCrwHN5FQSq1e1L1mjuCs9Lgqp2lA8yZ41bwW8cb0j3dn5maHszOQT
C7sPFEJQgdSO4Hkgp6L155rT0HWQeh2gDLdF6TbP0VCWkJ/ttp+2k/plbeLOAkpg/h3d2LkntIPA
IlkbqIpdqdl2vJb6VXujvIiyVuXkqO4Q3u1KivKgeX7f+ut/gk/ELzo9q85juKueD6d6PfZGG+b+
qTZQw8Vot7VLfpXgMR0u/gmpeA0HEq1d2JeV0Px9vlKOSuSVWezlYQZMTU4Veo2KeT5/juLv9coF
b1mcioJVaval63R3BWOlweCqtpvYmeNWcFtuN6R7qz8zMg/2ZnIKOu9DxQQgcQ7geSCno/XnmtPQ
9ccyg9DtHFq9Mtg0aoS0bsCvtH20n9MrbwnAGqMkggZOmiawXyBgOO89wQZG+tjZtjsSwHg6u/or
avPvUCE86KK8qB5ht/6+3+CT8QvPSV5zH8Vc8H030f8AsjC8qv6pNkobxK029qG/S3AYjpdZTUhO
6OZVm7sS8tofj7fKTBXJVZ7GVhTn6Ec13lX7exTyeBx3F3+uUCrPpN5FQyqte1L1ujuCsdJtyqtp
vYmeNWcFvJcb0j3Vn5maA/szOQUdd6HighA4uXcDyKCpo/XnmtPQ9dB6FaDgtXplsOQOShLROIFd
asn/ABZP6ZW2hOgRke3njAaCXHqhTYoxEzHbxce8qJGE2i0212KPvr/6K1zynwJRXFR3lQPMNvfX
2/wSfiF56vOY7irj6b6P/ZOG5T5y5KQHUrTb2qW3S3AX+UAnRcP0YOZVm5sS8xofj7fKowVySqz2
CfAB0Q17U6QMcVft7FPJ4LG8Xf65V1WMObr2FQ1Vr2pes0dwVjpcFVe0ulEzxq1gt5Lj+ke6s85Z
kH+zM5BMLuw8VIQg6yg6tPIoKij9e5aig63xKD0K0DBavTbYdAoS0DyRcLT9rJ/TK1kNTAXvjbIx
0jMbzAdRnhke9MpnOY7mS6ggMYLndcjX3e5PkFRI882jJO2uxnOv/orXvJCgRnlRnFB5jt77Rb/s
5PxC8/JXncbxVzn+j6ZoH7Jw3KfNwSlYdTotNvapbdLcBf5R5gkHKbecsHMqzd2JeZ0Px9vlJklc
Eqq9hKdBpEE6CQSr9vYp5PA43i7/AOZKBV9ZnJQiVVr26nrdHcFY6XBVXtL7Ezxq1gt5Lj+ke6s8
5ZoH+zN5BR8ruw8UEIAApTwPJBV0XrzzWooOsEHoVp03V6VbeDdVCV7I4ef2nPZJJ/TKhbOVsUfl
D2mil0JpIZGs7fo2qzh4maMV91nP+FUSmdcNvshtdbNrLU64UDJWMZO6F8cuA8OaAexahxACqSmH
nl+1222P8Nf/AElqnEd6BhxHeo7jxSR5ht57Rb/s5FgSvO47ibr6ZoH7Jw3KfNwSgHitNrbhs0v9
n3+TlxwVw85aOZVm7sPM6F4+jpk0SuVWexlPgOIgulet7FPJ4HG8Xf8AzJQatwLm8lDKq3NuXrdH
cFY6XJVXtL7FH4wrWC25cb0i3VnnLMfqzeQTC7sPFyEIHEjuB5IKui9e5aah66D0S0foq0uF6vtn
lNS2mhlocAD3E/WI1GqhK1pNq77PPZapuyz5WPdIYBFOD0uGnKy1Rfr8zb25VTLIWVstLKx1G6cA
sb0Ort8dwGV0MBGcYyP9NWiru5t7/wDT7VwP2Zu1OHN6WO4l7h24fG1e6SO0Oi5062Uaoef3xw/P
TZHwV/8ASC1RI0UJMOITDig8x279poPs5PxCwRK87jeKuPpegvsnDcp85cFIMYK02su3GbbpbP6B
f5QDGGt3pJI4m/WlcGNHzUSe57OQRYfeWOk+rExz2/NdGMPVdp9kZQ8XhMdThMRRcmM+6UD8vbO9
tdN//gU/HcbFPkR3eMO7pWOjUVaPuRGcO1R6SWKqsptzETOuV/TUNS+j6dgbJGCcujcH6d+iYIPc
piiqmIiYycC/di7eu1xqmpBqxhzeRUVUq9uXstHcFY6XBOqrNpfY2eNWsHtuP6RbqzzlmP1ZvIJh
d2HiwhB3hDuB5IKqi9eea09CfTQeg2jJLV6Tb4IqiN0EgDo3NIkHeD2KGUIezlirLFX2KlnqWStf
XVckTG5LY2mHhkrJVMgHlggL+rLXugPJ8W4f5l09FxnOLj44etjVqjm9r2I8n1q2MirRR1dRO+pc
3ffLjgzgAGrZvcuVLKGAvTgdtNkh/wAq4f0gtY5Eo5KZcUHme3WtTQfZvWCPBedxvE3H0rQf2Vhu
U+ckfuRUslXUSthpox6Ur/wA4ud7gsRcNrZXDdtsfRM7ZZADKeQ4NVrA4Oapi5U5PpBpSiKK8Lbn
Or/FPwY+aomleXzzPc7JOXnfJ+agvnYDhrcnsz/sF24ypiIeKmZnWfipLnO0vhoZntB4tjcU3LBW
waTUkzPFG4KUHqC61lFKJaSpkheDxY7C9Fte3cE4bFeoS459qg0fze3tWi7a7bZbuTS0NfG1vQyM
mZLFI0lkjDlpH+6r9CuBdiabsw+i6MqpqwFiYnOOy4KrNpcGiZ41Ywe8cn0i3dnnLMfq7fgmF3Ye
LCEDqR3A8kFVR+vPNaag66D0O06loC9TtQAa0AKGUa1jV/3h2Y8dV/SXjm2UxofKHS1TI3vdHeQ4
MZxd6EJwF1dDxniLsfGzWivVHN9J7NbTWvaa0x3G3PdubxZJG8YfFI3ix47wrV51K5EsmDvP99dk
/sbh/TC1bsYGvYgYPFMuUDzLbkjzmh+zf+KwFTPS0NHJXVhd0LHBoaOtI/sYP9T2Lh3bc3MdVTHf
MPf4LFRhdAWrvfFM5c85eX3W6Vd3qRUzgMjaMQwM6jB7s9veVnpZy0+gRp2rvUUxRTFMaoeCu3K7
lya6pzmWgisIpKUV13EkcR6sTeu7P1u5cfnTFS5bbbfBEOx5bl3zKya0R219/c7JrCvUNmbjXz0j
X1U++XDKkhIvto2amhMtZTMjceM0XoOBPJea3fZmstzPOad5qqPHrWjVvjCILYr7LbXkFvTU8hAl
gP4jucF6C9sRjingcXwSgGN/+h94XKx9nKIuQ9T6O4uqKqsPVOcT7aUcqs2kOaJnjVbB7xb9Id1Z
5yzI9mbyCjld2HiwhA6kPVPJBV0frzzWmoeuEHo9mGN1eoWzGAoZQz9zi29dtNavNp7SxnTVHmRe
15w0s16VeWbbnaai2iNRc6ihfPBXwv34WODBIY2kHHdhq62hozxdUfhyivPJ7/5ObDUU7bntDPdo
qqS+FlQ5kERihavRnnVcmumaa6qatdMzE+CY1MNd/wC+ey32Nf8AyNWpOgCxlJlxTLuHFB5vtrAZ
auhw4NHRyZJ4DBGq+b75dpbrWjU+bRbwgZ3Nzje8R7VTs2onF3657svJ3MXio/sjA2O6e1VPhMqC
pqC1hYP0uPJbvZax0VLKye4tb5y4B0MLv0G/WI71fcLXLT36po3U0kU4Dt4cF4+bfA2R5c4luTho
PZzUJqTIYqZgO7AzT4qcLpV0zh0UmB3FZyxg1ebzWXKljhI7dW96n7M3urtMogqiDE//AAzqQD3q
CTm1Vgp7eYrhQHNHOcbnHo3HXHhPYu9mrk6KfzGWfFNUkbpdwZJ2H4nQrVeoi5brp+MLGDvTYxFq
53U1Rm1csb4nuY8EOaSCFUbR+xM8YXIwkZXZep0/VFVixVGqc5ZrP9mbyCjrtw8bIQiJOIJ0KJVV
F65y1NvGHqJTD0a0HVq9NtnAImNSxqngbQ7MDvfV68ol857e307QV93rqRjW0DKyCMF3Xkexj2B4
7mnC6uheM+X9YLmp7r5J9qHVVmo7HU0T4KimoRPA/iyopy/d328joV6u8jJ1XPxfFX/zKvMjVDDX
f++ey32Ff/I1aokFaEmXY7ky46IQ8W8rl3fQwUFNDpLOHEnuYwgr59LAAXDTOpH1f+yU0RE1fGWy
5cmqm1T3UU5fzS9maRtXeBPKAYKVjp5e4hnVHxKh1dfU1dzkrjK9mXHcxxLVshoTH1tVXu1JK4ME
uurQACXEngpTJqIl4Jihlk10cMNb96SpIdgSMfE3OjnAEfHdUJhCcXwu1xkHTuXMRc+YOcSSSclQ
hvtj5pa+hq7VXxv6F8eGvI4fPtCxUkTqapqKaQguilc3I7wcFSR7HptLUyV9ppKt5zIMwyHtJj4H
4tKrdo/Y2afprlUU9nE183oMZfm7o7BzPdFX8mZ/Vm8gmF1IeekIREnEh4FEquiz05WqoOuolMPR
bRxavTbYDgImNSZWH/iXZUe+s/pLwTyjbM09mut3ZbpXRUZ82nkpjqC+Uu6vJdPQ/GRyj+qEXNl6
N5MLVfrjTbM3KofSRW+2RVjaboy4zzGb0S2TsAC90cSqeN4zER+LV5lOqGLu398NmPsK/wDkatQc
YVaWRl3DimnFB8weVusM+07YQdIKVrfi7Ll5nUktiJaQN1gHz0WcMV9ROfR7GXSpyN+smbCHdzGr
O0Fa15EM0e8MHdcOxSg+J2xgERDBz2/7KVI8F8cJDejazpJsHrdzcrIhfWHZ247QiSodVspaaMho
7PkF1d9nJbcwviqRPGBl3eq/rYm72Ybuz7ubHCmlcXxsG8A0vb7u9qSmG5JGSCMPGVta5fQ9uoIu
gZKIw0YC8a2xoxSbTSubgNqA1/uBd6JUzqYrnZKUup7rRE5G62ZnNh3Su9pBikb4wqFUfWfB0orz
wNFP7NVTM/qzeQTCvQ5suUIHkh4FBW0Pr3LUUHXUSmHolp4tXptsOgUJjUjbSS3Vt02f/JccL60M
rTA2bSMv6LtXi23N4vc1TXQ7QWsUdfLSUzAI9Y5OjkJ3wunojjKfDzhFzVL3DyPzB2wtGPqTzj5u
yvR3SjKrY+PruJ/MqI1Qxt112x2YPZ0Ff/I1atxVRkYccHimnEIPkjyhuLtr7tnsfGB/AFja0gxS
aHsWyGPe3tksbr3sfT04kLN2qkJKorxsp+R3wvbIXBwdnPfhIIZYggdnuTzCN9o0HSRFuezI1Qh6
bsrVyPtQghA3mOIcz9LnhWt2jNFRyVNSSN6ExsB0LnP46KtFE03KpWM4mmHk7w8OYWPwQ0yHswM6
fgSo2+S9p11OW57BnRWWiWqZ5Q7iWRwsgaOzOVF2ze6W40L3HU0rM/MpLE/sk8tvJb9emnBH7pP+
itdpDmkb41Tub+nkuUTP0b5pZf8AV28gmFbhTCREQfXJOh5FEq2i9e5aig6/xKiUw9FtPFq9MtmM
BGR2tY921GyxAdhvnpd3eqA1Xm/lcdCy6VYkexplssXR57XMqQcBdDRPGUf/ALvhjXqRvI6dtHvM
dE+MWQTZqTOP0+1sK+iX6Ej3rDSHG4j8yWEaoZC4uI2v2Z+xr/5GrWk6Ki29xokJpxCgfJ/lHaGb
X3PPAmI/OMLGVTXGKYZK2Qwl6d5L7pTi311JKQOhkEvNrwp22t7sElFuR1EbpWnLQDlIRLxaYAOw
05aR6J9ydgAcOifndJzvDi094RlCXFHcc4gZ0pB0fHo75Iniu73AVIdGO+Zyxy9rLtexEw5z3M6X
ea45kfhE7uja6Uj/ACsHwWUsUO10slVX08TASS8Z5BXd9qHVN7lZn0YCIm8mKELTZo5vcBB/w5uP
2RV1tH7GzxhVbvEU8lyjhvmlmP1dvIJhWoU5ISkQPpDwPIoK2h9e5amg66iUw9EtPFq9Lt3AKJTD
XQPIiJbjewcL5VurLncL1fDfpWz18NLVDA9VEYWh7eiXU0VRM35q7qac2ut655DZc7P3OL6tYD82
Bevz6OK16T4/EdRGpjLjrtfs17oa/wDkYtY45XPbI1QaKbJ0UJfLHlNaRtbW+9kf8ixcpG+7mQtk
MJd2Gvbab1G+RxFNLmKb7N+n3cUztTZTabk5rB9DKN+J3YQUkU9PO0Do5M7udD3KaMxuBGoPApCT
4eCQdV0d5xOS5+PjoiDjGEgZaWtyNfre5o7SptTs5X1VJ50G7m6Duxe7/cqJTB7Z+EWikqbtVMwQ
NyJh7XHgFnomvcXzSkl8hJzz1LkgaLZotF3gyw6MmGP3Cr3aP2RvjVW7v6eS3Rw0dUsv+rt5BMq1
CmRIgfyEjsYPIoK2h9e5aig6/wASolMPRbTxavSLdwCiWTU0x9MBfOt3YD5RdoYDwkhrPvpSV19E
beI/Jlqq1w2/kLePydem/wDOh/lXtU5O8tOlOPv848iNTG1/979nPsK7+Vi1hIIXObY2TJJTJUD5
i8qWm1c3vgjWEkeWycBoQVshgjTMEzCzI3sZaVoLNcqCuovyLd3lu6f7NO79D/ISkjPXDZ65UFY2
nliOHPAZIOqV6DR7FR+axmOYh+6C4O6rkhLL3q2RW2obAZQHkZweHwVayUwtmOP8M496EDZ64xQ3
Jj6oF4ccBx7F7OZqdtK6eR7WQtblznaDChLyK93k3mpayNpipIeo3t8R95UBwaOHV0+QUwxXWzWl
4hGvUl/kKvto/ZG+NVLvEU8lyjhvmlmM/wBnbyCYyrUKYykQO4SHqnkgr6H17lqaDrqJTD0S08Wr
0a3nQIyaWkOoXzVcb1bavyh1NfHKW0z5ZWPLwWkARbhyF1tE5zdvxGubFTVLUeSW/Wux2vaCsuFU
2GFgg5uOujAvYdl7pdrtY6evuNOyF87nvha3iYCcxl47HELXpXj73h5EakSv/vfs7/7eu/lYtYSu
Y2xsmXFNEqB8zeVMA7Vns/szF55UDdeOHDXBW2GMmA44Gg5rmWJkuA4hpxo73IhfWzam4W5rIK1n
ndMOAd1meFy9Dt219iq2gMqRDIR1JhuffwUJZK+bP1V3r31EVfSFuA0DpAqj813QDcrr3SwR9rd/
JQOtqdkrTh1NFJXTt4OPox55lVVxuVxu72vqniKFo9CJujRyHafeVCEchjQI2hrRnmuXOacHXOFm
L/ZkO/LcAyM9FNn4RuV5tJ7I3xhUrvEU8lyjhvmll/1dvIJhWoUwhA8kJ0PIoK6h9e5amg66iUw9
BtRGWr0S3nQImGnpCQWr5c8oEkVdtdc5KWGVpNT0Ze5u4C5rA0hdfQ05Yqr8uWqSbBVmz1BcJK6+
Wqeqp4dzcmazpIqd5PXkYvrCkuVBdKWKroKmOeB49F7Dkcj3H3FatLcfd+XyTGpnK7+9+z+v6rXf
gxa1xXMbI1QZcQmifeoS+afKnrtRx/VWLzycAvOq2QwRckdUnGcpOAPDiNERJS49pXLaemkfiTLR
kagKSDn5OoTwqnHTPUXAoaNrnZkc/d4jgmSXYEEYBijId39qQk5IeHZGeKkcbxwuiDjiolEL7ZwZ
vFN4Jf5Cr/aT2RvjCp3eIp5LtHDRzlmD6gfBMK1Cm5yjKB9IeqeSCvofXuWpoesolMN9ajq1eh24
6BEw09KeC8R8ocO/tHM4n9eoR8Hxkf8A6rqaJnLE1dE+cMKieRO4UcF3udFPM1slVA0RMd/ibnEL
2YbJWCku7LnRUhpKgZ3xTu6KKUEHrsGhUaW467yp8kRqQ60j88LBx9krvwYtW4hctsjVBslNE8lC
XzX5Vf7zD/2rF51MXuc/OOJ0WyGMowz3lIASOxSxkEkEEE6LsZB4dg4qSCEBxw0DgucEAan5IkEn
62cdqAMnQc0Bjhnh3JTk40REL3ZzfdeabAHUlP8A+BWh2j9kb41Su8RTyXaOG8ZZj/Ab8FHKtQpk
SIiT6QnQ8iiUCh9e5aeiPpKJTDe2s6heiW7gETDgQbT020UNXBP53bJiyOej0DoOzpI88e9y878p
guDdoqk04h6JhoXu3+Ik9IMXS0ZxE9P6w11PPaDZ+81N1p6WmfDT1RuboGTCQjo54tdMcMdhX2OW
ytjjbM8PkDAHvAwHO7Tjsys9K+2/RXllNVHlJGpi56mObba1xDrQ09Y0/vMicFtCTnsXLrpmmcp+
ET/GM2yPbTBongmiVgl89+UuKN+0GTx83avOJogScD4LZDGUY0pB1KU0x3jr29hWTGXJi94z3pHR
AAEgHQacEIIYiHvGeHzXIhy0HezrohJOi46ad+MLnc01I0IRLkuIaRkrgHGdexEQvtnji70xwT6E
ug8BWg2j9kb41Su7+nku0cN4yzBP0A5BR1ahTkZSIiD6Q8PgUSr6H1zlpqLrjmolMN7azqFpLhfv
yLRsmFBU1Tnu3QyFuceI64QZum8qt5lubaGnsVNDKdAKqcx/Mu3Qqba+XbCaruE9yp6GA+aUssjY
3b2IhLuxlpycnJ1XR0bxMeHnDCpSV8V8p71Wsq66OmlbeIjO+mz6Es4cekjK+qaCgbbaClomVE0w
hYG9LK7fkf7yStuk4nLDVT30fpEojXLzime//wAV6lpOnmGRz3Gr1RxOmioYqKoroz77Vv8AphnR
llPOTJAB4rhyrM3zx5S342lAx+qsWALyCdThbIYS5ZLSPcB02Ne5WUVFBKMsmYdOCnMcPoDGTkEe
/BXApIncZ2NRGbp9thcMGoi4ccFRqmlEIy2Vjh3DX5pkZq4g5GoSYBYPcpSZ6OV8gYyN7j2NAyU4
+kqoYy+SmlaOQUSLTZ7W60ZYddyX+QrQ7R+yN8ap3eIp5LlHZ+jeMssfUDkEwrUKchCB5IToUECh
9c5aai6/xKiUw3lrOoXoFA4howSgsq2wWa9wmG40McocAN/GJG8njULwvbPZsbM1tVQ0Fyd5tLb2
PfHUvBcWiXqM5EZXQ0bxVLCrUprteH3me81jqKSnfLHTTmPUgGMiPOT2HeX1jRVPnNBRT8elp435
8TQVY0j7cLhJ+7/jCI1y8vdNBbPKDNc7jUwwQywzsYXuAw2NrAD8SvVoamCphjnglZLFIA5j2nLX
D3FUsXTcn1V3sVRbmiiimZjKJmmmInJlRMZTTnnOZSU2SqTY+dfKZk7S6f8ApI/xK8+eSGSceBwt
kMO9VMxnXKsIpXggRkt9yxZRqWkFfM0HU/AqxbXB4GQ34tWWaJhyZIiDiOP71WVMzHtLGtAwRn4q
c0ZK8sgc45Yd7xFIWQdrHH3bxwpDeMxAMO7ICfSzo5vBdRNnD2uNTHGM8cnKC12fAF7pw3PUmOT4
CrzaL2RvjVK7v6eS3Rw/zSy59SEwrUKkkSIH0Hqnkgr6L1zlpaLrKJTDeWs6hbKW5RWy3y1csM0j
IwMsibvPOdOCDzq5+UTaGuzHbaKpoqF41qWQmSfd7SDwVBWy7MQzTnNxnkltkoMtfGelNS7qEK9o
/iI6ZYVaj21N7oLjcIqimqmyCW0QQzcRiVgGW6+8L6H2PrIqvZezyRysfu0sbHYOcOYMEFXdIR9S
w0/CrJEa5ee222265bc1pqqOOZjqquaS/XPRMix8i4q+8mj5YLbc7VKSTQV8kTeRVe/fu3cPct13
Jqpter9XHdTGRTTEVUzEZTVnm9HJTRK5Tc+ePKTrtG73Ukf4leevwA/GDotsMFYzGVKAGDxWLKNR
wMcAMZTgfKO0ok6ah/uCiRkudLk8SFMIl08Sdkch5NQ7IYdCNdQRhZMTJfvHOvv4Jok5zj4qJF/s
1h16pvsphr9mVdbR6UjfGqd3fU8lqjcTzll/8AJhWoVJIVyiUpcnqnkgrqL1zua01F1lEphu7X2L
0G3E4GqJhqKR7wAA4gLGbW0T63auxUwxmqttdAC7hkxq5gp7N6Z/Dr/lGbW842+sZofMYXxQ9NS2
ak6ZzBoSHmMleleS50B2WayOJjHMqZRIWjBcc6Ero4yYuaNt1R3V+aI1qqyXygrdtaanoaCdjIhX
tklOCJJHuDnvW3smzz7VcL1Vmr6U187ZN3d3dzGVzb0TY9bbqmKqrlNM5x3Jpyq7OUZRGbQrgnVU
m187+Ur+8kgz+qMWAkbhj1shjKnjJzxU1jz3rGUxqSmEY+CdBIOoClILxg6BRmk78vDiFMIl09x1
1OMrgkgHJHFZMUcga6kdyaIwDrpngokXuzpIvFNhufopfvYVf7R+yt8ap3d/HJboj6v8zKn1ITCt
QqBCIk8g9U8kSrqL1zlpaLr/ABKiUw1FLerVSzCKesjY/uPZzXqNsex7GOY4OaRo4HIKJguz219q
u1ZNRMbPTVkW8XU1QzcfgKmv1xmh8p2yrHynoRFhrewOm3mK7gaYqu3PybmX8GEpO3tH53dLszGT
+bT5B/8AanDlA8mFT0NPeKY9gp6lvKaJXZ97RlVP3Uz5QjvNbLbj9u5qqmtlVQ0k1NOWRTtLMyeh
vkBeyk5XPx3Y9flTMTMUURVMapqiIzTbz7JonU6pskKm2PnLyku/4nf76dqxjxlru3QLbDGVE0HI
U9uQGjPZwWEpjUkRgZOoXRGCdVKSHewOKYiBJl1OchTCJPPYMHMh446oyuHMxpvF3HVZMUYg7o0P
Eps8RpyUSL/ZwA3qm1HqZv6ZV3tESaRvjVO7vqeS1Rw89UssT9AFHVqFUmUIhIKQnQolX0frnc1p
KHrfFRKYNvtlTQuqZ20UdbSSAvlY/rsxxIKsthNqIbLPVUtxmkipDrHvMc7cf8EQ0lTV2/aDbqwV
NgEpkZI19bVMYWDcb4hxDRhO+VCeWk2otFXE8MfFTRPa/GQ0skK6OjIzxWXxoqhjU0Vgutzvu1Nf
R3Q0r5GWGeJtRSOzHPHI5uHtWV8ltxmftFNSTkOzQ9F8IyCFute3B3Py6f1n9Ed71GKqe7bimo3y
OeaaiqCCdT0cvRlvyIK3RwCVy7tE0V84pq/7ozbKZziDWCM6DCbcVqZPnPyjlw2pd3ebsWQIGuSd
AFt7oYKFuQ/s48FMYcgaY1WEsu5KADSchdYGvBSly5gA4KPHo+QclMIk6ZIgcF4C5DmOBOhHuWTE
zIMjgBrxTRJbnA5EINHs0AbzSaADo5/6ZVrtEMUrfGqd3fU8lqjh55sqfUtTCsQqhIpRCSkOMHkU
SrqP1x5rSUXW+KiUw2NPWU9FTuqKiQMjYBkqTSXfam8RZtdnpoqc9Was13+QQlodj9p7m6+Vez10
oqaKeKPpA6mbhnY7B+BVB5WIy640ru63E/KVdLRfGUcpY1d6wOxtlfc7bJbK6a2PrrVLVdNDLutZ
J6GB4NeCzHk+ENPf6PVjpGV00MkoORIJIju/DLVYs05WcRHws/8A1CHpzCR5Uedl/wD3XoxJyVzM
TMzVbn8Kj+UZMqNU85NniuCVWZvnTykf3nfr+qsWReRuAA9gW3uhgys0giqJma4a8j5FSYq1g/SH
4LFKc2pY86n5EFPiaLAy48O5Ew6MsW6PTHyKjxFjpJCHZ0CmCUkyOAHbr3LknLtSOAWTFHcdBnTm
EydSNDqg0Gzpa280Pgm/puVxtH7KPGFTu7+jktUbjxZM+pamFZhVCERB9IToeRRKvovWuWkouuol
MK/aWoe6po4Cx3RsG9jhvklemUu0W1rGARbKOOOH0nYiES2x7a021dbfG7LPkfUQ7nQmUAN6o4/u
qFt3dNoJ5KOe6WAUIdBLCwGXf3xkEldDRnGW/HyRVqUVj2fqn1lunfYfPYJoHyNp5aoRdMI9HFhB
BHIp+3V1PSXWCeGMQhtU0ug7YtyfQH4OXRsx/e3qP2qZj/dUh77M2IbaWyQMZvPttUHO7cB7MLWk
8l56ZmWyNUOSeSaPDiohL518oziNqX9xp2rIvBDRr2BbIYyx9b7ZU/au/FRVigLoEjtQLvv+sVa2
skvmyT1QpgXJZKCfV88lcPDw3rs4nGDofmshEc5rQdc5OEwHsac4PHuKiRpLAR+WaE5GNyXXvzGV
c7Q+yM8aqXd9TyWqNxPNkz6kJlWYVZCRA+g8PgUFfRetctJRdZRKYX81kprvBHHK5zHMdlsjRryX
qtrZ0cUbAXHdaBknU470TDSQEmqeP+Uw/eV535XIA61WyXtbPI35sV3Rs5YyxznyYVd7zXZyn2fZ
Lbp7/bnGhk6YOqWve4OLcABzWHLQxWdytttbYquqt8cYjiu1TC2Rmu9EW70evaBhdWn3MbVz866m
L1ygq31W0ez02G7sljkeCDrl5ZnIW+JGSvP3aYprqiO6W2NTglNnisIS+dvKQM7TvOf1VqyL8kAk
HgFs7mMsfWHNXU/au/FRVigIQCubScOm78NwpgXT2kAFNSAbpBGDkYWQ4YCBmEEzh+C33e7PapEY
u8sjQad79TljgN0rFKfZohTXukbpjMug1AzGdFb7Q+yM8SrXd9RyWqOHnqZM+qCYyrEKkkSIJS5P
AoIFF61y0lF1lEph1HDV3e9SQU9bJTMp48Oe1x63IKfVt2xs7hJUXeq80OnnEI6Xd8TTjCIbbZe2
S3K80d0dtVNXCGEOAazcHEt3Htzor/yoxB+zDH/Uq2feCFbwM5Yux1wiXmGxFndd6yjpvyrW0+XV
HqXYwAxp08Xarf8ANyKgsG2kcNRPIaOtYwMcfRLY3g75A/SXWv8Au4yedE/+Ri1Ww5E9Vs3U8XNt
FVBy6KUL1881xsbMzibsT/hqmn+EtlMZQaK4JVaGT5z8pTyNqeH6uwLLu6g7t0LZDGWdktdTLNLI
4sjjc8kOe7AIJUiOywke0Pk+yjJHzOFiJ7LBD+wmPikaPwC7/IVNwLGNPvkJQylw+y0Yzhzf4imI
KeKCSRrCMEDOFMB57IsEmMcT2lJ0cGuImce3JWSESYuBboQB3FdMikcSBUMY7eADXE72v+ixSubA
d6728YLSHSgj3iM5V3tH7KPGqt3fUclqjcTzZEn6IJlWYVHKEEpcngUECj9a7mtFRdb4qJTCzjsd
W6uFbb60U8zh6QIyCtRSVu3lJ6D7VSV7MYyxwblEIWzlqv8AFtrBUUtrda4pGb9VCXh0ZizhwbzX
qW3lN5zsfdRjJjY2QfuOBVjCzlibE/iU+aJeG7A26a6X2npWXKqpPRkcH0ztyQYat/YXugvu1WzV
fO6earD9ypIA6QtZrvDvwV1sfPZxF6fwqJ/3ojUa8nUIfNat9zg+lfcGYDsfU0P8S9uJK5mkKpnF
XIyyiJnLkyoyycErgqnDN84eUn+9X/2Y1mnDLRx1AWbGUumpYmhrmU287HXerMRTuHpSY9zQoZEN
MwAlxedeJKbMEA4MCBt8UeOqFSytAlOAOCmESby8E4jfz0SYdgZaWhZIgy4xFga4E+lnQ4IyE2Xw
9Ox/Qk6DeDnZ3liLy1yNF6o3NYAMyaA97CrbaL2VvjVS7v6OS3Tw3zSyJ9UEwrUKZUiCQkJ0KCDR
+tdzWjouuOaiUwutj5nyQ1Ac9zt2ocG5OcBet0B0CJhKgP8AxKP+mZ/+UK8u8AqbHdIPr0ko+bSs
7U5V0T8KoRU+a9hLX+U9oaenbW1FI/o3ubNA7deC0L0/Z3Z98O3t2krblNV1NFGwxyuaGb/TMwS7
kF29JRnfv/kU/wBcNcdzG3kS27aSqpoXFr47wyogx3z4X0i7iVRx850WKu+Yz8JiE0a6jRK4OFz2
185eUfXa33dDEs08h2ePVb+CyYyt/OqaCKMPlaDuDTifkk/KAPqoXu97juqGRl1TUuBwY2knuymC
+pdnNQ/kAAhCK9ryPXS/xKEwESP1J07SphEnz26aEJCSBwGc8VkxRZQDktJPu5pgaPaQ7OOzuWKV
1ZRi80OAOEn9Mq82h9kZ4lUu7+nktUcPPOWRPqgmFahUCEElIeB5IINH613NaKjOHfEqJTDnZ2+2
+3PrBUSO9KcuaQ3OQvQ6Lb/ZlhAfUzN9/ROQWNLtvsq6/edG5BsXmHR5cx49ISZXqskgFFUvDS8d
A87o/S9FTHsyRL5e2GujLVeJa94BFPRVMgadA5wjOG/Er0PYuouEG2FQyuqXVEtfbIqkyO4hzg1+
OQyQu7pHf3v3f/kwjVHNZ1tDSO8qVAalmRLQiWIdnSxbwHyAXrDuJXLxdVUxhs9XqacmdHfzNnKb
JGVVZS+dvKHrtadB6mJZdxGcY/RasmLiKJjQC0AZ7f8AuprAsZZwfAOOBXO4USbcw4J9FVp0lPJI
ROoOYHEYe/UnTIXBDWji4gntWxgjPIAOQeADUwAQ4aduhUQmV5ZgDe6IEDhJpyYVebQ+yM8SqXd9
RyWaNxPOWRPqgmFYhVCFIk5XLjoeSCDR+tdzWio8F3xUSmEzZWGCS5XYPihcBI0AFoONTwXrdJbr
dK0CSip3g8QYmlCEumoLczaYBtDTjFtBA6JvESjVb+nwXDI5pCKnyzYdnYLjthNZpJnxQCeZj93i
WQknd+OF64KSb/xSkduRsiitjehDeJbgNXcx053qvvwv6sI/Vb3myzVu02z1bDM1hpulMme1mmQP
mtqcErkXbkV0WacspopmJ/jm2UuCmyVqTL558oZxtX4oY1lTgD4N1+CyRKQyMYYcngprQADgKGTp
wdrrhNkDJUQkw8DHBVp9YdOwrKESHzRA4Lu1cFzHAlpWTGTEuG5BzxAz71G7cHXVRBK8swzfKHQ8
H/yFXe0IxSN8aqXd9TyWqOHnqlkD6oJlWYVJCEDxKac7Q8kEaiP0ruYWjo+KiUw2Vpghje5zI2tL
zlxA4leg0B0GiCRT67UH/pQ/qrZQnUc0jUip8xXKQ0G3V0dHc3UDhVzblSGlwY5+SN4DsPariS4w
bVziqqaoUtVFaHl87XhoZUUz8h7cdjl2sVvIn/SMI/V6PszfquuotmKquZ9NVNqIS4dpaMh/x3F6
Ge1ci5R2Yt1ft05/wmY/RnTOfg4PamyFgzfO/lD02sZ9nEsy7idOxv4LKGCVEzDGnPYNVNDw3B14
dihlGpwZAdcBcFz/AH8BooZGHudg6KtJJlOR2BIRJ1xfgklcPJ046j5LYwRZyMAYAAGM44qKwEvJ
GnvUSL+yEfl2h0OcSZ/gKudovZR4wql3fUclujcT1MeT9EEwrMKgQgdJC4IBB5II1F6x3NaOj4qJ
TDbW3iFvKDgEEul/vS7/AKUP6q10R4JBU+e7rU26h8pldLcYS6j6R3TtLN/LHxccDiFqXWXY2u2s
tHmNFRzUU9BLJuR9Qvae0BdjEbVr9z/Rrj9W0u1M43TZpsEOGRVT8tY3AYwREdnALXE4K5dcxNFq
InPKmfNlTrk0SVwTpwWtnL548oem1sf2cSzGCM6Hg1ZwxSGF7g0kqQAAByWEs4OAEkacSuCwnGAU
SZewgakKtIDZHBIRLpwl3zh0YGeOqQ5A9JwLsnBAWxgjuaMNfIX9HkjQDPf2rhzKYn0XTNJ/SJGF
ilcWESC90YcQSBL6Q4HDDgq32h9kb41Vu76jktUbiebHn1aZVmFSQhApByuyDg8kESi9Y7mtFR9Z
RItpb3JRVNNTQU7ZZpcY3nbrddAtlsztRHW1xt9VSvpato6jjo4gdiJJtBebxYNpRcWAVNEKSITQ
huHRxOfg6+JerWm40lzoaespJA+GZoc09vI9xB0KIl41tXXwWTymQ3CoDuhDIpH7oyS0s3EQWuau
2ttFdTURskNaySWEwPDpJGNG9kgaN3guvdnOMPP+kn+VMsI/V7DUxVL6+3mGfo2sdIZdM77N3qe7
XBVwTqVyZmnKmIjnLOM3BTZKhL558oQB2tb9nEs2dQdBnDVnCHTHAgZIwOKlskZ2Au+OFhLKNR0v
IxmRjfcOKbzFrl7iiczLzEAcNKriPpHYaQMLKETLpxGCNOCaeRu4JH+4WTE0A94DGxGQknLOOo/D
GV00dDLvutjHBp6p1+YysUrWzyNlvVHIdQWS8B/kOitdovZW+MKpdy9dTyW6M/o885Y53q01qrUK
ZEiCWQkPAoINJ6081oaPrKJGjdaKO5xNZO05HVe3RzVFbsftQa6mrIK2CaSneOhMjzvbrDlu9oiV
/WW/bK+11Rb6mCgpjNRRtlkDi4CJsu9kDJ1Ll65YLVDZrTR2+Fxc2BhG9w3nE7zj8SURLyPykGmj
23tEtQAYeggMjN3f3miV2RhV76kwXa2XKxwy26gLqgxPr5M0+B6zcZqWrq11RNGFjvjD1+UsY73t
toukF2oqSvhjkZHLvFm+MHGoz8cK8PHiuUzg0ThcEomHzzt+Qdrh9nEs+9gDT2jDVkiWXkqKwSn0
HFoJ3Rgp+OetfxJb7ljJmsIpA0DJJUoVzGDqn5LI1lNzI/QeufOeny0xkFM0ZOHtY5zvQaSTx964
cyIAfQxk57lkIzizcaGu3HZ4ngOzC7ipSHte6pp2gHjknCxSurUI236BrTvDEvpcMnoyrPaH2Rvj
CqXN/TyWqOH+ZjnerTKtQqSFyiEwlcngUSg0nrTzWgo+solMNpQPYwb73BrQMkk4AWnt13o6sSw2
+rp5qoRlzGF3o/HHYgi2faKoi2vjor1StpaqWkbDE5hzFJ6ZcCCe/gF6uwgEklES8Ave1v5d2utV
TYWbk8OIYpKgANe5x4kJbPZZq+6UcF5qjUxw3irpn0oyIQ8NMxcPc5y6NUe7hZ/Ar/VHxe9sZHEy
NkUbWMYA1jGjAaBpgBSzxK5yYcFNnCMofPHlB12t/ciVDnQaforOESZc2PGuVwWR/VwpQQNp2g5B
3iRywhzI2jgMIACPJ4arkYadBkZQG8S46jgdU2SME5PAoGz0AyXsDtDu5Jwfkm4xA54Apowc97sn
PxUSle2YxsvtLuMMbQyTTJP+Ge9We0J/sjfGql3fUrVG48ZY53qwmFZhUkIRCUgnQ8kSgUnrTzWh
o+t8VEi6r6Grr7a+CmeA8kEtOm8B2KVs9fbPZCGV1oloZ90MfOGFzX4RMmdr7paL9UxMtvSVVUYY
W0xiY4Oa8PcXAr362CqbQ0gqvXiGPpj/AMzA3vvREvHvKfTU9JfLJNSRsppngudPG3dJc14w4qg2
KrZoLlQNq2TNNRdGyxzvBDHkxvY70jxJLguz2Y+hYarnH8qmMa5fRTgRlSCdTouNLKHGi4KJfPO3
xxta7wRLNyv3SOGNwY7uCyglD6Y4GCcYOVz0upAO8MrJjJAXvOG5Ls9iGuOToTjghB1hOCXsPHkm
yC0jJPhRJXboA1Lsg6dgSDfIOmB29iBmU5ABYRgIizvN0zqMIL6ygOvdLjgGycPs3K02h9kb41Tu
7+nkt0cP80sa4+h8QmVZhUkmUZRCVlcEnBRKvhfIxzyxm8cjRX1sqGTe5wOre0KBpPy9QW2VkdQZ
Mlod6Lc6K+g2w2Uq6Z9PWTkRyN3XsfG7geSCs2HuVNQ7ZTW+geamhmYWQy41YPWL39p1KDxnyvgi
pskn+SX7iCpNNRQXHYLZamnBMUlxEbscQHve1dz/AKfhOuY/lUxjW9JtFvlttvhpJK2WqMWQJZOs
W50B5K3Y/IxnXC4aYBXJKMnzvt9rta/wxLKz4zgAEY4hZQSinBJLQeHbxXJcXADA4cOSyYy6Y7tx
wPd9yCN0YdgAHihDovcG411JBXZc0sBGRjhkIl0C7dcHOGMnu19wQwtcJG4J07s//wAEEaQOLidT
r1ksJb0uSgv7JkXulLjxZJqND1CrTaL2UeNUru/p5LlPD/MxbuomVahTIhEJa5JGCiUOk9aeavaR
jOl390b31saoNrQBhwXAaDtWxtsdurIY5WRQSxvGQ7dBBUJlKpJLZQbSmIupqbpqGJkbPRZvu6R2
gW5b1ikEvJPLAwGGyP8A88oXdrcWeT/Zt/1bpGf/AJyu3RwGE/O/9sO+XrcjOJTAPpN5hcSUwfJX
BwjJ89bcH/i+bwR/yLMOEYxvE5Pb3fNZQSjPD8kEDGNU2AcA5OdABxWTGUeWaOInJD3E8GnRWEVp
vM7BK6NlND2PkO593FYpWFJso6rYXi7scM8WNJCWp2UlpIy8XVoH+ZpChlkqZbddYIi/cbPF2vjO
9+GqiRVee0DvU5oSXYe7rE6DA/0XIADxrpnRShorJk3qm9HOkh/+Mqw2i9lHjVS7v6eS5Rw/jLFu
6iZVmFOSFCIhJSHODyRKHSetK0NIQDxUSLim2hs8bSH1XZ9Vyl7EbUWmhthp66rERZM7cy1xy069
iB3aa62y/wBRNS2yF9dUS00DICxhzG9j3Oc7LvcvbrTFVQW2ihqnh88dPG2V3HLw0BxyhLzbyvSw
GktEfSs6Vsr3GPPpbpHHCx1vnvX5oxVZuDPybR17I30vRjebh4k3w7iTkrtW+Bwn7wx75fRwljlh
ZJG8OY9ocxwOQ4EZBUYH0281xZTCQU32oyfO23BH53T8ov5Qs7JnfHDgMArOCUQgg9bI5/im4Iqm
unZTUTC5zuJ4DHeT2NCiULWSttdhyyhDamuAw+oePRZ4AqSumqqwiapqZHl4ye4fBBoLDc4qGkMR
OfSJXd+uzKugMTGOJJ5qMmcamNpK+ro5A6GVzSDwWohlt19BbNimrf0ZB1X+IIwVm5PSVDqWrYWS
A6af69oPYU4GbpBG9oNf+2VlA0dgaPyvAezck/kcpm0WPNW+MKpd39PJbo3HixbuomFZhTkLlCEt
IToeSJQ6Q/SnmtDSdZRI1NtoaMcKaIZP1AtNs7s7brfTui6MTF7y5zpWtJ4YxyRK6grrRa9o3xyz
U9KJaCIRg4YCd963LCDgggg6gg8QkIl415WrK1ktFeGP1kHm8jfe3VpCxlHFV02zT5uvbq6eOOrw
cmCWGTIdyc1duzwOG/eIYTrl7R5Pql0uy8UfSdIKaeaBknY9jHaELXN67ea4ksoSSmySjJ84bcZd
tXWAAn1X8gVLPqTgAejqsoJVNTM4lsMTcueeAHHJ4L1izbNG3Wh0L3Hp5wHTOHZ/kB9ySQ8rvFif
QVXRNk3g4kjPZzXDHtEAiIBa09fmkB8QRtaBvgHGnvTRO6cagqZQDFFPkSDs63aEtFZJ5qkBkoDc
6O7VCYegXWxPuNrawHeqYRmNx/S72fFYWjkEkRa7R7CA5pHcpglprEcXKHQ9SX+QqRtD7K3xqpc3
9PJap3HixLz6HxTOVZhTkZSIlKSHgeSCHSetPNaGk6yiRtLcdQo1xvt0de47TQVsNEdwZmmGjnEZ
wCQUTLZW+yeeVc9HeiytebbAJJC3GSZZDluOGFA2Rlqtn9pavZaeTpYHh01G88QOOEhCV5WqmlFk
oaZ0zenNWJGx9pYGuBK8hoKIz2apmbaXS9HURMkqWVG6QHkYj6Ptz3ruYaM8Bb+6/Hmwnae9bLX2
wOp4rRS00lvnhbpRVDSyTvJGesta0+m3muHLKD5K4J1Rk+a9tnE7V3HxR/yBVNQd0uJJ0+Cz7iXO
zEQmu5q39SlY6d3MdVek23bm1VdO8THong9Vyhi8yu9Z51VSOLusc57h2BVDRvFrQiVmyfLPoGxx
xdr5BnePuXJc+YkMq4ZD9Ut3UTkVoaQ/QtwdWE6t/wC3vS01a6CpY8OOAQCPcg9DO0lup2MDpgXO
IGAsPeabzS/uc3SOpAkZ+/xHzSSV9YcG4x+CXH8BKc2h9kb41Uub+nktUcP4yxL+oeaZVqFSQkQS
0h4Hkgh0nrTzWhpOsokbO3cQr6qtVkugjgrmxGTA3TvBsgHu9yJlDotj6qC7TwW3aGtpWtponj/E
0c9w3eIWqsOzVqtNzkmmuDqy6ysJMk0g6UM4ZaxEMv5V7LIRS3mJgcGxCmn/AMg3t5jl5RaamaKo
ZDG87k74hM3sIbI1zSV3cH7cDyvR5wx730/fbBbrzTBlTHiVg+gnbpJC7sLSFV7M3WtrWVFLcIw2
vopuiqMdV+Rlsg9zguFKYasrkoyfNe2OTtTcz3St/lCo7k5zYn6ndwB81n3ErGztEOy98nHWeGsz
yH/dYYDJCxQspd4yO1PFOMaei1OjnhvIdqlLRWi0xXGYvmcRDGdxvdotZcdmLFNSk0m/FOwEgnVr
lXruVxXFLdERNGbz2UDfjMmMtduOPuOigYILh7yt7UblpnB4e2aJxJBwHarY7XMxRWGX9J0coP7u
4UYplgObjDoD9FL/ACFP7Q+yN8aq3N/TyW6Nx4yxDx6B5plWoVAhBKXJOh5IIlJ6081oaTrKJGyt
3Ys5ZrbSbVXy6vrHvYGt+iazAdjOAfgkAuGys9nuU+BVVlJFAyWUwydHMxjnEZ4HhhekbF2fY+rf
Hd7dJVTVEOh6eXL4iRjUBBpPKFGX7IXH3CN3yeF4NavoGURyz+1SMZxGfo5muXd0fMfRKqfxPKM2
L6meQWAgggjQrIxO6LbKRjOE9qa+XnFLusPyeVwpTDWFNklGT5s2qcTtPd/tgFS3MHzY68Q04+Sy
7iVjaPpdlLzEOLXb+OYWFaoIWzgC/wC/5p8sPQOY1pLgQ8fu8VI0ez11omB8E7iyORwc2QDO673j
uWlrKu3UrN4VbJGDO7HE4nePvK1diO1m2xOVOTzucPqHvfgdYvd3ADVVjsvcTjiVsa3YAjLCQC5x
G40/itntnpRWGM9ZscpPx3EYpOzgLbhCMk/RSfyFPbReyt8aq3N/TyW6eH8ZYh/UPNMq1CoEIJKQ
jQ8kESk9aea0FJ1viokbO3cQsrSWgQ7Qzw11wno5J3OdTVTDutfk8CUgbehtW2dJdqiKhvcE7mUs
WHVLTrGS7A4FTbBsVeoNo23esqKWmxq6KjyBL4gdACgf8qddcI6eho45xDSTslMpxq90Q3gxZfY+
w0DpLbFcrbBVU10ildBNqHxyw9ZhIPDAV2mZjA+zXF7/AIo729m2authzPs7VvfA05fbJ3b0bx2i
Jx4FXdjrLXdGC6UY9OYNZKT129Hn0HjsIyqUkNEU0SUZPmnafXaO7Ef+qcFX1bBNCck6sGBy0WXc
S62UqGNr5qKQHcqmFhB7xwW/pdnLdDE5jIRqOKQdzz+6Wt9E8B4OGkt3vd2KvikexwkYSHNILUQW
obTTSGSPFM49ZvFhPf7k0yUtO5J0YOOuXFw+QUZMokrX4eXAlwOmewjtz8NMBT7VaZbhOI42no2u
G+5TKG/qNj6N80MgYWuYR8gsPtPU+fX7oGdSANhb+71kkX2zeBdYxk46GU//AI4Tm0XsrfGqlzL6
RHJbpz+j+MsO/qnmmFZhTCRSJaQnQ8kESk9aeav6TrKJGzt/YmZ/ziuzH0r9nqV0QccGaT7wQQiZ
M2az7dUNxlhoKmCIsgjJjfIJGCNzjgagr1jZyLaaNtT+W6ilkLntMIg/QGNQURKRtlbaWv2cuDZ4
Q8wwyTRHtZIxpIIWL2BstymoLLcJrsX0kDp3wUYiHoudvxdf4q3HBVfnR5SjveqyZ3SsXRsp7dtZ
Uwxt3W3KnFRgcOmhO6/+IOCqSQ2JyuDnVGT552zpHwbR12RpIWyD94KnppQ+IR4G80jX3LKNQoKv
paW4CZhLTvh7T7wvT6faCWe0uqqeHflj0lj7Q5IIecTXiruM7+mI9LqtHYUsDGOBc527GOLj9yEA
xu7WFwPaBkfcuRTHiIidNOKIRppGsPpyAuHBgP8A/AK/2a2pNtl6N8G8x79C3iEHo+0G0oobYJmN
+nm9GFp7/rH3BeR26KR00k7yS7JwSeJPHVRKYbnZuMmWsquxrWwt5u9I/gm9ovZG+MKlVOeInwdC
Yywlr5mGf1TzTKuw50kOUIJSQnQoItJ6081f0nWUSNdSTRQRmSV4Yxoy5xRbttXMlglqbe+KglkL
GVGc4cg9It5Dr/XOBBBoafB5uetPFjISCWT2m2wtFFJcLRWMqInyUbgyUxkxyF7eA3VirTtTZaTy
fS299extaaWqY2LD85eXY1AVqOEuR+LT5Sx73puzczpdmrNI55e40MOXHjkMATEtsln2ioK9zmiG
mppWMH6Rkl4/AAKrKYaIrknAKiWx5B5S6ImWiq2jgwsevLoJeikBwD3jsWVM6/uKqZiInumIlIqo
o6mIhpONS09yqqC41lqqy9hweD2nUOHvSWMNJJbLfeh51a5RFVcXwFZS4U9wgeWVULmYPDHooNxY
bFRVNujkdvhx4lriFW7T2qGhpo3xveSXgHLiUTl7GVpLdW1jwyCFzsnjjRbGCituz7BLXES1eMsh
b/r3BTCGblnrbxWullfk45NY3uHuVy5rYYmtjJAAAbkfMpCYbe1QupLdTwvaW756Ut7t/h9wVTtD
7K3xrm01drEV84djFW/V4XDR8aJlhnn0TzTK6MOKEIJKOw8kEWk9aeav6TrKJC3+ok82pqRnGZ+v
w4D4kr1N1ngrbPJbi0NYYQxn+Qt6pQQ/J3U1Ezq2CdpE1HDFTPHge9erRAghCVJtfZ6q6WyI0OG1
9NPHNSSEgbjgdUQ7M08GztTaWvB6WKdvSlvAzZPyGVnFcxRVR3VTEz4ISLDa5LRY6KgkmEroGEF4
04klWLNXhYSQfK5JUSyYba2OKWSGKVuWPicHj3LwytpJaSpkhkBy08e8dh+IWqzXHrrtE/F0cTZy
weEuxq7MxJqGVzD3juT9RFFVMB0PH0gPxVpzlI+CronB7QRgjD2q8p9rrgxgjqmQ1LO6Qa/Na5F7
Tba26Fm7+THtGeDHDC4q9sbZUgA2tzyOHSOGFJmpanay4SsMVNHHTMI4Rj0vmq6C31NSTNO8tBOr
ncSg0EMMcDAGM3W4+J97lJtdKaqrD3NLooiDJ7+5qxvV9i3VV8IWMLam9iLdHdNUZtkXvfIXPJJJ
GVndofZW+NcrDZzXMzrzdzTFMUxapjVFOTDP6p5ppdeHmpCRBJQc4KCNSetdzV9SdZRIau0nQ3S1
zOB3GOY7T3PytlR7Ey9IJIL7VRDUswNRn4hAzbtkb86/3Snbe54WCON8lU3IdMX+7eC9R2X2bjsf
nLvP6iplqHNMr5T9VShtCdFyTyQMPewENyCSOr2oAwTkBRLKAUiiUww+1RzUUwx+gVhrlQMuEAYX
BsrB9E8/gfcVyqrvq8ZVzjN6uxh4v6IpoyznsTlzzYCenmp5XRysLHt0IXLHAA4e5rvcuxExVETG
qXlK6Zpqmmdca0ptRnrtIydS0ZCQ0lvqM5AByeocHHIqZQbNlpiTgyhdNstIMkmY68OGiiIE6Clp
oT9HEzIA16yfe9rThxJdjmmUnsFNS1FfMWMAa0H039jfee8rZRQQwRMhhGGN+bj2ud7yudjrueVE
PQ6Fw1Wc351aoOjiOaz+0XsjfGFXwu22aZ1WuUsI86HmmV2IeZkIQSUE6HkgjUnrXc1fUnWUSNhQ
AEtyAcEYW4ouAQSqAA3659/mlP8Ai5ahhAASCUgOdjiU4SCWpKIZd4aNsYj2m0n7pVpTyUQzjUTV
IoIYbar2qn8BWV4riYrf1vb6M4GxyR6qjpa2IRTsGQCGyjrN/wBx7lkq2w11MS9kZmi/aMH4jiFd
weIjLsVOPpjARTV6+jVOtTDAxqnQ86aBdN586Hj6jU6JSBoAPgpJzgB8sjgwEuJOjR/stRbNmJ58
SVhMTM6M/TP+y0XbsW4+9nbt1Vy0UsEVKG00DQyJoB3R2nvPeUwMDsXEuV1VVzMvb4OimnDWoiMo
7JQdRzCzu0XsjfGFvwu14uXpnVb5SwrxoUyuxDzAQglJDwPJBGo/WuV/SdZRI2Vu7FtqLgETCXbg
4bQXI4OPNafB+LlsWAY4BAMBDiEuhfkBJYwzL2Z2vjdvDS0kY5yrSE6rFn3QTK5JRDDbVe1wfZrL
DtXExW/re40XwNjlJFcUGehPiK1W9pGk+Fq6oMVdmtlWSZqVod9dvon7lnqvZq2sO6yWoafgVfpx
VduHn7GCoxN3s55ewwbBQ5y2ecDk1Pss1qafVzPPe5+PwCTj6stWS9ToOiJ9tzOGsoaGjpWNMFOx
hIGo4/NT8LCqqqqM5nOXOmimiZpjulTV+On/AHQoZVWdqXp8Lw1rpgDiFntofZW+NWcLteLlaZ1W
+UsI/geaZXYh5iQhBKSHgeSCNSetPMK+pOsokbK3nULb0XAIlKteTfrqcn1NMPucVsYygeIBHALl
YjJu/voz/o4/qrUE8USZM0QPHJ7gMrgzOOcRn4lZIYraUPdUw6jIYsuuFi4mL9b22ipicDZjviAr
mg1iPiK1W9pOk+GnqhNVTX+u/dW2vU5mjeJ+SUIYS4AxotEvQy0kRHRR+ELrircaoePubyvqlT1/
r/goa0TtS9NheGtdMAcRzCz20PsrfGrOF2vFytM6rfKWEfwdzTK7EPMSEZQSUh7UEek9aeavqQje
4jiokbC3uaCNQtpRSMwPTCJlLtj2i93RxI3THT4PIFa+OeID1gQOmpixq5cecw54n5FRAyc02dr2
lpx/5T3f81aubIh17m5+YUwSYLhg6rgOGg14IMjtFrUw/ZrMEanjxXExm9q5vaaJn6rb6SFW1Afo
T4itFvXDPSfDT1QnKprh9MPCFtubMuZo3ifllDQtD0MtLEcxR6fohdq3GqHkK9uvqlTV3r/gFDWi
dqXpcLw9rpgDiFntofZW+NWcJtS5OmtVvlLBv4HmmV2IeZkIQSUHtQRab1ruau6YelwQayg4jRbW
iAwNAoTCdbWSNu1xeYzhzYMO7HYb2LVseAEHRcRjRcg4dnVBTy2+d1/bXjd6HzIQe8OEhctDUk7g
8QQRznA1XGDnXggyO0ODUw+A/is9KCCDkHIXHxUZ13OcPX6LmIsWPvpkyreg9UfGfwVWjbhY0lwt
XVCdqqqv0mHhW25sy5mjeJ+WUJKtD0MtHDkxR6fohO9iuRqh5C5vK+qVNX+v+AUNV52pemwvD2um
CA4I5hZ7aH2VvjVnC7Xi5GmtVvlLBPOh5ppdiHmZCEElB7UEWm9a7mryl6yDW0HELbUOSAoGig7F
ZsBxxQK7gOCVoG7kYQKRpEM/phOzHL2D3k/JA0VyUSyO0HtMPgVDI07hIbwPFcjERnXder0dOVjD
e3JGKtaDWJ3jP4Krb2lzSXC1dUJ+FU12emHhWy5sy5mjeJ+WUJItD0MtNB6mPwhOaK5GqHkLm8ud
UqWv9f8AAKGq87UvS4XhrXTAHEc1ntofZG+NWcLteLk6Z1W+UsG8aHmmV2IeZkIQSMpOw8kEel9Y
eauIJWMcAc5JOABlBpqGsjaRmKY8oythRXGIAf2ep5dEVCYX0F2ib+pVp5QFWLLyzT/y+vx9gUMg
67xkn/y24/CBKb23Q/k246dnQIjIlFfYqu5soRR1UT+iMuZm7mmccFePJ9Egd/3olydBwXJIJCDI
bQHNTFqOp/qqMBrsgkjRcu97btcPUYKcsJZqyzyjV4ohVvQepf4lSt7S/pHhauqE8DIVRX+uHhC2
3NlzNG8T8koKVV3oZaaD1UfhC7KuRqh5C5vK+qVLX+v/AHQoirztS9LhuGs9MEHEcws9tD7K3xqz
hdfi5OmdVvlLBvOh5phdiHmZGqEElBxg8kEal9YeatYPaYuTkTDZ28nI1K2VGSQFCGlpiQRqrVji
cZQO5yePYuA/XiUFE5gG1MMva21v+6RXoOkYP1AiQSMAALkkY4HigyV+waiPwceziqEZGDp7lyr/
ALLtUvUYDKcJbj/KbmBEh1BzrorC3+qf4lUjezzW8ZMTgInpT1UV/rh4QtlzZUNG8T8soaMqu9DL
TQ6RR+EJ1XI1Q8hc3lfVKkr89P8AAKFr3qvO1L0uF4a10wBnI5hZ3aH2RvjVnC6/FydM6rfKWDed
DzTK7EPMyMoygkJD2oI9McSFWsB/tMfJyDZ0B1C2VETgKEw0tMNArRgGAgeAA7OIXO5x0QVUjQLs
H9v5OLfnIFZgnePIfcEC4APDsXLtMHKDIX/2mHwKkYACdNVyr2+repwU5YKzyczN9Brg08SC7sU6
36xP8SqzGV5YxUzOAnPXFUQsFUV3rh4Qs7mypaN4n5ZQkKu9DLTw+qj8IXauRqh5G5vK+qVJXk9P
+6FEVedqXo8Lw9npIOI5hZ3aIgUzB3vVnCbXi5Wmddvplg38DzTK7EPMyEIJOEhwgiaskJVnTPBn
h17HINnQkaLX0TzooGnpn6DVWzH6ccIk8Tpx0RnB4IIVQQazOBk07Rn94lSS4ZdqeJQl1vZ7Vw8g
nigyV9eBUx+BUZOSOPFcq/va3qMDnGFtdLovDo3N3jw0Uu3nEcniWiqc66OTdiPZhL0ZZf3kSsMq
nrj9MPCEubKro3ifllDyjKrvQTLTQkdFH4Au8q5GqHka9uvqlTV5HTjX9EKFlaKtqXpMLw9rpgmR
kcwsZfaoTTsiYc7nHmrWDjOZcjTU7rlLN1LQzDe1Q11nmwlQSEIOSwOTTTLA8PAyAg0tDeYABvgh
aim2ht7cZe/+EqBewbV2poGZH/wlWEe2FoA67/4Sgf8Azzs37ST+ApfzztH7V/8AAUSiy7X2c1MO
JH4wMndPZn/dPN2ws+NZX58BQkp2xs37WT+AoO2Nm/av/gKDO3faW2TzxuZI/RmOqVUm/wBBjWR3
8K592zVNyuY1PQYTF2aMPapnPOI7nJ2goNQC/hxIUyj2itzGPDnv4/VWn1Fc1Q24jFWZw1dMTnMz
CZ+cts+u/wDhKrqvaC3PlBD38Pqqa7Fcwq4HE2rd/tVaspRfy7Q/Xd/Cj8u0H13fwrT9GuuxOkcP
+2vY9prYGMG+/gP0Su/zntf13/wlWos15Q87VeomqrmrKvaG3PlBD3cPqqIb/QgcXH91aZw1czMu
3Yx1iizbpnXFKsqb3NOejpoyC48yoz6PzGEzVRHSO6rO1XsNZ7ES4uksTN65HwiPZDMSyGR5ce9N
q05gQglIQC7Y8A6hBLiNBnL2YU4PtIHA/MoOhNax2n5lL5xbe8/eohEDzm3d5+9HnVu7z96lLk1N
uJByc8yjzqg7z96IIaug7z96Q1dB3lCTT5rc45JPzKbL7Z3H5lYzRTLZTduUxlE5QN+2+/5lKJbc
OBP3p2KUzduTrnOHXT2/vP3rky24nt+ZTs0oiuuNU5SN+2+/5lJv273/ADKdihPrrv7brp6DHEpP
OKHvKdmlh25IZaAnifvQ2W2g6gn4lOxSzi9cjVWmsvsFIwilpmh2OueKoKqrnqpC+V5JKyjKGEzM
z7UVCIGEIJOUiAQgEIiSFIiQhAIREOUIkiERBMIwiRhCAQgEIBIgRCAQgEZQSEIBCBEiAQgEIBc5
REBIhIQiQhAmUZQKkygEiBUhKBEIBCAwjCB9CAQgMJEAhAIREuSkRIQiJCESEiAQgEiASIBCAQgE
iBUqB5CAQgMpERBEIkJMoiQkRJSuUAhAIQCRAJEAhESEiJCEAlQCVA8hAIREkQiQhALlEQEiEBCJ
CRAIQIkQCNUCIQCEAhAIQCVA+hAIQBCRAIREuUIkJERBEIkIQCEAhESFyiQkQCEAhAIQC6QPIygR
KCiIBKREhCIhzlIiQhEQRCJCECJUAhEQFyiRlCAyjKAyjKAQgEIHkIBCIhyhEhIiJCESEiIgIRIQ
gEIBCIhyhEkS9iBEIBCASoBCD//Z
endef

define NHE_TAPESTRY_STEREO_FILE27
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
wMkIESIF+xCBEIBCAQgBkQCEAhAJEAhAIQIkQCEAhAIQCRuEg3IhVuoQOj9kuEq57n8Pi7LmqW8W
/bUbKlK2cRl7TewPP+zpZ7qe2xR4ZNXev/PzWefL5GOPPjxZebjLK6zjt47nPVMvZn+j3J9pPZ3I
5DDy1XJqy3q7F/uOoRW8fI984nlOI5Pico42fiWUWjyYePvU+Yjj+Rjny8nH4yxvafdMuPLHDHP1
X0b2o/on5ni+u/jSc7GHko1cnxXznykgqSrAggnYj43yMOfDc7WeZ9jl48uPLV8eqjc7fiPZbHzv
ZrPz3usXLAtfCqBHTYmN0taSPg03zcl48ZZ7ykTDHqt/FLs3hcWi/wBm60ewjPw6Lrd67mstZCF9
2lnUPwPsZT/WQWpy5PE3FH6bqR2gN/YrraTjnzc2sejp3fvv79LeOGHeXf8Aj8bLL+K9kuOXFHIP
yZfLqGRUtLVf2FFp/s+vqH2313nWpnxPZaoe2tHA5N5ap71Xta+4tW69asOoeYic3LJlb066Lcdb
9JcMNzW/Ml3/ACyeynE4HKX8n9NXLevFwHyAmMVFjsrouh1BvxTXZwvEZWLzb4FPIU34VNV605LI
Wast02EgKvhsETWXJyTkyn9PTOnc99zHDG4y992XwacZ7KcO9FBzTmvd9TPyFtWOyg6NqpUq9Snx
U7MUZfDcS3Gc1m4tWfR9DfDRKsllLHt+vqLaVfwjUzjzclyy3066p2997pbx4yTzvuXey3GYnK83
j4eWbRS1d7v2RAf+yqazuLA+k6jE9lOCzc/gXpfPXCz6s0mpygvU4qF+5gNENLzc2eGdk1qYe/v3
v/hhhjlO+979MScDweTk3WrXyeDg4mKb8tsroe1vtBEWoBUG2J1K8fi/ZTLqy8+o8nVgYSL9IV2q
e6yy46rWsgAD3kyfV5/X07JqW+rb4Onj99X4/iGXGey3s9y12DlYl2cMB7cinJqsZBelldDXqVYL
0kMFk4Psp7P8hdw+TQ/IV4WUcxHqtZO33jUm3qRguipmL8jnnVL09sbv897/AKanHhZL/Vq6v+Oz
Nx/s57Oc2+M/GXZ1aJnYtOZTeULirJtFQet0AEjJ9jcT+rd2fjZFzZlWRlbpYrpsfGcK7D3jqBMv
6jkxymOclsykuvGqn08LNzfjtsZfspxODmcnbl5OSvH4dWJ93pN112VULOhCQFnH8qeGNyHi0zFq
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
gEIBJgEIH//Z
endef

define NHE_TAPESTRY_STEREO_FILE28
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
ABQIJAAUAAAAAEiIBSH3AIAAAAYAAH//2Q==
endef

define NHE_TAPESTRY_STEREO_FILE29
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
endef

define NHE_TAPESTRY_STEREO_FILE30
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
endef

define NHE_TAPESTRY_STEREO_FILE31
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
AAAAAElFTkSuQmCC
endef

define NHE_TAPESTRY_STEREO_FILE32
iVBORw0KGgoAAAANSUhEUgAAAGkAAABsCAMAAABekWy7AAABUFBMVEUAAAAdHR0dHR0eHh4eHh4g
ICAjIyMjIyMmJiYnJycrKyssLCwwMDA3Nzc4ODg7Ozs+Pj5AQEBCQkJEREROT05PT09VVVVVVVVf
X19hYWFpaWl9fX2RkZGampqzs7PJyckQEBAVFRQXFxcaGhocHBweHh4gICAhISEjIyMlJSUnJyco
KCgpKSkpKiosKygrKyssLCwrLSotLS0tLiwuLi4uLywvLy8uMC8wMDAvMS8xMTEwMjAyMjIxMzEz
MzMyNDQzNDI0NDQzNTU0NTQ1NTU0NjY1NjQ2NjY2NzY3Nzc2ODc4ODg3OTc4OTg5OTk4Ojk6Ojo7
Ozs7PDw8PTw+Pj4/Pz9DQ0JHR0dMTEtQUFBUVFRZWVldXFxgYGBjY2NoaGhtbW1xc3N1dXV3eHd5
eXl8fHx6g3p5goKAgICBgYGDg4OGhoaJioqcnJyqqqq6urr0qW7eAAAAIHRSTlMACN8DWpIG86wH
3lbgi6nkptvj+FfXi+Pbqt/fxJJaBTTMEUIAAAsNSURBVHja7ZpNjyQ5EYbfeMOZ3T3dvTM7C0iI
RYIDN/4IRxAHJH4oHzcEB4TEXwABAi4LM7Pd0x9lRwSqdLmcH1UwIw4c2KiutJ12+vEbjoxUpRpf
2Vf2PzJBt/GTgT+wEAiE2NvglrC3gmaOjcV8NofsvxH2i5zz7iTpa5c/QkTZIYRQITwtZ4vetPCT
Kw7ApzLC3f2Xu/dbkn72EwE8ihUGk0GhECdiGhUVUwLnJcmh4XuSh7mH/OzB1qTbnw6EP2V3CBiQ
2hmymrFXt5oiBAiICwION/Ph53cr0vWPx0s8PZT8CCdHAQjZLD1ipaJtoaKa1a/DE64g743XPzs4
MNVivNih2ONf7wwiAjKI5GoECIStYqHvEvckzsOFMIhLJL38JOeS09XjXFP6IRVPf9gFhEIImECG
OBK8Y0qTZ42zdGDAq2QTJ+XWvPDy9+/nmtLzReQ/PmMCqQhBoh6ddU4HPDUtisYMNGjACDrgU78G
ivA5Hg1zEr94cfVuFzKBSBCkukxXiGTAQQSdWJnLESTSHFTgoATt8skNaUGy8vTwEBCZQASTD8w6
kbzsjzBE0LG0OKIZxwbJwuJJqXTT7/92TvreM5LVTasgVVFXDA7RAADTLqMcQZAjSBAAWECQaS9M
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
9d+EX9n/k/0LNnXykVZMf/AAAAAASUVORK5CYII=
endef

define NHE_TAPESTRY_STEREO_FILE33
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
endef

export NHE_TAPESTRY_STEREO_SRC1
export NHE_TAPESTRY_STEREO_SRC2
export NHE_TAPESTRY_STEREO_SRC3

define NHE_TAPESTRY_STEREO_CONFIGURE_CMDS
	mkdir -p $(@D)/examples/nhe-tapestry-stereo
	printf '%s\n' "$$NHE_TAPESTRY_STEREO_SRC1" > $(@D)/examples/nhe-tapestry-stereo/DistrhoPluginInfo.h
	printf '%s\n' "$$NHE_TAPESTRY_STEREO_SRC2" > $(@D)/examples/nhe-tapestry-stereo/Makefile
	printf '%s\n' "$$NHE_TAPESTRY_STEREO_SRC3" > $(@D)/examples/nhe-tapestry-stereo/TapestryStereoPlugin.cpp
endef

define NHE_TAPESTRY_STEREO_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(TARGET_CONFIGURE_OPTS) $(MAKE) NOOPT=true -C $(@D)/examples/nhe-tapestry-stereo lv2_dsp
endef

define NHE_TAPESTRY_STEREO_INSTALL_TARGET_CMDS
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2
	cp $(@D)/bin/nhe-tapestry-stereo.lv2/nhe-tapestry-stereo_dsp.so $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/
	$(file >$(@D)/.pb-1,$(NHE_TAPESTRY_STEREO_FILE4))
	cp $(@D)/.pb-1 $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/manifest.ttl
	$(file >$(@D)/.pb-2,$(NHE_TAPESTRY_STEREO_FILE5))
	cp $(@D)/.pb-2 $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui.ttl
	$(file >$(@D)/.pb-3,$(NHE_TAPESTRY_STEREO_FILE6))
	cp $(@D)/.pb-3 $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/nhe-tapestry-stereo.ttl
	$(file >$(@D)/.pb-4,$(NHE_TAPESTRY_STEREO_FILE7))
	cp $(@D)/.pb-4 $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/presets.ttl
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-5,$(NHE_TAPESTRY_STEREO_FILE8))
	base64 -d $(@D)/.pb-5 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/background.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-6,$(NHE_TAPESTRY_STEREO_FILE9))
	base64 -d $(@D)/.pb-6 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/format-btn-down.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-7,$(NHE_TAPESTRY_STEREO_FILE10))
	base64 -d $(@D)/.pb-7 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/format-btn.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-8,$(NHE_TAPESTRY_STEREO_FILE11))
	cp $(@D)/.pb-8 $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/icon-tapestry.html
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-9,$(NHE_TAPESTRY_STEREO_FILE12))
	base64 -d $(@D)/.pb-9 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/knob.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-10,$(NHE_TAPESTRY_STEREO_FILE13))
	base64 -d $(@D)/.pb-10 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/lcd.woff2
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-11,$(NHE_TAPESTRY_STEREO_FILE14))
	base64 -d $(@D)/.pb-11 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/led-green.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-12,$(NHE_TAPESTRY_STEREO_FILE15))
	base64 -d $(@D)/.pb-12 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/led-red.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-13,$(NHE_TAPESTRY_STEREO_FILE16))
	base64 -d $(@D)/.pb-13 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/onoff-down.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-14,$(NHE_TAPESTRY_STEREO_FILE17))
	base64 -d $(@D)/.pb-14 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/onoff.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-15,$(NHE_TAPESTRY_STEREO_FILE18))
	base64 -d $(@D)/.pb-15 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/screenshot-tapestry.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-16,$(NHE_TAPESTRY_STEREO_FILE19))
	cp $(@D)/.pb-16 $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/script-tapestry.js
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-17,$(NHE_TAPESTRY_STEREO_FILE20))
	base64 -d $(@D)/.pb-17 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/slider-cap.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-18,$(NHE_TAPESTRY_STEREO_FILE21))
	cp $(@D)/.pb-18 $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/stylesheet-tapestry.css
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-19,$(NHE_TAPESTRY_STEREO_FILE22))
	base64 -d $(@D)/.pb-19 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/tape-0.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-20,$(NHE_TAPESTRY_STEREO_FILE23))
	base64 -d $(@D)/.pb-20 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/tape-1.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-21,$(NHE_TAPESTRY_STEREO_FILE24))
	base64 -d $(@D)/.pb-21 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/tape-2.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-22,$(NHE_TAPESTRY_STEREO_FILE25))
	base64 -d $(@D)/.pb-22 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/tape-3.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-23,$(NHE_TAPESTRY_STEREO_FILE26))
	base64 -d $(@D)/.pb-23 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/tape-4.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-24,$(NHE_TAPESTRY_STEREO_FILE27))
	base64 -d $(@D)/.pb-24 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/tape-5.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-25,$(NHE_TAPESTRY_STEREO_FILE28))
	base64 -d $(@D)/.pb-25 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/tape-6.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-26,$(NHE_TAPESTRY_STEREO_FILE29))
	base64 -d $(@D)/.pb-26 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/tape-7.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-27,$(NHE_TAPESTRY_STEREO_FILE30))
	base64 -d $(@D)/.pb-27 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/tape-8.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-28,$(NHE_TAPESTRY_STEREO_FILE31))
	base64 -d $(@D)/.pb-28 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/tape-btn-down.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-29,$(NHE_TAPESTRY_STEREO_FILE32))
	base64 -d $(@D)/.pb-29 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/tape-btn.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui
	$(file >$(@D)/.pb-30,$(NHE_TAPESTRY_STEREO_FILE33))
	base64 -d $(@D)/.pb-30 > $($(PKG)_PKGDIR)/nhe-tapestry-stereo.lv2/modgui/thumbnail-tapestry.png
endef

$(eval $(generic-package))
