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
    const char* getLabel()       const override { return "Tapestry"; }
    const char* getDescription() const override { return "Tape machines from studio reel to answering machine: wow, flutter, saturation and tape's low end."; }
    const char* getMaker()       const override { return DISTRHO_PLUGIN_BRAND; }
    const char* getLicense()     const override { return "GPL-3.0-or-later"; }
    uint32_t    getVersion()     const override { return d_version(1, 0, 6); }   // = lv2:minorVersion 2, microVersion 6
    int64_t     getUniqueId()    const override { return d_cconst('n', 'T', 'p', 's'); }

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
        const float* in = inputs[0];
        float* out = outputs[0];

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

            const float x = in[i];

            // ---- record side
            float v = x;
            if (fAlcOn) {
                const float a = std::fabs(v);
                fAlcEnv += (a > fAlcEnv ? fAlcAtk : fAlcRel) * (a - fAlcEnv) + 1e-18f;
                v *= fAlcGain;
            }
            if (fNcOn) {                         // noise reduction encode (2:1)
                const float pw = v * v;
                fNcPin += (pw > fNcPin ? fNcAtk : fNcRel) * (pw - fNcPin) + 1e-18f;
                v *= fNcCA + frac * (fNcCB - fNcCA);
            }
            const float g = fG0 * fDrive;
            v = fPre.process(v * g);
            // self-erasure: hot treble partly wipes itself off the oxide, so the pick's
            // edge is smoothed before the body clips. Knee 0.5 of tape full scale [guess]
            fErLp += fEraseSplit * (v - fErLp);
            const float hi = v - fErLp;
            const float ah = std::fabs(hi);
            fErEnv += (ah > fErEnv ? fEraseAtk : fEraseRel) * (ah - fErEnv) + 1e-18f;
            v = fErLp + hi / (1.0f + 2.0f * fErEnv);
            v = saturate(v);
            v = fDe.process(v) / g * fDriveOut;

            // grain: the oxide isn't even, so the level shimmers with the signal
            const float n = fRng.next();
            fGrLpS += fGrainLp * (n - fGrLpS);
            fGrHpS += fGrainHp * (fGrLpS - fGrHpS);
            v *= 1.0f + fGrainAmt * (fGrLpS - fGrHpS);

            fBuf[fW] = v;
            fDry[fW] = x;

            // ---- tape path: read point swings around the centre
            const float d = fCentre + fDispA + frac * (fDispB - fDispA);
            const float rp = (float)fW - d + (float)kBufSize;
            const uint32_t ip = (uint32_t)rp;
            const float t = rp - (float)ip;
            const float xm1 = fBuf[(ip - 1) & kBufMask], x0 = fBuf[ip & kBufMask];
            const float x1  = fBuf[(ip + 1) & kBufMask], x2 = fBuf[(ip + 2) & kBufMask];
            const float c1 = 0.5f * (x1 - xm1);
            const float c2 = xm1 - 2.5f * x0 + 2.0f * x1 - 0.5f * x2;
            const float c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1);
            float y = ((c3 * t + c2) * t + c1) * t + x0;

            // ---- playback side
            if (fHissAmp > 0.0f) y += fHissDe.process(fHissAmp * fRng.next());
            y *= 1.0f - fDropEnv * fDropDepth;
            y = fHp1.process(y); y = fHp2.process(y);
            y = fBump.process(y);
            y = fLp1.process(y); y = fLp2.process(y);
            if (fNcOn) {                         // noise reduction decode (1:2)
                const float pw = y * y;
                fNcPout += (pw > fNcPout ? fNcAtk : fNcRel) * (pw - fNcPout) + 1e-18f;
                y *= fNcEA + frac * (fNcEB - fNcEA);
            }
            y *= fMakeup * fSw;
            // Tone: a first-order tilt, unity at 800 Hz
            y = fTiltGain * fTilt.process(y);

            const float dry = fDry[(fW - fDryDelay) & kBufMask];
            fW = (fW + 1) & kBufMask;

            const float active = fLev * (fMix * y + (1.0f - fMix) * dry);
            out[i] = fAct * active + (1.0f - fAct) * x;
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

    inline float saturate(float v)
    {
        fUp[fUpPos] = fUp[fUpPos + kPhaseTaps] = v;
        const float* h = &fUp[fUpPos];   // h[0] is the newest
        fUpPos = (fUpPos + kPhaseTaps - 1) % kPhaseTaps;
        for (int ph = 0; ph < kOS; ++ph) {
            float xo = 0.0f;
            for (int k = 0; k < kPhaseTaps; ++k) xo += kFir[k * kOS + ph] * h[k];
            fDn[fDnPos] = fDn[fDnPos + kTaps] = softClip(xo * (float)kOS);
            fDnPos = (fDnPos + kTaps - 1) % kTaps;
        }
        const float* q = &fDn[fDnPos + 1];
        float yd = 0.0f;
        for (int j = 0; j < kTaps; ++j) yd += kFir[j] * q[j];
        return yd;
    }

    void applyFormat(int fmt, int tape, float age)
    {
        const bool alcChanged = (kFormats[fmt].alcMaxDb > 0.0f) != (kFormats[fFmt].alcMaxDb > 0.0f);
        fFmt = fmt; fTape = tape;
        const FormatDef& F = kFormats[fmt];
        const TapeDef& T = kTapes[tape];
        const double ez = F.emphHz, ep = F.emphHz * std::pow(10.0, (F.emphDb + T.emphOffDb) / 20.0);
        fPre.set(ez, ep, fSr);       // pre: zero at ez, pole at ep (treble lift)
        fDe.set(ep, ez, fSr);        // de: the exact inverse
        fHissDe.set(ep, ez, fSr);    // hiss gets de-emphasised like it does on tape
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
    }

    void setResponse(int fmt, int tape, float age)
    {
        const FormatDef& F = kFormats[fmt];
        const TapeDef& T = kTapes[tape];
        const double nyq = 0.45 * fSr;
        // 4th order (two stages) uses Butterworth Qs; 2nd order uses 0.707
        const double qa = F.hpStages > 1 ? 0.5412 : 0.7071, qb = 1.3066;
        fHp1.highpass(F.hpHz, qa, fSr);
        if (F.hpStages > 1) fHp2.highpass(F.hpHz, qb, fSr); else fHp2.identity();
        fBump.peak(F.bumpHz, F.bumpDb, 1.0, fSr);
        // head wear and oxide shed: Age dulls the top end, corner down to 45 % at 10 [guess]
        const double lp = std::fmin(nyq, F.lpHz * T.lpMul / (1.0 + 0.12 * age));
        const double la = F.lpStages > 1 ? 0.5412 : 0.7071;
        fLp1.lowpass(lp, la, fSr);
        if (F.lpStages > 1) fLp2.lowpass(lp, qb, fSr); else fLp2.identity();
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
        }
    }

    // tilt: H(s) = (A s + w0) / (s + A w0): lows 1/A, highs A, exactly 1 at 800 Hz.
    // As a Shelf1 (DC gain 1, HF gain A^2) with zero at f0/A and pole at f0 A, times 1/A.
    // Tone +-5 = +-4 dB at the ends [guess, by ear]
    void setTilt(float tone)
    {
        const double A = std::pow(10.0, 0.8 * tone / 20.0);
        fTilt.set(800.0 / A, 800.0 * A, fSr);
        fTiltGain = (float)(1.0 / A);
    }

    void resetNc()
    {
        fNcPin = fNcPout = kRef * kRef;          // start at unity gain both ways
        fNcCA = fNcCB = fNcEA = fNcEB = 1.0f;
    }

    void clearFilters()
    {
        fPre.clear(); fDe.clear(); fHissDe.clear();
        fHp1.clear(); fHp2.clear(); fBump.clear(); fLp1.clear(); fLp2.clear();
        fErLp = fErEnv = 0.0f; fTilt.clear();
    }

    void reset()
    {
        std::memset(fBuf, 0, sizeof(fBuf));
        std::memset(fDry, 0, sizeof(fDry));
        std::memset(fUp, 0, sizeof(fUp));
        std::memset(fDn, 0, sizeof(fDn));
        fUpPos = 0; fDnPos = 0; fW = 0; fCrCount = 0;
        fPre.clear(); fDe.clear(); fHissDe.clear();
        fHp1.clear(); fHp2.clear(); fBump.clear(); fLp1.clear(); fLp2.clear();
        fGrLpS = fGrHpS = 0.0f;
        fErLp = fErEnv = 0.0f; fTilt.clear();
        fPhS = 0.0f; fPhC = 0.37f; fR1 = fR2 = fF1 = fF2 = 0.0f;
        fDispA = fDispB = 0.0f;
        fDropEnv = 0.0f; fDropDepth = 0.0f; fDropHold = 0; fSwHold = 0;
        fAlcEnv = kAlcTarget; fAlcGain = fAlcGainT = 1.0f;
        resetNc();
        fRng.s = 0x9e3779b9u; fRngMod.s = 0x2545F491u;
    }

    float fParams[kParameterCount];
    float fBuf[kBufSize], fDry[kBufSize];
    float fUp[2 * kPhaseTaps], fDn[2 * kTaps];
    int   fUpPos = 0, fDnPos = 0, fCrCount = 0;
    uint32_t fW = 0, fDryDelay = 288;

    Shelf1 fPre, fDe, fHissDe;
    Biquad fHp1, fHp2, fBump, fLp1, fLp2;
    Rng    fRng { 0x9e3779b9u }, fRngMod { 0x2545F491u };

    int   fFmt = kWalkman, fTape = kFerric;
    float fAgeApplied = -1.0f;
    float fSr = 48000.0f, fCr = 3000.0f, fSmooth = 0.0f, fSwCoef = 0.0f;
    float fAlcAtk = 0.0f, fAlcRel = 0.0f, fAlcGainC = 0.0f, fAlcEnv = kAlcTarget, fAlcGain = 1.0f, fAlcGainT = 1.0f;
    float fGrainHp = 0.0f, fGrainLp = 0.5f, fGrainNorm = 1.0f, fGrLpS = 0.0f, fGrHpS = 0.0f;
    float fCentre = 288.0f, fSwing = 240.0f;
    float fPhS = 0.0f, fPhC = 0.0f, fR1 = 0.0f, fR2 = 0.0f, fF1 = 0.0f, fF2 = 0.0f;
    float fRandNorm[kNumFormats], fFlutNorm[kNumFormats];
    float fDispA = 0.0f, fDispB = 0.0f;
    float fDropAtk = 0.0f, fDropRel = 0.0f, fDropEnv = 0.0f, fDropDepth = 0.0f;
    int   fDropHold = 0, fSwHold = 0;
    float fG0 = 3.0f, fHissAmp = 0.0f, fGrainAmt = 0.0f, fAlcMax = 1.0f, fMakeup = 1.0f;
    bool  fAlcOn = false;
    float fRandA = 0.001f, fSvfG = 0.01f, fSvfK = 0.667f;
    float fEraseSplit = 0.3f, fEraseAtk = 0.04f, fEraseRel = 0.0005f, fErLp = 0.0f, fErEnv = 0.0f;
    bool  fNcOn = false;
    float fNcAtk = 0.01f, fNcRel = 0.0003f, fNcPin = 0.01f, fNcPout = 0.01f;
    float fNcCA = 1.0f, fNcCB = 1.0f, fNcEA = 1.0f, fNcEB = 1.0f;
    Shelf1 fTilt;
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
    lv2:microVersion 6 ;
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
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
A//Z
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
iVBORw0KGgoAAAANSUhEUgAAIIAAAACACAMAAAByfB4uAAADAFBMVEUAAAAkJCQFBQUYGBg2NjZG
RkZWVlZnZ2eHh4d3d3eWlpZ+fn5VVVWmpqY6OjoFBQWpqam3t7f+/v77+/vGxsYYGBgGBgaXl5cn
JycHBwe4uLhnZ2cHBwfo6OgWFhYEBATW1tZISEiJiYkVFRUGBganp6e3t7cWFhYVFRUVFRW3t7d3
d3eZmZm4uLi4uLjIyMioqKjFxcVoaGg3NzcmJibFxcXGxsaHh4cmJiYnJydHR0dHR0e4uLg3NzfH
x8eoqKhXV1eXl5clJSWXl5e3t7cmJiZnZ2eoqKjExMTX19c3NzdXV1eIiIioqKhHR0c4ODhoaGh3
d3eJiYk3NzdGRkaoqKhXV1dnZ2d3d3cUFBR3d3eYmJhGRkZnZ2d4eHhVVVXFxcVISEg1NTV3d3cp
KSlYWFiYmJiFhYWXl5dpaWmHh4eHh4fl5eXU1NRUVFTT09PV1dXU1NTj4+PR0dHS0tLg4ODi4uIA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAABCrdkvAAABAHRSTlMA/v7+/v7+/v7+/gQE/QbUB/oB//kRlRAOchALUf8rt/wL
E1Eu1pBy05LT0tUwbRKR19PWKi9rzY7ReNVRVVAv0JVzK69Qlm6QECqUlVMqdFKWKoyKtSoqVbh2
s1VxKnOtrq2xtFFtq0y2cFMQUbMtaNlRj6c3dQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGfCaLgAB
AABJREFUeNrsvYmfHMWVLlpRkWttVJW6XZrqkae7bQmQkFowloR9ZWQZbKk9MBg82L6DB3s27B+I
CzN3+ftfxr6diIzMjKye35uu9y72GNCXcSLinO8scc5kcv27/l3/rn/Xv+vf9e/6d/27/l3/rn/X
v+vf9e/6d/27/l3/rn/Xv+vf9e/6d/27/l3/rn/Xv+vf9e/6d/27/l3/rn/Xv+vf9e/6d/27/l3/
rn/Xv+vf9e/6d/27/l3/rn/Xv+vf9e/6d/27/l3/rn/Xv+vf9e/6d/27/l3/rn/Xv+vf9e/6d/27
/l3/rn/Xv+vf9e/6d/27/l3/rn/Xv+vf9e/6d/27/l3/rn/Xv+vf9e/699/4N5+v13P6Wy/m82v8
A/+21/gSf32N/98df3uN/98Xf3G9/v+O+IurxJ9c8fr/i+FfBf9aXKX9mZjn70r45+Jq+ddivaL4
iyvDn18d/kSt/yrkv53Mtwu6/6urwm9wVwSe7MPkSvT/Yr4X678y/bdakf+cHF4AVO57IoH14vDw
2+an+M92vj34B8wn7P7vr+b8NxegWf+q2X62/1ej/wg81X/bK1AARO6r+X61WGyv4ACy9VP9s7iS
88fsT/MFV2j/Vxz/qvTvldrf9VXa//8C/sfi6uOfq/8C/HN1ZfvPzv/qKvX/ld1/wX+vUP8t1vvV
an9F+FT+e2qAif25Av63pfyD85/tFWwA0T97fv/+28Xf2Pm7Sv27bfyv5vTt91eif4T/1xzBxZXl
f1bM/72q+KvS/1fjfwr+dVXnf/FfJP733xx/ccX88+D3f04O/Nbyxw/oh/8XwN9e4/+33v/r8/df
DX971fjb6/3/77P/82v9e7Xrn1/x/bcZ36Hl/18Mf8v8sf8m53/h4PN40JXdv8mB1w/u/4Hwt771
Lw6Fv4Dv/2JyQHw3HrI42P3bgutfXOX9J/UYV21/D7b/65Vr/w63/obpeuzfYbLAW9D+U/2zPdT+
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
4nk28vfqjQH/1WI5rvxm/3f7brzs36rGP7t+tbM/dBJArf9s9M/o/29GDH+LZmPT+7/Cz8akH6vq
HpZZ/vVydPs/nPy1A35lln9k/Mr/mfjP2OIv1sb9P/r+W5v53+j6t+3/7LD4e9C/ef0Pq/9R43/L
v8znj9H9n9H/3r46sP2P7n8Obf82/M3ysPY3tv+x+N9D448ffzdX/9r+/98df23R/0Hj3/jrb8X/
N5f/X93/Hxp/bP6xtuEfeP03B91/4/MvK/8+qP3dvtocmP8fmn+Ojr8+9P67Ouz5c3NY/OWh+YdF
/uVh7f9mvTgs/qH5x2bs9V9b8s/zQ8p/6PzPPtb/sPv/0Oev9cHPn/WPWN88vjh/+vS0/Z4+Pb94
sdt7+wCv8TMd//GOe4+Ov+jkv1Lxbx9fZcs9yb/c6Prf4S+b5of5+Pi6/rcXb6+yxWZP679U5P/w
4fz2xc1mvhZXaZxvVQeB7FWPf1fhP63ws+VZNnb3Syt/hb99+vRuwL948a4xv1U2OgXILtc3b2/P
n37o5H/6YVvJv69vZ+GvXly0+NVP2OFX+399vZftv/s2Nf7TWvy7u7ud/e3833oP5teZ19WL2/MP
H3bYg/+72Vwu9qP/R5ebnf/bfpD9z81ysd6bCej+5/GrZbYH/9PrX8Kv1v9mD9I3PQjXGyz+3aw3
e8Dv7L/2PzJ+lu1t/ZdXj281+bP1nuJP5f8Q/e9N/us1uv57kx/lf4+vNll2sP1f87/D8s/9rT+B
v87Wh9T/zd7Q12vU/tbrff0CbP/t4v/mkPp/sUf5cfw9iv+vaX97w0fOnxX/22wOir83/4Odf2v8
zUHtL1sf2v/uzwIPuv6Hjn/r9b9k/M8OHP/3SP/+JeX/1fAvCv/Q/m99YP9zUP63O3+tf838c4/y
rwn597f9Dsw/1+uD7r/lofn3huA/h45/B/b/m8PafzZ6/t9k/y+uDs4/Dnz+zpaLA67/i73Gv6t/
Sf5/0P23L/+3EPWw3vnind9Z7zP3PKQhdl9D+tfXy/3DX7fYld2vs4f7wu30f1lrv0oGrZfZcv/4
D+t696ZiHddZV3qc71H/u1+yrGrx19n6Mlt+3P+D1X7wL3f4u4i32f3PTiWPPta2x8jfx+vsclnB
1/MuukdXFvvb/+vLne3VF+6X88t1tm/5s4cPawO8vj6E86mdzuXlUjtz7k3+h4PLWy6W1w/3rv8W
u2l7We5p14lvq+y8foO92wOXH+9N4vYHPKzsrup5W++c3+Xl/u1vOV9nm50H3P2ezT5rP913vagY
Z3vqXO5dATuVt9ibbJ/Uv8dfZyLu/gnIQLoO4wDXwn9m6+UBfsC6/182y0MpYF2RsH2WniT5q32/
Poz+K8c/rED26/vENd8c8mfU3/KA2JUf3r/91bAt/CHiX7P5mv1/oJXfbNYH23lLEfpA9tfGwfXB
tLAWKMgB5O7c0EH2X+P26xTIIeLfEiEjhyBAWizYN/z68OIf5AesD7z8FBfIDr0WvxL5pfU/ZPxp
c7CHOn/VJGi5PMiar5tDyCH413K9Hgjo5jA2X1OP+r+XB+C/WcuAD8N/lh31OpDvWYpGd1D/157D
D8ZAD+X/1jIH2b/9i7/lMP6vO/wfgH8Liq+qEAfA3wxaOED8WfZZ73oDXB5q69fCLw/h/5vq86Y9
AB5gBy6Xm19j4u/47b/M+Av45t0z5QfSf429+pVYxeJfzSgrxS8Wh8X/tXiFVdMEsDrg+i8OrPKj
/z1+x+/4Hb/jd/yO3/E7fsfv+B2/43f8jt/xO37H7/gdv+N3/I7f8RvtW/6q4f9FfsLR+g7+zQ+o
gcWB6rGLfgXmh1P58oA2sDju/aMDPiT+0f6O3/E7fsfv+B2/43f8jt/xO37H7/gdv+N3/I7f8Tt+
x+/4Hb/jd/yO3/E7fsfv+B2/43f8jt/xO37H7/gdv+N3/I7f8Tt+x+/4Hb/jd/yO3/E7fsfv+B2/
43f8jt/xO37H7/gdv+N3/I7f8Tt+x+/4Hb/jd/yO3/E7fsfv+B2/43f8jt/xO37H7/gdv+N3/I7f
8Tt+x+/4Hb/jd/yO3/E7fsfv+B2/43f8jt/xO37H7/gdv+N3/I7f8Tt+x+/4Hb/jd/zG+P7/x2FP
oqd6ll4AAAAASUVORK5CYII=
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
iVBORw0KGgoAAAANSUhEUgAAAooAAAGQCAMAAAAeD7HeAAADAFBMVEUXFxcnJycDAwM1NjXY2KZG
SEdWV1VmZ2Z2dnXn5rGYlpH7+/q4tomNAACJiIbIx5cbIRo8QjvHyMiop6ciIxy1tbWKiXOqp4xn
Z08dHiAeISH6+cmXlnDW1taopXhyAABCRDnn5+einJUHeAL8AAAHaALz87p2dlEPhQPR0Z5SAADg
3qyHhlovAAA9QkIERAMEWQSgnXQ8ORMFOANnZDrAvpCbpKlYVSxcYlpZXGI6PUDt68V+gXivAADJ
yKpAPjwQ/gCCfHZ1eoJ8dTne4KyVnKUiGxRSxwG6w88jiAryFxQv+AZ7gofO2OQDtghdYmYElQGA
fVRIRRyzu8dJ5xFO1Qj0KCZ9gFxhXjT7MjCysHvLAAD5amc46AD1V1Q73ABBPhe+wI2q/JBmywvc
5fC7/qv5dHHh3dqeoZuR/nPZFRXX/86N41XK/rnvIB7/qaZI9Q910yrbJiPUOjbrSkb7ioYBpgRa
2iNO/ixz/UzCvLT4YVz9lpMHwgZn/DCAeD2boneh7HIAAAAXFxcYGBggHyNhXljyQj5z0xV1/2WX
/4bUSkYA5AIqKiosLCw5OTk7OztT4iKF2D2E/V7cVlL6gX3/oZ1dt2Jd/1Nv4iCN3Uyc5GOgn6Kn
r8G+wbHRQz/dYFv/srAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAABLQixgAAABAHRSTlP+/v/+////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////
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
RK5CYII=
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
iVBORw0KGgoAAAANSUhEUgAAAEYAAACSCAMAAADPX0yPAAADAFBMVEUDBAQVFxgmKCcyNTZFSUsc
ISNRVVU8QkQjIhwbHSGapamrtbgiGQ6iqq05PUEcIB2TmJlkaGhbYWSzu8JYXWKTnaFhXFe6w8cA
AAA6QT5vdnhjY1oWFgyaoZ0rKiY4Ni9dYFujop6HjZC6wr3Ey8ocGREjIxYhIRwwKyMzMzNMST5F
RUUMDggUEQ0YFhEeIBoiGQsgGAs2NjJEQjtaXVRbXVh/AAB/f215fIR6goTO0dIAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAA86avWAAABAHRSTlP+/v7+//////7////+//////////////8A////Ev/FyP//
////vxXJcRb7C85yw3RvyXBwc88CDv///wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAc4TsDQAA
COpJREFUeNrtWgd34zgOJsEiKbYkS3EmjpPps/1u93r7/z/s8AGkRLmk7PrdzrsXRKZIigQpEF0x
u93Dn/68PoJ6vbZF004FniWQCr3//mG3M7uHb45GcmkfA2OmEUD6zbc78/BzfriWXnsOg1kiKpvf
/dP88fF19Spg0ci4/mb+sFhGRkm5HP4E/N1cBH68DBq6DBprXuEVXuGyYF3nHHmG6Jz3XTdWfthH
X3nv4hC9HyI3+B59ZPBbhwfeVdzhfFVVjqvecK/HfOlglGh1qDoMqCJ3Vzq+YtSVi67CenzFKs9i
NE0zKb5Q6FzVj+ZAFy9VcKlpQ2MbktaE0FqiBm0A3yhIw+J5E5oQLC4dHnSmCTyIJ4XAlSDDGgwL
MgwNQsPKTKAIGItFAuVFe2yIMDYQ4cclzaDIneDRAXgKTLhxYQP11Pf6XtgAUR9CLzvCBmRsEMzT
dpqQ1wgEPE3C3oMGpjRH9mkIU3FoR21pz86ckpmNmFZOYfntYA4qzaNvRMumvhwT2/46g2SXBe58
opmLtMKHQMJTRDNZpU7mkGAmV5u4GSF6LH/VULHw+LiNYzWOMY4R8ufjsI3d8Gkc9htHce8hYgNk
2UPyRLqioDTqfTxJSEq/JDvh0IF5hPbTUWfhPPaZ0BaJC+EEAjA5FScHESXZDveCtQlyy7zdW7qU
9mPp6DyfVuMgLFwQToWXdJVKkJNOZ9PNOlKZs6o/ZKw1rOu2e1AdKs6xEvWuYx3Yue2Ic4NqYyXn
Ryd6cXBuFHXLCjJGR53r7nBgR+LDrw3x1SsxzawW+4WUNjSrTjNRUt4JV028AKoNkM0qCHyCV6Ok
Iknr/HYvlIWzLqoQcaKl1RUZQnCqDG3aj+fnovKwDZu22DQqJoYJOIoVYuMDQo8wRl5+2wjbhH7Y
EjSErh3Tn4uBO+8wg8/ZmUSknuxEgV5Xg0kIWTbzLhY6IjRZLiZJAgFZQcsta54s4WASpblbUBlW
RQxc83Jn19ozJAaNO5doXblOSe5AU7kSVyd2dtPb27QrAonZSkPhKGE7/nFr65XCEUoHqog59QPo
7e/gAGCs77zSl1f2wQgVWAeyvel73YZylhXew3LQg9iUEqsmqmeTKB0h61PMteaMBjKJ4LXOsggN
KXE8qUp5WRhhl2xcUNtOvCoM2UO7ynZ7OV4WcRK2wY1ckjVSsbU6DWzDfBmruHXjAHbu4AuBgDHe
cSV+GIYhiru0H9BmZR7VreKy40V4MKsVZ8SDCaVrE/SQHQ5frX3iuEyOYLOcBf2doI1wpbJDcKHQ
RqJQmMBZTaudIHEpHtMI2e6cMZyzD/BCZdO8PCQ+hUaoctYyhIUmVoluUpXpH5LTAIHOY4Myd2HO
s+AfgTiEIg8hTOpYvcjDoevJG7bWPisSLnyuCer5Va2Z/Awz5zImLyYR157VS2I1nZg4MGQFDhYL
l/TBEDVYED0S1R2ZrECCxH7la007O5M9mX2KBc9UWL/q+NIwAkuxSVXChuTDNEk1JuNTYbDaCtFt
LFO3t9fX16vV9W2q3K64wZW2lepq1V5dXbXoW7Ur6dYf1zFj9an9cvufleFBmxsdiQmrBK2Ugh/I
ZTI/vrm62Ww2fL+RSdzGxNXGXLXSAKI2VVZyXbWbm3YliGVDVwluEqINT2iB5Pbzl09mdY1lgLJN
sEqNlWxOtqX9V1KudKkJPn9efWlN2wpexs+LtB/5r0VF4O1bXG2bdtLqljYKV29lzkce/nFjYuYL
gTcC8U28Z7X3Jsb7+Ob+w/39/fAhDnyT59MMlD/q3UzmIvsVqvkkP6g9sCjSqtfrWqpJJ6OLdNiv
1Bk5njlQZk+LJGstck1zLsxQxGRPGKkyezg58WG5rp01rj1j6OaA+VDeD+OxAxl8fpDWlLMFdXMQ
PpZxo7XPVeE2Rdm2CWfTuvOyzSKQmvspib66nyk30VFwE1BW15Wb/ePJSUamxJFRJEhpwHpXTlIa
MekeftQxsH7pxO3X5dg1Y7NddXlxxmREMbKzBRwVx3E8Rd1XcQk6L2hdhVAvSmomSlAXBYNXRce7
CYtDaqaDaEo7lCx2KMeUkeZlU6v2MDYOOV1jCht2irXSlg1eDY6m83d3ldKUSeclZ9Qp+YUCXqqZ
qAm8jmHaELDgZBAZuDt3xzZigCMlIUSlZ5dBuAFnlI6c9OA7Mo/6L//zvPREtul8aQ7Zw2HmJkmM
esNFxGiU+526nx7sHBEmRXVHJd03Ch9uEcFWnn1VJuBE45RgEH8xIJRLKSvEx6UH4zSqDjmkk+Cq
n/1WLb+ynGhdazIu+2IhWZrSo3YH/gw5mp0cCW1MFlOlVqXpGMm0doiYJGxSocaAKsdqGrQpfRlV
yW+lyzQHLIXjdtoUfSVfTko/nySR4nwpuCpvvgoqhCrKOmT23BajjcTdJGSufNKscgKsfUV3ww/s
Oo2EqfBBext6cQrhLPyfZvazkPVLvQCZ6+uwEME+qRSNU8sEasrfqK51OZlxcByEc/M5xSRlQW9g
K3OkJ9nUHsXc1r5+9HuF31F+TnKhPc5wGEm2GnWx2LPEBxg32Qzo9UBI4HANSRPXGB+H6Cwy+uQk
Ro4Dkms3m+34r1ht9+zmcXP/7/0+jtv9qNn+cY9BYrIdMnHy0S2yI1upjhR/FPcYJffMyMWgVJPE
Jlvm8kcjVYWmzPkv/vEg53UX/+9gzny8OREl9C/4hAM/pX9RsPG8L0K/D5r+q9rN89HQM6ZLqvwi
u6GXvlS/jDQvSJuc678AiWtqTqKp6zPj6yJHV8/ZOiQDnloqpb0nRFTbuatOA2rzxGHXuVjrr67T
ZKkwWCRNdDfatBk/6FanlAtpbsUiycIX9yu29YQIA4BG/4tLN1lrgib9Z5d+AlhLZy/PekD+LFV8
JTCSzUEVaR6k2HUL9XGuVRY+/Uj8m4PRxTJ1UakVQU2LzxXpsaFnQv3oQ/OOLgDfme8vgeYX88M7
N4c9hxnc+RPiYbtMert335rdD+9nr7386Egl4uznH3n6gHcPO/OP3U9/fe+O4wAqszen3NMM7//y
0273XzJ0aUVQp7m3AAAAAElFTkSuQmCC
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
/9j/4AAQSkZJRgABAQAAAQABAAD/2wCEAAYGBgYHBgcICAcKCwoLCg8ODAwODxYQERAREBYiFRkV
FRkVIh4kHhweJB42KiYmKjY+NDI0PkxERExfWl98fKcBBgYGBgcGBwgIBwoLCgsKDw4MDA4PFhAR
EBEQFiIVGRUVGRUiHiQeHB4kHjYqJiYqNj40MjQ+TERETF9aX3x8p//AABEIAqEA/AMBIQACEQED
EQH/xACzAAABBQEBAQAAAAAAAAAAAAAAAQMEBQYCBwgQAAEDAwIDAwgGBwcDBAMAAAEAAgMEBREG
IRIxcTJBUQcTFCJSYYGRIzNCYnKxJENTc5KhwRUWNDWCwtFjg7IXdKLhJvDxAQEAAwEBAQEAAAAA
AAAAAAAAAQIDBAUGBxEAAgEDAgQFAQYFAwQDAAAAAAECAxExBCEFEkFxEyIyUWGBBhQjQnKRUmKh
scEVM9E0Q6LwZILh/9oADAMBAAIRAxEAPwDxIBdIAQSgBNnKA5XQyEB2kQBhICgOkIASZQAhAIhA
IhACVACEAIQAkQAhAOIQAkQAlQCYCEAIwgBCAEIASFACEALlACEAIQAhACEAIQBlCAcCEAiEAIQA
hACEAIQAhACQoBFySgFBSoASIAQgBCAEiAEIAQgHUIAKRAKjCARCAEhQCBKgEQgBIgBGEAIQAhAI
hAAKEAmUqAEIAQgHUIBEIBUIBEIASIASIBEIAQgDKEAiEAIQAhACEAnelQAhACEA4hACTKAVCARC
AEIBCkQAhACEAiEAIQAhACQoAQgBKgBCARCAcQgBCAAhACMoBCUAoBEIAQgBGyARCAEIAQgBIgBB
QAhACEAJEA6hAclwaCSVVy1zieGIfFAMlla8ZJcumUtY7k4/Mqk5xhklJskNtdwdycPi4p8WO6O+
2P4isXqqSLckjv8Au9dj9tv8RXQ05d/bb/EVX77R/mJ8Ni/3du/ts/iKT+7129tv8RUPXUF/EPCk
c/3eu3tt/iKDp+6+23+IrP8A1LTr+InwZif2Bdfbb/EUhsN09tv8RUf6ppf5h4Mzk2K5+23+IpDZ
LmAcyN/iKlcT07/iHgzIhoa0Ejj/APkUhoq32v5lb/e6Rv8Aca/wNPp6thwXHl4lcebqPbPzWirQ
ZzulOLaeUOtpqtwyHn5lHotX7R+ZVXqYI1WkqSSaF9Fq/aPzXJgqm/aPzKLUwD0lVHLamoiO5JCs
4J2Sj3rZNNHO04uzySEKSAXKAeSICor5yXebB2701HKynaDgF5QHJnqJT2ypUQn9ty55tMsiyiFS
MfSPUtgq/wBs9c0uT2uabj4Fb+2f80uK39s/5rLyfwE7h+m/t3/NITW/tn/NUk6fWBPmOSa39s/5
pP039s/5rCTpfwRLq5yTWftn/NcE1n7Z/wA1C8HpCIdzkmrGczP+arp6ipflomfw58VtShScvQtv
Y0pQlKXYjZm9tyQmf23Lq8n8B1WqdZiOErhgvKiPEzThzitYOGDjrwknzdGI18zTs8p8PlcNpCk1
HNrijKXpTt7Ckze2UmZfbKrsbWn73EIceYTUWYpRvzWtKVpWOevDbmLxpyAV0uk5BCUiAcQeRQGa
kcXSk+JKUAvcqydkEWlPT5xsr6moicbLhqTsapF1BbiQNlZR2wkDZcE6pqoksWo+CX+yj4LF1i/K
IbWfBNG2HwXPPUl1A5NsPguDbD4Lklqi/hjZtx8E0+gDQXHAABJKtHUNtJZHIZCtrmvlLIh9ENif
aQ2BjgHA5b3L2+R0YQXV57nXobT54fmW9w9HPgkNMQiqHf8AdtxPR8Dkm30ge3hPjz8FMalmn7GV
XSc8JL3KuSB0by0hcsBacruunFWwzwPNTnZ+pMsGMY9mQlMBXK202exCmpwUlhnJg59FAq4yxofg
89lrTn5kY1qVoSLWIEwtdjmAlXoniCIQDq5J2PQoDNkZk+JU6niyVjVLI0tFTZxstHA0R+cyweoW
/HiXnT8zaNomroaYSyzMDRiMt36haGK3DA2Xj6mfJNx+EdEYkwW4Y5JXW9rQSQAPFcbqmqiU7qm2
+lR0zJg+WR2AGjPzKnGgHguXWSq0VDxFZyV0utjWEExs0A8E26hHgvKlqdzZUxh1EN9gslqCgnrK
UxUriOE5Lf2nuXo8P1EY6inOfpi9w9POcJqOUjy0tLSQQQQSCPBP01T5l+4y0ncL7icVODisHnae
s6FeE/4XuvdGiYxkrQ6M5BGy5MQ2Xk87TaeUfdQoxnFSjhpNP4EEWQkMQ22PJTzsh6calpWTMLXf
6Xeys7NBJDIWPGCF26Wre8HnofNcZ0TpTjWS2ls18iRyGN2R8QrmLglYHMKvXVrSRThdTn5qLzmI
GPGdhyVXc2gRDY81SjL8SJ3auj+BUfwTYgBRRfhb+SaXso+SeQSYQgdSHkehQGfjGZT1KuKSPJXN
Wyy8TZW6AEjZaSKjjlnLGUYmkDQXku4QvLc2pyfPypLd/BvFKxs7FSQcEoZTmKRrwJWE53V7PW26
iJZNMOMDsDcryK1KvX1MoR80nvf49zrhyqF+hnqzU78EU1O1n3n7lY651tfNg1MspDhkAjAI9wXs
aXh9HT8rlaU316GM63NtA1dm0VPTVNNW1FU3LMPbEweI7ytqaYeAXxHGuJw1eoThDljCPKvd2Z6W
louEM3vuNGmCjvpx4LwFVuzr5CgrZQ/MceC3vKqDFy2XtUHyQR6dDT8lPfPUyuodOCsa6ppm4qQN
290gH9V5c4lpIIIIJyF9rwjUrUadQl6obHzfFNN4OockrQnuTaKvdSvORmM9pv8AwtTEYpWcbDxA
jYrTW0uWSmsSyz6H7N6pVaM9PJ+envH5iHCNknCAOS4eY+llRELdlGqKaOoiLXDcDLHeyVrSqOM4
yXRnHrNBHU6apSfVbP2ZlqiGWnlMcgGR8j7wuYKl8Lw4cu8L2bQqQ2xJH5vF1NNqLtWnTk012NBF
KyZgezHLcKtuoxAzquKknGsk83PrtU4VdFKpB3UqaY8w/oUX4W/kmcr3FhHwry+7DKMoQOpHcnIC
ipxmU9VoKJmXLkr5ZpHCNzbIwSFpY2QMqHnz1VG5wHF5tmQvJu/EltF7Yk7I6I4zY3GnYYD6S6OS
d5c5pe6VvCeSjX3TtznrZaqnhErHBuzT6wwFxUdVTocRqOs1FSio3WEbzhKVJWdzO0dzdZpz563R
SHO4mZh46Eqn1dfYLtU088UTo+CEMc12++e5erHSN66GqjWcocjVr3W/sZeJHwlBqzTR7PRS01TS
QOhmZKPNM3a4Hu9yeMYX5LrXOFWcZJppu6as0fQ0krLshlzBuszca1rsxRn1eTnBZ6OMp1ex26ag
6tVe0d2URDQBy5rggY559y9pSZ6kojRGAdhy2WK1PpsVzH1lLgVLR67O6Uf8r1OGav7tqoSbvB+W
fZnncS0nj6WcUrzW8Tydxc0kOBBBOR3hT6C5PpJOZMZPrNX3dWkqtNx6NbHyWg1k9HrKVeOIS8y9
11NkyRk0bZGEFp5FdEAAdCvnXFxbi8o/W4OFWlCcHeMopp+6e5yTz2C4OM926kONiLV00dVCI3nG
CS13sn/hY2oikppXRSY4geY5H3hetoat4um8x3R8F9qNB4NeGqgvLU2n8SQU1W+nkDmnqPFWNfPF
PSsewnmMroq0vxac/mzODh+qvo9Tp5OzUXOP+USo8ehRfhb+SZ2XorCPAl6n3YIQqOJHcj0QFLSD
Mx6rSUQ9ZceoyzSHQ3trAyFp46mujnmhhD+OQMbBt6o8XZXj8sJ1JKeLX/ZpnVF2Nzp91SXVkUkz
5WRTBscj+Z23W1iAwF89xHkWom442du6ud1G9lfI1WUdHWRGOqp45WkfablecXfycW2qy6hqpaZ/
sP8ApGLm0fG9RoJ456XWDL1NJGqnbaRi7NpPU1k1PbnyMc6l89h80D8sIwe0F7WSvP8AtPrtLrtR
pq2md1Kj501Zp36nXw+nUjSkql7qW1zxLVPlPip7m2ioAJaeNxFTMPtnwjV7R1tJW0zamnkD2PGx
/oV2V+CVOH6DS1beapH8T4b3R63C9ZTrOvSjtOD3fuhx535JouGFxI9Zo4Lz4FRyRg7raJSzMVqj
TYrxJV0jQKodpn7Qf8ryUlzXEOBBBIII3BX3fBNWq+jUJeunaL7HxHGdI9Pq+eKtCp5iytt0fSSY
dkxOI4m/1C2rZY5I2vjcHNcO0nEaCjUU44eT637J8Q8bSvSTfnpbx+Ys5ztzSh23MLzz6xpCEhQa
2mjq4uF2A8dh3h/9LWjOVKpGa6HBxDRR1mjq0JfmWz9n0MVPFLBK6OQYcCo7pXNGx2zuF9HHkmk1
ho/IWqmnqyi1acG1JfODVxHNDCfuN/JNrZGD3bfyxCUIQOpHcj0QFNSfXHqtJQ9oLj1GWaQ6G+tX
ML0W3chuvnNZ1OymbKk5BXcZwAvna/U74IV52UV5Xg6mR301gjuJWU1dbrpc7DV0dtqhBO9vf+sb
3x57srl0NehR4hpqlaN6cKsZSXukzarGbo1FD1crsfH1TFPTTSwTxPjlY8tex2xaQrvTepamy1Wd
3wP+tj/qF+16vTQ1mkqU27xnG8X090z5vQ6uek1cKvzaa+Ge60ldT11LHU0zw+N42Ph45967JJxz
6r8znSlSqThP1Rk012P0aLjOKkneL3T+GNF2DjxTRwRy7lZbA44yQsNqjTQrQ+somYqRvJGOUg8f
xL1eFap6XVwnL0S8suzPL4no/vWknFeuPmizyglwJBByCchWduuj6N/CcuicfWb/AFC+7rUY1aTh
77o+O4brp6DXUa8b2i7SS6x6mzZKyVgewhzSNiu8k537l82002nlZR+yQlCpCE4NOMkrNdU9xslJ
xIgRK2jiq4w154XDsP8AD3dFh6uGWCQxyAhwK9nh9bmg6b6YPzn7V8P8HUx1UF5Ku0/iaNVAf0CD
8DPyXC9M+QBCAcQ7keiApqP689VpKLtLj1GWaQ6G+tXML0W3dy+b1h2UjY0nIK4YcBfN6p2TPRpA
92yjOO6+d1Ej0aSI7juosjua85eo6TzbXOiYNRQGqpg1lyjbhruQmHsPXzFUwT01RJBPG6OWNxa9
jhgtPgV+s/ZDiP3nQPTzl+JQx8w6Hy/E6HhVuZemf9y+07qSpstTsS+nefpYs/zC9xpqynradk9O
8OjkGx71j9o9FyVYamK2ntP9R9J9n9Z4tCVCT81L0/MWKSTncn3LnjHcF84ke+zl5JGBlcZIGcrR
IozDan0yyta6tomATjtxjlJ7x95eUkFpIIIIJyF93wbVPUaRRk71KXlfbofCcZ0j0+rk7WhPzLv1
LK23J9G/ByYyd2/1W0bI17Q9juJpAwVXiFDlmqixLZ9z7H7JcR8bSz0s356Pp+YMXi5bnmuCT4le
fY+tEJJVNeI2yQMyN2nAK6NLJqtT+GeLx2jGtwzURksRuu6HoQRQQj7jfyTa+iPyMEIBxcu5HoUB
UUn1x6rSUXaXHqMs0h0N9auYXotu7l83rep20zY0p2CtGFfL615PRog8qK4lfNV2enBbEd5USQlc
sN2bEZ4Oea861xoqC/wuqqYNZcY2bHkJh7L/AH+BXvcE18tBr6Vf8t+Wov5WcOuoeNRlHqt13Pmm
eGamlkhmY5kjHFr2OGC0juKv9OajqLPUHm+nefpI/wCoX69q9PDWaWdN4nG6fz0Z4Gh1T0mrp1Vh
O0l8M9qpqqnq6eOenkEkbxsU7sTyGy/OZwnCcoTVpRbTR+kKUZxUou6aTTOCcAYXJB2GOvVQiH1G
iSSdgFidTaaFYH1lIzFQPrGftOn3l6vCtV911UJP0y8suzPM4tpFqdHKMfXDzR7o8rOQSCCCrW23
J9I/gfkxOO48PeF9vWpKrSlDr07nx/CtdLQa6jqFhStJe8Xk2LXsexrmHiaRkFKchfONSUrPKP2O
FSE6cZRd1JJp+66HByqu6fUDf7S30/8Auw7nmcW/6HU/oHWH9Ci/C38k0volhH4/P1S7ghCp1lB3
aehQFRSfXHqtJQ9r4rj1GWaQ6G+tXML0W3cgvm9b1O2ka6mOwVmw7BfJ62WT06JVQ3m11VwqqCGr
Y+pgA85GDyUsleDrqFahJRqQcZOKlZ+0t0ejTaeCO8qK8rigjZkdxTDjuV1QM2ee620XDfoTVUoa
y4Rt2PITD2XL5tnhmgmfFKxzJGOLXMcMEEdy/VfspxD7zoPu83+JQ27weD5niNB0q/MsT/uX2ntQ
z2ifG7oHn6Rn9QvaqWqp6yBk8EjXxvGzv6H3rn+0GjUKsdTFbT2l3PpOAa1VdM6EvXSw/wCU7JGC
m8FfPI984dxYOMJCQQPBaIhsw2ptNiqD6yjYBMN5WD7fvHvXl5BB5FfccH1Xj6RRbvKn5X26HwfG
dItPqnKPoqXlEtrdcn0ruB+XRE7jw94Wwa9j2B7SC0jYrPX0eWoqixLPc+y+yfEPH0ktNN+ej6fm
L/4AklVVzI8wNvtLmoW8aFvc9ni3/Q6j9A6wj0OL8LfyTWV9EsI/H5+uXcEIVAApTyPRAVVJ9ceq
0lD2viuPUZZpDob61cwvRLcdgvm9b1O2kaymOwWF1rrUW2F9BQSA1bhiWQfqR4D768PR6F63iEKb
V6cWpVOyO51VSoyl1wj5+ZdK2hrWVdNM9k7H8TZO8n3+OV9H6O1pSakpMHhjrY2/TQ+P32L0/tjw
3x9HDVwXno7S/QyvC9S+edOTu3vH/Jq3u3UZxX5rFWPd3GHFMO3yt4lGNHqvPNbaMZfIjV0ga2vY
3oJgO4/eXucF170OvpVn6MT/AEs5NbRVajJdVvE+dZYpIZXxSMLHsJDmnYgjxV7YL/U2io2JdA4/
SR/1C/WNVQhqtNUpt3U47P5yj5/Q6mWl1VOqsJ2kvjqe0U1TT1dPHPBJxxvGQR3dei7JJJa3c52C
/OpU5QnKElZxbT7n6NGcZxUl6WrrsExEDAZ5YoR/1HtZ+ZUE3K15x/a1C0++VdVLQ6morxoyaOOr
rtJDNS7Ooqqkm+praaTfADZW5WN1RpeSXirKaEsl5vjxs/3tXfw+dXQ6uLqwcYy8srnDxKFHXaSS
pu84+aCPMCCCQVa265PpXcLsmInceHvC+vrUlVpyj16dz5jheuloddSrrCdpr3izXtka9ocx2QeR
Cq7n9QOq8OinGtFPKZ+ncSnGfDq0ou8XTTi/hjrP8HF+Fv5JpfQrCPyKfrl3BCFRxI7keiAqaT64
9VpaHtrj1GX2NIdDe2rmF6HQHYL5rXYZ3Ucm0tlMZiC7PAP5rK+UDyeC7wSXO0xAV7G/SQDlUNH+
9a8EpLTxlWmnet79FlDVScrJYh0PlKqLmve0tLXNJDmkYLSO4qNQ3Gst1bDV0kzopo3Za4L6WVOF
SE4TV4yi4yXwzjhKUJRnHKd0fUGkdZUupKPcNjrYh9ND4/fYtW4+9fi3EtBPQa6vp5YjLyv3i8H1
tGqqtKE44aGnFMOPNckTQaJ5pslbRKs881poyO9xuq6RrWV7fgJgO4/eXz1LFJDI+ORhY9pIc07E
EL9R+zGv+86HwZO86Fo//XofN8RoeHXco+mW6Nnp6rq7SWumLyyXlSNGZH+8eC2M9Jry4wF0dP8A
2fSv5eckFPt7y71ivXfCNNU1j1NS2L2eLotLi9aOip6a0m1dJr2MvU6Qqmcbp7vRcXgHF5VPNput
AJY4yjvcGHC9Fxpq0Yu30seffUSu3D+tynmt1VAcPZy+CnUF8u9tfiKrlj+471mfIrCvp4VIOFWm
mn0ZehqKlOXNCfXddCzlFDfpmcTIKCseD9JnFPO73+w4/JZqvt9Zb6qSmqoHxSs5tP5jxCtShy01
BO7jtcpVkpVHK1lLck224GmcGPOYjz9yurk5rqdjmnIJ2K82vS5dTCaxJ79z7ThWv8fgup00950Y
eX5g2PM/wcX4W/kml6awj4qfql3BCFTvCHcj0QFTSfXHqtJQ9tcWoyzSHQ31r7l6RaYTKRnsrwKt
F160YdG938HZGXLFs9DowA0ADZXkR2C66rjtBOyXQQ3PGvKj5M23uKW82eEC5MGZ4G8qkDw++vki
Rpa5wcCCCQ5pGCCO5erpKyq0YvqtpHLUi4zcemUSKC4Vduq4auklMc0bgWuC+ntJ6uo9R0edo6uN
v00P+9i+Z+1/DfG00NXTXno7T/Q+p6fCq7UpUm87o1BOSUy4r84R7w2TzTZWsSrGysXfNPW64XJl
WGMimh2qatwzGzwAb+smX1X2ShXfFE4eiMG6v6TzOJcvgK+eZWRobLYqekY+WlEdDGATLWTEOqnj
xLjszoFT3HV/k7tsjuOV9xn73j6RfpjnI8HlS8uE8y9zL1XlUscjHx02l49xgF4asKzU0Ic7jpHR
hx3LMtIyd8EKylU5X5OZFVHTxls5J2Nhb7pRVjR6NWmUntU1UGv29zu0iu0pbbgw+ZxR1HsHeBx/
2pTa5ceXEl1j8k1Iy5r383R9JfDPNrlaK211EsM8Lmlu743HOW+20/ab7wrajuFLWUUVBdXF1KBi
nqu1JSE8gfGP3KsouLT+vdCPmi1/X2M1dLXVWyrfTVDRxAAtc3dr2nk5p7wUxHVPbF5o7sznos6k
FJf1RtpdRKhNyWJRcZr4ZqYz+hxb/Zb+SbVlhHPLeUu7BCEDqR3I9EBU0n1x6rSUXaXHqMs0h0PQ
bQwvI8F6pbMANwFyUaXLzTeXjsbXvZGzpDsFeRHYLjqvJvDdHT3YA3XhPlP8mbLyJrzaIgLgAXzw
DlUjxH300Nd06yUnaMtmRXp80ebqj5Ue1zHFrgQQSCCNwVKt9xrLbVw1dJKY5o3AtcF786cKtOdO
avGUWpL4ZxxnKEoyjlO59NaU1XSaho8jEdXGPpof9zfctO4r8a4hop6LW1tPL8kvK/eLwfWUasat
KM11Vxork4XKi7EIDYpJnvLI2DdwGT0b949yz97u9BYaCOsuMYEgB9Cox/8Avzcv1D7KaNUOH+O1
aVVtv9K2Pn+I1XKu4dII+f7/AKqvF+mzVVJZAXbQM2jYm7bbZax5jtttkrHjnK4Yjb/QfFfSJ2bZ
503c1zdKaka3Mtxo6X7rN8fwhV9dZb02GSL+2aeZrhgtJLfzCnnl72M3GL6XMa+iq6GaMztfG3iH
0jDnb3EL1S0XOWKJjp6hlbbskGYDEsWe6QdwRJ3covzLp/F8GsZ7qL2i9r+xsbraqWutzIpJA+F2
9LU/ageff7PiF4bdbdUWytnjewB8R4ZmDsOB5Ob91ys4xcEo9MP4ZS8vEs+uX8rJo/Q23W1Q0WRx
tbxUT3c2nvhJ8D3LzqRj43lrgQQSCDzBCp+RFpRcZP2e5sIf8BB+Bv5JsqCoIQDqQ9k9EBVUf156
rSULmedDCRkkrlqrmnY0jg9JtAA4V6VbeQ6LKsko7YLxNpScgruMjAXk1jrgDyCobyQea5nF3Zoe
HeU3ybNuzZrzaIQK4DM8DeU48R99fLrwWkggggnIK+k0dbxKMW3eS2Z59WHJJx+qJdtuNXbKyKrp
ZTHNGctI/Ir6X0vqul1DRlzQI6qMfTQ/7m+IXzX2s4d4unhq4LzUvLP9LPS4XqLSdF9d0aUk5XIB
c8NHMkBfn1ODlNRWW0j2m0k74sx2sno6QT1NU8CktrC+Q+3Nj+eOQXypf75W6lvM9bUO4Q7st7o4
xyC/baFBabTUqMcQgor6I+QqTdSpKTy3ct9J6TbdSa2tJZRMdgAbOmI7gvYDPT01M2GBjIIGdljB
gK5QylffaFhIMgyspWXKlnBDXBAY2oq5oZnBjzwkbtO7T1Cct90moKgVFMeH9pFza4HmOilNrAaT
ye3aSr6R76djSXUFWcBh38xL7HQqV5RNPMFtZWwxl81MCPxQHtNPRXj6nH+JO313Im7QUpdLX+mx
53b4YZqKSmBPC9hMTu/ltuqC6QMrbfHWggVcTvM1bPbLezJ1I5rCtNwhRmseJyy7SwdMIKfPG92o
3j++49Af0CD8DfyXCuc4IQhjiCdihJTU7+GVysoHHizk5yspZZeOEekabuTJHsglIEn2T7S9gtud
lx1G975RrHJs6TBAVywheXVydcBHu2KivPPksjQjOJ8V4j5SvJyLq2W8WiACtAzUwM/Xj22/fXVo
KzpV+V+mRhXgpQbWYnzI5paSCCCDuFMt1xq7bVxVVLKWSsOQf6Fe7Upwq0505q8Zpxa+GcUJyhOM
llO6PpTTGqaPUFEXtwypYPp4fD7w+6tdSODJXzOA4YmOf8hsvzLS8NnR4/Q0k+ldNP3S3R9HVrxl
op1Y9YHlvlUuT6WxWy1MeeOpJqKleL22ifVz0tGw4dUSDiPgwL9Un+Xtf99z5lYbPYX19PAxkEAD
YIGhkbfcFg7zf6iqkMULiGrMGXcwOyXEu+OAo5ZF3Et/mgI0vECOL5poE5QGs0zf4rW6ojqRI6CV
vJnMOHIhfRRv1BV2S3zVMrf0oeacPEvGCETfPFLNm/2L2UoO/ul+54faGSQS1VKc5pZ3M/05VddA
ae6zMGzKmNp/1BWrQUqNZdFJtfRl6c7Soy6uNmdgYpmbdwTCosLsjKWX3YIUlWOJDyKElJF9aVYw
nf4rKZeJbRPLSCCQQdivY9Ganjq3soqpwbUAYjd3SrhrbLm6LJvH26o9lpCAArZp25rzajVzoicu
KjPIXO+pqMO5pgnHI7okyDxPyj+TptzbNd7TCBWAF9RA39cPaYPbXzS4EEggg5X0mjr+NRTfqWzP
NqxcJtfsTrdcay21kVVSylkrDsf6FfT+m73He9PSVgj4HvLIpW93Fxb4XPX0EJ8R0WsS81PmjL5V
nY3pVpfdqtHo7NHkfldne7Vhh7oqSJqytonFLVVtRt9DS8LersBepPK7L+xyLAst0L4SA7mFT8YD
OInnkqgJtostffJpGwkNZGMuceTVGu1pqLXOI5HBwPZcEBXbmLfqCmEB20FzgACSTgBe026nlh0u
I6iMsngmgfwnm0FEm5xfTe/1RZNWlf4f7Mpngs1XdmcRw9gfjl4FU2qWcEtBN1BWzxWQx4fwBI8w
FHWC9K7EPJyhSQPJDyKAo4vrSrCI7rGfUvAsoynPOOYQ5pIcCCCFyys7p4N43WMnvegNcsuQjttw
eG1jR9FIdhMB/uXr7TgLypQcHKHRYfwdCYOKjvKxZoiO4pkhSSMuJ2IODleLeUbydi4CW72iECq7
VRA39d99n3l06Ct4Vaz9Mtmc1eHNFPrE+cHAgkHIOd19D+TmUN0lKzOS2ojf0DnEL6B7OPc5YK/N
2MJ5WGk6sMvdLSxOCwUc5eyuyMGSMH+EhXqer6Iz/wCWVocQpDiTCzphVBsNFasj07VyGeAywSEF
wHMEKBqi9U13ry6jgdHDxuLWnmS4oCVX2n0CwQvnbiV3d73rFICdbYnS19IwczK3817nXgimuAA5
zU8PxaBlaQxLsOqMtMQ7Vt1OBhsTWfIAKJqWlEtJTHJHC/8ANG7Op74NPywKojEACjrNYRm8sEiE
IfXJOx6FCSli+sPVTIjusanU0jhFgwrp5XLLJsiMXvY9r2uLXNILXA4II8F9IeTzyhxXlrLZc5Ws
r2jEcp5Tgf71hqYXipxzHPYvTlmP7Hq5KjvOy8xnQMOKacURYZJ96aJIOQVXcrseLeUTyeivE13t
MOKnd1TA39d4vYPFUnk6qGOLKDjwai3PDB9+OUuX0Wmr+LRhJ+qMkmcXI4TnFYtcl+U+2OntNtur
Yd4CYZvc13IrxAMIYZgBw54XAe9dk00qf6bftsYLdz7tkIjBIXTXkAjuKqQaq2UVmr2NbUVIik73
cQH5rY0lJomxYqZasVEzey3Iefg1qAwmo9QTXqs4+DzcDPqo/wCp96zaA3OhbaKi6elSDENM0vcV
7G6mYKag8+ccT31czfZz638gp6dy8Fdt+255jZ3mqq66rdzqKgkdM5VrqOIttVM/xm/IJe7m/ll3
6Y+9kZV31KjKFhGLEJSIB9IeR6FAUcf1h6qbEVjU6mkcInMOyVxyFyy9RqiO881FD3xvD2PLXtIL
XA4LSO8LSFupDdnc+lvJ55RWXtkdsucgbcGjEUp5Tgf716mSvErQdKrKne6vddmdcGmkxgnmmid1
UuxokJs9VCW5DGyTnmV4hrd4s2raCupIWxFkLJXBm2XFxyu/QJp1YvrA56u0qftfc9LDLZd7dI04
fQ3CHf7jjzXy5ebTU6dvFTb61hLOWfbjPJ4XuQfPRuulmvrk45JQrW6Yf0KGrpX07wCeJjhljxyc
FEUEHKEALpAey6QkpzY2xejuiYxxkq5D+sY3drWfiT+o7zVttzo3j9MuJ4WRDnHBnl8eSvG9oyeF
cvv5l0dkVWn4g4tij34CWtx3nvWm1tTCnt1DEPskZ6rOKyXniJ5y/wCqPUKMpRiIkQD+QkdjB6FA
UTPrD1UuI7rCp1NI4ROYU4TsuV5NkRnqE9aw6FWR2ySRvZJG4te0gtcDggjvC+mPJ75RGXuOO2XO
RrbgwYjk5CcD/eufX0VKmqqVnD+3UvQm1Jrpk9UccZTROF5KOobJCbKuirZwV57rG3Q103DwgTiB
piefEZ26Fd3D96zT6wMK2Iv2ZgNHanNqqX2utBEEkmAO9jl6LqKw2zUtvip6mRrZME0dYN8e4+5e
xRfK5J4u3b4eTnqx5oqSy+vyj5+udnumm53UN2oi+mcfVcOyfvRuWdr6ejiMb6Wq86x47JGHM9xV
5wcJfD3XYopKcFJZWxCZFK84YxzjjOAM7J+K318rgGUspP4SqkGmo9F3BzRNXyR0UHe+VwarP+79
mnnhkpJXtoomfT1Evqskd3cAO6ukTbBp33ClpKCOSdhiooSPR4jtJM/xK84uNzqqqqlrqo4qJhhj
RsI4+Qx4eASTtjHT6Em/0XUQ0hp3yRcZDc49nPIrQa5miqKGnfE/iHGsk8p+xeV9jzJ5+iPVRsqy
MgykQDuEh7J6ICkZ2z1KlRndYVOppDoTWFOlcrNkRnqE9axKMivKbZLJFIySN5a5pDmuBwQR3roV
mrPHVFLtSTWUfTugPKDHe4ordcpGC4tYOB/dOB/vXqBK+frUnTryh06P4O6ElKN0NlNnKqiTgrLX
+klmnikBADYxj4Lv0S/FfYwrdO55BqewPrGOqYG/pLe2wHt47x94KNp/Xk1I0U1Zh/c7j2bJ19h/
v5FevJWtLqc6tun6XueoUl2obrA+lZ5qsjIBfQ1AAmaPu55j3jIWEu+idK1MzzTyVNvk74nDiYCt
YyUo+8fbrF/8Gc4S5nKG0uvtJFJFo+voZZJ7fqKgHqcOS4My3oU0yW5gls+qGeGICM//ABCeDS3a
mSpVbWasPtoqZ7xL6O+pI389Vkho/i3Kh198tlO9uXmtqGkiONoxCw+4I3GOCd+uTIXKuqKmcz1k
gfP9mIdhg8CqiRzy8Pe7icdysxuemaajxFDuc8PNW2qA4UNN+NUl6TR4RinfUjqFGUoxBCkDyQnY
9CgKJvbPUqVGsKnU0h0JrCnCdlyvJqMPUF/etYkMivUc810RMmLFLJFI2SN5a9pBa4HBBHevp/QG
v477Eygr3htxY3Z3ITgf71ya6kpU1NZhnsa0Zb8rPTSU2TsvJWTrOCVBrWNeGszvw8l2aNpVX2MK
iul3PObhAY5Xkcw8/kvONXUFsfSGsIMVT6oHD+sP3gvcjZpnK1sefQV88ADDh7R2Q77P4TzC11Jr
m7QxtZ6fJIwD6uqY2ob0yfWVVs82+RdW3Jh1c+oYTJbbPx47XC9n8lVu1DW5zE+gpx9wErTmn1ae
4fLs0rFTWXBtRvUXCeoz9hjeBv8ANNUtHcashtHSFjHbZA5/6iqbsjJW1FNNSTywSxlkjHEOBG4S
RRFxGyiewW9j17TtNwwRfhU/VcJFupv3iybujZ4PPH/VfEKOtDA5yjKAfSHsnogKMdtSI1hUyzSH
QnMTp5LmZqRnlRHrSBDIj1HcuiJkzjI32XUUssMrJY3lj2EFrmnBBHgr2TTTIu01Y+ndAa+ivsLK
CvkDbgxuzjynA/3L0wrwKlPw6s4Pph+66HdGV0mNkqJWxl7WEHBA2KtS/P2X9yrzEx1fEx/FxYY/
PwK8d1HG+omc454WAhgXq0q14JGM4WMBNTkcZyNkT0ssUbPOY37GDldVNXMGQw0l4bnvXs1N5Ore
5kL31JPExrj6p7xnxV1a7QtdXNHRaNslMW/RF2PcAtHDR00AxDCxgx3Df5qXbpgk8x1/YsmK5xM8
I5/9rliqOiyW9Asq7xL3Qh7ezPZdP297oowG8mjJ8EutoWxWuFo/aLCF3uaTfQ8il7B6qKVujERI
hDH0hOx6FCSjB9c9SpMfNYVPUzSHQmsTpXMzVEd6iPI3WkCrIjyFHcuiJmNFJlXRUdhmkglZLE9z
JGODmuBwQQvpzQevYr9C2hrXtZcGDoJx4/iXFr6SlCNRJ3jnsb0pfleMo9JJ2KHx8TG79y46FpOS
Xt/k0ls0Zq40YeHYHcV5he7c9uQ5mF0wi0ysjzO4UZY5wwqeYksY1xOGA4HVehRMJIgxkiRuF9UQ
DEEA/wClGPk1Xj6gvT9SQAQCeE4VXW6hslvafSrhC13sNdxv+TVdk9DB3LWJurZKG30DnCUFjnPH
E5w9zQrmxaNnwyStPmh+zG7/AI+C56l5bILytvqeo08EUELYomBrQBgLEa8/y6P96mEiMnjcp9Q9
VEV0UDKRCEPpDy+BQkoh2z1KkxrCp6maQ6E5idK5maojPUR/IrSBRkN6YcuiJQ4XCuirBOwzzU8r
JYXuZIxwc1zTgtISyaaYTaex9N6F13DfoGUdY8MuDG9BOB3heoAgxtXl0YOnXqQfRbduh0yacYsq
qkAkrO1sDHghzQ5vgV00nuRIxlx01QVRPCXROPhuB81k6nQlWWkQVUTgfEFq9CHJcwfMrlPL5Pb1
xjgkp9vvYV+LL5RCQwXkAAYH0qs4Ru97ERckjk6H1PV/42/jH43vVvbvJpZ4HB1VUz1J8B9G1Uas
wm3k39BbqCgj4KOkihGNy0bnqVZMVGWJo5BYLXn+Wx/vVVkHjUvYPVRVZFQQgHkE7FAUQ7Z6lSY+
awqepmkcInMTjlz9TVEd6iPV4FGRHKOV0RKDZXKssFWISgKxA/BPNBKyWGRzJGODmuacEEeC+wdF
XiqvOmKCtqQPPO42vI7yw4ysasI88Z9bWv8ABpBv+pbTZyVS1IG6wo5NZFRIDkpBs4D3ld8cGW4o
HrJxhy9aEbjn20+1QwPtTrOY6LKQJo5LBa7/AMti/eqrIPGZew7qoysioiRAPoPZPRAUY7Z6lSY+
awqepmkcImsTpXOzVEd6hv71eBRkVyjldESg2VwrlWCQIiDpfWfk0I/uVbOsv/mq1MIvDJqpTklU
9QMkrlp5NpFTKCCdwmXE4yvQhgzeBWnfmnmYDldlRQTspDCqsEgJ1ncs5AmjksHrv/LYv3qqweMy
9h3VRlZGbEK5QklLk9k9EBRD6wqTGsKmTSOETWck6SudmqGHlQ3960iUZFco5W8Sg2VyeSuirEQp
IBfWfk0z/cq2dZf/ADWdTCLwyauXmVUVPIrlpZNplPIMOOQmXH1T1XoRwZsBsSnGncdFoyp2CVJZ
yCrIkkjknI1nIgnDkFhNd/5bH+9VQeMy9g9VEVkUBCEMeQeyeiElEO2epUmNYVMmkcIms5Jw8lzs
1Qw/KiPWkSjIj0wVvEoNFIroqwSKQgX1n5NttF2zrJ/5rOrhFoZNVIckqoqeS5aRtIqZB6xUd+Az
qvQiZsQZzzTrQchXKocGVKad1VkkhvJOM5hUkCb3fBYTXf8Alsf70KrIPGJDlh6qKpRQTKFJBIKQ
nYoSUn20+xYzyzSOETmck4VzM1Qw9RHrSJRkRwTBW8TNjRSK6IYJFIQL6z8m5/8Awq1/93/zWdTC
LQyamQ81VTkbrnpZNpFTIcuOyjuALOXeu6ODIVoAK7AOVYhDjeRUhqhkklnJOs5hZyIRM7vgsHrv
/Lo/3qhg8Xf9X8VGVigJEIRJSHGD0KElJ9tPsWM8s0jhE1idK5maojvUR/etIlGRXpgreJQaKRXR
ViFCBAvrLyb7aLtf/d/81SpgtHJp5TgFVFQ7msaSNZFY/PEmjswdV2rBmcg7jnsCnBzzupIQ43kV
KYoZJIan2cws5EEru+Cweu/8tj/eqGDxd/YKiqxQEIQh9ITsehQkpB21JYsZ5ZpHCJrE53LmZoMP
UR/etIlWRXpgreJmxopFchiLlEQdL6v8nbgNF2rpL/5lVmrovAu56lueY5KunlaAXOIa3xJx+apS
ReRnqu+2mnJ85cIAfAO4j/JUk2tdOMaQat7z92NxXRzIqQj5QNPt+zVO/wBASt8oun/2dWP9DU5i
HYmxeUHTJO807OsSuqbVumpiAy6RD8QcxQ5E7GgpqykqADBUwy/geCpzSQRsVVje5MByAsHrv/LY
/wB6o6IqeLy9l3VRlYowSISPoPL4FAUg7aksWM8s0jhExidXOaDD+SiPV4lWRXpgreJQaKQkq5Vn
JSKSBV73pvU8Ft0rbafgy8Med3YG7iqVG0tsl4FVcNa1TgRHII/wDCxFbe5qhxMkr3n3nKzUZPJZ
tFFLVl2d1EdKTlapGbGiUmVKIFBwpLJOSEosIKsxkEEgrXW7VdxpuEMrJMDuJ4gs5RaLpnqNq1U+
ohYZmNdkcxsqzWdwp5rdEGuwfOciibsTKKTPKJuTvxKJlamLESISSlyeRQFKO38VIYsZ5ZpHCJjE
8VzmhHf3qI/vV4lWRXpkreJmxopFchiLlEQKFe1dU+KCijaTj0Vp+ZKNXJRUOme4802XEoQc5QpA
JUADGUuVKAocV0JHAhVsD0jT9Q/0SPom9U1Z8xRt++VdR8j7GkngpJD6h6qMqozOUICUuTyKApR2
/ipDFjPLNI4RMYnVzl0MP71EerxIZFemSt4mbGikVyGclIpIFCsa8gij5/4ZiArUIASqUAQAiAqE
AJRhAejWD/CR48FA1Xsyi/G5afkl2Lz6d0QpOweqjLFYRQVIpBISE7FAUw7ZUhixnlmkcImsTh5L
nZdDD1FerxIZEemCt4mbGykVyGIkKIgUKfcD/hP/AGrFYFchQAXSlAUAk4CXhPNSgAGx23XODlLA
MYKcwSAcd6gI9GsTOGnYMfYGVXas2ZRePG5aL0S7F5/l7lfJ2T1UdZLCKAhASUh5HogKYdv4lPs5
rGeWaRwiaxOdy52XQw9RXq8SGRXply3iZsaKRXIZyUikg6yrG5EH0PAx+ixoCsQgBdE7KUBWHnsP
infVPI4xyHipQGzlpII70oe0A7b52KkHOd+SAqko9MsYIp2Bw3xyVZqzdlF+Ny0Xol2LT/L3K6Ts
nqo6xWEUBCkEnK5cdj0QFMO2epUhnNYzyzSOETWJzuXOy6GHqK8q8SGRHpkreJmxspFchnJXQGc7
hSQIrG4lpNLwkkCmjGSMICsQgBKVKAo2KFKwBTjZIpB0QMZz8FygPTrIT6NH+EKr1b2KL8blZemX
6TSf5Sul7J6qOsVhGYIUgeJTTnbHogKtv1iks5rGeWaRwiaxOdy52XQw9RH96vEhkZ6YK3iZsbKR
XIZyUikgUK0ucbWPpQDzpYj8wgKpCAF0pQBAIVgBRlVAoJXThk7Y+Clknp1lGII9x2QqfV3Ki/E9
XW8JL4Jq5j3Kwu4ogfHBTKyWyRUEIB0kLggEHogKtv1ikMWM8s0jhE1icKwLoZcoj+9WiQyM8Jgr
eJmxspFchiLlEQKFNrc5pv3DFYEFCgAulKAhSqUAQoALoEYOSUCPUrOCII9gPVCpdX9mh6vWkfTL
sWqYXcqQMQM6BNrIqCEApByuyDg9EBUt+sUhixnlmkcImsOwThWBdDLlEerRIZGcmCt4mbGyuVdE
MFypIFCm1oANP+4YVIIaQqegEXXgoQEKVSgGEKACEYPVbQCYmDH2VSav5UHV60j6H2L1MfVFSPqG
9Am91kUESICWQkPIoCm+2n2LGeWaRwiaxOFYF0MPUV6tEhkV6ZK3iZsbK5V0QwXKkg6Cn3DnS/8A
to0HQgDmF29vCVdelgURPIyRgeJTrYWkDLyegRRJQNZHxAFr/wAl1KyHfAdsPaUE7HBZFw5Dim/N
k8nAoRY4LXDmCEKAerWjIhj5HZUWr+dD1etI+h9i1TEf1IqR9Q3oE2sigLlCCYSuTyKElN9tPsWM
8s0jhExicKwLoYeoz1aJDIr0yVujNjZXKuiGIUikg6CsbiwNfTAPDh6NEc/BAQmR5w4nDc81eUds
q6qdrKaBxBHbI8ffyC0hglRbH7rY5bWyB87myedJ3BPqkdyo5pHtPCHHCu9kuwIhJPehZEGy0VZ6
a63Qw1LOKERuc8La3DybUjgTRVb4z3Nk9ZqRau08I0aSjE8+uunL1ag41MBMXdKz1o1ROYMswDy+
CNEZPT7WCIhkHOBsqHWHKg/1q8doy7EVMLuVAP0DOgTSyKghCCUgnY9EJKb7afYsZ5ZpHCJjE4Vg
XQw9Rnq8SGRXpkrZGbGyuVdEMQpFJAoVjWtPHT+rzgj4Rz7lJKNNatPxjgmrwSSAWQcjjxf4dF6U
yJgjiazDWtAw1o2W9KG3M+pEnd2XuVWpaD0uz1YG748Ss/08141K8Paw43xgqs9rdg0xnuRkrIHr
/kvpRi5VHfhkYXrOAkY5+Waya8vY5dE1wIwMHmOYXnd+0HS1XFNbuGCfmYuUT+nslXvuU3yiFQQS
xgxSxujkjwHxu7TT/wALKawGBQj3uUraMl8Cpul3KYH6FvQLhZFRMoyhBKyuCTgoSVI7akMWM8s0
jhExicKwZdDD1GerxIZFemStkZsbK5V0QwXKIgUL0ygtETKGG5v4TJ6K0Qt7mkDHEff4LWEeacUT
hS97bEq3RvfGMkklxJPetLLWUluohLWTBgI9Ufad0C6pZ2wZwXLFN5MPcdW3GsyyhiFPCQQXndxC
oKbTN2qWtdTUFTMDycG8LfmVzVJR6Oy6GkYvLySHaUv0ALpKGNo7y6Rm381WT2e5NJ/RwQPZIKos
XLcreCAH1dK/LXSROzzBLStbateagoXNa+cVMfsTb/J3MJcqsnrVh1harwWxAmCqP6l55/gPepWo
L7S2akdUTYL+UUXe9ytFXfws9hJ2RiKSoqaqR9VUSF00u5PcB3Ae4LM6zcHegnYHL8hWupKUl1WC
Zq0Yr2aKIfUt6BcLEqIhCCWuSRgoSVA7afZzWM8s0jhExidWDLoYeoz1eJDIrkyVsjNjZXKuiGC5
REChapl4noZIW7vhkpYhJGTz25jwK0i+WSYNey8W+it8EsDxPNN9TF4Ec+PwwpNNpiqu73VNwf1c
44Den9AFrKftmW5ZRTfwkbm16WttNEJIqZnqj/EVADj1Y3kE1cL7pG3uIrLo6okH2GuLv5M2CxjT
ck2klHq2JVVHZRuzC3jWGmqqmqIKakkbx7NdwAKshvtH2ae4SU5aNmyDLT8wQtb09le6KxlUd+ha
trKSpYBcKGCaM/r4fUP8shVVw0XHM109nlMveYHbPaquKV2W2bME5s1PKY5Wua5ruhaQptxrq6tl
gfV1D5zGxrWknOGhU3Sa6sex6LbM+ZG+2FnNY86E/iV16ZdianTuUw+pb0CbWRmxChAiSkOcHohJ
Ujt/Ep9nNYzyy8cImMTh5LBmiGXqM9XiQyK5MlbIzY2VyrohiFIpIFCn1xJfB7qeP8lK6g3mhdPs
me+5VQxDEcN95Ph716heLxQWWljqq8DiwfRqNqU1zS/z8IvN8kV7+3yzxq7anv8AqOV4fMYqcc42
nhjaPvKrpYqISCOmpJa6f3A8HyG5Sc3N2WEVhGMItt3kybLpW/VMr5jQxQBxyGcTWAJ2noL5bBKD
QU1Qx+7muDZOSiyYUh+luFndMWSQTWyo9uLePo9ju5bizVDKCUMqAw+dP0FRH9W/3DPI+4q8SVud
6ksUV7ppJ2QCOtYziAH65g8PvBeKP4onFhOR3H3KZLa5GGep2zHmIyCOEtCzmsOdD1crR3hLsTV6
dylG8LegTaxKMFygRLSE7HohJUDtqSzmsZ5ZeOES2Jw8lgzQZeor1eJDIzkyVsjNjZXKuiGC5REC
haGntstxudBSxes6WKIfMI3ZS7F4K7S6XPb3VFFZ7Y+cY9Fo28EI/aP73dSeS8KuNyqr1cn1NXMA
XH4MaO4LV+WnZZez+hWT5ppvv+5f2OxPu445C6C3Ru7u1KQvSIG0lDTiGkhZBEB3cz1PMrNBu7KW
suFOCcyD5rL1tRG8Esf8ihBk6itlc8xy4kZ4O5joVNt94koWSREGalkG8TuYPcR4FSrdRv0PQbBf
Km8UscJcPS6Ygxv7x4Hp3FU2sbVH6lwp4A1tU5wkA5Rzt7Q/1LRS5rr4Jaw/dk3TsokoIwT9lUur
mPPoWGnm5INKnLsy1Tmly2V9yjB+hb0CbysjNhlIhJKSHkeiAqR2j1Kks5rGeWXjhEticKwZoMvU
V/etIkMjFMlbRM2NlcqyIYhSKSDpeu6PoSBV3E846CGOL8co4UfRfKLx/N2I3lGq/MCgtUbvVjYJ
Hj38gvPLbRPr66CmyQHH1j7LeZKvO+1/b++5TrL9R6ya2CKNkUIDIYmhrG+4LG3W/wA8zzFASG+K
oDMvL3kl8rs+5NEOHZlPQoCLISXHPNcAkIDT6WklgrnVEU3A6NnZ9oHZe4XS2RXDT0jIuc1OJmHw
kYOIFTGbUoro2WduRvqeb2Ij0ZjmDAO+PzTuqZc0NEz2ZD/PCma8nY3g932MV+qCaVTlYJEJJaQ8
j0QFSO2pDOaxnll44RLYnSsGaDL1FetIlWRnJkrZFGNlcqyIYLlEQdL6B0jC0WGg/wCrUxZ/0MR5
XZl4YfdHletZzUapuR8JQwf6QAmrZO2nkuNR3tY2Jnx//i0qetlI+lC1NxLoiAVTcYa3J7xkqgHq
K33G5ueKaMlreZ5AKHVU1TSTGKZpa4IBlx4mgkbj8kygLeyyllfFg9oOb/Je0Wu417qSljbKBDFM
Gub3lhP/ANq0Wk0y63XwmZa1RGGWvp/2FZKz4ZyoepieCkHUq8/TVJg7cn6f8GW/VDoE0sjMEICU
uSdj0QFUO2pDOaxnll44RLYnSsGaDL1Ff3rSJVkZyZK2iUZwcYXBVkQC5UkHQX0DoqVjtNW3xZW4
PxaoeUXhh/Q8m1hH5rVV0H/X4vmAVUPdiGsZ4ytd+a0qeuRRelEAPdjmU7KSWN6BUBvtD6htNuZN
TXEYje4uD8ZCzGoK2mrK79FLnRtBDXHm5APXO2eiW2mfIMSENHz3WZQFjaml1fD7iT8gvYLIAaJw
8ZowPi8BWteJeBWUjmuul+c3kbhJhUupX5lpR4MJ/mrzxVEf+12/wzNg5hb0CbWRQEICSkI2PRAV
Q7akM5rGeWXRLYnCsGaDL1GetIlWRnJgraJRnBSAKyIEK5UkChey+TyoM1luVMO3BIydg6KOse5a
PUpvKXQcNzpbiz6urhGT99qwErgQ1+RiRmD1CvLp8pFcXIKdD/V4T47KoNLRWCK4Na6KpDHHmMcQ
/ktZR6dsdlAq7hWse5u7WnYZ9zeZQGJ1BejdazjY0shZkRt7+p95WfQE+3vmbVxeaOHE4+B5r2ah
4KSKmMh4REx9VIPBsQPD83K0d3y/+77FsRcvr+25mNOuL6d8jjl0sjpHfFUepql4uZjB2ZC0OWra
cJt9X/kO8VBLFrf0Ktn1DOgXCwKgkQEtITseiAqh21IZzWM8suiWxOdywZoMvUZ60iVZGcp1mtwu
dzpqMvczzriOIDONsqak3To1JpXcYN27IiKUpxi8Nok3u3Wihf5qkuTqqUOw7DMMHR2dyt/YNEW8
UUM1xjdJNI0O83kgMB5BePxHieq0+gpVPD8KtVe0b3sjt09ClUqzavKEV192VWotKWttNUVNqmaX
wbzQB4fho5kdF5kQu3hWrr6nTXrx5asXaSta/VM59VSjTqeT0vAi1+iryLTfIZHn6KQFknQr0mc6
yeu320C52yrtWQZGETUT/Ecwvnx9NKx8jJGljo3EODtsEdyvJ3SJaGHBw5gg4XCqVO2ve3suI6FD
nOccucSfegOFKo6OesqI4IWFz3nACA9Hs2n6GG4mQScUVOzErndlzxuce5d6kuD4LbwEYmuHC7B+
zTs7I6FbQXJKT/8AdkJWcY72f/LGdNlgouMjhZgkrE3CZ08s1U4jM0hLR90clV2VNe7kWl6o9hxn
+HZ+EJFmVEOUICUkJ2KAqx21IZzWM8suiUxXtktJu1WacTCIhhfxYzyWOZIvhGxZ5M55R/mrB/2i
nf8A0lqncrxH8Yit1TkivPHrc8z1HZZLHdZ7e+Zsrow08YGB6wymrNx8df5okS+gy8GPhxY+CrXU
VSmpY6k0788bHembd/aF5pIcZY14fJ+Fu69c1ddXW6zTuY7Esx81H7s8yvneLr7xxfQaforOX1f/
AOHdpl4ekq1Ou9jxqwmQXan4D7XH+DhPFn4KlOMnHivpVbxp2zyxv2uzgd/Dj+pnC7aS0gjmDkLQ
zPbdL33+06SnpnyBlTH/AIZ59oc4j15tTuo9KM1Ax9bRARXBgxNA7bjwrJ3Rps0eQyNkge6juED2
PjJG4w9n/ITT7bUFnHDiaP2mb/McwosUZAcx7ThzSOoXCggv6WwVsrfOz8NND3ySnh+QWstkUYHo
1pY8ce0tY5vrv90YWsEo2m/p3ItzvlWOrNUf7Pt9ueZnYooPrCOcz/2LD3n2ivJb1dKi51s1VPgO
kOzByYwdlo9wCltqnfrL+2X/AFDu5b9C/dMKazxU4dh0wAz4N5uKx9TJxO4e5uyo35YR+P7ln6pf
RFkw/QR/hC5VCAQgJKO49EBVjtqQzmsZ5ZdEpiu7NdZbTV+kxxtkJaWOadtisl6kXymesWzWNiuL
PMTzvpJHgDD3cPyeE5c9NalfGZrNqepcOYileCD0eF2KTsnHHa5jaF7TVzwm+NurbnUsurpDWNIE
pecnltuoFFWz0VZDUwkCSN2Rnl0KynHnU4y6ppl0+Rpx6M9PtesNL08TnCiNJK8ZkayPIJ9xCyGo
L+2/XCnZn0eljJawuBOM83uAXgaHhOqo6+eor1PE5U+R33d9jtr6uFSjGnGNk8ss436Wt9puDKS4
mWtlgdGJHRuHPmGjuyvPF6ugWrf3iephyynU2V7pRSsjmrun5FDCRwul3GBOoKw0s4cWlzCRxtzh
ewWXVtPUOihuUpjmb9RWs58P3vEKUWWDWXW32y6UzBdKJk8ePo66n3wP9O4WAn8nJLzLZb1HIO5r
jwuHxap3W8SXZlJc9O6wpKeRtVG18RGC7LXKhpdOXOd3AIiOL4o3sr7JBQV/Wbak0dVuDZ7gZ5CO
QIL3dGtCuK6ttdkgLKlwYSNqSJwM8n7xw2jHiArRi5NtvddeiREpKMVGO9+nVs8svN7rLrM103Cy
Jm0MDNmRt8AFDo6GSqcPZ4t3KJyu9sWtFfBEIdPq2P3CqjdMfNdlo4We4KmJVW7hl0z6iPoEiggE
iAkoOcFAVY7aks5rGeWXRKYrW3W2ruVR6PTtBdjJycABY7t2WS6wej27QNsgjM91qzIG7loPBGOp
VpU62s1mphSWe2zThmzQxjmRD4nmumEFBXnKxSTnNqMVc8QvtzqbrdKqtqYwyWUjLACA3AwOapTs
VN7yK2skvY4JVvcLLV0FHQ1UpZ5uqYXR8Jyfis51oU6lGEr3qSaj3SuXjByjJ9EUxJXOVsZiIQAp
1NU+b9STLmZ7jgtPi33oEaWhvd3tg89RVjwwntR7t6SRlXzNcmYA11ooqo+3ETBIrqafqv3WSXGS
d4tJvo8M7l1VaHtwbbdm/dFW4tVzoytoLrdjS/2bK1jWOk4pqh7+XdjYFX5o2/3qkitp3f4dJfS5
7UAAAAAAvAvKZZ4qO7UtRRx8L6tj+Nrfab3rElJ32MFFaHNaZKlwY0cx/wAlcVVwBi8xAA2Pl4Fy
b7PoayXLG3V5KgkkkkpFLMi4YfoI+gSKACEBJQTseiAqx21IYsZ5ZdEti0enbrBaq59RKx7wYizD
OayVlNXwXd7O2T0GPyjWdnOkqj8Gq0ofKNQVcwgpbVcJpDyYxrSuvmovdz/8TFKs/wAn/keRa9mk
m1RXySU74XFsWY3kEj1B7KxRUP1Mnfrk4PIrealqKaXTunGxzRueyEhzQ4Et2HMLh1MJy1WhajdR
qybfeDRtTaVOsnlpWMCUi7zARKgEQgH4pZIncTHFpVg2spJgBU02Dj6yM4PxB2KhovGSWVdEQsaC
fNVII9+WlW9ju9ZZbnDXxFjyzZzS7ttPMK19rFD3OPym6XNOJHyzNfjeLgJK8n1DrWe7XCSZsIbE
BwwtPNo8T4kqCYtp3Ri56madxMjyfyUZHcCoQguGD6BnQLlACEBKSHkeiArB2z1Uhixnll0S2Kwo
qCqr5xBTRl7yPkPErBl1g9Is/k8gyJLnUl4Az5qM8Lfi5b2prbPpmySVcNK30dgaGthA9cu5brpp
03s5Z9ikp9EfN+oLtJebvVV74hGZSPUG+A0YCoThXbvJsqlZIbKegibNKyMysjDj23nDR1S9lJ2v
sNm0mWFVZqqCujpGujmfIxr4zG7LXNcM7FU6rCpGpGLSavFOzyrlpQab72ESq5QRCAVIEAJVLAiV
QAQgBIUBcM+oZ0CRACEBKSHkeiArB2z1Uhixnll1glsWo0xc6W23F81SS1j4izI3wc96yjtNF3ez
seo3G0wakoAKa6yMbw7ebfmN34wFF1bQT02gmUgbxvpxTtdwAkeqdyuu8ue7xbBkrPvc+fnLS6Nj
bJqCmjfE17HskD2uGRjhXDrG46LUtOzVKTT+hvQX49P9SNlfdDU1Q0zW0CGYfqvsP6eBS2GttE1I
+G6U1FT1lO7gkErGMLh3FfNLW6nXcOtCc/vFCSuoZnB7HpKEaFdyxCf9GaSQ2T1eA0fnjCfM4LeM
tDTjhXzv3lej9nlqOXUeNz38lua+N8HLr5Rk6dulxEL6FnnghSAQgBChgEIgCFJKBBQFuz6hnQJE
IBGUBJSHvQFaO2eqkMWM8susEtieAWDLrBaYvdhmp5mukpZJWB7MHmPvBeqaa1rcaqgnqK62vfBA
4NlqYN8d+TGumnJ+mRnKN3dfseRavnoKjUVfNQujdTPLCwx7N7IVBTVdTSTCanmfFIAQHNODupnC
M+aEknF7NPFgm0k1kt4tW6jiO1xkd7ngPCsJ7jS6kayOrZHT3AACKcDDJvuSeB8CvNloKGnqQ1Ol
hyTh6oRxOPVHRGtOcHTm7xlh+zIN0lnt9XaX8HDPFRMBDxyIyMELLrt03K6UZp3us/F2Z1U1NxeU
xELcyBKgEQgFQQgEQgBCAVIRsgLVn1DOgSKSAQgJKD3oCtHbPVSGLGeWXWCWxbDR1FHU3XjkaC2B
nGAfa5BYreaXyXxETWN5Nwr/ADDQPNUrnNa7vce9X/k2vxhqzZ5Wt83OXPiPeHgbg9Qt7/iFEnym
L1paorZqOugiAbE4iWMDk0Sb4WWgglqJ44YYy+R5Aa0d5UzcYczk7JK7fwgrysllm/h8nVQYQZq+
NkuOyG8QBWNq7U633F1JXl0bW83sbxZaeRbyzleVoOMQ1lWrThTcWk3C79SOuvpFRjGV7ptJm2Gk
2Xaihr3XiZ7RT/R8ce4azk3mvMCFrw7WfeJamn4KpqjPksncz1FKNPkabfMr7iIXpnMCAEAIQAlx
gIBEIAQgBIRsgLNh+hZ0CFJAIQElB70BWjtnqpDFjPLLxwiYxbTRdSyG6ujeQPOxkN/EN1nH1ou8
MY1RYqukr5p2QvfTzPL2vaM8JPMFXfk+07XPu8VyngfFBCHFhdtxvIwrP/ca6tj8t+ljNa+rYq3U
9a6IgtiDIc+9g3Vbp2pbQz1td5sPkpqVzo2n2i4Nyq6uHiUq1O9uZct+7sKD5ZRl1W6NXSXnWtXR
mtgpqV0IDiAW7uxzwFR3Gv8A7y258joWsr6NpcQzlJD34Hi1eLp9FoKFfxtLN81Coo1E3fZ7M65y
ruPLUafPG6t7m607n+6dN7qeX+q8MA2C04NtqeKL/wCR/lkav00P0BhGF7pxBhCAMIwlwGEYQBhC
AMIIQBhcvGylZILFg+gZ0CRWKghASMpO49EBXt7R6qQxYzyy8cImMUuIvD2GMnjDgW45g92FgzRH
pFs11UwkU1bQvlmBDMx7OJ97StFernq99ue6hs5gaWHieZGvmaPc0LrhVi+l5JY6GTpy6tJHgbwc
nmnqGqfR1Imaxrxwua9jhs9jtiCsJR54zjLrs2aJuLTNvSaxoqC1MpaWknL2BwZ5xw4W59454WCp
Z6mmqY54HESscXNIHz+C4NHoPAerlVmpOvK8rKysa1K0pypcqty+nuei0GrrRHbnUstLLTOEbxwt
bxMy/wAPALy4MwFHDtHV01TVupJSVSalGS6jUVVU5FazirNCcKOFepc5w4UYS4DhRwpcC8KThS4D
hRwpcBwpeFLgOFNyDZSmQTW/Us6BcrQqG6EBJQcYPRAV7e0pDOaxnll0TWBbPR9Eye5mV4yIW8QH
3jsFit5pfJd7RbNVZjBcdZ1c4haBTQkNPi4Hh4irmi1XNLqya0vjYIOJzInfa42DO66U4pzf81ik
lJ2X8p5hre3x0Wpa5sbQGScMoH4xkqrsFsp7lchSTPewPjeWub4hcmrquhSrVEruEW7dka0kpyin
hsk3nS1fbAZcCaD9ozu/EForRpe3VUEFfQ3OqjJ5HDQ5ju8LydRxZ/coailTjKEny1IyymdVPTxV
Vxlf3i0XNXpiCWs9PkqHySR05HC5ow8tYRkrxsM2C04PrZamE7wUVTUYpIpqacYOKWXdsTgRwL2L
nIHAjgS4DgRwJcBwI4EuA4EcCXB1wJCxLgOD3JiZuGhTF7hkhp+ib0CRbmYmUZQEhIe9AQGnDz1U
lnNZTLxJ0YW90VI1tZUxnm5jSPgVjD/cj3Lv0s2unLRNb7hdamUt4JX5jOfs54is/pSglr9U1VzD
SYIppXh/cXP2AC0lFqKXV1CE03JrCiUOuahk+passIIiYyL4tCobNXi2V7Kow+d4WOHDnHaXPrIe
NCtTvbmi437qxek+Xll7bmzbrmmcC2W3PDSCDhwdt0KrZ5JaannrdPVbmQOPFUU2AXRH2sH7K8Gj
w16OXJVfi0KrSmrWs+jOmVZ1Y4tPowqdQ3GGpovPVLjBJRNfIwNG5ewrCCM4G3cvX0enpUIt04cq
klfuY1G27Po2HAk4F13MrBwI4EuLBwJeBLiwcCOBLiwcCTgS4sLwI4EuLBwKLUtwwdVaL3RDwKBi
JvQLldJkCEBJwkOEBBewteU9EVnMvEsIu5WtJUTU00c0Ly17TsVyNtSTWUardM0lXqu61NI6n9SM
OGHuYN3Bc2bU1faKSpp4GtcJN2cX6t3eQrPUSclJw2WEV8Lytc+7ZmZON73PeSXOJLj4kpksWfM2
23ll7YELE9TTz0s7J4Hlj29/u8D4go+WUXGWHsyUndWJFzqY6yeOSOnELWwtZwA5G39FXcBUUk4U
4wcrtLId5NsTgRwK9yLBwI4EuLBwI4PclxYXgScHuS4sHAjgS4sLwI4EuLCFnuVbUZfK1jR3rSnv
IpLZD1QwRhrFEXWYglQEhCA5cwOCjFkkZzjIUNXQWxJiqmDmCFOZWwAcyuSdORupIeFdT+J+SX06
m8T8lm6Uy3PEQ1tN4n5Lk1tMe8/JFSmOeInplN4n5I9MpvE/JSqcyOaIhrKfxPyR6XT+J+SeHMc0
RPTKfxPyR6XT+0fknhzHNEPTKfxPyR6ZT+J+SeHMc0Q9Lp/Eo9Lp/E/JPDmOaIel0/ifkj0yn8T8
k8OY5oh6XT+JR6XT+JTw5jmiHplP4n5INZB4lPDmOaJHfUyTERwsJcTt3lWsdtFuh8/VkCVw9Vng
umlC3cymzPyyGR5cfFNrYoCEBKQgBOMeAdwgJTBbnnMsakiOyAdg/NyiyG4cFk9k/NyOCy+yfm5R
yxJvIThsvs/zckLbN7J+bk5Yi8hOGzewfm5Jw2f2D83JyxIvIC20eyfm5IRaPZPzKcqF5HPDafA/
MpCLT4H5lOWIvIMWrwPzKMWrwPzKcsSbsMWnwPzKMWrwPzKcsReQYtPgfmUmLV4H5lOVC8gxa/A/
zSYtfgfmU5Yi8gxa/A/MpW/2UDuwn4lOWIuyfHe6ajYRR0zGuI7feqKqq56qQvleSSpRBFQpAYQg
JOUiAEIAQhDEKRCQQgBCEI5QhIiEIQmEYQkMIQAhACEAJEAiEAIQAjKAkIQAhAIkQAhACEALnKEI
EiBghCQQgEyjKAVJlACRAKkJQCIQAhAGEYQD6EAIQBhIgBCAEIQzkpEJBCEMEISCRACEAJEAJEAI
QAhACRAKlQDyEAIQBlIhCEQhIJMoQwSISKVygBCAEIASIASIAQhDBIhIIQAlQAlQDyEAIQhiIQkE
IAXKEIEiBAhCQSIAQgESIARugEQgBCAEIAQgBKgH0IAQgAhIgBCEM5QhIJEIQiEJBCAEIAQhDBco
SCRACEAIQAhAC6QDyMoBEoKEICUiEghCEc5SISCEIQiEJBCARKgBCEIFyhIZQgDKMoAyjKAEIAQg
HkIAQhCOUISCRCGCEJBIhCBCEghACEAIQhHKEJES9yARCAEIASoAQgP/2Q==
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
