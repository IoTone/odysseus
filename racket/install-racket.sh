#!/usr/bin/env bash
# install-racket.sh — get the right, full-featured Racket for development &
# release builds of the Odysseus port.
#
# Policy (see ../PORTING_PLAN.md):
#   - Linux (first-class: Debian/Ubuntu x86_64): official Racket release from
#     racket-lang.org, installed in-place under a user prefix. No sudo, no
#     distro package (Debian's `racket` is split/outdated), and — crucially —
#     a working `raco exe` (the Homebrew minimal-racket bottle segfaults).
#   - macOS: Homebrew is the tried-and-true path: `brew install --cask racket`
#     (full) or `brew install minimal-racket`. This script defers to it.
#   - Other systems: explored down the road; the natipkg build below is the
#     most distro-portable Linux option when we get there.
#
# Usage:
#   racket/install-racket.sh                 # install to ~/racket
#   RACKET_PREFIX=/opt/racket racket/install-racket.sh
#   RACKET_VARIANT=natipkg racket/install-racket.sh   # cross-distro portable build
set -euo pipefail

RACKET_VERSION="${RACKET_VERSION:-9.2}"
RACKET_PREFIX="${RACKET_PREFIX:-$HOME/racket}"
RACKET_VARIANT="${RACKET_VARIANT:-}"   # "" = standard linux-cs; "natipkg" = portable

os="$(uname -s)"
arch="$(uname -m)"

if [ "$os" = "Darwin" ]; then
  echo "macOS detected — use Homebrew instead:"
  echo "    brew install --cask racket      # full, includes DrRacket + GUI"
  echo "    brew install minimal-racket     # smaller (dev was bootstrapped on this)"
  exit 0
fi

if [ "$os" != "Linux" ] || [ "$arch" != "x86_64" ]; then
  echo "This script targets Linux x86_64 (first target: Debian/Ubuntu)."
  echo "Detected: $os/$arch — see https://download.racket-lang.org/ for other builds."
  exit 1
fi

suffix="x86_64-linux-cs"
[ "$RACKET_VARIANT" = "natipkg" ] && suffix="x86_64-linux-natipkg-cs"

installer="racket-${RACKET_VERSION}-${suffix}.sh"
url="https://download.racket-lang.org/installers/${RACKET_VERSION}/${installer}"
tmp="$(mktemp -d)"

echo "Downloading $installer ..."
curl -fSL -o "$tmp/$installer" "$url"

echo "Installing (in-place, no sudo) to $RACKET_PREFIX ..."
# --in-place: self-contained tree under --dest; --create-dir: make it if absent.
sh "$tmp/$installer" --in-place --create-dir --dest "$RACKET_PREFIX"
rm -rf "$tmp"

echo
echo "Done. Add Racket to your PATH:"
echo "    export PATH=\"$RACKET_PREFIX/bin:\$PATH\""
echo
"$RACKET_PREFIX/bin/racket" --version
