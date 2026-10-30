#!/usr/bin/env bash
# Runs the playbook's check.sh on Tapestry Stereo. The stereo plugin shares the mono source and
# face, and check.sh wants each in one folder, so stage a merged copy first. It also builds the
# mono plugin (native and Duo) so the tests can hold the stereo one against it on both machines.
#   bash tools/check_stereo.sh [--no-qemu]          (playbook next to this repo, or set PB=...)
# Writes a test recipe, dist/nhe-tapestry-stereo.mk (not committed: the builder uses mod-plugin-builder/).
set -euo pipefail
cd "$(dirname "$0")/.."
PB="${PB:-../MOD-plugin-playbook}"
HERE="$PB/tools"
CACHE="${PB_CACHE:-$HOME/.cache/mod-playbook}"
S="$(mktemp -d)"; trap 'rm -rf "$S"' EXIT
mkdir -p "$S/plugins/nhe-tapestry-stereo" "$S/bundle/nhe-tapestry-stereo.lv2"
cp plugins/nhe-tapestry-stereo/DistrhoPluginInfo.h "$S/plugins/nhe-tapestry-stereo/"
cp plugins/nhe-tapestry/TapestryPlugin.cpp "$S/plugins/nhe-tapestry-stereo/TapestryStereoPlugin.cpp"
cp plugins/nhe-tapestry-stereo/Makefile "$S/plugins/nhe-tapestry-stereo/"
cp -r bundle/nhe-tapestry.lv2/modgui "$S/bundle/nhe-tapestry-stereo.lv2/"     # the shared face,
cp -r bundle/nhe-tapestry-stereo.lv2/. "$S/bundle/nhe-tapestry-stereo.lv2/"   # then stereo's own panel and images
rm -f "$S/bundle/nhe-tapestry-stereo.lv2/modgui/screenshot-tapestry.png" "$S/bundle/nhe-tapestry-stereo.lv2/modgui/thumbnail-tapestry.png"
cp bundle/nhe-tapestry-stereo.lv2/modgui/screenshot-tapestry.png bundle/nhe-tapestry-stereo.lv2/modgui/thumbnail-tapestry.png \
   "$S/bundle/nhe-tapestry-stereo.lv2/modgui/" 2>/dev/null || true

# the mono plugin to compare against (check.sh fetches DPF into the cache; do the same here)
if [ -d "$CACHE/dpf" ]; then
  python3 "$HERE/assemble_recipe.py" plugins/nhe-tapestry bundle/nhe-tapestry.lv2 "$S/nhe-tapestry.mk" >/dev/null
  for T in native arm32; do
    rm -rf "$S/dpf-$T"; cp -r "$CACHE/dpf" "$S/dpf-$T"
    C=""; [ "$T" != native ] && C="CROSS=$T"
    make -s -f "$HERE/harness.mk" RECIPE="$S/nhe-tapestry.mk" PREFIX=NHE_TAPESTRY SRC="$S/dpf-$T" OUT="$S/mono-$T" $C >"$S/mono-$T.log" 2>&1 \
      || { cat "$S/mono-$T.log"; echo "FAIL building the mono plugin ($T)"; exit 1; }
  done
  export PB_SO_MONO="$S/mono-native/nhe-tapestry.lv2/nhe-tapestry_dsp.so"
  export PB_SO_MONO_ARM="$S/mono-arm32/nhe-tapestry.lv2/nhe-tapestry_dsp.so"
else
  echo "(no DPF in $CACHE yet: run the mono check once; the comparison with mono is skipped)"
fi
if [ "${RENDER_FACE:-0}" = 1 ]; then      # re-render the stereo screenshot and thumbnail from the merged face
  python3 "$HERE/render_face.py" "$S/bundle/nhe-tapestry-stereo.lv2"
  cp "$S/bundle/nhe-tapestry-stereo.lv2/modgui/screenshot-tapestry.png" "$S/bundle/nhe-tapestry-stereo.lv2/modgui/thumbnail-tapestry.png" \
     bundle/nhe-tapestry-stereo.lv2/modgui/
  python3 -c "
from PIL import Image
p='bundle/nhe-tapestry-stereo.lv2/modgui/screenshot-tapestry.png'
Image.open(p).convert('RGBA').quantize(256, method=Image.FASTOCTREE).save(p, optimize=True)"   # 256 colours: keeps the .mk small
  cp bundle/nhe-tapestry-stereo.lv2/modgui/screenshot-tapestry.png "$S/bundle/nhe-tapestry-stereo.lv2/modgui/"
fi

bash "$HERE/check.sh" --src "$S/plugins/nhe-tapestry-stereo" --bundle "$S/bundle/nhe-tapestry-stereo.lv2" \
    --test tests/test_nhe_tapestry_stereo.py "$@"
