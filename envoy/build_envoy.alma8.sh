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
    gcc-toolset-13 \
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

# --- install pinned Clang/LLVM 18 (Envoy v1.33.0's reference toolchain) --
# Alma8 only ships Clang 21 (llvm-toolset:rhel8), which is too new for v1.33.0's
# 2022-era vendored deps (v8, tcmalloc, fmt, ...). Use the official LLVM 18.1.8
# prebuilt: it is built for Ubuntu 18.04 (glibc 2.27) so it runs on Alma8's
# glibc 2.28, and it is the toolchain this Envoy release was tested with.
LLVM_VER="18.1.8"
LLVM_DIR="$HOME/.local/clang+llvm-${LLVM_VER}-x86_64-linux-gnu-ubuntu-18.04"
if [ ! -x "$LLVM_DIR/bin/clang" ]; then
    echo ">> Installing Clang/LLVM ${LLVM_VER} (~1 GB, first run only)"
    mkdir -p "$HOME/.local"
    _llvm_tarball="$HOME/.local/llvm-${LLVM_VER}.tar.xz"
    curl -fL -o "$_llvm_tarball" \
        "https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VER}/clang%2Bllvm-${LLVM_VER}-x86_64-linux-gnu-ubuntu-18.04.tar.xz"
    tar -C "$HOME/.local" -xJf "$_llvm_tarball"
    rm -f "$_llvm_tarball"
fi
# Clang 18 needs a C++20-capable libstdc++; Alma8's system gcc-8 one lacks
# <version>/<concepts>. Pin gcc-toolset-13's libstdc++ via a wrapper so EVERY
# clang invocation uses it -- including Bazel's local_config_cc toolchain
# detection, which records the builtin include dirs. (Passing --gcc-toolchain
# only as a compile flag makes detection see gcc-8 dirs but compiles pull gcc-13
# headers, tripping Bazel's "absolute path inclusion" check.) libstdc++ is linked
# statically, so the binary still runs on the host's glibc 2.28.
GCC_TOOLCHAIN="/opt/rh/gcc-toolset-13/root/usr"
WRAP_DIR="$HOME/.local/clang18-gcc13-wrap"
mkdir -p "$WRAP_DIR"
# The wrapper also normalizes the linker flag: the toolchain emits a broken
# '-fuse-ld=<abs path to ld.lld>:' (trailing colon), which clang rejects as an
# "invalid linker name" -- breaking both foreign_cc CMake probes and direct
# Bazel links. Rewrite any -fuse-ld=... to -fuse-ld=lld (clang finds its bundled
# ld.lld). Bazel passes link flags via @params files, so rewrite inside those too.
for name in clang clang++; do
cat > "$WRAP_DIR/$name" <<EOF
#!/bin/bash
real="$LLVM_DIR/bin/\${0##*/}"
fixed=()
tmps=()
for a in "\$@"; do
  case "\$a" in
    @*)
      pf="\${a#@}"
      tmp="\$(mktemp)"
      tmps+=("\$tmp")
      sed 's|^-fuse-ld=.*|-fuse-ld=lld|' "\$pf" > "\$tmp"
      fixed+=("@\$tmp")
      ;;
    -fuse-ld=*) fixed+=("-fuse-ld=lld") ;;
    *) fixed+=("\$a") ;;
  esac
done
"\$real" --gcc-toolchain="$GCC_TOOLCHAIN" "\${fixed[@]}"
rc=\$?
[ \${#tmps[@]} -gt 0 ] && rm -f "\${tmps[@]}"
exit \$rc
EOF
done
chmod 755 "$WRAP_DIR/clang" "$WRAP_DIR/clang++"
CLANG_CC="$WRAP_DIR/clang"
CLANG_CXX="$WRAP_DIR/clang++"
"$CLANG_CC" --version | head -1

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
# Build with the pinned Clang/LLVM 18.1.8 installed above. Envoy's `--config=clang`
# would otherwise set CC=clang and pick up the host's too-new Clang 21; override
# CC/CXX (action, host/exec, and repo-rule envs) to point at LLVM 18 instead.
# The same flags must go to `bazel info` below, or it reports the wrong output dir.
# Build with the LLVM 18 wrapper (CC/CXX) defined above, which pins
# gcc-toolset-13's libstdc++. Override the CC=clang that `--config=clang` sets,
# for compile actions, host/exec actions, and repo-rule (toolchain detection).
BUILD_FLAGS=(
    -c opt --config=clang
    --action_env=CC="$CLANG_CC"      --action_env=CXX="$CLANG_CXX"
    --host_action_env=CC="$CLANG_CC" --host_action_env=CXX="$CLANG_CXX"
    --repo_env=CC="$CLANG_CC"        --repo_env=CXX="$CLANG_CXX"
    # The auto-configured toolchain turns on clang module-map layering checks
    # for clang 18; they treat libstdc++ headers as a module and fail strict
    # decluse on std includes (absl cctz, etc.). Envoy doesn't rely on these.
    --features=-layering_check
    --features=-module_maps
    # The auto-configured (local_config_cc) clang toolchain adds -Wthread-safety
    # by default; tcmalloc compiles with -Werror, so its lock-guarded return
    # (info_) trips -Wthread-safety-reference-return. Envoy's reference toolchain
    # doesn't add -Wthread-safety, so this is specific to the local toolchain.
    --copt=-Wno-thread-safety-reference-return
    --host_copt=-Wno-thread-safety-reference-return
)
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
