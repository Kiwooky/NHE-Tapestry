#!/usr/bin/env bash
# Runs the playbook's check.sh on the mono Tapestry (playbook next to this repo, or set PB=...).
# Writes a test recipe, dist/nhe-tapestry.mk (not committed: the builder uses mod-plugin-builder/). Tapestry Stereo: tools/check_stereo.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
PB="${PB:-../MOD-plugin-playbook}"
bash "$PB/tools/check.sh" --src plugins/nhe-tapestry --bundle bundle/nhe-tapestry.lv2 --test tests/test_nhe_tapestry.py "$@"
