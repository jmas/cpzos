#!/usr/bin/env bash
# Bump VERSION, commit it, create an annotated tag and push.
#
# The tag alone builds nothing: publish a GitHub Release for it and
# .github/workflows/build.yml builds the image, attaches it to that release
# and publishes it to OSS/os-list.
#
# Usage:
#   ./tools/release.sh                 # bump patch: 0.1.0 -> 0.1.1
#   ./tools/release.sh minor           # 0.1.1 -> 0.2.0
#   ./tools/release.sh major           # 0.2.0 -> 1.0.0
#   ./tools/release.sh 0.3.0-beta.1    # explicit (prerelease) version
#   ./tools/release.sh patch --dry-run # show what would happen
#   ./tools/release.sh patch --no-push # commit + tag locally only
#
# Environment:
#   RELEASE_BRANCH   branch to release from (default: current branch)
set -euo pipefail

BRANCH="${RELEASE_BRANCH:-}"
bump="patch"
explicit=""
push=1
dry_run=0
assume_yes=0
skip_checks=0

usage() {
	cat <<'EOF'
Bump VERSION, commit, tag and push (publish the GitHub Release to build).

Usage: tools/release.sh [patch|minor|major|X.Y.Z[-prerelease]] [options]

Options:
  --no-push       commit and tag locally, do not push
  --dry-run       print the next version and tag, change nothing
  --yes, -y       do not ask for confirmation
  --skip-checks   do not run verify-stage.sh / tests/run.sh first
  --help, -h      show this help

Environment:
  RELEASE_BRANCH  branch to release from (default: current branch)
EOF
}

die() {
	printf 'release: %s\n' "$*" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
		patch | minor | major)
			bump=$1
			explicit=""
			;;
		-h | --help)
			usage
			exit 0
			;;
		--no-push) push=0 ;;
		--dry-run) dry_run=1 ;;
		-y | --yes) assume_yes=1 ;;
		--skip-checks) skip_checks=1 ;;
		v[0-9]* | [0-9]*.[0-9]*.[0-9]*)
			explicit=${1#v}
			;;
		*)
			printf 'release: unknown argument: %s\n\n' "$1" >&2
			usage >&2
			exit 1
			;;
	esac
	shift
done

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"
[ -f VERSION ] || die "VERSION file is missing"

branch_now=$(git rev-parse --abbrev-ref HEAD)
[ "$branch_now" != "HEAD" ] ||
	die "detached HEAD; check out a branch before releasing"
BRANCH="${BRANCH:-$branch_now}"

current=$(tr -d '[:space:]' <VERSION)
case "$current" in
	'' | *[!0-9A-Za-z.-]*)
		die "VERSION must look like X.Y.Z or X.Y.Z-prerelease (got '$current')"
		;;
esac
if ! printf '%s\n' "$current" |
	grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
	die "VERSION must look like X.Y.Z or X.Y.Z-prerelease (got '$current')"
fi

current_base=${current%%-*}
IFS=. read -r major minor patch <<<"$current_base"

if [ -n "$explicit" ]; then
	new=$explicit
else
	case "$bump" in
		major) new="$((major + 1)).0.0" ;;
		minor) new="$major.$((minor + 1)).0" ;;
		patch)
			if [ "$current_base" != "$current" ]; then
				# A stable release promotes the current prerelease base.
				new=$current_base
			else
				new="$major.$minor.$((patch + 1))"
			fi
			;;
	esac
fi

if ! printf '%s\n' "$new" |
	grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
	die "invalid version '$new' (expected X.Y.Z or X.Y.Z-prerelease)"
fi

tag_current=0
if [ "$new" = "$current" ]; then
	if [ -z "$explicit" ]; then
		die "already at $current; pass an explicit version or use minor/major"
	fi
	# An explicit version may equal VERSION: tag the current commit instead of
	# creating an empty bump commit (used for the first release).
	tag_current=1
fi

tag="v$new"

if [ "$dry_run" = 1 ]; then
	printf 'release (dry run)\n'
	printf '  branch:  %s\n' "$BRANCH"
	if [ "$tag_current" = 1 ]; then
		printf '  version: %s (tag current commit)\n' "$current"
	else
		printf '  version: %s -> %s\n' "$current" "$new"
	fi
	printf '  tag:     %s\n' "$tag"
	printf '  push:    %s\n' "$([ "$push" = 1 ] && echo yes || echo no)"
	exit 0
fi

if [ "$tag_current" = 1 ]; then
	git ls-files --error-unmatch VERSION >/dev/null 2>&1 ||
		die "VERSION is untracked; 'git add VERSION && git commit' it first"
fi

branch_now=$(git rev-parse --abbrev-ref HEAD)
[ "$branch_now" = "$BRANCH" ] ||
	die "on branch '$branch_now', expected '$BRANCH' (set RELEASE_BRANCH to override)"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	die "working tree has uncommitted changes; commit or stash them first"
fi

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
	die "tag $tag already exists locally"
fi

if [ "$push" = 1 ]; then
	fetch_rc=0
	git fetch --quiet origin "$BRANCH" 2>/dev/null || fetch_rc=$?
	if [ "$fetch_rc" -ne 0 ]; then
		heads_rc=0
		heads=$(git ls-remote --heads origin 2>/dev/null) || heads_rc=$?
		[ "$heads_rc" -eq 0 ] || die "cannot reach origin"
		[ -z "$heads" ] ||
			die "cannot fetch origin/$BRANCH"
		printf 'origin has no branches yet; this will be the first push.\n'
	fi
	if git rev-parse -q --verify "refs/remotes/origin/$BRANCH" >/dev/null; then
		behind=$(git rev-list --count "HEAD..origin/$BRANCH")
		[ "$behind" -eq 0 ] ||
			die "branch is behind origin/$BRANCH by $behind commit(s); pull first"
	fi
	if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
		die "tag $tag already exists on origin"
	fi
fi

printf 'Release %s\n' "$tag"
printf '  branch:  %s\n' "$BRANCH"
if [ "$tag_current" = 1 ]; then
	printf '  version: %s (tag current commit)\n' "$current"
else
	printf '  version: %s -> %s\n' "$current" "$new"
fi
printf '  changes:\n'
git log --oneline "$(git describe --tags --abbrev=0 2>/dev/null || echo HEAD)"..HEAD |
	sed 's/^/    /'

if [ "$assume_yes" = 0 ]; then
	printf 'Continue? [y/N] '
	read -r answer || answer=""
	case "$answer" in
		y | Y | yes | YES) ;;
		*)
			echo "Aborted."
			exit 1
			;;
	esac
fi

if [ "$skip_checks" = 0 ]; then
	printf 'Running host checks...\n'
	./tools/verify-stage.sh
	./tests/run.sh
fi

if [ "$tag_current" = 1 ]; then
	printf 'Tagging the current commit (%s).\n' "$(git rev-parse --short HEAD)"
else
	printf '%s\n' "$new" >VERSION
	git add VERSION
	git commit -m "chore(release): $tag"
fi
git tag -a "$tag" -m "$tag"

if [ "$push" = 1 ]; then
	git push origin "HEAD:refs/heads/$BRANCH"
	git push origin "refs/tags/$tag"
	repo_slug="$(git remote get-url origin)"
	repo_slug="${repo_slug%.git}"
	repo_slug="${repo_slug#*github.com}"
	repo_slug="${repo_slug#[:/]}"
	printf '\nPushed %s.\n' "$tag"
	printf 'Publish a GitHub Release for %s to start the image build:\n' "$tag"
	printf '  https://github.com/%s/releases/new?tag=%s\n' "$repo_slug" "$tag"
else
	printf '\nCreated %s locally. Push it with:\n' "$tag"
	printf '  git push origin HEAD:refs/heads/%s\n' "$BRANCH"
	printf '  git push origin refs/tags/%s\n' "$tag"
	printf 'The image build starts when the GitHub Release for %s is published.\n' "$tag"
fi
