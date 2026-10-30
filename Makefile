#!/usr/bin/make -f
# Top-level build, used by the package files in mod-plugin-builder/ (and by you).
#
#   make                                  build bin/nhe-tapestry.lv2 (DSP + TTL + face)
#   make NAME=nhe-tapestry-stereo         Tapestry Stereo (same source, same face)
#   make install DESTDIR=...              install into $(DESTDIR)$(PREFIX)/lib/lv2
#   make clean
#
# Cross builds take CC/CXX/CXXFLAGS from the environment, which is what
# mod-plugin-builder and builder.mod.audio pass in.

PREFIX  ?= /usr/local
NAME    ?= nhe-tapestry
BUNDLE  := $(NAME).lv2

all: plugin bundle

plugin:
	$(MAKE) -C plugins/$(NAME)

bundle: plugin
	# the stereo bundle borrows the mono face; its own modgui/ files (panel with the STEREO
	# badge, screenshot, thumbnail) then go over the top
	[ "$(NAME)" = nhe-tapestry ] || cp -r bundle/nhe-tapestry.lv2/modgui bin/$(BUNDLE)/
	cp -r bundle/$(BUNDLE)/. bin/$(BUNDLE)/

install: all
	install -d $(DESTDIR)$(PREFIX)/lib/lv2/$(BUNDLE)
	cp -r bin/$(BUNDLE)/. $(DESTDIR)$(PREFIX)/lib/lv2/$(BUNDLE)/

clean:
	$(MAKE) -C plugins/nhe-tapestry clean
	$(MAKE) -C plugins/nhe-tapestry-stereo clean
	rm -rf bin build

.PHONY: all plugin bundle install clean
