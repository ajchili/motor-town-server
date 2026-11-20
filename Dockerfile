# syntax=docker/dockerfile:1.7
# Motor Town: Behind The Wheel dedicated server (Windows build) running under
# GE-Proton on Linux. Multi-arch: builds natively for the host by default.
#
#   linux/amd64  x86_64 GE-Proton + 64-bit steamcmd. For real x86_64 hosts.
#   linux/arm64  aarch64 GE-Proton, which bundles FEX as Wine's ARM64EC/WoW64
#                emulator, so the x86_64 Windows server is translated inside
#                Wine. Plus Valve's native linuxarm64 steamcmd. For Apple
#                Silicon and other ARM hosts.
#
# Don't run the amd64 image on Apple Silicon: Docker Desktop's x86 emulation
# can't run Wine (Rosetta: AVX signal-frame assertion; QEMU: Wine's fixed mmap
# aborts and steamcmd crashes).
#
# Two targets:
#   compose (default)  for docker compose; see compose.yaml
#   panel              for Calagopus/Pterodactyl/Pelican; see egg-motor-town.json
#
# Layout: the big downloads (Proton, steamcmd) each live in their own stage that
# depends only on its version ARG and the target arch, so changing runtime
# packages, the entrypoint, or anything else in the final stage never
# re-downloads them.

# Pinned by digest so a rebuild gets the same base. To update:
#   docker buildx imagetools inspect debian:trixie-slim   (the "Digest:" line)
ARG DEBIAN_IMAGE=debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

# ---------------------------------------------------------------------------
# Shared minimal downloader base (curl only)
FROM ${DEBIAN_IMAGE} AS fetch
ARG TARGETARCH
RUN --mount=type=cache,id=apt-cache-${TARGETARCH},target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lib-${TARGETARCH},target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl

# ---------------------------------------------------------------------------
# GE-Proton: rebuilt only when GE_PROTON_VERSION (or the arch) changes. The
# tarball is also kept in a BuildKit cache mount, so even a forced rebuild
# skips the download.
#
# The checksums are pinned here rather than fetched next to the tarball: a
# .sha512sum from the same release would only catch a broken download, not a
# replaced release. When changing GE_PROTON_VERSION, take both values from that
# release's GE-Proton*-x86_64.sha512sum and GE-Proton*-aarch64.sha512sum.
FROM fetch AS proton
ARG TARGETARCH
ARG GE_PROTON_VERSION=GE-Proton11-11
ARG GE_PROTON_SHA512_X86_64=45721a7b625b2404d8896bb5e2a8b87fc9623a394873a6dd6b900c839681d5c01ec694ca00d003fc9c733c5f6c5648af8171985656f9fa47e20999fbebdbe235
ARG GE_PROTON_SHA512_AARCH64=4863f86773514ce7cc2c7867d393b725fcd9e32f7948a3b4035ae67a84b3e0ff4b179c479079a0dcf141c159faa19f67e7b82b3ed4c4b0ef9720226d55594661
RUN --mount=type=cache,target=/downloads \
    set -eux; \
    case "$TARGETARCH" in \
      amd64) arch=x86_64;  sha="$GE_PROTON_SHA512_X86_64" ;; \
      arm64) arch=aarch64; sha="$GE_PROTON_SHA512_AARCH64" ;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    name="${GE_PROTON_VERSION}-${arch}.tar.gz"; \
    cd /downloads; \
    if ! echo "$sha  $name" | sha512sum -c --status 2>/dev/null; then \
      curl -fSLo "$name" "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${GE_PROTON_VERSION}/${name}"; \
      echo "$sha  $name" | sha512sum -c; \
    fi; \
    mkdir -p /opt/proton; \
    tar -xzf "$name" -C /opt/proton --strip-components=1

# ---------------------------------------------------------------------------
# steamcmd (it self-updates at runtime, so this rarely needs rebuilding).
# The documented steamcmd_linux.tar.gz still ships a 2017 bootstrapper that can
# no longer bootstrap from Valve's current manifests: it silently exits 1, on
# real x86 hosts too. Instead we install Valve's current packages straight from
# the per-arch manifest (sha256-checked); see scripts/seed-steamcmd.sh.
# unzip is installed here, not in `fetch`, so the Proton stage stays cached.
FROM fetch AS steamcmd
ARG TARGETARCH
RUN --mount=type=cache,id=apt-cache-${TARGETARCH},target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lib-${TARGETARCH},target=/var/lib/apt,sharing=locked \
    apt-get install -y --no-install-recommends unzip
COPY --chmod=755 scripts/seed-steamcmd.sh /usr/local/bin/seed-steamcmd.sh
RUN case "$TARGETARCH" in \
      amd64) manifest=steam_cmd_linux ;; \
      arm64) manifest=steam_cmd_linuxarm64 ;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac \
 && seed-steamcmd.sh /opt/steamcmd "$manifest"

# ---------------------------------------------------------------------------
# Runtime base shared by both images: packages, Proton, the entrypoint.
FROM ${DEBIAN_IMAGE} AS runtime
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    PROTON_DIR=/opt/proton

# steamcmd is native 64-bit on both arches, so no i386 libraries are needed.
# Proton needs python3 and dlopens libvulkan at startup even for headless
# servers; xvfb gives Wine a display to talk to so it doesn't stall on headless
# hosts.
RUN --mount=type=cache,id=apt-cache-${TARGETARCH},target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lib-${TARGETARCH},target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl python3 procps tini locales-all \
      libfreetype6 libvulkan1 \
      xvfb xauth

# Wine/Proton reads /etc/machine-id, which slim images don't ship.
RUN tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id

# Big, rarely-changing payload first...
COPY --from=proton /opt/proton /opt/proton

# ...frequently-edited files last.
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
RUN ln -s entrypoint.sh /usr/local/bin/motortown

# Steam game/query port. Players can also reach the server through Steam's
# relays, so publishing it is optional.
EXPOSE 27015/udp

# Per-arch: which steamcmd client steamcmd.sh launches. Its default on x86 is
# the 32-bit client, which no longer works, so pick the 64-bit one.
FROM runtime AS base-amd64
ENV STEAM_PLATFORM=linux64

FROM runtime AS base-arm64
ENV STEAM_PLATFORM=linuxarm64

# ---------------------------------------------------------------------------
# Game panel image (Calagopus / Pterodactyl / Pelican): `--target panel`.
# Wings runs it as its own non-root UID with only /home/container mounted, so
# everything that persists lives there: game files, the steamcmd copy (it
# self-updates, so it must be writable), the Steam login token, the Wine
# prefix. The egg's startup command arrives in $STARTUP.
FROM base-${TARGETARCH} AS panel
ENV HOME=/home/container \
    USER=container \
    SERVER_DIR=/home/container \
    STEAMCMD_SEED=/opt/steamcmd \
    STEAMCMD_DIR=/home/container/steamcmd \
    WINEPREFIX=/home/container/.wine \
    DEDI_CONFIG=/home/container/DedicatedServerConfig.json
COPY --from=steamcmd /opt/steamcmd /opt/steamcmd
COPY --chmod=755 panel-entrypoint.sh /usr/local/bin/panel-entrypoint.sh
RUN useradd -m -d /home/container -s /bin/bash container
USER container
WORKDIR /home/container
# No `tini -g`: the stop signal must go only to the entrypoint, which asks the
# game to save and quit. Signalling the whole group also killed Xvfb, and Wine
# with it, before the game could save.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/panel-entrypoint.sh"]

# ---------------------------------------------------------------------------
# docker compose image (the default target, so it stays last).
FROM base-${TARGETARCH} AS compose
ARG PUID=1000
ARG PGID=1000
# steamcmd runs from a writable copy in the steam-data volume (it updates
# itself), so the container can run with a read-only root filesystem. Caches
# go to /tmp for the same reason.
ENV STEAM_HOME=/home/steam \
    STEAMCMD_SEED=/opt/steamcmd \
    STEAMCMD_DIR=/home/steam/.steam/steamcmd \
    XDG_CACHE_HOME=/tmp/cache \
    SERVER_DIR=/home/steam/server \
    STEAM_COMPAT_DATA_PATH=/home/steam/compatdata \
    STEAM_COMPAT_CLIENT_INSTALL_PATH=/home/steam/.steam/steam

RUN groupadd -g "$PGID" steam \
 && useradd -m -u "$PUID" -g steam -d "$STEAM_HOME" -s /bin/bash steam \
 && mkdir -p "$SERVER_DIR" "$STEAM_COMPAT_DATA_PATH" "$STEAM_COMPAT_CLIENT_INSTALL_PATH" \
 && chown -R steam:steam "$STEAM_HOME"
COPY --from=steamcmd /opt/steamcmd /opt/steamcmd

USER steam
WORKDIR /home/steam

# Game files, Steam login cache (steamcmd keeps config/config.vdf under
# ~/.steam/steam, so Steam Guard is only needed once), Wine prefix
VOLUME ["/home/steam/server", "/home/steam/.steam", "/home/steam/compatdata"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["start"]
