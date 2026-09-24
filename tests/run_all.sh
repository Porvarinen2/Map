#!/bin/sh
# Runs the whole test suite. Every check must pass before the package ships.
set -e
cd "$(dirname "$0")"
fail=0
for t in test_guide.lua test_engine.lua test_movement.lua test_world.lua test_physical.lua test_lifecycle.lua test_bootstrap.lua; do
  echo ""
  echo "=================== $t ==================="
  if lua5.4 "$t"; then :; else echo "*** $t FAILED"; fail=1; fi
done
echo ""
echo "=================== powershell ==================="
if command -v pwsh >/dev/null 2>&1; then PWSH=pwsh
elif [ -x /opt/pwsh/pwsh ]; then PWSH=/opt/pwsh/pwsh
else PWSH=""; fi
if [ -n "$PWSH" ]; then
  "$PWSH" -NoProfile -File test_powershell.ps1 || fail=1
else
  echo "pwsh not installed - installer scripts not parse-checked"
fi

echo ""
echo "=================== syntax ==================="
find ../package/mod/TeslesNPCOverhaul -name '*.lua' -exec luac5.4 -p {} + && echo "all lua files compile"
node --check ../package/livemap/app.js && echo "app.js parses"
echo ""
if [ "$fail" = "0" ]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; exit 1; fi
