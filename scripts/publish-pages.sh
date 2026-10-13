#!/usr/bin/env bash
# Publishes a signed IPA to GitHub Pages (branch gh-pages), one folder per tag.
#
# The branch is rewritten as a single orphan commit on every publish, so IPAs never pile up in the
# history. Every stable (main) build is kept, plus the newest $KEEP_BRANCH_BUILDS branch builds.
#
# Required environment:
#   TAG IPA ICON_57 ICON_512 BASE_URL      what to publish and where the site lives
#   VERSION BUILD_NUMBER BUNDLE_ID APP_NAME STABLE BRANCH SHA RUN_URL DEVICES REPO   (build.json)
# Writes page_url, manifest_url and install_url to $GITHUB_OUTPUT when it is set.
set -euo pipefail

: "${TAG:?}" "${IPA:?}" "${ICON_57:?}" "${ICON_512:?}" "${BASE_URL:?}"
KEEP_BRANCH_BUILDS="${KEEP_BRANCH_BUILDS:-50}"
BRANCH_REF="refs/heads/gh-pages"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
GIT_DIR_ABS="$(git rev-parse --absolute-git-dir)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. The new build folder, prepared once.
export IPA_NAME
IPA_NAME="$(basename "$IPA")"
NEW="$WORK/new"
mkdir -p "$NEW"
cp "$IPA" "$NEW/$IPA_NAME"
cp "$ICON_57" "$NEW/icon-57.png"
cp "$ICON_512" "$NEW/icon-512.png"
URLS="$(python3 "$SCRIPTS/pages.py" build "$NEW")"

# 2. Merge it with what is published and push, retrying if another build publishes meanwhile.
for attempt in 1 2 3 4 5 6; do
  SITE="$WORK/site-$attempt"
  mkdir -p "$SITE"

  OLD_SHA="$(git ls-remote origin "$BRANCH_REF" | cut -f1)"
  if [ -n "$OLD_SHA" ]; then
    git fetch --quiet --no-tags origin "+$BRANCH_REF:refs/remotes/origin/gh-pages"
    OLD_SHA="$(git rev-parse refs/remotes/origin/gh-pages)"
    git archive "$OLD_SHA" | tar -x -C "$SITE"
  fi

  # Keep only build folders (those with build.json): the branch may have been created from the code.
  shopt -s dotglob nullglob
  for entry in "$SITE"/*; do
    if [ ! -d "$entry" ] || [ ! -f "$entry/build.json" ]; then
      rm -rf "$entry"
    fi
  done
  shopt -u dotglob nullglob

  rm -rf "${SITE:?}/$TAG"
  cp -R "$NEW" "$SITE/$TAG"
  python3 "$SCRIPTS/pages.py" site "$SITE" "$KEEP_BRANCH_BUILDS"

  # Single orphan commit, built with a throwaway index. --force so a *.ipa in .gitignore is ignored.
  export GIT_INDEX_FILE="$WORK/index-$attempt"
  git -C "$SITE" --git-dir="$GIT_DIR_ABS" --work-tree="$SITE" add -A --force .
  TREE="$(git -C "$SITE" --git-dir="$GIT_DIR_ABS" --work-tree="$SITE" write-tree)"
  unset GIT_INDEX_FILE
  COMMIT="$(git -c user.name="github-actions[bot]" \
                -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
                commit-tree "$TREE" -m "Publicar $TAG")"

  if git push --force-with-lease="$BRANCH_REF:$OLD_SHA" origin "$COMMIT:$BRANCH_REF"; then
    echo "Publicado $TAG en gh-pages (intento $attempt)."
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      python3 -c 'import json,sys; [print(f"{k}={v}") for k, v in json.loads(sys.argv[1]).items()]' "$URLS" >> "$GITHUB_OUTPUT"
    fi
    echo "$URLS"
    exit 0
  fi
  echo "gh-pages cambió mientras se publicaba; reintentando…"
  sleep $((attempt * 5 + RANDOM % 5))
done

echo "::error::No se pudo publicar en gh-pages tras varios intentos."
exit 1
