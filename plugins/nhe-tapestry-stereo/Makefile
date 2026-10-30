#!/usr/bin/make -f
# DSP-only LV2 build. NAME = the bundle name; the binary is <NAME>_dsp.so.
# The source is the mono plugin's (included by TapestryStereoPlugin.cpp).
NAME = nhe-tapestry-stereo
FILES_DSP = TapestryStereoPlugin.cpp
include ../../dpf/Makefile.plugins.mk
TARGETS = lv2_dsp
all: $(TARGETS)
