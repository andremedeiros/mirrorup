#!/bin/sh
# Prints the Camera Extension's bundle version: the number of commits that touched what the
# extension is built from. App-only changes leave it alone, so updating the app does not replace a
# running extension (macOS 27.2 can lose a replaced extension until the Mac restarts; AGENTS.md).
# Uncommitted changes to those sources add a second component derived from their content, so a
# development build with edited extension sources still installs, and rebuilding the same edit
# does not reinstall.
set -eu
cd "$(dirname "$0")/.."
paths="macOS/MirrorupCameraExtension macOS/Shared macOS/project.yml macOS/extension-version.sh Sources/MirrorupDiagnostics"

# shellcheck disable=SC2086
count=$(git rev-list --count HEAD -- $paths)
# shellcheck disable=SC2086
changes=$({ git diff HEAD -- $paths; git ls-files --others --exclude-standard -z -- $paths | xargs -0 cat 2>/dev/null; } | shasum | cut -c1-7)
# shellcheck disable=SC2086
if [ -z "$(git status --porcelain -- $paths)" ]; then
    echo "$count"
else
    # Seven hex digits fit a 32-bit integer component.
    echo "$count.$(printf '%d' "0x$changes")"
fi
