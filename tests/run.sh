#!/usr/bin/env sh
# Run the test suite: tests/run.sh [filter]
# Each spec file runs in its own headless Neovim so module state never leaks
# between files. An optional filter selects spec files by substring.
cd "$(dirname "$0")/.." || exit 1
status=0
for spec in tests/*_spec.lua; do
  case "$spec" in *"$1"*) ;; *) continue ;; esac
  SPEC="$spec" nvim --headless -u NONE -i NONE --cmd "set rtp^=$(pwd)" -c "luafile tests/runner.lua" || status=1
done
exit $status
