#!/bin/sh
# Run the CPZ unit tests. No root and no ARM hardware required.
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

printf '== CPZ unit tests ==\n'
cd "$root"
python3 -m unittest discover -s tests -p 'test_*.py' -v
