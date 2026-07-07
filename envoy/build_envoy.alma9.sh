#!/usr/bin/env bash
#
# build_envoy — build a stripped, static Envoy binary on AlmaLinux 9.
# Usage: ./build_envoy <version> [--no-checkout]   e.g. ./build_envoy v1.29.6
#
# See envoy-build.md for how the build works and why these choices were made.

set -euo pipefail

# --- arguments ----------------------------------------------------------
VERSION=""
NO_CHECKOUT=0
for arg in "$@"; do
    case "$arg" in
        --no-checkout) NO_CHECKOUT=1 ;;
        -*)            echo "Unknown option: $arg" >&2; exit 1 ;;
        *)             [ -z "$VERSION" ] && VERSION="$arg" \
                           || { echo "Unexpected argument: $arg" >&2; exit 1; } ;;
    esac
done
[ -n "$VERSION" ] || { echo "Usage: $0 <version> [--no-checkout]  (e.g. v1.29.6)" >&2; exit 1; }

ENVOY_SRC="$HOME/envoy-source"
OUT_DIR="$HOME/artifactory/$VERSION"
PATCH_DIR="$HOME/patch/$VERSION"
ENVOY_REPO="https://ossmirror.ouryahoo.com/mirror-github/envoyproxy--envoy.git"

# --- install build dependencies -----------------------------------------
echo ">> Installing build dependencies"
sudo dnf install -y dnf-plugins-core
# libstdc++-static lives in the CRB (EL9) / PowerTools (EL8) repo.
sudo dnf config-manager --set-enabled crb 2>/dev/null \
    || sudo dnf config-manager --set-enabled powertools 2>/dev/null || true
sudo dnf groupinstall "Development Tools" -y
sudo dnf install -y \
    gcc \
    gcc-c++ \
    clang \
    make \
    git \
    libatomic \
    libstdc++ \
    libstdc++-static \
    libtool \
    lld \
    patch
sudo dnf install -y y1.0-python313 --enablerepo oath-rpms-stable

# --- install bazel (via bazelisk) ---------------------------------------
if [ ! -x /usr/local/bin/bazel ]; then
    echo ">> Installing bazel (bazelisk)"
    arch=$([ "$(uname -m)" = "aarch64" ] && echo arm64 || echo amd64)
    sudo curl -fL -o /usr/local/bin/bazel \
        "https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-${arch}"
    sudo chmod 755 /usr/local/bin/bazel
fi

# --- get the source -----------------------------------------------------
if [ ! -d "$ENVOY_SRC" ]; then
    [ "$NO_CHECKOUT" -eq 0 ] || { echo "--no-checkout set but $ENVOY_SRC does not exist" >&2; exit 1; }
    echo ">> Cloning Envoy source into $ENVOY_SRC"
    git clone "$ENVOY_REPO" "$ENVOY_SRC"
fi
cd "$ENVOY_SRC"

if [ "$NO_CHECKOUT" -eq 1 ]; then
    echo ">> Building existing tree (--no-checkout) at $(git rev-parse --short HEAD)"
else
    echo ">> Checking out $VERSION"
    git fetch --tags --prune
    git checkout "$VERSION"
    bazel clean
fi

# --- record local changes -----------------------------------------------
echo ">> Saving local changes to $PATCH_DIR/build.patch"
mkdir -p "$PATCH_DIR"
git diff > "$PATCH_DIR/build.patch"
cat "$PATCH_DIR/build.patch"

# --- build --------------------------------------------------------------
echo ">> Building Envoy (this takes a while)"
# Same flags must go to `bazel info` below, or it reports the wrong output dir.
# Clang 21 (llvm-toolset:rhel8) is far newer than v1.33.0's reference toolchain,
# so it raises diagnostics the pinned deps weren't written for and -Werror turns
# them fatal. Suppress them (these land before the targets' -Werror, so the
# specific warnings are simply disabled tree-wide):
#   FMT_USE_CONSTEVAL=0          - fmt 11.0.2 consteval FMT_STRING rejected by clang 21
#   -Wno-thread-safety-reference-return - new clang-21 check; trips tcmalloc + Envoy
CLANG21_COPTS=(
    --copt=-DFMT_USE_CONSTEVAL=0          --host_copt=-DFMT_USE_CONSTEVAL=0
    --copt=-Wno-thread-safety-reference-return
    --host_copt=-Wno-thread-safety-reference-return
)
BUILD_FLAGS=(-c opt --config=clang "${CLANG21_COPTS[@]}")
bazel build "${BUILD_FLAGS[@]}" --verbose_failures //source/exe:envoy-static.stripped

# --- collect artifacts --------------------------------------------------
echo ">> Collecting artifacts in $OUT_DIR"
mkdir -p "$OUT_DIR"
cp -f "$(bazel info "${BUILD_FLAGS[@]}" bazel-bin)/source/exe/envoy-static.stripped" "$OUT_DIR/envoy"
chmod 755 "$OUT_DIR/envoy"
cd "$OUT_DIR"
sha256sum envoy > envoy.sha256
tar czf envoy.tar.gz envoy

echo ">> Done. Binary: $OUT_DIR/envoy"
"$OUT_DIR/envoy" --version
