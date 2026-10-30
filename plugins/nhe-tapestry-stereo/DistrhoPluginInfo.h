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
