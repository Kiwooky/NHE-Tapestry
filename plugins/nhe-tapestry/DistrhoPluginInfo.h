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
