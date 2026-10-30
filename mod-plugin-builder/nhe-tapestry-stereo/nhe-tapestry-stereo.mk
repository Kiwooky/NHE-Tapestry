######################################
#
# nhe-tapestry-stereo  (path B package file): Tapestry Stereo, from the same repo as the mono one
#
# Builds the plugin from the GitHub repo at a given commit. Upload this file at
# https://builder.mod.audio/buildroot for an install link, or put it in
# mod-plugin-builder at plugins/package/nhe-tapestry-stereo/nhe-tapestry-stereo.mk.
#
# 1. DPF is a git submodule at dpf/; the hook below fetches it.
# 2. Push, then set NHE_TAPESTRY_STEREO_VERSION to the FULL 40-character commit hash
#    (GitHub: Commits -> copy button, or `git rev-parse HEAD`).
# The filename must match the variable prefix: nhe-tapestry-stereo.mk -> NHE_TAPESTRY_STEREO_.
#
######################################

# <- the full 40-character commit hash of NHE-Tapestry to build
NHE_TAPESTRY_STEREO_VERSION = 0000000000000000000000000000000000000000
NHE_TAPESTRY_STEREO_SITE = https://github.com/Kiwooky/NHE-Tapestry.git
NHE_TAPESTRY_STEREO_SITE_METHOD = git
NHE_TAPESTRY_STEREO_GIT_SUBMODULES = y
NHE_TAPESTRY_STEREO_BUNDLES = nhe-tapestry-stereo.lv2

# fetch git submodules (DPF), as MOD's own packages do (mod-plugin-builder)
NHE_TAPESTRY_STEREO_PRE_DOWNLOAD_HOOKS += MOD_PLUGIN_BUILDER_DOWNLOAD_WITH_SUBMODULES

NHE_TAPESTRY_STEREO_TARGET_MAKE = $(TARGET_MAKE_ENV) $(TARGET_CONFIGURE_OPTS) $(MAKE) NOOPT=true NAME=nhe-tapestry-stereo -C $(@D)

define NHE_TAPESTRY_STEREO_BUILD_CMDS
	$(NHE_TAPESTRY_STEREO_TARGET_MAKE)
endef

define NHE_TAPESTRY_STEREO_INSTALL_TARGET_CMDS
	$(NHE_TAPESTRY_STEREO_TARGET_MAKE) install DESTDIR=$(TARGET_DIR) PREFIX=/usr
endef

$(eval $(generic-package))
