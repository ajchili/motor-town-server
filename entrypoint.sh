#!/usr/bin/env bash
# Commands:
#   login   interactive steamcmd login (password + Steam Guard), caches the token
#   update  install/update the dedicated server with the cached login
#   start   update (unless SKIP_UPDATE=1) then run the server under Wine (default)
#   run     run the server without updating
# start/run take the server's command line as extra arguments, overriding
# SERVER_ARGS (the panel egg's startup command uses this).
#   shell   drop into bash
set -euo pipefail

STEAM_APP_ID="${STEAM_APP_ID:-2223650}"           # "Motor Town: Behind The Wheel - Dedicated Server" (what steamcmd downloads)
STEAM_GAME_APP_ID="${STEAM_GAME_APP_ID:-1369670}" # the base game; what the server must identify as to Steam
STEAM_BETA="${STEAM_BETA:-}"                      # e.g. "beta"
STEAM_BETA_PASSWORD="${STEAM_BETA_PASSWORD:-}"    # e.g. "motortowndedi"
# Login: the cached token is used when present. STEAM_PASS (and optionally a
# fresh STEAM_AUTH Steam Guard code) are for hosts without an interactive
# `login` step, like game panels; steamcmd also prompts for a missing Steam
# Guard code on the console.
STEAM_PASS="${STEAM_PASS:-}"
STEAM_AUTH="${STEAM_AUTH:-}"
SERVER_EXE="${SERVER_EXE:-}"                      # path relative to $SERVER_DIR; auto-detected if empty
# Defaults from the server's own RunDedicatedServer.bat
SERVER_ARGS="${SERVER_ARGS:-Jeju_World?listen? -server -log -useperfthreads}"
# Kept outside the game files so updates don't touch it; passed via -DediConfig.
DEDI_CONFIG="${DEDI_CONFIG:-/home/steam/config/DedicatedServerConfig.json}"
USE_XVFB="${USE_XVFB:-1}"
# On stop, the server gets SIGINT, which makes it save and quit. If it's still
# running this many seconds later, it gets SIGTERM. Keep it below the stop
# timeout of whatever stops the container (compose: stop_grace_period).
STOP_TIMEOUT="${STOP_TIMEOUT:-60}"
# Panel eggs expose updates as AUTO_UPDATE (1/0 or true/false).
case "${AUTO_UPDATE:-1}" in 0|false|False|FALSE|no) SKIP_UPDATE=1 ;; esac
# "wine" (default): run Proton's bundled Wine directly. "proton": `proton run`,
# which crashes this server at startup (EXCEPTION_ACCESS_VIOLATION at 0x28):
# it wires in Proton's Steam-client bridge, which expects a desktop Steam
# client that doesn't exist in a container.
LAUNCHER="${LAUNCHER:-wine}"
export WINEPREFIX="${WINEPREFIX:-$STEAM_COMPAT_DATA_PATH/pfx}"
export WINEDEBUG="${WINEDEBUG:--all}"
export PROTON_USE_XALIA=0   # Proton's controller-accessibility helper; crashes headless
WINE="$PROTON_DIR/files/bin/wine"

# Panel image: steamcmd self-updates, so it runs from a writable copy of the
# image's seed in the persistent server folder.
seed_steamcmd() {
  if [[ -n "${STEAMCMD_SEED:-}" && ! -x "$STEAMCMD_DIR/steamcmd.sh" ]]; then
    echo "Copying steamcmd to $STEAMCMD_DIR..."
    mkdir -p "$STEAMCMD_DIR"
    cp -a "$STEAMCMD_SEED/." "$STEAMCMD_DIR/"
  fi
}

steamcmd() { seed_steamcmd; "$STEAMCMD_DIR/steamcmd.sh" "$@"; }

require_user() {
  if [[ -z "${STEAM_USER:-}" ]]; then
    echo "STEAM_USER is not set. The server files are only given to accounts that own Motor Town." >&2
    return 1
  fi
}

do_login() {
  require_user || return 1
  echo "Logging in as $STEAM_USER. steamcmd will prompt for your password and Steam Guard code."
  echo "The session token is cached in the steam-data volume, so later updates won't prompt."
  steamcmd +login "$STEAM_USER" +quit
}

# Quote a value for a steamcmd script line. steamcmd has no escape for '"'.
steam_quote() {
  if [[ "$1" == *'"'* || "$1" == *$'\n'* ]]; then
    echo "Steam login values can't contain double quotes or newlines." >&2
    return 1
  fi
  printf '"%s"' "$1"
}

do_update() {
  require_user || return 1
  local user pass="" guard="" dir beta=""
  user="$(steam_quote "$STEAM_USER")" || return 1
  dir="$(steam_quote "$SERVER_DIR")" || return 1
  if [[ -n "$STEAM_PASS" ]]; then pass=" $(steam_quote "$STEAM_PASS")" || return 1; fi
  if [[ -n "$STEAM_AUTH" ]]; then guard="$(steam_quote "$STEAM_AUTH")" || return 1; fi
  if [[ -n "$STEAM_BETA" ]]; then
    beta=" -beta $(steam_quote "$STEAM_BETA")" || return 1
    if [[ -n "$STEAM_BETA_PASSWORD" ]]; then
      beta+=" -betapassword $(steam_quote "$STEAM_BETA_PASSWORD")" || return 1
    fi
  fi
  # The commands go through a script file rather than steamcmd's command line,
  # where the password would show in `ps` inside the container and on the host.
  # mktemp creates it readable only by us; it's removed as soon as steamcmd exits.
  local script status=0
  script="$(mktemp "${TMPDIR:-/tmp}/steamcmd.XXXXXX")"
  {
    # Exit non-zero when a command fails (a failed login or download), so a
    # failed update is noticed; steamcmd otherwise exits 0 regardless.
    echo '@ShutdownOnFailedCommand 1'
    # Force Windows depots: there is no Linux build of the server.
    echo '@sSteamCmdForcePlatformType windows'
    echo "force_install_dir $dir"
    if [[ -n "$guard" ]]; then echo "set_steam_guard_code $guard"; fi
    echo "login $user$pass"
    echo "app_update $STEAM_APP_ID$beta validate"
    echo 'quit'
  } > "$script"
  steamcmd +runscript "$script" || status=$?
  rm -f "$script"
  return "$status"
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

# Fill in keys missing from the config with the server's own sample, so a
# config that holds only a few keys (as a panel writes it) still gets every
# setting. Existing values are never changed, except that values whose sample
# is a string are turned back into strings (a panel writes a numeric password
# as a number). Keys taken from the sample are made safe first: the Host Web
# API stays off and the sample's placeholder admins are dropped.
merge_sample_config() {
  local sample="$SERVER_DIR/DedicatedServerConfig_Sample.json"
  [[ -f "$sample" ]] || return 0
  python3 -I - "$sample" "$DEDI_CONFIG" <<'PY'
import json, os, sys
sample_path, config_path = sys.argv[1], sys.argv[2]
with open(sample_path, encoding="utf-8-sig") as f:
    sample = json.load(f)
config = {}
if os.path.exists(config_path):
    try:
        with open(config_path, encoding="utf-8-sig") as f:
            config = json.load(f)
    except ValueError as e:
        print(f"Config: {config_path} is not valid JSON ({e}); leaving it as is", file=sys.stderr)
        sys.exit(0)
if not isinstance(sample, dict) or not isinstance(config, dict):
    print(f"Config: {config_path} or the sample isn't a JSON object; leaving it as is", file=sys.stderr)
    sys.exit(0)
safe = {
    "bEnableHostWebAPIServer": False,
    "HostWebAPIServerPassword": "",
    "Admins": [],
    "PoliceRolePlayers": [],
    "Password": "",
}
added = []
retyped = []
for key, value in sample.items():
    if key not in config:
        config[key] = safe.get(key, value)
        added.append(key)
    elif isinstance(value, str) and isinstance(config[key], (int, float)) and not isinstance(config[key], bool):
        config[key] = str(config[key])
        retyped.append(key)
if added or retyped or not os.path.exists(config_path):
    os.makedirs(os.path.dirname(config_path) or ".", exist_ok=True)
    with open(config_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
        f.write("\n")
    if added:
        print(f"Config: added {len(added)} default keys from the sample to {config_path}")
    if retyped:
        print(f"Config: stored {', '.join(retyped)} as text, as the server expects")
PY
}

# A virtual display for Wine, run directly rather than through xvfb-run so the
# stop signal reaches the game instead of a wrapper script, and the display
# stays up until the game has finished saving (otherwise Wine dies with
# "XIO: fatal IO error" the moment the display goes away).
XVFB_PID=""
start_xvfb() {
  local display_file
  display_file="$(mktemp "${TMPDIR:-/tmp}/xvfb-display.XXXXXX")"
  Xvfb -displayfd 3 -screen 0 1024x768x24 -nolisten tcp 3>"$display_file" >/dev/null 2>&1 &
  XVFB_PID=$!
  local _
  for _ in $(seq 1 100); do
    [[ -s "$display_file" ]] && break
    kill -0 "$XVFB_PID" 2>/dev/null || break
    sleep 0.1
  done
  if [[ ! -s "$display_file" ]]; then
    rm -f "$display_file"
    echo "Xvfb failed to start." >&2
    return 1
  fi
  export DISPLAY=":$(tr -dc '0-9' < "$display_file")"
  rm -f "$display_file"
}

stop_xvfb() {
  if [[ -n "$XVFB_PID" ]]; then
    kill "$XVFB_PID" 2>/dev/null || true
    wait "$XVFB_PID" 2>/dev/null || true
    XVFB_PID=""
  fi
}

# Signal handler while the server runs: the first TERM/INT asks it to save and
# quit, and starts a watchdog that forces it after STOP_TIMEOUT. A second
# signal forces it right away.
SERVER_PID=""
WATCHDOG_PID=""
stop_server() {
  [[ -n "$SERVER_PID" ]] || return 0
  if [[ -n "$WATCHDOG_PID" ]]; then
    echo "Stopping now (SIGTERM)."
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    return 0
  fi
  echo "Stopping: asking the server to save and quit (forced after ${STOP_TIMEOUT}s)..."
  kill -INT "$SERVER_PID" 2>/dev/null || true
  (
    sleep "$STOP_TIMEOUT"
    if kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "Server still running after ${STOP_TIMEOUT}s; stopping it (SIGTERM)."
      kill -TERM "$SERVER_PID" 2>/dev/null || true
    fi
  ) &
  WATCHDOG_PID=$!
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

  # The Steam login is only for steamcmd. Wine copies the environment into the
  # Windows process, where the game, anything it starts, and its crash reports
  # (which include memory dumps) could read it, so drop it before launching.
  unset STEAM_USER STEAM_PASS STEAM_AUTH

  # Steam API reads steam_appid.txt next to the binary when not launched by
  # Steam. It must hold the base game's app ID, not the dedicated server's
  # download ID, or the server never finishes "Creating Session..".
  echo "$STEAM_GAME_APP_ID" > "$(dirname "$exe")/steam_appid.txt"

  # Split SERVER_ARGS on spaces without glob expansion ("Jeju_World?listen?"
  # contains '?', which bash would otherwise treat as a filename wildcard).
  local args
  if [[ $# -gt 0 ]]; then
    args=("$@")
  else
    set -f
    # shellcheck disable=SC2206
    args=($SERVER_ARGS)
    set +f
  fi
  merge_sample_config
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

  if [[ "$USE_XVFB" == "1" ]]; then
    start_xvfb
  fi

  local cmd
  if [[ "$LAUNCHER" == "proton" ]]; then
    # Note: the stop signal then goes to Proton's Python script, not the game.
    cmd=("$PROTON_DIR/proton" run "$exe" "${args[@]}")
  else
    if [[ ! -f "$WINEPREFIX/system.reg" ]]; then
      echo "Creating Wine prefix in $WINEPREFIX (first run only)..."
      "$WINE" wineboot -i >/dev/null 2>&1 || true
    fi
    # steam_api64.dll finds the Steam client library through this registry key.
    # A prefix that Proton ever touched points it at Proton's Steam bridge in
    # C:\Program Files (x86)\Steam, which is empty without a desktop Steam client,
    # so steamclient64.dll never loads and the server hangs at "Creating
    # Session..". Point it at the game server's own copy on every start.
    local steamclient_win="Z:${SERVER_DIR//\//\\}\\steamclient64.dll"
    if [[ -f "$SERVER_DIR/steamclient64.dll" ]]; then
      local key='HKCU\Software\Valve\Steam\ActiveProcess' name value reg_ok=1
      for name in SteamClientDll64 SteamClientDll SteamPath; do
        case "$name" in
          SteamClientDll64) value="$steamclient_win" ;;
          SteamClientDll)   value="Z:${SERVER_DIR//\//\\}\\steamclient.dll" ;;
          SteamPath)        value="Z:${SERVER_DIR//\//\\}" ;;
        esac
        if ! "$WINE" reg add "$key" /v "$name" /d "$value" /f >/dev/null 2>&1; then
          echo "Warning: couldn't set $name in the Wine registry; Steam session creation will likely hang." >&2
          reg_ok=0
        fi
      done
      if [[ "$reg_ok" == 1 ]]; then echo "Steam client library: $steamclient_win"; fi
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
    seed_steamcmd   # also when updates are skipped
    if [[ -f "$STEAMCMD_DIR/$plat/steamclient.so" ]]; then
      mkdir -p "$HOME/.steam"
      ln -sfn "$STEAMCMD_DIR/$plat" "$HOME/.steam/$sdk"
      echo "Linux Steam client for Proton bridge: ~/.steam/$sdk -> $STEAMCMD_DIR/$plat"
    else
      echo "Warning: $STEAMCMD_DIR/$plat/steamclient.so not found; Steam session creation will likely hang." >&2
    fi
    # The wine loader becomes the game process (same PID), so signals sent to
    # this PID reach the game itself.
    cmd=("$WINE" "$exe" "${args[@]}")
  fi

  "${cmd[@]}" &
  SERVER_PID=$!
  # docker stop / the panel's stop / Ctrl-C arrive here via tini.
  trap stop_server TERM INT
  # tail exits on its own when the server process does.
  tail -n +1 -F --pid="$SERVER_PID" "$logfile" 2>/dev/null &
  local status=0
  wait "$SERVER_PID" || status=$?
  # wait returns early when a trapped signal arrives; wait again for the real exit.
  while kill -0 "$SERVER_PID" 2>/dev/null; do
    status=0
    wait "$SERVER_PID" || status=$?
  done
  trap - TERM INT
  if [[ -n "$WATCHDOG_PID" ]]; then kill "$WATCHDOG_PID" 2>/dev/null || true; fi
  stop_xvfb
  echo "Server exited with status $status"
  return "$status"
}

do_start() {
  if [[ "${SKIP_UPDATE:-0}" != "1" ]]; then
    if ! do_update; then
      # A failed update (Steam down, expired login) shouldn't keep an already
      # installed server offline.
      if [[ -n "$(find_exe)" ]]; then
        echo "Update failed; starting the installed server anyway." >&2
      else
        echo "Update failed and no server is installed yet." >&2
        exit 1
      fi
    fi
  fi
  do_run "$@"
}

cmd="${1:-start}"
[[ $# -gt 0 ]] && shift
case "$cmd" in
  login)  do_login ;;
  update) do_update ;;
  start)  do_start "$@" ;;
  run)    do_run "$@" ;;
  shell)  exec bash ;;
  *)      exec "$cmd" "$@" ;;
esac
