#!/usr/bin/env bash
# tools/lunx-patches.sh — the lunx tree-prep phase for the fork's GE tree.
#
# This is the fork's equivalent of the prep/gate section of the lunx-base
# package recipe (packages/proton-lunx/pkg/build.sh). The GitHub Actions
# workflow (_job_build.yml, "Patch" step) runs it after checkout and before
# configure/make. Idempotent — safe to re-run on a retried step.
#
# The fork's repo root IS the GE-Proton11-4 tree at the pinned commit
# (7855e7f, see source.env), committed as the fork's root commit. So unlike the
# lunx-base package there is no separate "carried patches" dir to prove
# byte-identical — the tree's own patches/ are the pinned bytes. The lunx
# additions here are:
#   patches/wine/0001-winedmo-pcm-byte-order-reverse-bsf-ffmpeg8.patch
#       (the ffmpeg >= 7.0 BSF port for winedmo, applied to the wine submodule)
#   patches/proton-ds5-haptic/0130-winepulse-gate-sony-haptic-retarget-to-matching-endpoint.patch
#       (the locally-authored US-82 follow-on, committed directly into the
#       tree's proton-ds5-haptic/ dir so GE's sorted-glob patch apply picks it
#       up after 0118)
#   patches/pipewire/0001-alsa-pcm-support-aux-channel-map.patch
#       (already ships in the GE tree at the pin; committed copy is provenance)
#
# Author: Pedro Nascimento <pnascimento@gmail.com>
set -euxo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
REPO_ROOT="${PWD}"

source ./source.env
: "${VERSION:?source.env must set VERSION}"
: "${GE_COMMIT:?source.env must set GE_COMMIT}"

[ -f configure.sh ] && [ -f Makefile.in ] && [ -d make ] || {
    echo "ERROR: repo root is not a GE tree (missing configure.sh/Makefile.in/make)" >&2
    exit 1; }

# -- fetch ALL submodules at their pinned gitlinks, shallow ------------------
# SUBMODULE RULE (user rule): every fetch here is shallow (--depth 1), never a
# full clone. Wine in particular is multi-GB full; the shallow fetch at the
# pinned gitlink is what keeps this buildable at all.
# sourceware.org (the bzip2 submodule's host) rate-limits anonymous clones
# (HTTP 429) and is chronically hot on the runner's IP. Point bzip2 at a GitHub
# mirror that carries the exact pinned commit 6a8690f (genotrance/bzip2,
# verified) so the fetch never depends on sourceware's rate window. A
# submodule.<name>.url in .git/config overrides .gitmodules for
# `git submodule update`. The backoff retry below stays as the insurance net
# for the OTHER submodule hosts.
SUB_RETRIES=5
sub_ok=""
for i in $(seq 1 "${SUB_RETRIES}"); do
    git config submodule.bzip2.url https://github.com/genotrance/bzip2.git
    if git submodule update --init --depth 1 --recursive --force; then
        sub_ok=1
        break
    fi
    echo "WARN: proton-lunx: submodule fetch attempt ${i}/${SUB_RETRIES} failed (likely the sourceware bzip2 429 rate limit) — backing off" >&2
    sleep "$((i * 10))"
done
[ -n "${sub_ok}" ] || {
    echo "ERROR: proton-lunx: submodule fetch failed ${SUB_RETRIES}/${SUB_RETRIES} attempts — sourceware 429 not clearing" >&2
    exit 1; }

# -- 0130 follow-on is committed directly into the tree's patches dir --------
# (no build-time inject needed, unlike the lunx-base package where it lived in
# a separate carried dir). GE's sorted-glob patch apply (patches/protonprep-
# valve-staging.sh, run inside `make redist`) picks it up after 0118.
[ -f patches/proton-ds5-haptic/0130-*.patch ] || {
    echo "ERROR: proton-lunx: 0130 follow-on missing from patches/proton-ds5-haptic/" >&2
    exit 1; }

# -- proton-script wiring gate ----------------------------------------------
# The script at the pin must resolve PROTON_PIPEWIRE_ALSA_PLUGIN to
# files/lib/aarch64-linux-gnu/alsa-lib/libasound_module_pcm_pipewire.so for
# host_pe_arch == aarch64-windows, and the GE Makefile must install the plugin
# at exactly that path. A future rebase that breaks either half fails here.
grep -q 'host_pe_arch == "aarch64-windows"' proton
grep -q 'aarch64-linux-gnu' proton
grep -q 'libasound_module_pcm_pipewire.so' proton
grep -q 'pipewire-alsa-aarch64' Makefile.in
grep -q '$(aarch64-unix_LIBDIR)/alsa-lib' Makefile.in
grep -q 'aarch64-unix_LIBDIR := aarch64-linux-gnu' make/rules-common.mk
echo "==> proton-lunx: proton-script wiring gate passed (aarch64 plugin path is wired)"

# -- FEX describe gate: make GE's two FEX `git describe` calls --always ------
# GE's Makefile.in stamps FEX's version via
#   git -C $(SRCDIR)/FEX describe --abbrev=7 > $(FEX_SRC)/.git_describe
# (Makefile.in:996, and :1008 for fex_unixlib) with NO fallback. Under the
# SUBMODULE RULE depth-1 fetch the FEX clone carries no tags and no upstream
# tag points at the pinned commit, so `git describe` exits 128 and the
# container `make redist` dies at .fex-post-source. GE guards every OTHER
# submodule's describe with --always; FEX's two are the only unguarded sites.
# Add --always so the stamp is the abbreviated commit SHA instead of a tag
# string. This edits the tree's Makefile.in; the two grep gates below prove it
# landed exactly twice, so a GE rebase that moves these lines fails loudly.
GE_MAKEFILE="Makefile.in"
sed 's|git -C $(SRCDIR)/FEX describe --abbrev=7|git -C $(SRCDIR)/FEX describe --always --abbrev=7|g' \
    "${GE_MAKEFILE}" > "${GE_MAKEFILE}.fexdesc" \
    && mv "${GE_MAKEFILE}.fexdesc" "${GE_MAKEFILE}"
[ "$(grep -c 'git -C $(SRCDIR)/FEX describe --always --abbrev=7' "${GE_MAKEFILE}")" = "2" ] || {
    echo "ERROR: proton-lunx: FEX describe --always substitution did not land (exactly 2 sites expected) — did a GE rebase move Makefile.in:996/1008?" >&2
    exit 1; }
[ "$(grep -c 'git -C $(SRCDIR)/FEX describe --abbrev=7' "${GE_MAKEFILE}")" = "0" ] || {
    echo "ERROR: proton-lunx: an unguarded FEX describe line remains in Makefile.in — substitution incomplete" >&2
    exit 1; }
echo "==> proton-lunx: FEX describe is --always (shallow-submodule safe; Makefile.in:996+1008 rewritten)"

# -- wine/ffmpeg compat: port winedmo's BSF to the ffmpeg >= 7.0 API ---------
# Wine @36078f5 vendors dlls/winedmo/libavcodec/pcm_byte_order_reverse_bsf.c
# written against the PRE-7.0 BSF API, which does not compile against GE's
# ffmpeg 8.1 pin (@9047fa1). GE itself ports this file in
# patches/ge-video-rework/0001-* via protonprep; the lunx build does not run
# protonprep, so we carry GE's proven WineFFBitStreamFilter port here as a
# patch and apply it idempotently.
# Idempotent: reverse-check first so retries skip cleanly; hard-fail if the
# patch neither applies nor reverses (a wine rebase that changed these files).
# Absolute path from REPO_ROOT: `git -C wine apply` resolves its patch path
# RELATIVE TO THE WINE SUBMODULE, not the repo root — a relative
# "patches/wine/..." here was the run-32583142395 failure
# ("can't open patch ... : No such file or directory").
WINE_WINEDMO_PATCH="${REPO_ROOT}/patches/wine/0001-winedmo-pcm-byte-order-reverse-bsf-ffmpeg8.patch"
if git -C wine apply --reverse --check "${WINE_WINEDMO_PATCH}" 2>/dev/null; then
    echo "==> proton-lunx: winedmo BSF ffmpeg-8 port already applied (idempotent retry)"
elif git -C wine apply --check "${WINE_WINEDMO_PATCH}"; then
    git -C wine apply "${WINE_WINEDMO_PATCH}"
    echo "==> proton-lunx: winedmo BSF ported to ffmpeg >= 7.0 API"
else
    echo "ERROR: proton-lunx: winedmo BSF ffmpeg-8 port patch neither cleanly applied nor cleanly reversible" >&2
    exit 1
fi

# -- xrandr tarball pre-seed: GE's bare wget (Makefile.in:1517) has no retry
#    budget past wget's own --tries=20 default, and xorg.freedesktop.org
#    (www.x.org's redirect target) times out from the runner's IP. Pre-seed the
#    178K tarball into contrib/ (GE's own rule target, Makefile.in:1515,
#    $(SRC) == the GE tree) with a bounded backoff; GE's rule then finds the
#    file present and skips wget entirely. Best-effort: if all 5 tries fail we
#    let GE's own wget have its shot.
seed_xrandr() {
    local dst="contrib/xrandr-1.5.4.tar.xz" i
    [ -f "${dst}" ] && return 0
    mkdir -p contrib
    for i in 1 2 3 4 5; do
        if wget --no-use-server-timestamps -O "${dst}.part" \
                "https://xorg.freedesktop.org/archive/individual/app/xrandr-1.5.4.tar.xz" 2>/dev/null; then
            mv "${dst}.part" "${dst}"
            echo "==> proton-lunx: pre-seeded contrib/xrandr-1.5.4.tar.xz (178K)"
            return 0
        fi
        echo "WARN: proton-lunx: xrandr download attempt ${i}/5 failed (xorg.freedesktop.org) — backing off" >&2
        sleep "$((i * 10))"
    done
    rm -f "${dst}.part"
    echo "WARN: proton-lunx: xrandr pre-seed failed 5/5 — letting GE's own wget try" >&2
    return 0
}
seed_xrandr

echo "==> proton-lunx: tree prep complete (submodules + gates + patches)"
