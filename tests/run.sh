#!/bin/sh
# Run the CPZ unit tests. No root and no ARM hardware required.
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

printf '== cpz-settings unit tests ==\n'
cd "$root"
python3 -m unittest discover -s tests -p 'test_*.py' -v

printf '\n== cpz-hdmi-console unit tests ==\n'
sh "$root/tests/shell/test-hdmi-console.sh"
