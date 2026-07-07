# Building Envoy on Alma9

How to build a stripped, static Envoy binary on AlmaLinux 9 (RHEL9 family), and
the toolchain facts you need to not get stuck. Driver script: `build_envoy`.

## TL;DR

```bash
./build_envoy v1.29.6                 # fetch + checkout the tag, then build
./build_envoy v1.29.6 --no-checkout   # build the existing local tree as-is
```

Build with Envoy's **hermetic Clang** toolchain. Do **not** use `--config=gcc`.

`--no-checkout` skips `git fetch`/`git checkout` and builds `~/envoy-source`
exactly as it is — use it to preserve local edits or rebuild without touching the
checkout. `<version>` is still required (it names the output dir). The source
dir must already exist.

## Building on AlmaLinux 8

Alma8 ships **glibc 2.28**, but Envoy's prebuilt Rust toolchain needs
**GLIBC ≥ 2.29** (and glibc cannot be upgraded on EL8). So a native Alma8 build
fails in the Rust step. Use the wrapper, which runs the *same* build inside an
Alma9 container (glibc 2.34) — the host is never modified:

```bash
./build_envoy_alma8 v1.38.3        # builds in an almalinux:9 container via podman/docker
```

- Requires `podman` (EL8 default) or `docker` on the host.
- Delegates to `build_envoy` inside the container, so build logic isn't
  duplicated. Artifacts/cache persist on the host (`~/artifactory`,
  `~/.cache/bazel-envoy-alma8`).
- Use a current Envoy (hermetic-Clang toolchain). Older releases (≤ v1.36) use a
  host-clang toolchain this wrapper doesn't set up — and the container removes the
  glibc reason to use them.
- **Runtime check:** confirm the binary actually runs on Alma8's glibc 2.28
  before deploying — its floor is set by Envoy's hermetic sysroot, not the build:
  ```bash
  objdump -T envoy | grep -oE 'GLIBC_[0-9.]+' | sort -V | tail -1   # must be <= GLIBC_2.28
  ```

## How the Envoy Bazel build works

- **Bazel** is pinned by `.bazelversion` (currently `7.7.1`) and run via
  `bazelisk` (installed to `/usr/local/bin/bazel`), so the right Bazel is fetched
  automatically.
- **Toolchains are registered in `bazel/toolchains.bzl`.** Two exist:
  1. **Hermetic LLVM/Clang** (`llvm_toolchain`, Clang **18.1.8**) — downloads its
     own Clang **and** a distro-agnostic sysroot (`@sysroot_linux_amd64`). Fully
     self-contained: does not use the host gcc, glibc, or libstdc++.
  2. **GCC** (`.../configs/linux/gcc/cc`) — intended for Envoy's Ubuntu RBE
     containers. Its `tool_paths` **hardcode Ubuntu paths**: `/usr/bin/gcc` and
     `/usr/lib/gcc/x86_64-linux-gnu/13/include`.
- **Toolchain selection is by platform constraint.** The GCC toolchain only
  matches a platform that carries `@bazel_tools//tools/cpp:gcc`. That marker
  exists only on Envoy's gcc platforms, which `--config=gcc` selects
  (`.bazelrc`). With any other host platform, Bazel falls back to the hermetic
  Clang toolchain.
- **Build target:** `//source/exe:envoy-static.stripped` (stripped static binary).
- The driver copies the result to `~/artifactory/<version>/envoy` and writes a
  `.sha256` + a gzipped `envoy.gz`.

## Why Clang, not GCC, on Alma9

| | Hermetic Clang (use this) | Envoy GCC config |
|---|---|---|
| Compiler source | Downloaded by Bazel (18.1.8) | Expects `/usr/bin/gcc` = GCC 13 |
| Sysroot | Bundled, distro-agnostic | Ubuntu container layout |
| Alma9 fit | Works as-is | Paths don't exist on Alma9 |
| C++20 | Yes | Stock Alma9 `/usr/bin/gcc` is GCC 11 (too old) |

The hermetic Clang toolchain sidesteps every host-toolchain problem. Alma9's
stock GCC 11 is too old for Envoy's C++20, and gcc-toolset-13 lives at
`/opt/rh/...`, not the Ubuntu paths the GCC config hardcodes.

### The trap that was hit

Setting `--config=gcc` **and** overriding `--host_platform=@platforms//host`:

- `@platforms//host` lacks the `@bazel_tools//tools/cpp:gcc` constraint, so Bazel
  silently picked the **Clang** toolchain instead of GCC.
- `--config=gcc` still injected GCC-only flags (e.g. `-Wno-error=restrict`).
- Clang doesn't know the `restrict` warning, and brotli compiles with `-Werror`
  → fatal `error: unknown warning option '-Werror=restrict'`.

Rule of thumb: pick one toolchain. For Alma9, that's Clang — leave
`--config=gcc` out entirely.

## Stamp the build as "Yahoo" in `envoy --version`

`envoy --version` prints an SCM status string. It comes from `tree_status` in
`bazel/get_workspace_status`, which Bazel emits as `BUILD_SCM_STATUS` and the
build compiles into the binary (`source/common/version/...`). Stock Envoy sets
it to `Clean` (no local changes) or `Modified` (uncommitted changes). For Yahoo
builds, change the `Modified` value to `Yahoo` so the provenance is visible.

Edit `bazel/get_workspace_status`:

```diff
 tree_status="Clean"
 git diff-index --quiet HEAD -- || {
-    tree_status="Modified"
+    tree_status="Yahoo"
 }
```

Notes:

- This only takes effect when the working tree has uncommitted changes (the
  `git diff-index --quiet` check fails). The `build_envoy` flow applies patches,
  so the tree is dirty and the stamp shows `Yahoo`. A pristine checkout stays
  `Clean`.
- `build_envoy` records local edits via `git diff > build.patch`, so this change
  is captured in the per-version patch file automatically.
- After building, confirm with `envoy --version` — the output should contain
  `/Yahoo/`.

## Gaps / things to know

- **`libtinfo.so.5: no version information available`** — benign warning from the
  hermetic Clang binary; the build still succeeds. To silence it, provide the
  compat lib (verify the package on your mirror): `sudo dnf install -y ncurses-compat-libs`.
- **Disk + time** — Bazel cache lives in `~/.cache/bazel`; a clean build pulls
  many external repos and takes a while. Ensure ample free space.
- **Network** — first build downloads Bazel, the LLVM toolchain, the sysroot, and
  all external deps. Source is cloned from the Yahoo mirror
  (`ossmirror.ouryahoo.com`); the toolchain/deps come from upstream.
- **GCC build is not supported as-is.** If ever required, you must patch
  `bazel/rbe/toolchains/configs/linux/gcc/cc/BUILD` `tool_paths` + include dirs to
  point at `/opt/rh/gcc-toolset-13/root/...` and keep `--config=gcc`. Fragile;
  prefer Clang.

## Pick-up guide (zero prior knowledge)

Prerequisites on a fresh Alma9 host:

1. `git`, `patch`, `python3-pip`, and `curl` (the driver installs these).
2. Enough disk for `~/.cache/bazel`.

Run:

```bash
./build_envoy v1.29.6
```

It will: install deps → fetch Bazel via bazelisk → clone Envoy source to
`~/envoy-source` → checkout the tag → build with hermetic Clang → collect the
binary, checksum, and gzipped binary under `~/artifactory/<version>/`.

To build manually inside an existing checkout:

```bash
cd ~/envoy-source && git checkout -f v1.29.6
bazel build -c opt --config=clang --verbose_failures \
    //source/exe:envoy-static.stripped
```

Verify:

```bash
# Pass the SAME flags to `bazel info`, else it reports the default
# k8-fastbuild path instead of the -c opt path and the file won't exist.
$(bazel info -c opt --config=clang bazel-bin)/source/exe/envoy-static.stripped --version
```

## Key files

- `build_envoy` — driver script (preflight, build, package).
- `.bazelversion` — pinned Bazel version.
- `.bazelrc` — `--config=clang` / `--config=gcc` definitions.
- `bazel/toolchains.bzl` — registers the LLVM and GCC toolchains.
- `bazel/rbe/toolchains/configs/linux/gcc/cc/BUILD` — GCC tool paths (Ubuntu).

