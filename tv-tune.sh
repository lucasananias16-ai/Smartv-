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

ask_yn() { # ask_yn "pergunta" padrão(y|n|vazio = obrigatório responder)
  local q="$1" def="${2:-}" ans hint="[s/n]"
  [ "$def" = y ] && hint="[S/n]"
  [ "$def" = n ] && hint="[s/N]"
  while :; do
    printf '  %s %s ' "$q" "$hint"
    read -r ans <&7 || ans=""
    [ -z "$ans" ] && ans="$def"
    case "$ans" in
      [SsYy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) printf '  Digite s (sim) ou n (não).\n' ;;
    esac
  done
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
    warn "falhou: $what ($out)"
  else
    log "OK    $what"
    log "      do:   $cmd"
    log "      undo: $undo"
    [ -n "$out" ] && log "      out:  $out"
    info "feito: $what"
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
    MINGW*|MSYS*|CYGWIN*) OS=windows
      # Sem isto, o Git Bash troca "/proc/meminfo" por "C:/Program Files/Git/proc/meminfo".
      export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' ;;
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
  step "1. Preparação"
  detect_os
  info "Computador: $OS"
  if command -v adb >/dev/null 2>&1; then
    info "adb já está instalado: $(adb version | head -1)"
    return
  fi
  [ "$OS" = windows ] && find_windows_adb && { info "adb encontrado: $ADB"; return; }

  warn "adb não está instalado."
  case "$OS" in
    mac)
      command -v brew >/dev/null 2>&1 || die "Homebrew não encontrado. Instale em https://brew.sh e rode este script de novo."
      info "Instalando com Homebrew..."
      brew install --cask android-platform-tools || die "A instalação com Homebrew falhou." ;;
    linux)
      command -v apt-get >/dev/null 2>&1 || die "apt não disponível. Instale o adb pelo gerenciador de pacotes e rode este script de novo."
      info "Instalando com apt (pode pedir sua senha)..."
      sudo apt-get update && sudo apt-get install -y adb || die "A instalação com apt falhou." ;;
    windows)
      info "Instalando com winget..."
      winget install --id Google.PlatformTools -e --accept-source-agreements --accept-package-agreements \
        || die "A instalação com winget falhou."
      find_windows_adb || die "adb instalado, mas ainda não encontrado. Feche e abra o Git Bash de novo e rode este script outra vez." ;;
    *) die "Sistema desconhecido. Instale o Android platform-tools e rode este script de novo." ;;
  esac
  command -v adb >/dev/null 2>&1 || [ "$ADB" != adb ] || die "adb ainda não foi encontrado."
  info "adb instalado."
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
  step "2. Procurando sua TV"
  : > "$TMP/found"

  info "Procurando via mDNS..."
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
    info "Varrendo $net.1-254 na porta $PORT (este computador é $me)..."
    : > "$TMP/scan"
    local i
    for i in $(seq 1 254); do
      { ( exec 3<>"/dev/tcp/$net.$i/$PORT" ) && echo "$net.$i" >> "$TMP/scan"; } </dev/null >/dev/null 2>&1 &
    done
    sleep 4
    kill $(jobs -p) 2>/dev/null; wait 2>/dev/null
    cat "$TMP/scan" >> "$TMP/found"
  else
    warn "Não foi possível descobrir o IP deste computador; pulando a varredura."
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
    warn "Nenhuma TV encontrada automaticamente."
    printf '  Digite o IP da TV (na TV: Configurações > Rede): '
    read -r ip <&7
    [ -z "$ip" ] && die "Nenhum IP informado."
    echo "$ip" > "$TMP/cands"; n=1
  fi

  if [ "$n" -eq 1 ]; then
    TARGET="$(head -1 "$TMP/cands")"
  else
    bold "  Encontrei $n aparelhos:"
    local k=0 line name
    while read -r line; do
      k=$((k+1))
      name="$(grep "^${line%%:*}|" "$TMP/names" 2>/dev/null | head -1 | cut -d'|' -f2)"
      printf '    %d) %s %s\n' "$k" "$line" "${name:+($name)}"
    done < "$TMP/cands"
    printf '  Qual deles é a sua TV? [1-%d]: ' "$n"
    read -r k <&7
    TARGET="$(sed -n "${k}p" "$TMP/cands")"
    [ -z "$TARGET" ] && die "Opção inválida."
  fi
  case "$TARGET" in *:*) ;; *) TARGET="$TARGET:$PORT" ;; esac
}

connect_tv() {
  bold "  Conectando em $TARGET"
  # Reinicia o servidor do adb para começar limpo.
  "$ADB" kill-server >/dev/null 2>&1
  "$ADB" start-server >/dev/null 2>&1
  info "adb: $("$ADB" connect "$TARGET" 2>&1 | tr -d '\r')"
  bold "  >>> Olhe para a TV agora e aperte \"Permitir\" (marque \"Sempre permitir\" para não perguntar de novo). <<<"
  local t=0 st last=""
  while [ $t -lt 120 ]; do
    st="$("$ADB" -s "$TARGET" get-state 2>&1 | tr -d '\r')"
    if [ "$st" != "$last" ]; then
      case "$st" in
        device) ;;
        *unauthorized*) info "Estado: aguardando você apertar \"Permitir\" na TV..." ;;
        *offline*) info "Estado: TV respondeu, mas está offline. Tentando de novo..." ;;
        *) info "Estado: $st" ;;
      esac
      last="$st"
    fi
    case "$st" in
      device) info "Conectado: $(tv getprop ro.product.manufacturer) $(tv getprop ro.product.model), Android $(tv getprop ro.build.version.release)"; return ;;
      *unauthorized*) ;;
      *offline*) "$ADB" disconnect "$TARGET" >/dev/null 2>&1; "$ADB" connect "$TARGET" >/dev/null 2>&1 ;;
      *) "$ADB" connect "$TARGET" >/dev/null 2>&1 ;;
    esac
    sleep 2; t=$((t+2))
  done
  warn "A TV não autorizou em 2 minutos. Último estado: $st"
  info "Tente, nesta ordem:"
  info "  1. Na TV, aperte Home e veja se a janela \"Permitir depuração\" está escondida atrás de algum app."
  info "  2. Na TV: Opções do desenvolvedor > \"Revogar autorizações de depuração USB\"."
  info "  3. Desligue e ligue de novo a \"Depuração USB\" (e \"Depuração de rede\", se existir)."
  info "  4. Confira se $TARGET é mesmo a TV (Configurações > Rede > Endereço IP)."
  info "  Depois rode de novo:  TVTUNE_TARGET=${TARGET%%:*} bash tv-tune.sh"
  exit 1
}

# ---------------------------------------------------------------- 3. audit

mem_kb() { tv cat /proc/meminfo | awk -v k="$1:" '$1==k{print $2}'; }

check_mem() { # prefixo
  local v; eval "v=\${${1}_AVAIL:-}"
  if [ -z "$v" ] || [ "$v" = 0 ]; then
    warn "Não consegui ler a memória da TV. Resposta: $(tv cat /proc/meminfo | head -2)"
    return 1
  fi
}

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
    android) CAT=REQ; DESC="Sistema principal do Android" ;;
    com.android.systemui) CAT=REQ; DESC="Interface do sistema (notificações, janelas)" ;;
    com.android.vending) CAT=REQ; DESC="Google Play Store" ;;
    com.google.android.gms) CAT=REQ; DESC="Google Play Services (login, atualizações; a maioria dos apps precisa)" ;;
    com.google.android.gsf*) CAT=REQ; DESC="Google Services Framework (conta e sincronização)" ;;
    com.google.android.tvlauncher|com.google.android.leanbacklauncher|com.google.android.apps.tv.launcherx)
      CAT=REQ; DESC="Tela inicial original (launcher)" ;;
    com.google.android.leanback.ime|com.google.android.inputmethod.latin)
      CAT=REQ; DESC="Teclado na tela" ;;
    com.android.tv.settings|com.google.android.tv.settings) CAT=REQ; DESC="Configurações da TV" ;;
    com.android.settings*) CAT=REQ; DESC="Partes das configurações do Android" ;;
    com.android.providers.*|com.google.android.providers.*) CAT=REQ; DESC="Armazenamento de dados (configurações, mídia, downloads...)" ;;
    com.google.android.tv.remote.service) CAT=REQ; DESC="Controle remoto e pareamento com o celular" ;;
    com.google.android.tungsten.setupwraith) CAT=REQ; DESC="Assistente de configuração (roda após reset e atualizações)" ;;
    com.android.packageinstaller|com.google.android.packageinstaller) CAT=REQ; DESC="Instala e atualiza apps" ;;
    com.android.bluetooth*|com.google.android.bluetooth*) CAT=REQ; DESC="Bluetooth (controles, fones)" ;;
    com.android.shell) CAT=REQ; DESC="adb shell (este programa precisa dele)" ;;
    com.android.inputdevices) CAT=REQ; DESC="Layouts de teclado e controle" ;;
    com.android.externalstorage|com.android.documentsui|com.google.android.documentsui) CAT=REQ; DESC="Acesso a USB e arquivos" ;;
    com.google.android.tv) CAT=REQ; DESC="Canais ao vivo (sintonizador / entradas)" ;;
    com.android.tv|com.mediatek.wwtv.tvcenter|com.sony.dtv.tvplayer|com.tcl.tv) CAT=REQ; DESC="Sintonizador de TV / entradas" ;;
    com.google.android.partnersetup|com.google.android.configupdater|com.google.android.backuptransport|com.google.android.syncadapters.*)
      CAT=REQ; DESC="Serviço de sistema do Google" ;;

    # ---- yes/no questions later
    com.google.android.katniss) CAT=OPT; DESC="Busca por voz / Assistente no controle (também faz a busca funcionar)" ;;
    com.google.android.googlequicksearchbox) CAT=OPT; DESC="App Google / Assistente" ;;
    com.google.android.apps.mediashell) CAT=OPT; DESC="Chromecast integrado (transmitir do celular)" ;;
    com.android.dreams.basic|com.android.dreams.phototable|com.google.android.backdrop|com.google.android.apps.tv.dreamx)
      CAT=OPT; DESC="Protetor de tela / Modo ambiente" ;;

    # ---- bloat and ad/recommendation services
    com.google.android.tvrecommendations) CAT=SAFE; DESC="Recomendações (anúncios e fileiras de 'o que assistir')" ;;
    com.google.android.leanbacklauncher.recommendations) CAT=SAFE; DESC="Fileiras de recomendação da tela inicial" ;;
    com.google.android.feedback) CAT=SAFE; DESC="Envia relatórios de feedback ao Google" ;;
    com.google.android.tv.bugreportsender) CAT=SAFE; DESC="Envia relatórios de erro" ;;
    com.google.android.marvin.talkback) CAT=SAFE; DESC="Leitor de tela TalkBack (mantenha se usar)" ;;
    com.google.android.tts) CAT=SAFE; DESC="Voz de leitura de texto (só para o TalkBack)" ;;
    com.android.printspooler) CAT=SAFE; DESC="Impressão (não usada na TV)" ;;
    com.android.gallery3d|com.android.music|com.android.camera2|com.android.calendar|com.android.contacts)
      CAT=SAFE; DESC="App de celular (quase nunca usado na TV)" ;;
    com.android.egg) CAT=SAFE; DESC="Brincadeira escondida da versão do Android" ;;
    com.android.wallpaper.livepicker|com.android.bookmarkprovider) CAT=SAFE; DESC="Resto de celular, sem uso" ;;
    com.sony.dtv.sonyselect) CAT=SAFE; DESC="Sony Select (propaganda de apps)" ;;

    # ---- user-facing apps (you choose)
    com.google.android.youtube.tv) CAT=APP; DESC="YouTube" ;;
    com.google.android.youtube.tvmusic) CAT=APP; DESC="YouTube Music" ;;
    com.google.android.youtube.tvkids) CAT=APP; DESC="YouTube Kids" ;;
    com.google.android.youtube.tvunplugged) CAT=APP; DESC="YouTube TV" ;;
    com.google.android.videos) CAT=APP; DESC="Google TV / Play Movies & TV" ;;
    com.google.android.music) CAT=APP; DESC="Google Play Música (descontinuado)" ;;
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
    me.efesser.flauncher) CAT=APP; DESC="FLauncher (tela inicial sem anúncios)" ;;
  esac
  [ -n "$CAT" ] && return

  # Generic patterns for core parts (checked after the exact names above).
  case "$p" in
    *.ime|*inputmethod*|*keyboard*) CAT=REQ; DESC="Teclado na tela" ;;
    *tvsettings*|*.settings) CAT=REQ; DESC="Parte das configurações" ;;
    *setupwizard*|*setupwraith*) CAT=REQ; DESC="Assistente de configuração (roda após reset e atualizações)" ;;
    *permissioncontroller*) CAT=REQ; DESC="Pedidos de permissão dos apps" ;;
    *webview*) CAT=REQ; DESC="Motor web (muitos apps usam para mostrar páginas)" ;;
    *networkstack*|*wifi*|*connectivity*|*tethering*) CAT=REQ; DESC="Rede / Wi-Fi" ;;
    *overlay*|*frameworkpackagestubs*) CAT=REQ; DESC="Recursos visuais do sistema" ;;
    *launcher*) CAT=REQ; DESC="Tela inicial (launcher)" ;;
    *tvinput*|*tvplayer*|*tvcenter*|*hdmi*|*cec*) CAT=REQ; DESC="Entradas da TV / HDMI / sintonizador" ;;
  esac
  [ -n "$CAT" ] && return
  [ "$sys" = 1 ] && case "$p" in
    *media*|*codec*|*audio*) CAT=REQ; DESC="Reprodução de mídia / codecs"; return ;;
  esac

  # Guesses from the name: shown so you can review them.
  case "$p" in
    *advert*|*.ads.*|*.ads|*adservice*|*promo*|*analytics*|*tracking*|*telemetry*|*survey*|*recommend*)
      CAT=SAFE; DESC="Nome sugere anúncios/rastreamento/recomendações (palpite, confira)"; return ;;
  esac

  if [ "$sys" = 1 ]; then
    CAT=REQ; DESC="Componente do sistema ou do fabricante (desconhecido, mantido por segurança)"
  else
    CAT=APP; DESC="App instalado por você ou pelo fabricante"
  fi
}

audit() {
  step "3. Análise (nada é alterado aqui)"
  if ask_yn "Reiniciar a TV antes, para a medição de memória ser justa?" y; then
    reboot_and_wait
  fi
  snapshot_mem BEFORE
  check_mem BEFORE || die "Sem leitura de memória não dá para comparar. Me mande um print desta tela."
  info "Antes: MemAvailable $((BEFORE_AVAIL/1024)) MB, MemFree $((BEFORE_FREE/1024)) MB, total $((BEFORE_TOTAL/1024)) MB"

  tv pm list packages -s | sed 's/^package://' | sort > "$TMP/sys"
  tv pm list packages -3 | sed 's/^package://' | sort > "$TMP/third"
  tv pm list packages -d | sed 's/^package://' | sort > "$TMP/disabled"
  info "$(wc -l < "$TMP/sys" | tr -d ' ') pacotes do sistema, $(wc -l < "$TMP/third" | tr -d ' ') apps instalados, $(wc -l < "$TMP/disabled" | tr -d ' ') já desativados"

  : > "$TMP/table"
  local p sys
  for p in $(cat "$TMP/sys" "$TMP/third"); do
    sys=0; grep -qx "$p" "$TMP/sys" && sys=1
    classify "$p" "$sys"
    grep -qx "$p" "$TMP/disabled" && DESC="$DESC [já desativado]"
    printf '%s\t%s\t%s\n' "$CAT" "$p" "$DESC" >> "$TMP/table"
  done

  # Ask which user-facing apps are actually used.
  awk -F'\t' '$1=="APP"' "$TMP/table" > "$TMP/apps"
  if [ -s "$TMP/apps" ]; then
    bold "  Quais destes apps você realmente usa?"
    awk -F'\t' '{printf "    %2d) %-45s %s\n", NR, $2, $3}' "$TMP/apps"
    printf '  Digite os números dos que você usa, separados por espaço (Enter = manter todos): '
    local used; read -r used <&7
    local n=0 cat2 pkg desc
    : > "$TMP/apps2"
    while IFS="$(printf '\t')" read -r cat2 pkg desc; do
      n=$((n+1))
      if [ -z "$used" ] || printf ' %s ' "$used" | grep -q " $n "; then
        printf 'MINE\t%s\t%s\n' "$pkg" "$desc" >> "$TMP/apps2"
      else
        printf 'SAFE\t%s\t%s (você disse que não usa)\n' "$pkg" "$desc" >> "$TMP/apps2"
      fi
    done < "$TMP/apps"
    awk -F'\t' '$1!="APP"' "$TMP/table" > "$TMP/t2"; cat "$TMP/apps2" >> "$TMP/t2"; mv "$TMP/t2" "$TMP/table"
  fi

  {
    printf 'Análise da Android TV %s (%s)\n\n' "$STAMP" "$TARGET"
    printf '%-16s %-55s %s\n' "CATEGORIA" "PACOTE" "O QUE É"
    printf '%-16s %-55s %s\n' "--------" "-------" "----------"
    local c label
    for c in REQ MINE SAFE OPT; do
      case $c in
        REQ) label="NECESSÁRIO" ;; MINE) label="MEU" ;;
        SAFE) label="PODE DESATIVAR" ;; OPT) label="PERGUNTA À PARTE" ;;
      esac
      awk -F'\t' -v c="$c" -v l="$label" '$1==c{printf "%-16s %-55s %s\n", l, $2, $3}' "$TMP/table" | sort -k2
    done
  } > "$AUDIT"
  echo
  cat "$AUDIT"
  echo
  info "Tabela salva em $AUDIT"
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
  step "4. Suas escolhas"
  awk -F'\t' '$1=="SAFE" && $3 !~ /already disabled/' "$TMP/table" > "$TMP/safe"
  if [ -s "$TMP/safe" ]; then
    bold "  Estes seriam desativados (não desinstalados):"
    awk -F'\t' '{printf "    %2d) %-45s %s\n", NR, $2, $3}' "$TMP/safe"
    printf '  Números para MANTER (tirar da lista), separados por espaço. Enter = aprovar todos: '
    local keep; read -r keep <&7
    : > "$TMP/todisable"
    local n=0 c p d
    while IFS="$(printf '\t')" read -r c p d; do
      n=$((n+1))
      printf ' %s ' "$keep" | grep -q " $n " || echo "$p" >> "$TMP/todisable"
    done < "$TMP/safe"
    info "$(grep -c . "$TMP/todisable") apps aprovados para desativar."
  else
    : > "$TMP/todisable"
    info "Nada na lista PODE DESATIVAR."
  fi

  echo
  OPT_VOICE=0; OPT_CAST=0; OPT_SAVER=0; OPT_LIVETV=0; OPT_ANIM=0; OPT_LAUNCHER=0; OPT_HIDE_STOCK=0
  ask_yn "Desligar a busca por voz / Assistente? (o botão do microfone e a busca param de funcionar)" n && OPT_VOICE=1
  ask_yn "Desligar o Chromecast integrado? (não dá mais para transmitir do celular)" n && OPT_CAST=1
  ask_yn "Desligar o protetor de tela / Modo ambiente?" y && OPT_SAVER=1
  ask_yn "Impedir que a TV ligue direto na TV ao vivo?" y && OPT_LIVETV=1
  ask_yn "Zerar as animações para os menus ficarem mais rápidos?" y && OPT_ANIM=1
  if ask_yn "Trocar a tela inicial original por uma simples e sem anúncios (FLauncher)? Enter = manter a original" n; then
    OPT_LAUNCHER=1
    if [ -n "$(stock_launcher)" ]; then
      info "Em algumas TVs (principalmente Google TV) o botão Home ainda abre a tela inicial original."
      ask_yn "Desativar também a tela inicial original para o Home sempre abrir o FLauncher? (dá para desfazer)" n && OPT_HIDE_STOCK=1
    fi
  fi

  echo
  bold "  Última confirmação: aplicar estas mudanças agora?"
  ask_yn "Aplicar? (digite s e Enter)" || { info "Nada foi alterado. Análise salva em $AUDIT"; exit 0; }
}

# ---------------------------------------------------------------- 5. apply

disable_pkg() {
  local p="$1"
  tv pm list packages "$p" | grep -qx "package:$p" || return 0
  echo "$p" >> "$TMP/wanted"
  change "desativar $p" "pm disable-user --user 0 $p" "pm enable --user 0 $p"
}

set_setting() { # namespace key value
  local ns="$1" key="$2" val="$3" old undo
  old="$(tv settings get "$ns" "$key")"
  if [ "$old" = "null" ] || [ -z "$old" ]; then undo="settings delete $ns $key"
  else undo="settings put $ns $key '$old'"; fi
  change "configuração $ns $key = $val (era $old)" "settings put $ns $key '$val'" "$undo"
}

set_home() { # component
  local new="$1" old; old="$(current_home)"
  case "$old" in */*) ;; *) old="" ;; esac
  if [ -n "$old" ]; then
    change "tela inicial -> $new (era $old)" "cmd package set-home-activity --user 0 $new" "cmd package set-home-activity --user 0 $old"
  else
    change "tela inicial -> $new" "cmd package set-home-activity --user 0 $new" "true"
  fi
}

apply() {
  step "5. Aplicando"
  mkdir -p "$WORKDIR"
  {
    echo "# Registro de mudanças do tv-tune"
    echo "# TV: $TARGET  ($(tv getprop ro.product.manufacturer) $(tv getprop ro.product.model))"
    echo "# Início: $(date)"
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
  [ $OPT_LIVETV = 1 ] && [ $OPT_LAUNCHER = 1 ] && info "TV ao vivo: a tela inicial agora é o FLauncher, então a TV liga nele."
  [ $OPT_LIVETV = 1 ] && livetv_vendor_hint

  verify_disabled
  write_undo
}

# Confere na TV se cada app pedido está mesmo desativado.
verify_disabled() {
  tv pm list packages -d | sed 's/^package://' | sort > "$TMP/disabled_now"
  local want ok=0 bad=0 p
  want="$(sort -u "$TMP/wanted" 2>/dev/null)"
  [ -z "$want" ] && return
  echo
  bold "  Conferindo na TV:"
  for p in $want; do
    if grep -qx "$p" "$TMP/disabled_now"; then ok=$((ok+1))
    else bad=$((bad+1)); warn "continua ativo: $p"; log "CHECK still enabled: $p"; fi
  done
  info "$ok de $((ok+bad)) apps estão desativados."
  log "CHECK $ok of $((ok+bad)) packages disabled"
  [ $bad -gt 0 ] && info "Alguns apps de sistema não deixam ser desativados nesta TV. Isso é normal; o resto foi aplicado."
}

fix_live_tv_boot() {
  local home stock; home="$(current_home)"; stock="$(stock_launcher)"
  case "$home" in
    *launcherx*|*tvlauncher*|*leanbacklauncher*)
      info "A tela inicial já é o launcher normal ($home)." ;;
    */*)
      if [ -n "$stock" ]; then set_home "$stock"
      else warn "Não encontrei o launcher original para usar como tela inicial."; fi ;;
    *)
      [ -n "$stock" ] && set_home "$stock" ;;
  esac
}

livetv_vendor_hint() {
  info "Se a TV ainda abrir na TV ao vivo ao ligar, é uma opção do fabricante que o adb não muda. Procure:"
  info "  Sony: Configurações > Sistema > Energia > 'Comportamento ao ligar' > Tela inicial do Android TV"
  info "  Philips / TCL / Hisense: Configurações > Entradas ou Energia > 'Entrada ao ligar' > Tela inicial"
}

install_flauncher() {
  if tv pm list packages "$FL_PKG" | grep -qx "package:$FL_PKG"; then
    info "FLauncher já está instalado."
    tv pm list packages -d | grep -qx "package:$FL_PKG" && change "ativar FLauncher" "pm enable --user 0 $FL_PKG" "pm disable-user --user 0 $FL_PKG"
  else
    local apk="$WORKDIR/flauncher-0.18.0.apk"
    if [ ! -f "$apk" ] || [ "$(sha256_of "$apk")" != "$FL_SHA256" ]; then
      info "Baixando o FLauncher..."
      curl -fsSL -o "$apk" "$FL_URL" || { warn "O download falhou; pulando a tela inicial."; return; }
    fi
    [ "$(sha256_of "$apk")" = "$FL_SHA256" ] || { warn "O arquivo baixado não confere; não vou instalar."; rm -f "$apk"; return; }
    info "Instalando o FLauncher..."
    local out; out="$("$ADB" -s "$TARGET" install "$apk" 2>&1 | tr -d '\r')"
    if printf '%s' "$out" | grep -q Success; then
      log "OK    install FLauncher ($FL_PKG) from $FL_URL sha256 $FL_SHA256"
      log "      undo: pm disable-user --user 0 $FL_PKG   (disabled, not uninstalled)"
      add_undo "pm disable-user --user 0 $FL_PKG"
      info "feito: FLauncher instalado"
    else
      log "FAIL  install FLauncher: $out"; warn "A instalação falhou: $out"; return
    fi
  fi
  local comp; comp="$(tv cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME | grep "^$FL_PKG/" | head -1)"
  [ -z "$comp" ] && comp="$(tv cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME "$FL_PKG" | grep "^$FL_PKG/" | tail -1)"
  if [ -n "$comp" ]; then
    set_home "$comp"
  else
    warn "Não consegui definir o FLauncher como tela inicial; aperte Home na TV e escolha FLauncher."
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
    echo "# Desfaz todas as mudanças que o tv-tune fez em $STAMP na TV $TARGET."
    echo "adb connect $TARGET"
    echo "adb -s $TARGET wait-for-device"
    printf '%s\n' "$UNDO_CMDS" | grep -v '^$' | while read -r c; do
      printf 'adb -s %s shell "%s"\n' "$TARGET" "$c"
    done
    echo "echo 'Desfeito. Reiniciando a TV.'"
    echo "adb -s $TARGET reboot"
  } > "$UNDO"
  chmod +x "$UNDO"
  UNDO_ONELINER="adb connect $TARGET && adb -s $TARGET shell \"$body\" && adb -s $TARGET reboot"
  {
    echo
    echo "# ---- Para desfazer tudo, rode este ÚNICO comando:"
    echo "#   bash \"$UNDO\""
    echo "# ou, sem o script:"
    echo "#   $UNDO_ONELINER"
  } >> "$LOG"
}

# ---------------------------------------------------------------- 6. results

reboot_and_wait() {
  info "Reiniciando a TV..."
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
  [ $t -ge 300 ] && die "A TV não voltou em 5 minutos. Rode 'adb connect $TARGET' e confira."
  info "Ligou. Esperando $SETTLE segundos para os apps em segundo plano estabilizarem..."
  sleep "$SETTLE"
}

results() {
  step "6. Resultado"
  reboot_and_wait
  snapshot_mem AFTER
  check_mem AFTER || return
  local fb=$((BEFORE_FREE/1024)) fa=$((AFTER_FREE/1024)) ab=$((BEFORE_AVAIL/1024)) aa=$((AFTER_AVAIL/1024))
  {
    echo
    echo "# ---- Memória antes x depois"
    printf '#   %-14s %8s %8s %8s\n' "" "Antes" "Depois" "Diferença"
    printf '#   %-14s %6s MB %6s MB %+6d MB\n' "MemAvailable" "$ab" "$aa" $((aa-ab))
    printf '#   %-14s %6s MB %6s MB %+6d MB\n' "MemFree" "$fb" "$fa" $((fa-fb))
  } | tee -a "$LOG" | sed 's/^# \{0,1\}//'
  echo
  info "MemAvailable é o número que importa: memória que os apps podem usar agora."
  echo
  bold "  Registro de mudanças: $LOG"
  bold "  Para desfazer tudo, rode:"
  echo
  echo "    bash \"$UNDO\""
  echo
  if [ "${FL_INSTALLED:-0}" = 1 ]; then
    bold "  Termine sua nova tela inicial (um minuto, com o controle):"
    info "  1. Segure OK num app > categorias: crie uma fileira 'Meus apps' com seus apps."
    info "  2. Crie uma segunda fileira 'Entradas e configurações' com o app de Entradas da TV e Configurações."
    info "  3. Configurações do FLauncher (engrenagem, canto superior direito) > ligue o relógio e escolha um fundo simples."
  fi
}

# ---------------------------------------------------------------- main

main() {
  exec 7<"$TTY" || die "Não consigo ler respostas de $TTY (rode isto num terminal)."
  bold "Acelerar e limpar a Android TV"
  info "Nada é alterado até você aprovar na etapa 4."
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
