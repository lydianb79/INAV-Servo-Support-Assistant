#!/bin/bash
# Builds the arm64 and x86_64 apps and publishes them as a GitHub release.
#
#   ./release.sh              build + create release v<VERSION> (VERSION from build_app.sh)
#   ./release.sh --draft      create the release as a draft (publish it later on GitHub)
#   ./release.sh --skip-build use the zips that are already there
#
# Needs the GitHub CLI: brew install gh && gh auth login
# If the release already exists, the zips are re-uploaded (replaced) and the notes updated.
set -euo pipefail
cd "$(dirname "$0")"

REPO="${REPO:-lydianb79/INAV-Servo-Support-Assistant}"
DRAFT=""
BUILD=1
for a in "$@"; do
  case "$a" in
    --draft) DRAFT="--draft" ;;
    --skip-build) BUILD=0 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Unknown option: $a" >&2; exit 1 ;;
  esac
done

VERSION="$(sed -n 's/^VERSION="\(.*\)"/\1/p' build_app.sh | head -1)"
[ -n "$VERSION" ] || { echo "❌ Could not read VERSION from build_app.sh" >&2; exit 1; }
TAG="v$VERSION"
TITLE="INAV Servo Support Assistant $VERSION"
ZIPS=("INAV-Servo-Support-Assistant-$VERSION-macOS-arm64.zip"
      "INAV-Servo-Support-Assistant-$VERSION-macOS-x86_64.zip")
echo "==> Release $TAG for $REPO"

# --- GitHub CLI ------------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "==> Installing GitHub CLI (brew install gh)"
    brew install gh
  else
    echo "❌ GitHub CLI 'gh' not found. Install it: https://cli.github.com (or: brew install gh)" >&2
    exit 1
  fi
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "==> Sign in to GitHub (one time)"
  gh auth login --hostname github.com --git-protocol https --web
fi

# --- source must match origin/main ----------------------------------------
echo "==> Updating from origin"
git fetch -q origin
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
  echo "❌ You are on branch '$BRANCH' – switch to main first (git switch main)." >&2; exit 1
fi
git pull -q --ff-only origin main
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "❌ Uncommitted changes in tracked files – commit or stash them first:" >&2
  git status --short --untracked-files=no >&2
  exit 1
fi
COMMIT="$(git rev-parse HEAD)"
if [ "$COMMIT" != "$(git rev-parse origin/main)" ]; then
  echo "❌ Local main is not equal to origin/main – push your commits first." >&2; exit 1
fi

# --- build -----------------------------------------------------------------
chmod +x build_app.sh
if [ "$BUILD" = 1 ]; then
  ./build_app.sh --arch arm64
  ./build_app.sh --arch x86_64
fi
for z in "${ZIPS[@]}"; do
  [ -f "$z" ] || { echo "❌ $z missing – run without --skip-build" >&2; exit 1; }
done

# --- notes: newest section of RELEASE_NOTES.md (up to the first ---) ---------
NOTES="$(mktemp -t release-notes)"
trap 'rm -f "$NOTES"' EXIT
awk '/^---[[:space:]]*$/ {exit} {print}' RELEASE_NOTES.md > "$NOTES"
if ! head -1 "$NOTES" | grep -q "$VERSION"; then
  echo "⚠️  RELEASE_NOTES.md does not start with version $VERSION – using it anyway."
fi

# --- tag + release ---------------------------------------------------------
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "==> Tag $TAG already exists on GitHub"
else
  echo "==> Creating tag $TAG on $COMMIT"
  git tag -a "$TAG" -m "$TITLE" "$COMMIT" 2>/dev/null || true
  git push -q origin "$TAG"
fi

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "==> Release $TAG exists – replacing the zips and updating the notes"
  gh release upload "$TAG" "${ZIPS[@]}" --repo "$REPO" --clobber
  gh release edit "$TAG" --repo "$REPO" --title "$TITLE" --notes-file "$NOTES"
else
  echo "==> Creating release $TAG"
  gh release create "$TAG" "${ZIPS[@]}" --repo "$REPO" --verify-tag \
     --title "$TITLE" --notes-file "$NOTES" $DRAFT
fi

URL="$(gh release view "$TAG" --repo "$REPO" --json url -q .url)"
echo "✅ Done: $URL"
open "$URL" 2>/dev/null || true
