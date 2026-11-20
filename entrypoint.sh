#!/usr/bin/env bash
# Commands:
#   login   interactive steamcmd login (password + Steam Guard), caches the token
#   update  install/update the dedicated server with the cached login
#   start   update (unless SKIP_UPDATE=1) then run the server under Wine (default)
#   run     run the server without updating
#   shell   drop into bash
set -euo pipefail

STEAM_APP_ID="${STEAM_APP_ID:-2223650}"           # "Motor Town: Behind The Wheel - Dedicated Server" (what steamcmd downloads)
STEAM_GAME_APP_ID="${STEAM_GAME_APP_ID:-1369670}" # the base game; what the server must identify as to Steam
STEAM_BETA="${STEAM_BETA:-}"                      # e.g. "beta"
STEAM_BETA_PASSWORD="${STEAM_BETA_PASSWORD:-}"    # e.g. "motortowndedi"
SERVER_EXE="${SERVER_EXE:-}"                      # path relative to $SERVER_DIR; auto-detected if empty
# Defaults from the server's own RunDedicatedServer.bat
SERVER_ARGS="${SERVER_ARGS:-Jeju_World?listen? -server -log -useperfthreads}"
# Kept outside the game files so updates don't touch it; passed via -DediConfig.
DEDI_CONFIG="${DEDI_CONFIG:-/home/steam/config/DedicatedServerConfig.json}"
USE_XVFB="${USE_XVFB:-1}"
# "wine" (default): run Proton's bundled Wine directly. "proton": `proton run`,
# which crashes this server at startup (EXCEPTION_ACCESS_VIOLATION at 0x28):
# it wires in Proton's Steam-client bridge, which expects a desktop Steam
# client that doesn't exist in a container.
LAUNCHER="${LAUNCHER:-wine}"
export WINEPREFIX="${WINEPREFIX:-$STEAM_COMPAT_DATA_PATH/pfx}"
export WINEDEBUG="${WINEDEBUG:--all}"
export PROTON_USE_XALIA=0   # Proton's controller-accessibility helper; crashes headless
WINE="$PROTON_DIR/files/bin/wine"

steamcmd() { "$STEAMCMD_DIR/steamcmd.sh" "$@"; }

require_user() {
  if [[ -z "${STEAM_USER:-}" ]]; then
    echo "STEAM_USER is not set. The server files are only given to accounts that own Motor Town." >&2
    exit 1
  fi
}

do_login() {
  require_user
  echo "Logging in as $STEAM_USER. steamcmd will prompt for your password and Steam Guard code."
  echo "The session token is cached in the steam-data volume, so later updates won't prompt."
  steamcmd +login "$STEAM_USER" +quit
}

do_update() {
  require_user
  local beta_args=()
  if [[ -n "$STEAM_BETA" ]]; then
    beta_args+=(-beta "$STEAM_BETA")
    [[ -n "$STEAM_BETA_PASSWORD" ]] && beta_args+=(-betapassword "$STEAM_BETA_PASSWORD")
  fi
  # Force Windows depots: there is no Linux build of the server.
  steamcmd \
    +@sSteamCmdForcePlatformType windows \
    +force_install_dir "$SERVER_DIR" \
    +login "$STEAM_USER" \
    +app_update "$STEAM_APP_ID" "${beta_args[@]}" validate \
    +quit
}

find_exe() {
  if [[ -n "$SERVER_EXE" ]]; then
    echo "$SERVER_DIR/$SERVER_EXE"
    return
  fi
  # UE server builds live under <Project>/Binaries/Win64/*Server*-Win64-Shipping.exe
  local found
  found="$(find "$SERVER_DIR" -path '*Binaries/Win64/*' -iname '*server*.exe' 2>/dev/null | sort | head -n1 || true)"
  if [[ -z "$found" ]]; then
    found="$(find "$SERVER_DIR" -maxdepth 1 -iname '*server*.exe' 2>/dev/null | head -n1 || true)"
  fi
  echo "$found"
}

do_run() {
  local exe
  exe="$(find_exe)"
  if [[ -z "$exe" || ! -f "$exe" ]]; then
    echo "Could not find the server executable under $SERVER_DIR." >&2
    echo "Install it with the 'update' command, or set SERVER_EXE (see ReadMe.txt in the server files)." >&2
    echo "Executables found:" >&2
    find "$SERVER_DIR" -iname '*.exe' 2>/dev/null | sed "s|^$SERVER_DIR/|  |" >&2 || true
    exit 1
  fi

  # Steam API reads steam_appid.txt next to the binary when not launched by
  # Steam. It must hold the base game's app ID, not the dedicated server's
  # download ID, or the server never finishes "Creating Session..".
  echo "$STEAM_GAME_APP_ID" > "$(dirname "$exe")/steam_appid.txt"

  # Split SERVER_ARGS on spaces without glob expansion ("Jeju_World?listen?"
  # contains '?', which bash would otherwise treat as a filename wildcard).
  local args
  set -f
  # shellcheck disable=SC2206
  args=($SERVER_ARGS)
  set +f
  if [[ -f "$DEDI_CONFIG" ]]; then
    # Wine maps the Linux root to drive Z:
    args+=("-DediConfig=Z:${DEDI_CONFIG//\//\\}")
  else
    echo "No config at $DEDI_CONFIG; the server will use DedicatedServerConfig.json from the game folder or built-in defaults." >&2
  fi

  # The Shipping build doesn't write Unreal's usual Saved/Logs file and Wine
  # doesn't relay its console, but the game writes its own server log, so
  # follow that. <Project>/Binaries/Win64/x.exe -> <Project>/Saved/ServerLog
  local logfile
  logfile="$(cd "$(dirname "$exe")/../.." && pwd)/Saved/ServerLog/motortown.log"
  mkdir -p "$(dirname "$logfile")"
  : > "$logfile"   # start each run with a fresh log so tail shows only this run

  echo "Launching ($LAUNCHER): $exe ${args[*]}"
  echo "Proton/Wine: $(cut -d' ' -f2 "$PROTON_DIR/version" 2>/dev/null || echo unknown)"
  echo "Following $logfile"
  # Run from the server root like RunDedicatedServer.bat does: the game
  # server's steamclient64.dll lives there, not next to the exe.
  cd "$SERVER_DIR"

  local cmd
  if [[ "$LAUNCHER" == "proton" ]]; then
    cmd=("$PROTON_DIR/proton" run "$exe" "${args[@]}")
  else
    if [[ ! -f "$WINEPREFIX/system.reg" ]]; then
      echo "Creating Wine prefix in $WINEPREFIX (first run only)..."
      xvfb-run --auto-servernum "$WINE" wineboot -i >/dev/null 2>&1 || true
    fi
    # steam_api64.dll finds the Steam client library through this registry key.
    # A prefix that Proton ever touched points it at Proton's Steam bridge in
    # C:\Program Files (x86)\Steam, which is empty without a desktop Steam client,
    # so steamclient64.dll never loads and the server hangs at "Creating
    # Session..". Point it at the game server's own copy on every start.
    local steamclient_win="Z:${SERVER_DIR//\//\\}\\steamclient64.dll"
    if [[ -f "$SERVER_DIR/steamclient64.dll" ]]; then
      local key='HKCU\Software\Valve\Steam\ActiveProcess'
      "$WINE" reg add "$key" /v SteamClientDll64 /d "$steamclient_win" /f >/dev/null 2>&1
      "$WINE" reg add "$key" /v SteamClientDll /d "Z:${SERVER_DIR//\//\\}\\steamclient.dll" /f >/dev/null 2>&1
      "$WINE" reg add "$key" /v SteamPath /d "Z:${SERVER_DIR//\//\\}" /f >/dev/null 2>&1
      echo "Steam client library: $steamclient_win"
    else
      echo "Warning: $SERVER_DIR/steamclient64.dll not found; Steam session creation will likely hang." >&2
    fi
    # Proton's Wine swaps that DLL for its lsteamclient bridge, which forwards
    # to a Linux steamclient.so at ~/.steam/sdk64 (x86_64) or ~/.steam/sdkarm64
    # (ARM64). steamcmd ships that same library, which works as a game server
    # without a desktop Steam client, so link steamcmd's client folder there.
    local sdk plat
    case "$(uname -m)" in
      aarch64) sdk=sdkarm64; plat=linuxarm64 ;;
      *)       sdk=sdk64;    plat=linux64 ;;
    esac
    if [[ -f "$STEAMCMD_DIR/$plat/steamclient.so" ]]; then
      mkdir -p "$HOME/.steam"
      ln -sfn "$STEAMCMD_DIR/$plat" "$HOME/.steam/$sdk"
      echo "Linux Steam client for Proton bridge: ~/.steam/$sdk -> $STEAMCMD_DIR/$plat"
    else
      echo "Warning: $STEAMCMD_DIR/$plat/steamclient.so not found; Steam session creation will likely hang." >&2
    fi
    cmd=("$WINE" "$exe" "${args[@]}")
  fi
  if [[ "$USE_XVFB" == "1" ]]; then
    cmd=(xvfb-run --auto-servernum --server-args="-screen 0 1024x768x24" "${cmd[@]}")
  fi

  "${cmd[@]}" &
  local pid=$!
  # Forward docker stop / Ctrl-C to the server (tini delivers them to us).
  trap 'kill -TERM "$pid" 2>/dev/null' TERM INT
  # tail exits on its own when the server process does.
  tail -n +1 -F --pid="$pid" "$logfile" 2>/dev/null &
  local status=0
  wait "$pid" || status=$?
  # wait returns early when a trapped signal arrives; wait again for the real exit.
  while kill -0 "$pid" 2>/dev/null; do wait "$pid" || status=$?; done
  echo "Server exited with status $status"
  return "$status"
}

case "${1:-start}" in
  login)  do_login ;;
  update) do_update ;;
  start)  [[ "${SKIP_UPDATE:-0}" == "1" ]] || do_update; do_run ;;
  run)    do_run ;;
  shell)  exec bash ;;
  *)      exec "$@" ;;
esac
