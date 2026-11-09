#!/usr/bin/env bash
# tv-tune.sh: speed up an Android TV and clean up its home screen over adb.
#
# Run it on a computer that is on the same Wi-Fi as the TV:
#   bash tv-tune.sh
#
# Works on macOS and Linux, and on Windows from Git Bash.
# It only changes things after you approve them. Apps are disabled with
# "pm disable-user --user 0" and are never uninstalled. Every change is
# logged, and an undo script is written next to the log.
#
# Written for the bash 3.2 that ships with macOS, so it avoids newer features.

set -u

PORT=5555
WORKDIR="$HOME/tv-tune"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$WORKDIR/changes-$STAMP.log"
UNDO="$WORKDIR/undo-$STAMP.sh"
AUDIT="$WORKDIR/audit-$STAMP.txt"
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t tvtune)"
trap 'rm -rf "$TMP"' EXIT

# FLauncher: open-source, ad-free Android TV launcher (gitlab.com/flauncher/flauncher).
FL_PKG="me.efesser.flauncher"
FL_URL="https://gitlab.com/api/v4/projects/26632151/packages/generic/flauncher/0.18.0/flauncher-0.18.0.apk"
FL_SHA256="376fc528c880cdf7c7c04b2d3708c69f911144498218babb6300808b772af32e"

ADB="adb"
TARGET="${TVTUNE_TARGET:-}"        # set to skip discovery, e.g. TVTUNE_TARGET=192.168.1.50
TTY="${TVTUNE_TTY:-/dev/tty}"
SETTLE="${TVTUNE_SETTLE:-90}"      # seconds to wait after boot before reading memory
BOOTWAIT="${TVTUNE_BOOTWAIT:-20}"
UNDO_CMDS=""   # newline-separated shell commands, newest first

# ---------------------------------------------------------------- helpers

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '\033[33m  ! %s\033[0m\n' "$*"; }
die()   { printf '\033[31m  x %s\033[0m\n' "$*"; exit 1; }
step()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

ask_yn() { # ask_yn "question" default(y|n)
  local q="$1" def="${2:-n}" ans hint="[y/N]"
  [ "$def" = y ] && hint="[Y/n]"
  printf '  %s %s ' "$q" "$hint"
  read -r ans <&7 || ans=""
  [ -z "$ans" ] && ans="$def"
  case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

tv() { "$ADB" -s "$TARGET" shell "$@" 2>&1 | tr -d '\r'; }

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

add_undo() { UNDO_CMDS="$1
$UNDO_CMDS"; }

# Run one change on the TV, log it, and remember how to undo it.
change() { # change "what" "command on tv" "undo command on tv"
  local what="$1" cmd="$2" undo="$3" out
  out="$("$ADB" -s "$TARGET" shell "$cmd" 2>&1 | tr -d '\r')"
  # The undo is recorded even if the command looks like it failed:
  # re-enabling an enabled app or restoring a setting's old value is harmless.
  add_undo "$undo"
  if printf '%s' "$out" | grep -qE 'Exception|Failure|^Error|Error:|Unknown (command|package)|not allowed|Cannot '; then
    log "FAIL  $what"
    log "      do:   $cmd"
    log "      out:  $out"
    warn "failed: $what ($out)"
  else
    log "OK    $what"
    log "      do:   $cmd"
    log "      undo: $undo"
    [ -n "$out" ] && log "      out:  $out"
    info "done: $what"
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# ---------------------------------------------------------------- 1. setup

detect_os() {
  case "$(uname -s)" in
    Darwin) OS=mac ;;
    Linux)  OS=linux ;;
    MINGW*|MSYS*|CYGWIN*) OS=windows ;;
    *) OS=unknown ;;
  esac
}

find_windows_adb() {
  local base="${LOCALAPPDATA:-}"
  [ -z "$base" ] && return 1
  base="$(cygpath -u "$base" 2>/dev/null || echo "$base")"
  local f
  for f in "$base"/Microsoft/WinGet/Packages/Google.PlatformTools*/platform-tools/adb.exe \
           "$base"/Android/Sdk/platform-tools/adb.exe; do
    [ -x "$f" ] && { ADB="$f"; return 0; }
  done
  return 1
}

setup_adb() {
  step "1. Setup"
  detect_os
  info "Computer: $OS"
  if command -v adb >/dev/null 2>&1; then
    info "adb is installed: $(adb version | head -1)"
    return
  fi
  [ "$OS" = windows ] && find_windows_adb && { info "adb found: $ADB"; return; }

  warn "adb is not installed."
  case "$OS" in
    mac)
      command -v brew >/dev/null 2>&1 || die "Homebrew is missing. Install it from https://brew.sh, then run this script again."
      info "Installing with Homebrew..."
      brew install --cask android-platform-tools || die "Homebrew install failed." ;;
    linux)
      command -v apt-get >/dev/null 2>&1 || die "apt is not available. Install adb with your package manager, then run this script again."
      info "Installing with apt (it may ask for your password)..."
      sudo apt-get update && sudo apt-get install -y adb || die "apt install failed." ;;
    windows)
      info "Installing with winget..."
      winget install --id Google.PlatformTools -e --accept-source-agreements --accept-package-agreements \
        || die "winget install failed."
      find_windows_adb || die "adb installed but not found yet. Close and reopen Git Bash, then run this script again." ;;
    *) die "Unknown system. Install Android platform-tools yourself, then run this script again." ;;
  esac
  command -v adb >/dev/null 2>&1 || [ "$ADB" != adb ] || die "adb still not found on PATH."
  info "adb installed."
}

# ---------------------------------------------------------------- 2. find TV

local_ip() {
  local ip=""
  case "$OS" in
    mac)
      local ifc; ifc="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
      [ -n "$ifc" ] && ip="$(ipconfig getifaddr "$ifc" 2>/dev/null)"
      [ -z "$ip" ] && ip="$(ipconfig getifaddr en0 2>/dev/null)" ;;
    linux)
      ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
      [ -z "$ip" ] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')" ;;
    windows)
      ip="$(ipconfig | tr -d '\r' | awk -F': ' '/IPv4/{print $2}' | grep -vE '^(127|169\.254)\.' | head -1)" ;;
  esac
  echo "$ip"
}

discover() {
  step "2. Finding your TV"
  : > "$TMP/found"

  info "Looking with mDNS..."
  "$ADB" mdns services 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+' >> "$TMP/mdns" || true
  if command -v avahi-browse >/dev/null 2>&1; then
    # _androidtvremote2 is advertised by Android/Google TVs; _adb by adb itself.
    for svc in _androidtvremote2._tcp _adb._tcp _adb-tls-connect._tcp; do
      avahi-browse -rtp "$svc" 2>/dev/null | awk -F';' '$1=="=" && $3=="IPv4"{print $8"|"$4}' >> "$TMP/names"
    done
  fi
  # mDNS adb entries on port 5555 count as found; others (wireless debugging) are listed too.
  grep -oE '^([0-9.]+)' "$TMP/mdns" 2>/dev/null >> "$TMP/found" || true
  cut -d'|' -f1 "$TMP/names" 2>/dev/null >> "$TMP/found" || true

  local me; me="$(local_ip)"
  if [ -n "$me" ]; then
    local net="${me%.*}"
    info "Scanning $net.1-254 for port $PORT (this computer is $me)..."
    : > "$TMP/scan"
    local i
    for i in $(seq 1 254); do
      { ( exec 3<>"/dev/tcp/$net.$i/$PORT" ) && echo "$net.$i" >> "$TMP/scan"; } </dev/null >/dev/null 2>&1 &
    done
    sleep 4
    kill $(jobs -p) 2>/dev/null; wait 2>/dev/null
    cat "$TMP/scan" >> "$TMP/found"
  else
    warn "Could not work out this computer's IP address; skipping the port scan."
  fi

  # Keep only hosts that really answer on port 5555.
  : > "$TMP/cands"
  local ip
  for ip in $(sort -u "$TMP/found" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'); do
    if grep -qx "$ip" "$TMP/scan" 2>/dev/null || ( exec 3<>"/dev/tcp/$ip/$PORT" ) 2>/dev/null; then
      echo "$ip" >> "$TMP/cands"
    fi
  done

  local n; n="$(grep -c . "$TMP/cands")"
  if [ "$n" -eq 0 ]; then
    warn "No TV found automatically."
    printf '  Type the TV IP address (Settings > Network on the TV): '
    read -r ip <&7
    [ -z "$ip" ] && die "No IP given."
    echo "$ip" > "$TMP/cands"; n=1
  fi

  if [ "$n" -eq 1 ]; then
    TARGET="$(head -1 "$TMP/cands")"
  else
    bold "  Found $n devices:"
    local k=0 line name
    while read -r line; do
      k=$((k+1))
      name="$(grep "^${line%%:*}|" "$TMP/names" 2>/dev/null | head -1 | cut -d'|' -f2)"
      printf '    %d) %s %s\n' "$k" "$line" "${name:+($name)}"
    done < "$TMP/cands"
    printf '  Which one is your TV? [1-%d]: ' "$n"
    read -r k <&7
    TARGET="$(sed -n "${k}p" "$TMP/cands")"
    [ -z "$TARGET" ] && die "Invalid choice."
  fi
  case "$TARGET" in *:*) ;; *) TARGET="$TARGET:$PORT" ;; esac
}

connect_tv() {
  bold "  Connecting to $TARGET"
  "$ADB" connect "$TARGET" >/dev/null 2>&1
  bold "  >>> Look at your TV now and press \"Allow\" (tick \"Always allow\" to skip this next time). <<<"
  local t=0 st
  while [ $t -lt 90 ]; do
    st="$("$ADB" -s "$TARGET" get-state 2>&1 | tr -d '\r')"
    case "$st" in
      device) info "Connected: $(tv getprop ro.product.manufacturer) $(tv getprop ro.product.model), Android $(tv getprop ro.build.version.release)"; return ;;
      *unauthorized*) ;;
      *) "$ADB" connect "$TARGET" >/dev/null 2>&1 ;;
    esac
    sleep 2; t=$((t+2))
  done
  die "The TV did not authorize within 90 seconds. Check that USB debugging is on, then run again."
}

# ---------------------------------------------------------------- 3. audit

mem_kb() { tv cat /proc/meminfo | awk -v k="$1:" '$1==k{print $2}'; }

snapshot_mem() { # prefix
  eval "${1}_TOTAL=\$(mem_kb MemTotal)"
  eval "${1}_FREE=\$(mem_kb MemFree)"
  eval "${1}_AVAIL=\$(mem_kb MemAvailable)"
}

# Known packages. Sets CAT and DESC.
# CAT: REQ (needed), APP (a user-facing app: ask), SAFE (can disable),
#      OPT (handled by a yes/no question later).
classify() {
  local p="$1" sys="$2"
  CAT=""; DESC=""
  case "$p" in
    # ---- needed to boot or use the TV
    android) CAT=REQ; DESC="Android core system" ;;
    com.android.systemui) CAT=REQ; DESC="System UI (notifications, overlays)" ;;
    com.android.vending) CAT=REQ; DESC="Google Play Store" ;;
    com.google.android.gms) CAT=REQ; DESC="Google Play Services (sign-in, updates, most apps need it)" ;;
    com.google.android.gsf*) CAT=REQ; DESC="Google Services Framework (account and sync plumbing)" ;;
    com.google.android.tvlauncher|com.google.android.leanbacklauncher|com.google.android.apps.tv.launcherx)
      CAT=REQ; DESC="Stock home screen (launcher)" ;;
    com.google.android.leanback.ime|com.google.android.inputmethod.latin)
      CAT=REQ; DESC="On-screen keyboard" ;;
    com.android.tv.settings|com.google.android.tv.settings) CAT=REQ; DESC="TV Settings app" ;;
    com.android.settings*) CAT=REQ; DESC="Android settings components" ;;
    com.android.providers.*|com.google.android.providers.*) CAT=REQ; DESC="Data provider (storage for settings, media, downloads...)" ;;
    com.google.android.tv.remote.service) CAT=REQ; DESC="Remote control and phone-remote pairing" ;;
    com.google.android.tungsten.setupwraith) CAT=REQ; DESC="Setup wizard (runs after resets and updates)" ;;
    com.android.packageinstaller|com.google.android.packageinstaller) CAT=REQ; DESC="Installs and updates apps" ;;
    com.android.bluetooth*|com.google.android.bluetooth*) CAT=REQ; DESC="Bluetooth (remotes, headphones)" ;;
    com.android.shell) CAT=REQ; DESC="adb shell (this tool needs it)" ;;
    com.android.inputdevices) CAT=REQ; DESC="Keyboard and remote layouts" ;;
    com.android.externalstorage|com.android.documentsui|com.google.android.documentsui) CAT=REQ; DESC="USB and file storage access" ;;
    com.google.android.tv) CAT=REQ; DESC="Live Channels (TV tuner / inputs app)" ;;
    com.android.tv|com.mediatek.wwtv.tvcenter|com.sony.dtv.tvplayer|com.tcl.tv) CAT=REQ; DESC="TV tuner / inputs app" ;;
    com.google.android.partnersetup|com.google.android.configupdater|com.google.android.backuptransport|com.google.android.syncadapters.*)
      CAT=REQ; DESC="Google system service" ;;

    # ---- yes/no questions later
    com.google.android.katniss) CAT=OPT; DESC="Voice search / Assistant on the remote (also powers the search box)" ;;
    com.google.android.googlequicksearchbox) CAT=OPT; DESC="Google app / Assistant" ;;
    com.google.android.apps.mediashell) CAT=OPT; DESC="Chromecast built-in (cast from your phone)" ;;
    com.android.dreams.basic|com.android.dreams.phototable|com.google.android.backdrop|com.google.android.apps.tv.dreamx)
      CAT=OPT; DESC="Screensaver / Ambient mode" ;;

    # ---- bloat and ad/recommendation services
    com.google.android.tvrecommendations) CAT=SAFE; DESC="Recommendation feed (ads and 'what to watch' rows)" ;;
    com.google.android.leanbacklauncher.recommendations) CAT=SAFE; DESC="Home screen recommendation rows" ;;
    com.google.android.feedback) CAT=SAFE; DESC="Sends feedback reports to Google" ;;
    com.google.android.tv.bugreportsender) CAT=SAFE; DESC="Sends bug reports" ;;
    com.google.android.marvin.talkback) CAT=SAFE; DESC="TalkBack screen reader (keep if you use it)" ;;
    com.google.android.tts) CAT=SAFE; DESC="Text-to-speech voice (needed only for TalkBack)" ;;
    com.android.printspooler) CAT=SAFE; DESC="Printing (unused on a TV)" ;;
    com.android.gallery3d|com.android.music|com.android.camera2|com.android.calendar|com.android.contacts)
      CAT=SAFE; DESC="Phone-style stock app (rarely used on a TV)" ;;
    com.android.egg) CAT=SAFE; DESC="Android version easter egg" ;;
    com.android.wallpaper.livepicker|com.android.bookmarkprovider) CAT=SAFE; DESC="Unused phone leftover" ;;
    com.sony.dtv.sonyselect) CAT=SAFE; DESC="Sony Select (app promotions)" ;;

    # ---- user-facing apps (you choose)
    com.google.android.youtube.tv) CAT=APP; DESC="YouTube" ;;
    com.google.android.youtube.tvmusic) CAT=APP; DESC="YouTube Music" ;;
    com.google.android.youtube.tvkids) CAT=APP; DESC="YouTube Kids" ;;
    com.google.android.youtube.tvunplugged) CAT=APP; DESC="YouTube TV" ;;
    com.google.android.videos) CAT=APP; DESC="Google TV / Play Movies & TV" ;;
    com.google.android.music) CAT=APP; DESC="Google Play Music (discontinued)" ;;
    com.google.android.play.games) CAT=APP; DESC="Google Play Games" ;;
    com.google.android.apps.photos*) CAT=APP; DESC="Google Photos" ;;
    com.netflix.ninja) CAT=APP; DESC="Netflix" ;;
    com.amazon.amazonvideo.livingroom) CAT=APP; DESC="Prime Video" ;;
    com.disney.disneyplus) CAT=APP; DESC="Disney+" ;;
    com.spotify.tv.android) CAT=APP; DESC="Spotify" ;;
    com.plexapp.android) CAT=APP; DESC="Plex" ;;
    com.hbo.hbonow|com.wbd.stream) CAT=APP; DESC="Max (HBO)" ;;
    com.apple.atve.androidtv.appletv) CAT=APP; DESC="Apple TV" ;;
    org.xbmc.kodi) CAT=APP; DESC="Kodi" ;;
    com.globo.globotv|com.globo.globoplay*) CAT=APP; DESC="Globoplay" ;;
    me.efesser.flauncher) CAT=APP; DESC="FLauncher (ad-free home screen)" ;;
  esac
  [ -n "$CAT" ] && return

  # Generic patterns for core parts (checked after the exact names above).
  case "$p" in
    *.ime|*inputmethod*|*keyboard*) CAT=REQ; DESC="On-screen keyboard" ;;
    *tvsettings*|*.settings) CAT=REQ; DESC="Settings component" ;;
    *setupwizard*|*setupwraith*) CAT=REQ; DESC="Setup wizard (runs after resets and updates)" ;;
    *permissioncontroller*) CAT=REQ; DESC="App permission prompts" ;;
    *webview*) CAT=REQ; DESC="Web view engine (many apps use it to show pages)" ;;
    *networkstack*|*wifi*|*connectivity*|*tethering*) CAT=REQ; DESC="Networking / Wi-Fi" ;;
    *overlay*|*frameworkpackagestubs*) CAT=REQ; DESC="System resource overlay" ;;
    *launcher*) CAT=REQ; DESC="Home screen (launcher)" ;;
    *tvinput*|*tvplayer*|*tvcenter*|*hdmi*|*cec*) CAT=REQ; DESC="TV inputs / HDMI / tuner" ;;
  esac
  [ -n "$CAT" ] && return
  [ "$sys" = 1 ] && case "$p" in
    *media*|*codec*|*audio*) CAT=REQ; DESC="Media playback / codecs"; return ;;
  esac

  # Guesses from the name: shown so you can review them.
  case "$p" in
    *advert*|*.ads.*|*.ads|*adservice*|*promo*|*analytics*|*tracking*|*telemetry*|*survey*|*recommend*)
      CAT=SAFE; DESC="Name suggests ads/analytics/recommendations (guess, review it)"; return ;;
  esac

  if [ "$sys" = 1 ]; then
    CAT=REQ; DESC="Preinstalled system/vendor component (unknown, kept to be safe)"
  else
    CAT=APP; DESC="App you or the TV maker installed"
  fi
}

audit() {
  step "3. Audit (nothing is changed here)"
  if ask_yn "Reboot the TV first so the baseline memory reading is fair?" y; then
    reboot_and_wait
  fi
  snapshot_mem BEFORE
  info "Baseline: MemAvailable $((BEFORE_AVAIL/1024)) MB, MemFree $((BEFORE_FREE/1024)) MB, total $((BEFORE_TOTAL/1024)) MB"

  tv pm list packages -s | sed 's/^package://' | sort > "$TMP/sys"
  tv pm list packages -3 | sed 's/^package://' | sort > "$TMP/third"
  tv pm list packages -d | sed 's/^package://' | sort > "$TMP/disabled"
  info "$(wc -l < "$TMP/sys" | tr -d ' ') system packages, $(wc -l < "$TMP/third" | tr -d ' ') installed apps, $(wc -l < "$TMP/disabled" | tr -d ' ') already disabled"

  : > "$TMP/table"
  local p sys
  for p in $(cat "$TMP/sys" "$TMP/third"); do
    sys=0; grep -qx "$p" "$TMP/sys" && sys=1
    classify "$p" "$sys"
    grep -qx "$p" "$TMP/disabled" && DESC="$DESC [already disabled]"
    printf '%s\t%s\t%s\n' "$CAT" "$p" "$DESC" >> "$TMP/table"
  done

  # Ask which user-facing apps are actually used.
  awk -F'\t' '$1=="APP"' "$TMP/table" > "$TMP/apps"
  if [ -s "$TMP/apps" ]; then
    bold "  Which of these apps do you actually use?"
    awk -F'\t' '{printf "    %2d) %-45s %s\n", NR, $2, $3}' "$TMP/apps"
    printf '  Type the numbers you use, separated by spaces (Enter = keep all): '
    local used; read -r used <&7
    local n=0 cat2 pkg desc
    : > "$TMP/apps2"
    while IFS="$(printf '\t')" read -r cat2 pkg desc; do
      n=$((n+1))
      if [ -z "$used" ] || printf ' %s ' "$used" | grep -q " $n "; then
        printf 'MINE\t%s\t%s\n' "$pkg" "$desc" >> "$TMP/apps2"
      else
        printf 'SAFE\t%s\t%s (you said you do not use it)\n' "$pkg" "$desc" >> "$TMP/apps2"
      fi
    done < "$TMP/apps"
    awk -F'\t' '$1!="APP"' "$TMP/table" > "$TMP/t2"; cat "$TMP/apps2" >> "$TMP/t2"; mv "$TMP/t2" "$TMP/table"
  fi

  {
    printf 'Android TV audit %s (%s)\n\n' "$STAMP" "$TARGET"
    printf '%-16s %-55s %s\n' "CATEGORY" "PACKAGE" "WHAT IT IS"
    printf '%-16s %-55s %s\n' "--------" "-------" "----------"
    local c label
    for c in REQ MINE SAFE OPT; do
      case $c in
        REQ) label="REQUIRED" ;; MINE) label="MINE" ;;
        SAFE) label="SAFE TO DISABLE" ;; OPT) label="ASKED SEPARATELY" ;;
      esac
      awk -F'\t' -v c="$c" -v l="$label" '$1==c{printf "%-16s %-55s %s\n", l, $2, $3}' "$TMP/table" | sort -k2
    done
  } > "$AUDIT"
  echo
  cat "$AUDIT"
  echo
  info "Saved this table to $AUDIT"
}

# ---------------------------------------------------------------- 4. ask

current_home() {
  tv cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1
}

stock_launcher() {
  tv cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME \
    | grep -E 'launcherx|tvlauncher|leanbacklauncher' | head -1
}

choose() {
  step "4. Your choices"
  awk -F'\t' '$1=="SAFE" && $3 !~ /already disabled/' "$TMP/table" > "$TMP/safe"
  if [ -s "$TMP/safe" ]; then
    bold "  These would be disabled (not uninstalled):"
    awk -F'\t' '{printf "    %2d) %-45s %s\n", NR, $2, $3}' "$TMP/safe"
    printf '  Numbers to KEEP (remove from the list), separated by spaces. Enter = approve all: '
    local keep; read -r keep <&7
    : > "$TMP/todisable"
    local n=0 c p d
    while IFS="$(printf '\t')" read -r c p d; do
      n=$((n+1))
      printf ' %s ' "$keep" | grep -q " $n " || echo "$p" >> "$TMP/todisable"
    done < "$TMP/safe"
    info "$(grep -c . "$TMP/todisable") apps approved for disabling."
  else
    : > "$TMP/todisable"
    info "Nothing in SAFE TO DISABLE."
  fi

  echo
  OPT_VOICE=0; OPT_CAST=0; OPT_SAVER=0; OPT_LIVETV=0; OPT_ANIM=0; OPT_LAUNCHER=0; OPT_HIDE_STOCK=0
  ask_yn "Turn off voice search / Assistant? (the remote's mic button and the search box stop working)" n && OPT_VOICE=1
  ask_yn "Turn off Chromecast built-in? (you can no longer cast from your phone)" n && OPT_CAST=1
  ask_yn "Turn off the screensaver / Ambient mode?" y && OPT_SAVER=1
  ask_yn "Stop the TV from booting into Live TV?" y && OPT_LIVETV=1
  ask_yn "Set animation scales to 0 for snappier menus?" y && OPT_ANIM=1
  if ask_yn "Install a minimal ad-free home screen (FLauncher: clock, rows of your apps, settings)?" y; then
    OPT_LAUNCHER=1
    if [ -n "$(stock_launcher)" ]; then
      info "On some TVs (mostly Google TV) the Home button still opens the stock home screen."
      ask_yn "Also disable the stock home screen so Home always opens FLauncher? (undoable)" n && OPT_HIDE_STOCK=1
    fi
  fi

  echo
  bold "  Last check: apply these changes now?"
  ask_yn "Apply?" n || { info "Nothing changed. Audit saved at $AUDIT"; exit 0; }
}

# ---------------------------------------------------------------- 5. apply

disable_pkg() {
  local p="$1"
  tv pm list packages "$p" | grep -qx "package:$p" || return 0
  change "disable $p" "pm disable-user --user 0 $p" "pm enable --user 0 $p"
}

set_setting() { # namespace key value
  local ns="$1" key="$2" val="$3" old undo
  old="$(tv settings get "$ns" "$key")"
  if [ "$old" = "null" ] || [ -z "$old" ]; then undo="settings delete $ns $key"
  else undo="settings put $ns $key '$old'"; fi
  change "setting $ns $key = $val (was $old)" "settings put $ns $key '$val'" "$undo"
}

set_home() { # component
  local new="$1" old; old="$(current_home)"
  case "$old" in */*) ;; *) old="" ;; esac
  if [ -n "$old" ]; then
    change "home screen -> $new (was $old)" "cmd package set-home-activity --user 0 $new" "cmd package set-home-activity --user 0 $old"
  else
    change "home screen -> $new" "cmd package set-home-activity --user 0 $new" "true"
  fi
}

apply() {
  step "5. Applying"
  mkdir -p "$WORKDIR"
  {
    echo "# tv-tune change log"
    echo "# TV: $TARGET  ($(tv getprop ro.product.manufacturer) $(tv getprop ro.product.model))"
    echo "# Started: $(date)"
    echo
  } > "$LOG"

  local p
  while read -r p; do [ -n "$p" ] && disable_pkg "$p"; done < "$TMP/todisable"

  if [ $OPT_VOICE = 1 ]; then
    disable_pkg com.google.android.katniss
    disable_pkg com.google.android.googlequicksearchbox
  fi
  [ $OPT_CAST = 1 ] && disable_pkg com.google.android.apps.mediashell
  if [ $OPT_SAVER = 1 ]; then
    set_setting secure screensaver_enabled 0
    set_setting secure screensaver_activate_on_sleep 0
    set_setting secure screensaver_activate_on_dock 0
    for p in com.google.android.backdrop com.google.android.apps.tv.dreamx com.android.dreams.basic com.android.dreams.phototable; do
      disable_pkg "$p"
    done
  fi
  if [ $OPT_ANIM = 1 ]; then
    set_setting global window_animation_scale 0
    set_setting global transition_animation_scale 0
    set_setting global animator_duration_scale 0
  fi

  if [ $OPT_LAUNCHER = 1 ]; then
    install_flauncher
  elif [ $OPT_LIVETV = 1 ]; then
    fix_live_tv_boot
  fi
  [ $OPT_LIVETV = 1 ] && [ $OPT_LAUNCHER = 1 ] && info "Live TV boot: the home screen is now FLauncher, so the TV boots there."
  [ $OPT_LIVETV = 1 ] && livetv_vendor_hint

  write_undo
}

fix_live_tv_boot() {
  local home stock; home="$(current_home)"; stock="$(stock_launcher)"
  case "$home" in
    *launcherx*|*tvlauncher*|*leanbacklauncher*)
      info "Home is already the normal launcher ($home)." ;;
    */*)
      if [ -n "$stock" ]; then set_home "$stock"
      else warn "Could not find the stock launcher to make it the home screen."; fi ;;
    *)
      [ -n "$stock" ] && set_home "$stock" ;;
  esac
}

livetv_vendor_hint() {
  info "If the TV still opens Live TV at power-on, it is a TV-maker setting adb cannot change. Look for:"
  info "  Sony: Settings > System > Power > 'Auto start' / 'Power on behavior' > Android TV home"
  info "  Philips / TCL / Hisense: Settings > Inputs or Power > 'Boot to source' / 'Startup input' > Home"
}

install_flauncher() {
  if tv pm list packages "$FL_PKG" | grep -qx "package:$FL_PKG"; then
    info "FLauncher already installed."
    tv pm list packages -d | grep -qx "package:$FL_PKG" && change "enable FLauncher" "pm enable --user 0 $FL_PKG" "pm disable-user --user 0 $FL_PKG"
  else
    local apk="$WORKDIR/flauncher-0.18.0.apk"
    if [ ! -f "$apk" ] || [ "$(sha256_of "$apk")" != "$FL_SHA256" ]; then
      info "Downloading FLauncher..."
      curl -fsSL -o "$apk" "$FL_URL" || { warn "Download failed; skipping launcher."; return; }
    fi
    [ "$(sha256_of "$apk")" = "$FL_SHA256" ] || { warn "Download checksum mismatch; not installing."; rm -f "$apk"; return; }
    info "Installing FLauncher..."
    local out; out="$("$ADB" -s "$TARGET" install "$apk" 2>&1 | tr -d '\r')"
    if printf '%s' "$out" | grep -q Success; then
      log "OK    install FLauncher ($FL_PKG) from $FL_URL sha256 $FL_SHA256"
      log "      undo: pm disable-user --user 0 $FL_PKG   (disabled, not uninstalled)"
      add_undo "pm disable-user --user 0 $FL_PKG"
      info "done: installed FLauncher"
    else
      log "FAIL  install FLauncher: $out"; warn "Install failed: $out"; return
    fi
  fi
  local comp; comp="$(tv cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME | grep "^$FL_PKG/" | head -1)"
  [ -z "$comp" ] && comp="$(tv cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME "$FL_PKG" | grep "^$FL_PKG/" | tail -1)"
  if [ -n "$comp" ]; then
    set_home "$comp"
  else
    warn "Could not find FLauncher's home activity; press Home on the TV and pick FLauncher."
  fi
  if [ $OPT_HIDE_STOCK = 1 ]; then
    local s; s="$(stock_launcher)"; s="${s%%/*}"
    [ -n "$s" ] && disable_pkg "$s"
  fi
  "$ADB" -s "$TARGET" shell input keyevent KEYCODE_HOME >/dev/null 2>&1
  FL_INSTALLED=1
}

write_undo() {
  local body; body="$(printf '%s\n' "$UNDO_CMDS" | grep -v '^$' | paste -sd ';' - | sed 's/;/; /g')"
  {
    echo "#!/usr/bin/env bash"
    echo "# Undo every change tv-tune made on $STAMP to $TARGET."
    echo "adb connect $TARGET"
    echo "adb -s $TARGET wait-for-device"
    printf '%s\n' "$UNDO_CMDS" | grep -v '^$' | while read -r c; do
      printf 'adb -s %s shell "%s"\n' "$TARGET" "$c"
    done
    echo "echo 'Undo finished. Rebooting the TV.'"
    echo "adb -s $TARGET reboot"
  } > "$UNDO"
  chmod +x "$UNDO"
  UNDO_ONELINER="adb connect $TARGET && adb -s $TARGET shell \"$body\" && adb -s $TARGET reboot"
  {
    echo
    echo "# ---- To undo everything, run this ONE command:"
    echo "#   bash \"$UNDO\""
    echo "# or, without the script:"
    echo "#   $UNDO_ONELINER"
  } >> "$LOG"
}

# ---------------------------------------------------------------- 6. results

reboot_and_wait() {
  info "Rebooting the TV..."
  "$ADB" -s "$TARGET" reboot >/dev/null 2>&1
  sleep "$BOOTWAIT"
  local t=0
  while [ $t -lt 300 ]; do
    "$ADB" connect "$TARGET" >/dev/null 2>&1
    if [ "$("$ADB" -s "$TARGET" get-state 2>/dev/null | tr -d '\r')" = device ] \
       && [ "$(tv getprop sys.boot_completed)" = 1 ]; then
      break
    fi
    sleep 5; t=$((t+5))
  done
  [ $t -ge 300 ] && die "The TV did not come back within 5 minutes. Run 'adb connect $TARGET' and check it."
  info "Back up. Waiting $SETTLE seconds for background apps to settle..."
  sleep "$SETTLE"
}

results() {
  step "6. Results"
  reboot_and_wait
  snapshot_mem AFTER
  local fb=$((BEFORE_FREE/1024)) fa=$((AFTER_FREE/1024)) ab=$((BEFORE_AVAIL/1024)) aa=$((AFTER_AVAIL/1024))
  {
    echo
    echo "# ---- Memory before vs after"
    printf '#   %-14s %8s %8s %8s\n' "" "Before" "After" "Change"
    printf '#   %-14s %6s MB %6s MB %+6d MB\n' "MemAvailable" "$ab" "$aa" $((aa-ab))
    printf '#   %-14s %6s MB %6s MB %+6d MB\n' "MemFree" "$fb" "$fa" $((fa-fb))
  } | tee -a "$LOG" | sed 's/^# \{0,1\}//'
  echo
  info "MemAvailable is the number that matters: memory apps can use right now."
  echo
  bold "  Change log: $LOG"
  bold "  To undo everything, run:"
  echo
  echo "    bash \"$UNDO\""
  echo
  if [ "${FL_INSTALLED:-0}" = 1 ]; then
    bold "  Finish your new home screen (one minute, with the remote):"
    info "  1. Long-press any app > 'Move to' / categories to make a row called 'My apps' with your apps."
    info "  2. Add a second row 'Inputs & settings' with your TV's Inputs app and Settings."
    info "  3. FLauncher settings (gear, top right) > turn on the clock, pick a plain wallpaper."
  fi
}

# ---------------------------------------------------------------- main

main() {
  exec 7<"$TTY" || die "Cannot read answers from $TTY (run this from a terminal)."
  bold "Android TV speed-up and clean-up"
  info "Nothing is changed until you approve it at step 4."
  setup_adb
  if [ -n "$TARGET" ]; then
    detect_os; case "$TARGET" in *:*) ;; *) TARGET="$TARGET:$PORT" ;; esac
  else
    discover
  fi
  connect_tv
  audit
  choose
  apply
  results
}

[ "${TVTUNE_NO_MAIN:-0}" = 1 ] || main "$@"
