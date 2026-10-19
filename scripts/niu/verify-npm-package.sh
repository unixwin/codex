#!/usr/bin/env bash
# Stage, pack, and install-test the @unixwin/codex npm packages.
#
# Verifies the thing that actually breaks in practice: a tarball that installs
# but is missing a binary, a resource, or the launcher's vendor tree.
#
# Usage:
#   scripts/niu/verify-npm-package.sh <version> [vendor-root] [work-dir]
#
#   version     npm release version, e.g. 0.163.0-alpha.1
#   vendor-root directory whose child is the target triple, containing the
#               canonical package layout (bin/, codex-resources/, codex-path/,
#               codex-package.json). Build it with:
#                 python scripts/build_codex_package.py --target x86_64-pc-windows-msvc \
#                   --variant codex --cargo-profile release \
#                   --package-dir <vendor-root>/x86_64-pc-windows-msvc --force
#   work-dir    scratch directory (default: a temp dir)
#
# Windows note: the meta package only ships bin/codex.js, so the launcher finds
# binaries through optionalDependencies or, absent that, its vendored sibling
# tree. Staging with --vendor-src gives it that tree, which is what makes the
# local install test meaningful before anything is published.

set -euo pipefail

VERSION="${1:?usage: verify-npm-package.sh <version> [vendor-root] [work-dir]}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENDOR_ROOT="${2:-$(mktemp -d)/vendor}"
WORK_DIR="${3:-$(mktemp -d)}"
TRIPLE="x86_64-pc-windows-msvc"
PLATFORM_TAG="win32-x64"

step() { printf '\n=== %s\n' "$1"; }

step "inputs"
echo "repo        : $REPO_ROOT"
echo "version     : $VERSION"
echo "vendor root : $VENDOR_ROOT"
echo "work dir    : $WORK_DIR"
echo "platform    : $TRIPLE ($PLATFORM_TAG)"

step "1/6 canonical package layout is complete"
PKG="$VENDOR_ROOT/$TRIPLE"
REQUIRED="
bin/codex.exe
bin/codex-code-mode-host.exe
codex-resources/codex-command-runner.exe
codex-resources/codex-windows-sandbox-setup.exe
codex-path/rg.exe
codex-package.json
"
missing=0
for rel in $REQUIRED; do
  if [ -f "$PKG/$rel" ]; then
    printf '  ok      %-46s %s bytes\n' "$rel" "$(stat -c '%s' "$PKG/$rel")"
  else
    printf '  MISSING %s\n' "$rel"
    missing=1
  fi
done
[ "$missing" -eq 0 ] || { echo "layout incomplete; refusing to stage"; exit 1; }
echo "  codex-package.json:"
cat "$PKG/codex-package.json"

step "2/6 stage the meta package (bin/codex.js + vendor tree)"
STAGE_META="$WORK_DIR/meta"
rm -rf "$STAGE_META"; mkdir -p "$STAGE_META"
python "$REPO_ROOT/codex-cli/scripts/build_npm_package.py" \
  --package codex \
  --vendor-src "$VENDOR_ROOT" \
  --release-version "$VERSION" \
  --staging-dir "$STAGE_META"

step "3/6 stage the platform package"
STAGE_PLATFORM="$WORK_DIR/platform"
rm -rf "$STAGE_PLATFORM"; mkdir -p "$STAGE_PLATFORM"
python "$REPO_ROOT/codex-cli/scripts/build_npm_package.py" \
  --package "codex-$PLATFORM_TAG" \
  --vendor-src "$VENDOR_ROOT" \
  --release-version "$VERSION" \
  --staging-dir "$STAGE_PLATFORM"

step "4/6 pack both packages and report what npm will ship"
(cd "$STAGE_META" && npm pack --json >/dev/null && cp ./*.tgz "$WORK_DIR/")
(cd "$STAGE_PLATFORM" && npm pack --json >/dev/null && cp ./*.tgz "$WORK_DIR/")
python - "$WORK_DIR" <<'PY'
import glob, os, sys, tarfile
work = sys.argv[1]
for tgz in sorted(glob.glob(os.path.join(work, "*.tgz"))):
    with tarfile.open(tgz) as tf:
        members = [m for m in tf.getmembers() if m.isfile()]
        total = sum(m.size for m in members)
    print(f"  {os.path.basename(tgz)}: {len(members)} files, {total/1_000_000:.1f} MB unpacked, "
          f"{os.path.getsize(tgz)/1_000_000:.1f} MB on the wire")
    for m in members[:8]:
        print(f"      {m.name}  {m.size}")
    if len(members) > 8:
        print(f"      ... {len(members)-8} more")
PY

step "5/6 install the meta package and simulate the npm alias optional dependency"
# The meta package ships only bin/codex.js: its binaries arrive through
# optionalDependencies as `npm:@unixwin/codex@<version>-win32-x64`, which npm
# installs under the alias path node_modules/@unixwin/codex-win32-x64/. Nothing
# is published yet, so unpack the platform tarball to that exact path. This is
# the same resolution the launcher performs in a real install.
PROJ="$WORK_DIR/proj"
rm -rf "$PROJ"; mkdir -p "$PROJ"
(cd "$PROJ" && npm init -y >/dev/null 2>&1)
META_TGZ="$(ls "$WORK_DIR"/unixwin-codex-*.tgz | grep -v "$PLATFORM_TAG" | head -1)"
PLATFORM_TGZ="$(ls "$WORK_DIR"/unixwin-codex-*-"$PLATFORM_TAG".tgz | head -1)"
[ -n "$META_TGZ" ] && [ -n "$PLATFORM_TGZ" ] || { echo "missing a tarball"; exit 1; }
(cd "$PROJ" && npm install --omit=optional --no-audit --no-fund "$META_TGZ")
ALIAS_DIR="$PROJ/node_modules/@unixwin/codex-$PLATFORM_TAG"
# Unpack with Python's tarfile, not tar. On Windows the runner's temp dir is a
# native `D:\a\_temp` path, and tar reads the drive colon as a remote host
# ("Cannot connect to D:"). --force-local and cygpath normalization both still
# trip over the mixed separators Git Bash produces from `$RUNNER_TEMP/...`.
# tarfile takes the path natively and is already a dependency of this script.
rm -rf "$ALIAS_DIR"
python - "$PLATFORM_TGZ" "$ALIAS_DIR" <<'PY'
import os
import shutil
import sys
import tarfile

tgz, dest = sys.argv[1], sys.argv[2]
os.makedirs(dest, exist_ok=True)
with tarfile.open(tgz) as archive:
    for member in archive.getmembers():
        # npm tarballs are rooted at `package/`; the tar call this replaces
        # used --strip-components=1 to drop that level.
        if not member.name.startswith("package/"):
            continue
        relative = member.name[len("package/"):]
        if not relative:
            continue
        target = os.path.join(dest, *relative.split("/"))
        if member.isdir():
            os.makedirs(target, exist_ok=True)
        elif member.isfile():
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with archive.extractfile(member) as source, open(target, "wb") as output:
                shutil.copyfileobj(source, output)
        else:
            print(f"  skipping non-file member: {member.name}")
PY
echo "  meta package   : $PROJ/node_modules/@unixwin/codex"
echo "  platform alias : $ALIAS_DIR ($(find "$ALIAS_DIR" -type f | wc -l) files)"
echo "  resolved by the launcher:"
node -e "console.log('    ' + require.resolve('@unixwin/codex-$PLATFORM_TAG/package.json'))" --prefix "$PROJ" 2>/dev/null \
  || (cd "$PROJ" && node -e "console.log('    ' + require.resolve('@unixwin/codex-$PLATFORM_TAG/package.json'))")
(cd "$PROJ" && ./node_modules/.bin/codex --version)
(cd "$PROJ" && ./node_modules/.bin/codex --help 2>&1 | head -3)

step "6/6 publish order reminder"
printf '  Publish the platform package first, then the meta package:\n'
printf '    npm publish %s --tag %s\n' "$(basename "$PLATFORM_TGZ")" "$PLATFORM_TAG"
printf '    npm publish %s --tag latest\n' "$(basename "$META_TGZ")"

printf '\nAll checks passed for %s\n' "$VERSION"
