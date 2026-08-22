#!/usr/bin/env bash
# tools/build.sh — the lunx custom Proton, aarch64 (fork recipe record).
#
# The full recipe for building a complete aarch64 GE-Proton for the AYN Odin 2
# Portal on this fork. It is the fork's adaptation of the lunx-base package
# recipe (packages/proton-lunx/pkg/build.sh) with the fork's path assumptions:
#
#   * the GE tree IS this repo (the fork's root commit imports GE-Proton11-4 at
#     the pinned 7855e7f), so there is no fetch / HEAD==GE_COMMIT gate — the
#     checkout is the pin by construction;
#   * source.env sits at the repo root (the pins);
#   * the prep phase (submodule fetch, wiring gates, lunx patches) lives in
#     tools/lunx-patches.sh and is called here so the workflow and this recipe
#     share one source of truth for that logic;
#   * the build uses GE's own steamrt4 arm64-llvm container image (pulled, not
#     built) — no Fedora BUILDER_IMAGE is involved, so there is no toolchain.env
#     to carry.
#
# The GitHub Actions workflow (_job_build.yml) reproduces these exact steps as
# discrete steps; this script is the self-contained record and can be run
# standalone on a machine with docker (or podman).
#
# Artifact contract: out/proton-lunx-${VERSION}.tar.zst (the
# compatibilitytools.d tarball).
#
# Author: Pedro Nascimento <pnascimento@gmail.com>
set -euxo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
REPO_ROOT="${PWD}"

source ./source.env
: "${VERSION:?source.env must set VERSION}"
: "${GE_COMMIT:?source.env must set GE_COMMIT}"

MODE="${LUNX_PROTON_MODE:-full}"
[ "${MODE}" = "full" ] || {
    echo "ERROR: unknown LUNX_PROTON_MODE=${MODE} (only 'full' is supported on the fork)" >&2
    exit 1; }

if command -v podman >/dev/null 2>&1; then
    CT=podman
elif command -v docker >/dev/null 2>&1; then
    CT=docker
else
    echo "ERROR: neither podman nor docker found" >&2
    exit 1
fi

rm -rf out
mkdir -p out

# -- prep phase: submodules + gates + lunx patches ---------------------------
bash tools/lunx-patches.sh

# -- GE's configure.sh is bash >= 4 (uses ${var,,}); pick a modern bash -------
ge_pick_bash4() {
    local c
    for c in /opt/homebrew/bin/bash /usr/local/bin/bash /opt/local/bin/bash /bin/bash; do
        if [ -x "${c}" ] && "${c}" -c 'exit $((BASH_VERSINFO[0] < 4))' 2>/dev/null; then
            printf '%s\n' "${c}"; return 0
        fi
    done
    return 1
}
GE_BASH="$(ge_pick_bash4)" || {
    echo "ERROR: GE configure.sh needs bash >= 4 (uses \${var,,}); none found on this runner" >&2
    exit 1; }
echo "==> proton-lunx: GE configure.sh interpreter: ${GE_BASH}"

# -- GE build (configure in a subdir; GE forbids top-level in-tree builds) ---
GE_BUILD="${REPO_ROOT}/build"
rm -rf "${GE_BUILD}"
mkdir -p "${GE_BUILD}"
# GE's configure.sh defaults --target-arch to x86_64 and resolves THAT arch's
# toolchain image to probe the container engine (configure.sh:124-133). We
# build arm64 (make redist TARGET_ARCH=arm64 below), so configure must match.
# DOCKER_DEFAULT_PLATFORM is pinned so the probe's `[ "$inner_uid" -eq 0 ]`
# (which captures 2>&1) survives the platform-mismatch warning on an x86_64
# host's binfmt emulation; on a native arm64 host it is a harmless no-op.
( cd "${GE_BUILD}" && \
    DOCKER_DEFAULT_PLATFORM="linux/arm64" \
    "${GE_BASH}" "${REPO_ROOT}/configure.sh" \
      --build-name="${VERSION}" \
      --target-arch=arm64 \
      --container-engine="${CT}" )
# The toolchain image is arm64; on an x86_64 runner docker needs binfmt for it.
# GE's Makefile re-enters make INSIDE the steamrt container for redist, and
# $(MAKE) auto-expands to the HOST make's absolute path (on macOS that is the
# Xcode path, which does not exist in the Linux container). Override MAKE=make
# so the container resolves its own make via PATH.
# GE's .DEFAULT redist (Makefile.in:1804-1807) re-enters make inside the
# steamrt container forwarding `-j$(J) $(filter -j%,$(MAKEFLAGS))`. A host `-jN`
# opens a jobserver and MAKEFLAGS then carries a BARE `-j` + --jobserver-fds,
# which the container cannot honor -> `-j0 forced` (unlimited) -> the 44k-glyph
# msyh.ttf otf2ttf step exhausted the container. So run the HOST make with no
# -j at all (no jobserver -> nothing leaks) and pin J=4, which overrides GE's
# `J := $(shell nproc)`; the container make then gets `-j4`, bounded.
( cd "${GE_BUILD}" && make -s J=4 TARGET_ARCH=arm64 MAKE=make SUPPRESS_WARNINGS=1 redist )

# -- repackage the GE redist tarball as the lunx artifact --------------------
GE_TARBALL="${GE_BUILD}/${VERSION}.tar.gz"
[ -f "${GE_TARBALL}" ] || { echo "ERROR: GE redist produced no ${GE_TARBALL}" >&2; exit 1; }
# compatibilitytools.d tarball: the top-level dir inside is the version name.
tar --zstd -cf "${REPO_ROOT}/out/proton-lunx-${VERSION}.tar.zst" -C "${GE_BUILD}" "${VERSION}"
echo "==> proton-lunx: repackaged GE redist as out/proton-lunx-${VERSION}.tar.zst"

# -- artifact gate: the plugin must actually be in the tarball ---------------
tar -tzf "${GE_TARBALL}" | grep -q \
    "${VERSION}/files/lib/aarch64-linux-gnu/alsa-lib/libasound_module_pcm_pipewire.so" || {
    echo "ERROR: redist tarball is missing the aarch64 pipewire-alsa plugin" >&2
    exit 1; }
echo "==> proton-lunx: aarch64 pipewire-alsa plugin present in the tarball"

echo "built: ${REPO_ROOT}/out/proton-lunx-${VERSION}.tar.zst"
