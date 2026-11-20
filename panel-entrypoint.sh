#!/usr/bin/env bash
# Entrypoint for game panels (Calagopus, Pterodactyl, Pelican). Wings passes the
# egg's startup command in $STARTUP with {{VARIABLE}} placeholders; turn those
# into ${VARIABLE} and run the result, the same way Pterodactyl's yolk images do.
set -euo pipefail
cd /home/container

# Wings runs the container as its own UID, which has no passwd entry unless the
# node enables passwd mounting. Nothing here needs one, but keep HOME and USER
# pointing at the server folder either way.
export HOME=/home/container USER="${USER:-container}"

startup="$(printf '%s' "${STARTUP:-motortown start}" | sed -e 's/{{\([A-Za-z0-9_]*\)}}/${\1}/g')"
printf '\033[1;33mcontainer@calagopus~ \033[0m%s\n' "$startup"

# No globbing: the map URL "Jeju_World?listen?" contains '?' wildcards.
set -f
eval "exec $startup"
