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
    uint32_t    getVersion()     const override { return d_version(1, 0, 7); }   // = lv2:minorVersion 2, microVersion 7
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
