#!/usr/bin/env bash
# tv-diagnostico.sh: descobre quando e por que a Android TV desligou.
# Só lê informações; não muda nada na TV.
#
#   bash tv-diagnostico.sh 192.168.1.187
#
# Salva tudo em ~/tv-tune/diagnostico-<data>.txt

isnum() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' ;; esac

IP="${1:-${TVTUNE_TARGET:-}}"
[ -z "$IP" ] && { printf 'Digite o IP da TV: '; read -r IP; }
case "$IP" in *:*) T="$IP" ;; *) T="$IP:5555" ;; esac

ADB=adb
if ! command -v adb >/dev/null 2>&1; then
  for f in "${LOCALAPPDATA:-/nonexistent}"/Microsoft/WinGet/Packages/Google.PlatformTools*/platform-tools/adb.exe; do
    [ -x "$f" ] && ADB="$f"
  done
fi

mkdir -p "$HOME/tv-tune"
OUT="$HOME/tv-tune/diagnostico-$(date +%Y%m%d-%H%M%S).txt"

tv() { "$ADB" -s "$T" shell "$@" 2>&1 | tr -d '\r'; }
sec() { printf '\n==== %s ====\n' "$1"; }

"$ADB" connect "$T" >/dev/null 2>&1
st="$("$ADB" -s "$T" get-state 2>&1 | tr -d '\r')"
[ "$st" = device ] || { echo "Não conectou na TV ($st). Ligue a TV, aperte \"Permitir\" se aparecer e rode de novo."; exit 1; }

{
  echo "Diagnóstico da TV $T em $(date)"
  echo "Modelo: $(tv getprop ro.product.manufacturer) $(tv getprop ro.product.model), Android $(tv getprop ro.build.version.release)"

  sec "1. Quando a TV ligou pela última vez (último boot)"
  now="$(tv date +%s)"; up="$(tv cat /proc/uptime | cut -d. -f1)"
  isnum "$now" || now=""; isnum "$up" || up=""
  if [ -n "$now" ] && [ -n "$up" ]; then
    boot=$((now - up))
    echo "Ligada há $((up/3600))h $((up%3600/60))min"
    echo "Último boot: $(tv date -d "@$boot" '+%d/%m/%Y %H:%M:%S' 2>/dev/null || tv toybox date -d "@$boot")"
  fi
  echo "Motivo do último boot: $(tv getprop sys.boot.reason) $(tv getprop persist.sys.boot.reason) $(tv getprop ro.boot.bootreason)"

  sec "2. Última vez que a tela apagou / acendeu (sono)"
  tv dumpsys power | grep -iE 'mWakefulness=|mLastSleepTime|mLastSleepReason|mLastWakeTime|mLastWakeReason|mScreenOffTimeoutSetting|mSleepTimeoutSetting|mAttentiveTimeoutSetting|mStayOn'
  if [ -n "${up:-}" ]; then
    for k in mLastSleepTime mLastWakeTime; do
      ms="$(tv dumpsys power | grep -oE "$k=[0-9]+" | head -1 | cut -d= -f2)"
      if [ -n "${now:-}" ] && isnum "$ms" && [ "$ms" -gt 0 ]; then
        t=$((now - up + ms/1000))
        echo "$k em: $(tv date -d "@$t" '+%d/%m/%Y %H:%M:%S' 2>/dev/null)"
      fi
    done
  fi

  sec "3. Timers de desligamento e protetor de tela"
  for kv in "system screen_off_timeout" "secure sleep_timeout" "secure attentive_timeout" \
            "secure screensaver_enabled" "secure screensaver_activate_on_sleep" \
            "global stay_on_while_plugged_in"; do
    set -- $kv; echo "$1 $2 = $(tv settings get "$1" "$2")"
  done

  sec "4. HDMI-CEC (outro aparelho pode desligar a TV)"
  for k in hdmi_control_enabled hdmi_control_auto_device_off_enabled hdmi_control_auto_wakeup_enabled; do
    echo "global $k = $(tv settings get global "$k")"
  done
  tv dumpsys hdmi_control 2>/dev/null | grep -iE 'standby|power|<Standby>|activeSource' | tail -20

  sec "5. Registros de desligamento e sono (mais recentes no fim)"
  tv logcat -b events -d 2>/dev/null | grep -iE 'power_sleep_requested|power_screen_state|power_soft_sleep|screen_toggled|shutdown|am_low_memory' | tail -40
  tv logcat -b system -b main -d 2>/dev/null | grep -iE 'ShutdownThread|goToSleep|Going to sleep|thermal|overheat|Standby|CEC.*standby|reboot' | tail -40

  sec "6. Desligamentos anteriores guardados pelo sistema"
  tv dumpsys dropbox 2>/dev/null | grep -iE 'SYSTEM_BOOT|SYSTEM_RESTART|system_server_crash|SYSTEM_LAST_KMSG|kernel_panic|watchdog' | tail -20

  sec "7. Temperatura"
  tv dumpsys thermalservice 2>/dev/null | grep -iE 'Status|Temperature\{' | head -10
} | tee "$OUT"

echo
echo "Salvo em: $OUT"
echo "Me mande esse arquivo (ou um print desta tela)."
