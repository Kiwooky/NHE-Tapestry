######################################
#
# nhe-tapestry  (path B package file)
#
# Builds the plugin from the GitHub repo at a given commit. Upload this file at
# https://builder.mod.audio/buildroot for an install link, or put it in
# mod-plugin-builder at plugins/package/nhe-tapestry/nhe-tapestry.mk.
#
# 1. DPF is a git submodule at dpf/; the hook below fetches it.
# 2. Push, then set NHE_TAPESTRY_VERSION to the FULL 40-character commit hash
#    (GitHub: Commits -> copy button, or `git rev-parse HEAD`).
# The filename must match the variable prefix: nhe-tapestry.mk -> NHE_TAPESTRY_.
#
######################################

# <- the full 40-character commit hash of NHE-Tapestry to build
NHE_TAPESTRY_VERSION = d1779d1605d9747e1c0a9c184b7fce249d545c44
NHE_TAPESTRY_SITE = https://github.com/Kiwooky/NHE-Tapestry.git
NHE_TAPESTRY_SITE_METHOD = git
NHE_TAPESTRY_GIT_SUBMODULES = y
NHE_TAPESTRY_BUNDLES = nhe-tapestry.lv2

# fetch git submodules (DPF), as MOD's own packages do (mod-plugin-builder)
NHE_TAPESTRY_PRE_DOWNLOAD_HOOKS += MOD_PLUGIN_BUILDER_DOWNLOAD_WITH_SUBMODULES

NHE_TAPESTRY_TARGET_MAKE = $(TARGET_MAKE_ENV) $(TARGET_CONFIGURE_OPTS) $(MAKE) NOOPT=true -C $(@D)

define NHE_TAPESTRY_BUILD_CMDS
	$(NHE_TAPESTRY_TARGET_MAKE)
endef

define NHE_TAPESTRY_INSTALL_TARGET_CMDS
	$(NHE_TAPESTRY_TARGET_MAKE) install DESTDIR=$(TARGET_DIR) PREFIX=/usr
endef

$(eval $(generic-package))
