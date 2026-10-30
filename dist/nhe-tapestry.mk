# Upload this file at https://builder.mod.audio/buildroot with a MOD unit
# connected over USB. Assembled by tools/assemble_recipe.py (MOD plugin playbook).


NHE_TAPESTRY_VERSION = 61d38eb638449647fb8395a35c5b8dab7e981ba7
NHE_TAPESTRY_SITE = https://github.com/DISTRHO/DPF.git
NHE_TAPESTRY_SITE_METHOD = git
NHE_TAPESTRY_BUNDLES = nhe-tapestry.lv2

define NHE_TAPESTRY_SRC1
#ifndef DISTRHO_PLUGIN_INFO_H_INCLUDED
#define DISTRHO_PLUGIN_INFO_H_INCLUDED

// Rename these together with the TTL (see docs/lv2-and-mod-rules.md).
#define DISTRHO_PLUGIN_BRAND       "New Horizon"
#define DISTRHO_PLUGIN_NAME        "Tapestry"
#define DISTRHO_PLUGIN_URI         "urn:mod-cookbook:nhe-tapestry"

#define DISTRHO_PLUGIN_HAS_UI       0
#define DISTRHO_PLUGIN_IS_RT_SAFE   1
#define DISTRHO_PLUGIN_NUM_INPUTS   1
#define DISTRHO_PLUGIN_NUM_OUTPUTS  1

// Control ports, in TTL order (indices start after the audio ports).
// The bypass port is always last.
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

define NHE_TAPESTRY_SRC2
#!/usr/bin/make -f
# DSP-only LV2 build. NAME = the bundle name; the binary is <NAME>_dsp.so.
NAME = nhe-tapestry
FILES_DSP = TapestryPlugin.cpp
include ../../Makefile.plugins.mk
TARGETS = lv2_dsp
all: $$(TARGETS)
endef

define NHE_TAPESTRY_SRC3
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

define NHE_TAPESTRY_FILE4
@prefix lv2:  <http://lv2plug.in/ns/lv2core#> .
@prefix pset: <http://lv2plug.in/ns/ext/presets#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .

<urn:mod-cookbook:nhe-tapestry>
    a lv2:Plugin , lv2:SimulatorPlugin ;
    lv2:binary <nhe-tapestry_dsp.so> ;
    rdfs:seeAlso <nhe-tapestry.ttl> , <modgui.ttl> .

<urn:mod-cookbook:nhe-tapestry#always-on>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
    rdfs:label "Always on" ;
    rdfs:seeAlso <presets.ttl> .

<urn:mod-cookbook:nhe-tapestry#walkman-cheap>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
    rdfs:label "Walkman, cheap tape" ;
    rdfs:seeAlso <presets.ttl> .

<urn:mod-cookbook:nhe-tapestry#walkman-chrome>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
    rdfs:label "Walkman, chrome" ;
    rdfs:seeAlso <presets.ttl> .

<urn:mod-cookbook:nhe-tapestry#studio-half-inch>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
    rdfs:label "Studio half-inch" ;
    rdfs:seeAlso <presets.ttl> .

<urn:mod-cookbook:nhe-tapestry#home-reel>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
    rdfs:label "Home reel-to-reel" ;
    rdfs:seeAlso <presets.ttl> .

<urn:mod-cookbook:nhe-tapestry#pocket-dictaphone>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
    rdfs:label "Pocket dictaphone" ;
    rdfs:seeAlso <presets.ttl> .

<urn:mod-cookbook:nhe-tapestry#answering-machine>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
    rdfs:label "Answering machine" ;
    rdfs:seeAlso <presets.ttl> .

<urn:mod-cookbook:nhe-tapestry#vhs-linear>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
    rdfs:label "VHS linear" ;
    rdfs:seeAlso <presets.ttl> .

<urn:mod-cookbook:nhe-tapestry#eight-track>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
    rdfs:label "8-track cartridge" ;
    rdfs:seeAlso <presets.ttl> .

<urn:mod-cookbook:nhe-tapestry#bedroom-four-track>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
    rdfs:label "Bedroom 4-track" ;
    rdfs:seeAlso <presets.ttl> .
endef

define NHE_TAPESTRY_FILE5
@prefix lv2:    <http://lv2plug.in/ns/lv2core#> .
@prefix modgui: <http://moddevices.com/ns/modgui#> .

<urn:mod-cookbook:nhe-tapestry>
    modgui:gui [
        modgui:resourcesDirectory <modgui> ;
        modgui:iconTemplate <modgui/icon-tapestry.html> ;
        modgui:stylesheet <modgui/stylesheet-tapestry.css> ;
        modgui:javascript <modgui/script-tapestry.js> ;
        modgui:screenshot <modgui/screenshot-tapestry.png> ;
        modgui:thumbnail <modgui/thumbnail-tapestry.png> ;
        modgui:brand "New Horizon" ;
        modgui:label "Tapestry" ;
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

define NHE_TAPESTRY_FILE6
@prefix doap:   <http://usefulinc.com/ns/doap#> .
@prefix foaf:   <http://xmlns.com/foaf/0.1/> .
@prefix lv2:    <http://lv2plug.in/ns/lv2core#> .
@prefix rdf:    <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs:   <http://www.w3.org/2000/01/rdf-schema#> .
@prefix units:  <http://lv2plug.in/ns/extensions/units#> .

<urn:mod-cookbook:nhe-tapestry>
    a lv2:Plugin , lv2:SimulatorPlugin ;
    doap:name "Tapestry" ;
    doap:license <http://spdx.org/licenses/GPL-3.0-or-later.html> ;
    doap:maintainer [ foaf:name "New Horizon" ] ;
    rdfs:comment "Tape machines from studio reel to answering machine: wow, flutter, saturation and tape's low end." ;
    lv2:minorVersion 2 ;
    lv2:microVersion 8 ;
    lv2:optionalFeature lv2:hardRTCapable ;
    lv2:requiredFeature <http://lv2plug.in/ns/ext/options#options> ,
                        <http://lv2plug.in/ns/ext/urid#map> ;
    lv2:extensionData <http://lv2plug.in/ns/ext/options#interface> ;
    lv2:port [
        a lv2:InputPort , lv2:AudioPort ;
        lv2:index 0 ;
        lv2:symbol "in" ;
        lv2:name "In"
    ] , [
        a lv2:OutputPort , lv2:AudioPort ;
        lv2:index 1 ;
        lv2:symbol "out" ;
        lv2:name "Out"
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 2 ;
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
        lv2:index 3 ;
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
        lv2:index 4 ;
        lv2:symbol "drive" ;
        lv2:name "Drive" ;
        lv2:default 0 ;
        lv2:minimum -12 ;
        lv2:maximum 18 ;
        units:unit units:db
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 5 ;
        lv2:symbol "tone" ;
        lv2:name "Tone" ;
        lv2:default 0 ;
        lv2:minimum -5 ;
        lv2:maximum 5
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 6 ;
        lv2:symbol "wow" ;
        lv2:name "Wow" ;
        lv2:default 100 ;
        lv2:minimum 0 ;
        lv2:maximum 200 ;
        units:unit units:pc
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 7 ;
        lv2:symbol "flutter" ;
        lv2:name "Flutter" ;
        lv2:default 100 ;
        lv2:minimum 0 ;
        lv2:maximum 200 ;
        units:unit units:pc
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 8 ;
        lv2:symbol "age" ;
        lv2:name "Age" ;
        lv2:default 3 ;
        lv2:minimum 0 ;
        lv2:maximum 10
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 9 ;
        lv2:symbol "hiss" ;
        lv2:name "Noise" ;
        lv2:default 0 ;
        lv2:minimum 0 ;
        lv2:maximum 10
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 10 ;
        lv2:symbol "mix" ;
        lv2:name "Mix" ;
        lv2:default 100 ;
        lv2:minimum 0 ;
        lv2:maximum 100 ;
        units:unit units:pc
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 11 ;
        lv2:symbol "level" ;
        lv2:name "Level" ;
        lv2:default 0 ;
        lv2:minimum -12 ;
        lv2:maximum 12 ;
        units:unit units:db
    ] , [
        a lv2:InputPort , lv2:ControlPort ;
        lv2:index 12 ;
        lv2:symbol "lv2_enabled" ;
        lv2:name "Enabled" ;
        lv2:default 1 ;
        lv2:minimum 0 ;
        lv2:maximum 1 ;
        lv2:portProperty lv2:integer , lv2:toggled ;
        lv2:designation lv2:enabled
    ] .
endef

define NHE_TAPESTRY_FILE7
@prefix lv2:  <http://lv2plug.in/ns/lv2core#> .
@prefix pset: <http://lv2plug.in/ns/ext/presets#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .

<urn:mod-cookbook:nhe-tapestry#always-on>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
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

<urn:mod-cookbook:nhe-tapestry#walkman-cheap>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
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

<urn:mod-cookbook:nhe-tapestry#walkman-chrome>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
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

<urn:mod-cookbook:nhe-tapestry#studio-half-inch>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
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

<urn:mod-cookbook:nhe-tapestry#home-reel>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
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

<urn:mod-cookbook:nhe-tapestry#pocket-dictaphone>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
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

<urn:mod-cookbook:nhe-tapestry#answering-machine>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
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

<urn:mod-cookbook:nhe-tapestry#vhs-linear>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
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

<urn:mod-cookbook:nhe-tapestry#eight-track>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
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

<urn:mod-cookbook:nhe-tapestry#bedroom-four-track>
    a pset:Preset ;
    lv2:appliesTo <urn:mod-cookbook:nhe-tapestry> ;
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

define NHE_TAPESTRY_FILE8
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
Y3VtZW50SUQ9InhtcC5kaWQ6OTkxRkNEN0FDOUMzMTFGMTg3MDZFQjYyQjY3REYwMzQiIHhtcE1N
Okluc3RhbmNlSUQ9InhtcC5paWQ6OTkxRkNENzlDOUMzMTFGMTg3MDZFQjYyQjY3REYwMzQiIHht
cDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIDI3LjEwIChNYWNpbnRvc2gpIj4gPHhtcE1N
OkRlcml2ZWRGcm9tIHN0UmVmOmluc3RhbmNlSUQ9InhtcC5paWQ6Nzk3YWZkOGEtZjE5NC00NjM1
LTk0OTktYTFjNzA4YWRlNTNkIiBzdFJlZjpkb2N1bWVudElEPSJhZG9iZTpkb2NpZDpwaG90b3No
b3A6NjczYzZiYTktOTQxMi0xYzQ2LWE4NjEtY2VjMTRjOWNmNWQyIi8+IDwvcmRmOkRlc2NyaXB0
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
QUIKg//Z
endef

define NHE_TAPESTRY_FILE9
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
endef

define NHE_TAPESTRY_FILE10
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
gg==
endef

define NHE_TAPESTRY_FILE11
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

define NHE_TAPESTRY_FILE12
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

define NHE_TAPESTRY_FILE13
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
fEatxnEdlAEAAA==
endef

define NHE_TAPESTRY_FILE14
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

define NHE_TAPESTRY_FILE15
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

define NHE_TAPESTRY_FILE16
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
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
endef

define NHE_TAPESTRY_FILE17
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

define NHE_TAPESTRY_FILE18
iVBORw0KGgoAAAANSUhEUgAAAooAAAGQCAMAAAAeD7HeAAAWfmNhQlgAABZ+anVtYgAAAB5qdW1k
YzJwYQARABCAAACqADibcQNjMnBhAAAAFlhqdW1iAAAAR2p1bWRjMm1hABEAEIAAAKoAOJtxA3Vy
bjpjMnBhOjg4ZGIwYWI5LWExMDAtNDFmZi1iMWNkLTlkMWVhNDI5NjQyYgAAAAOTanVtYgAAAClq
dW1kYzJhcwARABCAAACqADibcQNjMnBhLmFzc2VydGlvbnMAAAAAuGp1bWIAAABEanVtZGNib3IA
EQAQgAAAqgA4m3ETYzJwYS5pbmdyZWRpZW50LnYzAAAAABhjMnNopVhLwu48RH6/J1XnmwbegAAA
AGxjYm9yo2lkYzpmb3JtYXRpaW1hZ2UvcG5namluc3RhbmNlSUR4LHhtcDppaWQ6MmI4OTAxNGYt
ZTI5OS00MjQyLWI3NzMtYjU3Njc3ZGYyOGE0bHJlbGF0aW9uc2hpcGhwYXJlbnRPZgAAAeJqdW1i
AAAAQWp1bWRjYm9yABEAEIAAAKoAOJtxE2MycGEuYWN0aW9ucy52MgAAAAAYYzJzaCyPnrwG+XcZ
btizhUeR5XUAAAGZY2JvcqJnYWN0aW9uc4KiZmFjdGlvbmtjMnBhLm9wZW5lZGpwYXJhbWV0ZXJz
oWtpbmdyZWRpZW50c4GiY3VybHgtc2VsZiNqdW1iZj1jMnBhLmFzc2VydGlvbnMvYzJwYS5pbmdy
ZWRpZW50LnYzZGhhc2hYIBRzqw22f/D1YO6xXTHCPHV9lPy7UeAZP2oNolTcU6hppGZhY3Rpb254
HWNvbS5hbnRocm9waWMuY2xhdWRlLnByb3ZpZGVkanBhcmFtZXRlcnOheB9jb20uYW50aHJvcGlj
Lm9yaWdpbi1jb25maWRlbmNlZ3Vua25vd25rZGVzY3JpcHRpb254ZkNsYXVkZSBwcm92aWRlZCB0
aGlzIGZpbGUgYXQgdGhlIHJlcXVlc3Qgb2YgYSB1c2VyIGFuZCBtYXkgaGF2ZSBjcmVhdGVkIG9y
IG1vZGlmaWVkIHRoZSBmaWxlIGNvbnRlbnRzLm1zb2Z0d2FyZUFnZW50oWRuYW1lZkNsYXVkZXJh
bGxBY3Rpb25zSW5jbHVkZWT1AAAAyGp1bWIAAABAanVtZGNib3IAEQAQgAAAqgA4m3ETYzJwYS5o
YXNoLmRhdGEAAAAAGGMyc2gEY9xpviKYk7U5WezDJ+quAAAAgGNib3KlY2FsZ2ZzaGEyNTZjcGFk
TQAAAAAAAAAAAAAAAABkaGFzaFgghcSwYlBgehsBTBUQkjzvma00SDrF/8mnJa+KmEm4kNNkbmFt
ZW5qdW1iZiBtYW5pZmVzdGpleGNsdXNpb25zgaJlc3RhcnQYIWZsZW5ndGgZFooAAAI+anVtYgAA
ACdqdW1kYzJjbAARABCAAACqADibcQNjMnBhLmNsYWltLnYyAAAAAg9jYm9ypWNhbGdmc2hhMjU2
aXNpZ25hdHVyZXhNc2VsZiNqdW1iZj0vYzJwYS91cm46YzJwYTo4OGRiMGFiOS1hMTAwLTQxZmYt
YjFjZC05ZDFlYTQyOTY0MmIvYzJwYS5zaWduYXR1cmVqaW5zdGFuY2VJRHgseG1wOmlpZDoyNDRm
NzMxNS1jYzNjLTQxZWYtYmNjNy1hMzQ1ODE1NTNhMTFyY3JlYXRlZF9hc3NlcnRpb25zg6JjdXJs
eC1zZWxmI2p1bWJmPWMycGEuYXNzZXJ0aW9ucy9jMnBhLmluZ3JlZGllbnQudjNkaGFzaFggFHOr
DbZ/8PVg7rFdMcI8dX2U/LtR4Bk/ag2iVNxTqGmiY3VybHgqc2VsZiNqdW1iZj1jMnBhLmFzc2Vy
dGlvbnMvYzJwYS5hY3Rpb25zLnYyZGhhc2hYIKvY1RBpCH1nsIcQ3Sx8pAljWTF0izCKf9GFpWPI
qok5omN1cmx4KXNlbGYjanVtYmY9YzJwYS5hc3NlcnRpb25zL2MycGEuaGFzaC5kYXRhZGhhc2hY
ICsgeCNZ4QX4FWDVyOgTtaM16cAqKPOXSPq9FL4abbSGdGNsYWltX2dlbmVyYXRvcl9pbmZvo2Ru
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
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD2WEB6ADE0uVfnSalGhaFh3FR9jRjRRLse
/5yI07wWaTOpAUvnEqV/+gow4jb7SKCCVkZZYtKi86eaxSf3MkXo0BQbyN5pGwAAAwBQTFRFFxcX
JycnAwMDNTY12NilRkhGVldVZmdmdnZ15uaxmJaR+/v7uLaJjQAAiYiGyMeXGiEZPEI7x8jIqKen
IiMctbW0iolzqqeNZ2dP+vrJHR4gqKV41tbWcgAAl5ZwHiEhQkU45+fnBncCopyV/AAA8/O6B2gC
dnZRD4UCUgAA0dGdPUFCh4VaLwAAoZ50A0UCA1kD4N6sOzgTBDgCZ2Q6wL6QXGJamqSqWFUtOz5B
lZylWVxifoF4rwAA7OrGEP4Agnx23uCsuMTSytfoIhsVyMetUscBe4OKcnmCI4gJgHU28hcUL/gG
XWJmA7YHQD47BJUBgX1UR0Qdr7rJSecRTtUI9CgmfYBcfXI0+zIwYV01ywAA1+X2nqCc+WpnOOgA
9VdUO9wAqvyQQT4YZssLs7F8vsCMu/6r+XRx4d3akf5z2RUV1//OjeNVyv657yAe/6mmSPUPddMq
2yYj1Do2wryx60pG+4qGWtojTv4sYV5Wc/1M+GFc/ZaTAacEZ/wwm6J3oexyw87iAAAAFxcXFxcX
CcIG8kI+c9MVdf9ll5Fcl/+G1EpGAOQCKioqLCwsOTk5Ozs7U+Iihdg9hP1epK3A3FZS+oF9/6Gd
W7dgXf9Tb+IggG84hY+hn7LEjd1MnORjoJ+hvsGxu87iv9Hh0UM/3WBb/7KwAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAYDSAjwAAAQB0Uk5T/v7//v//////////////////////
////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////8ATsX/
/////////07FTsX/////////////////////////////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAChx1HwAAHCcSURBVHja7b2JYyNHduYZkcGITCaoJJiJBFEghKPZEltFqqQq1cViSVOq
krpqbJfbatntdh8+1m7b7bHXZ4/Xx/heX+OZnZ1r7/v6N/e9iMjMyEQekQBIgCyEVDwAMJDHD9+L
9+LFC/LX/+6/Zdu2bYs0urr23/zbvyb/bntFt239KFL6b8lWE7dtrQimuki2F3bbylC7Ugxl26K4
bXnQ1qWKWxS3rcjYFsVt25RBYKmhppfetihuW1Ht5lCkV9K2KG7bnOG9OiXcorht1qq4RXHb1j9U
vKIgzhbFbSvnjW1R3LaNJXFroLdti+K2bVGkV962KG7bFsVtu0yqFnWg14PhFsUtilsUt22L4hbF
N2fYZ5lnc8WO8hbFN5TGXApiEc31quAWxRXE2lZ+FzZVqDYERUrW0GjZcTiWjZTcSXI9Gq0Ckdyk
tiCKdEPuiTWI2OhGnMNid4mVfpCcm9TqYSTVJIqwc8Xt1t60yCKcwHsff9WqffxegcW1nMMibees
TBcliIrRluaeZsPExnHBZYw1KlBz5Om0RREug3/1t+TW7p4gRU1866uW7WNkMX8OQedatFv7/fkB
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
B01HnpllPhkXAAAAAElFTkSuQmCC
endef

define NHE_TAPESTRY_FILE19
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

define NHE_TAPESTRY_FILE20
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

define NHE_TAPESTRY_FILE21
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

define NHE_TAPESTRY_FILE22
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
endef

define NHE_TAPESTRY_FILE23
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
endef

define NHE_TAPESTRY_FILE24
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
kF7gEAAAAFAAA//Z
endef

define NHE_TAPESTRY_FILE25
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
endef

define NHE_TAPESTRY_FILE26
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
gEIBCIhyhEkS9iBEIBCASoBCD//Z
endef

define NHE_TAPESTRY_FILE27
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

define NHE_TAPESTRY_FILE28
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
ABQIJAAUAAAAAEiIBSH3AIAAAAYAAH//2Q==
endef

define NHE_TAPESTRY_FILE29
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
endef

define NHE_TAPESTRY_FILE30
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
endef

define NHE_TAPESTRY_FILE31
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
AAAAAElFTkSuQmCC
endef

define NHE_TAPESTRY_FILE32
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

define NHE_TAPESTRY_FILE33
iVBORw0KGgoAAAANSUhEUgAAAGgAAABACAYAAAD24zL6AAAWfmNhQlgAABZ+anVtYgAAAB5qdW1k
YzJwYQARABCAAACqADibcQNjMnBhAAAAFlhqdW1iAAAAR2p1bWRjMm1hABEAEIAAAKoAOJtxA3Vy
bjpjMnBhOjYyMTEyZDFmLTc2MzctNDRmZS05ZDI5LWRkNjhmM2IwYjI0ZAAAAAOTanVtYgAAAClq
dW1kYzJhcwARABCAAACqADibcQNjMnBhLmFzc2VydGlvbnMAAAAAuGp1bWIAAABEanVtZGNib3IA
EQAQgAAAqgA4m3ETYzJwYS5pbmdyZWRpZW50LnYzAAAAABhjMnNo5vLJkeajrphkrVSsSpJykQAA
AGxjYm9yo2lkYzpmb3JtYXRpaW1hZ2UvcG5namluc3RhbmNlSUR4LHhtcDppaWQ6ZGU2ODlkNzYt
M2ZiYS00NDkwLWJkZjMtMmIzOTIyMjU1MzM0bHJlbGF0aW9uc2hpcGhwYXJlbnRPZgAAAeJqdW1i
AAAAQWp1bWRjYm9yABEAEIAAAKoAOJtxE2MycGEuYWN0aW9ucy52MgAAAAAYYzJzaF96XdEnbgXZ
nrCCFZbUocMAAAGZY2JvcqJnYWN0aW9uc4KiZmFjdGlvbmtjMnBhLm9wZW5lZGpwYXJhbWV0ZXJz
oWtpbmdyZWRpZW50c4GiY3VybHgtc2VsZiNqdW1iZj1jMnBhLmFzc2VydGlvbnMvYzJwYS5pbmdy
ZWRpZW50LnYzZGhhc2hYIMYHHc9nf17YghSvHaDJLqQTWgxbmNpSlzlaMUFXX6sppGZhY3Rpb254
HWNvbS5hbnRocm9waWMuY2xhdWRlLnByb3ZpZGVkanBhcmFtZXRlcnOheB9jb20uYW50aHJvcGlj
Lm9yaWdpbi1jb25maWRlbmNlZ3Vua25vd25rZGVzY3JpcHRpb254ZkNsYXVkZSBwcm92aWRlZCB0
aGlzIGZpbGUgYXQgdGhlIHJlcXVlc3Qgb2YgYSB1c2VyIGFuZCBtYXkgaGF2ZSBjcmVhdGVkIG9y
IG1vZGlmaWVkIHRoZSBmaWxlIGNvbnRlbnRzLm1zb2Z0d2FyZUFnZW50oWRuYW1lZkNsYXVkZXJh
bGxBY3Rpb25zSW5jbHVkZWT1AAAAyGp1bWIAAABAanVtZGNib3IAEQAQgAAAqgA4m3ETYzJwYS5o
YXNoLmRhdGEAAAAAGGMyc2isMNqiRrfoGEoQbvkEDZojAAAAgGNib3KlY2FsZ2ZzaGEyNTZjcGFk
TQAAAAAAAAAAAAAAAABkaGFzaFggTN9M2MoM5mWgu0s1WvMtrDA+hsuTWEFCnrC5C4rV30xkbmFt
ZW5qdW1iZiBtYW5pZmVzdGpleGNsdXNpb25zgaJlc3RhcnQYIWZsZW5ndGgZFooAAAI+anVtYgAA
ACdqdW1kYzJjbAARABCAAACqADibcQNjMnBhLmNsYWltLnYyAAAAAg9jYm9ypWNhbGdmc2hhMjU2
aXNpZ25hdHVyZXhNc2VsZiNqdW1iZj0vYzJwYS91cm46YzJwYTo2MjExMmQxZi03NjM3LTQ0ZmUt
OWQyOS1kZDY4ZjNiMGIyNGQvYzJwYS5zaWduYXR1cmVqaW5zdGFuY2VJRHgseG1wOmlpZDo5NWJm
NGU2MC0xYjY4LTRmY2ItYmRiYy02YTZjZWE4MGU3MWFyY3JlYXRlZF9hc3NlcnRpb25zg6JjdXJs
eC1zZWxmI2p1bWJmPWMycGEuYXNzZXJ0aW9ucy9jMnBhLmluZ3JlZGllbnQudjNkaGFzaFggxgcd
z2d/XtiCFK8doMkupBNaDFuY2lKXOVoxQVdfqymiY3VybHgqc2VsZiNqdW1iZj1jMnBhLmFzc2Vy
dGlvbnMvYzJwYS5hY3Rpb25zLnYyZGhhc2hYIPdcxVbvcfW4B0C/5QoZTMw2JQL6LBjmtFevucxr
gh8MomN1cmx4KXNlbGYjanVtYmY9YzJwYS5hc3NlcnRpb25zL2MycGEuaGFzaC5kYXRhZGhhc2hY
IH1oc0U+UzLw7zVnCYc58ECxWSF0+Npq3s1WCpS2TGNGdGNsYWltX2dlbmVyYXRvcl9pbmZvo2Ru
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
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
endef

export NHE_TAPESTRY_SRC1
export NHE_TAPESTRY_SRC2
export NHE_TAPESTRY_SRC3

define NHE_TAPESTRY_CONFIGURE_CMDS
	mkdir -p $(@D)/examples/nhe-tapestry
	printf '%s\n' "$$NHE_TAPESTRY_SRC1" > $(@D)/examples/nhe-tapestry/DistrhoPluginInfo.h
	printf '%s\n' "$$NHE_TAPESTRY_SRC2" > $(@D)/examples/nhe-tapestry/Makefile
	printf '%s\n' "$$NHE_TAPESTRY_SRC3" > $(@D)/examples/nhe-tapestry/TapestryPlugin.cpp
endef

define NHE_TAPESTRY_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(TARGET_CONFIGURE_OPTS) $(MAKE) NOOPT=true -C $(@D)/examples/nhe-tapestry lv2_dsp
endef

define NHE_TAPESTRY_INSTALL_TARGET_CMDS
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2
	cp $(@D)/bin/nhe-tapestry.lv2/nhe-tapestry_dsp.so $($(PKG)_PKGDIR)/nhe-tapestry.lv2/
	$(file >$(@D)/.pb-1,$(NHE_TAPESTRY_FILE4))
	cp $(@D)/.pb-1 $($(PKG)_PKGDIR)/nhe-tapestry.lv2/manifest.ttl
	$(file >$(@D)/.pb-2,$(NHE_TAPESTRY_FILE5))
	cp $(@D)/.pb-2 $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui.ttl
	$(file >$(@D)/.pb-3,$(NHE_TAPESTRY_FILE6))
	cp $(@D)/.pb-3 $($(PKG)_PKGDIR)/nhe-tapestry.lv2/nhe-tapestry.ttl
	$(file >$(@D)/.pb-4,$(NHE_TAPESTRY_FILE7))
	cp $(@D)/.pb-4 $($(PKG)_PKGDIR)/nhe-tapestry.lv2/presets.ttl
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-5,$(NHE_TAPESTRY_FILE8))
	base64 -d $(@D)/.pb-5 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/background.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-6,$(NHE_TAPESTRY_FILE9))
	base64 -d $(@D)/.pb-6 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/format-btn-down.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-7,$(NHE_TAPESTRY_FILE10))
	base64 -d $(@D)/.pb-7 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/format-btn.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-8,$(NHE_TAPESTRY_FILE11))
	cp $(@D)/.pb-8 $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/icon-tapestry.html
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-9,$(NHE_TAPESTRY_FILE12))
	base64 -d $(@D)/.pb-9 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/knob.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-10,$(NHE_TAPESTRY_FILE13))
	base64 -d $(@D)/.pb-10 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/lcd.woff2
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-11,$(NHE_TAPESTRY_FILE14))
	base64 -d $(@D)/.pb-11 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/led-green.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-12,$(NHE_TAPESTRY_FILE15))
	base64 -d $(@D)/.pb-12 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/led-red.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-13,$(NHE_TAPESTRY_FILE16))
	base64 -d $(@D)/.pb-13 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/onoff-down.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-14,$(NHE_TAPESTRY_FILE17))
	base64 -d $(@D)/.pb-14 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/onoff.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-15,$(NHE_TAPESTRY_FILE18))
	base64 -d $(@D)/.pb-15 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/screenshot-tapestry.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-16,$(NHE_TAPESTRY_FILE19))
	cp $(@D)/.pb-16 $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/script-tapestry.js
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-17,$(NHE_TAPESTRY_FILE20))
	base64 -d $(@D)/.pb-17 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/slider-cap.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-18,$(NHE_TAPESTRY_FILE21))
	cp $(@D)/.pb-18 $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/stylesheet-tapestry.css
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-19,$(NHE_TAPESTRY_FILE22))
	base64 -d $(@D)/.pb-19 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/tape-0.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-20,$(NHE_TAPESTRY_FILE23))
	base64 -d $(@D)/.pb-20 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/tape-1.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-21,$(NHE_TAPESTRY_FILE24))
	base64 -d $(@D)/.pb-21 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/tape-2.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-22,$(NHE_TAPESTRY_FILE25))
	base64 -d $(@D)/.pb-22 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/tape-3.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-23,$(NHE_TAPESTRY_FILE26))
	base64 -d $(@D)/.pb-23 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/tape-4.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-24,$(NHE_TAPESTRY_FILE27))
	base64 -d $(@D)/.pb-24 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/tape-5.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-25,$(NHE_TAPESTRY_FILE28))
	base64 -d $(@D)/.pb-25 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/tape-6.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-26,$(NHE_TAPESTRY_FILE29))
	base64 -d $(@D)/.pb-26 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/tape-7.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-27,$(NHE_TAPESTRY_FILE30))
	base64 -d $(@D)/.pb-27 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/tape-8.jpg
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-28,$(NHE_TAPESTRY_FILE31))
	base64 -d $(@D)/.pb-28 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/tape-btn-down.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-29,$(NHE_TAPESTRY_FILE32))
	base64 -d $(@D)/.pb-29 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/tape-btn.png
	mkdir -p $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui
	$(file >$(@D)/.pb-30,$(NHE_TAPESTRY_FILE33))
	base64 -d $(@D)/.pb-30 > $($(PKG)_PKGDIR)/nhe-tapestry.lv2/modgui/thumbnail-tapestry.png
endef

$(eval $(generic-package))
