#!/bin/sh
# Static checks for the CPZ image sources. Requires shellcheck, ruff and mypy
# (see tests/README.md; CI installs them with pip).
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

for tool in shellcheck ruff mypy; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		printf 'missing %s; install the dev tools listed in tests/README.md\n' \
			"$tool" >&2
		exit 1
	fi
done

echo "== shellcheck =="
list=$(mktemp)
trap 'rm -f "$list"' EXIT INT TERM
find . \
	\( -path ./.git -o -path ./.venv -o -path ./.ruff_cache \
	-o -path ./.mypy_cache -o -path ./work -o -path ./deploy \
	-o -path ./node_modules \) -prune -o \
	-type f -print | while IFS= read -r file; do
	case "$file" in
		*.sh) printf '%s\n' "$file" ;;
		*)
			if head -n 1 "$file" 2>/dev/null | grep -qE '^#!.*(bash|sh)'; then
				printf '%s\n' "$file"
			fi
			;;
	esac
done | sort -u >"$list"
# -x follows the helpers sourced by build.sh (scripts/common).
# shellcheck disable=SC2046  # repository paths cannot contain spaces
shellcheck -x $(cat "$list")

echo "== ruff =="
ruff check scripts tools tests stage3/01-session/files/cpz-settings \
	stage3/01-session/files/cpz-search

echo "== mypy =="
mypy --ignore-missing-imports scripts/*.py tools/*.py tests/*.py \
	stage3/01-session/files/cpz-settings
# Extension-less scripts are both seen as "__main__"; check them separately.
mypy --ignore-missing-imports stage3/01-session/files/cpz-search
