desktop_fail() {
  jq -cn --arg message "$1" '{state:"failed", message:$message}'
}

desktop_is_ready() {
  [[ -S "$desktop_runtime/vnc.sock" ]] \
    && [[ "$(DISPLAY=":$desktop_uid" XAUTHORITY="$desktop_runtime/Xauthority" xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null)" == *"window id # "* ]] \
    && curl --fail --silent --max-time 0.25 "http://127.0.0.1:$desktop_port/vnc.html" >/dev/null
}

desktop_status() {
  if systemctl --no-ask-password is-active --quiet "$desktop_unit"; then
    if desktop_is_ready; then
      jq -cn --argjson port "$desktop_port" '{state:"running",port:$port}'
    else
      desktop_fail "The desktop is starting or its viewer is unavailable. Check journalctl -u $desktop_unit."
    fi
  elif systemctl --no-ask-password is-failed --quiet "$desktop_unit"; then
    desktop_fail "The desktop service failed. Check journalctl -u $desktop_unit, then retry ryra desktop start."
  elif [[ ! -s "$desktop_password" ]]; then
    printf '%s\n' '{"state":"needs_password"}'
  else
    printf '%s\n' '{"state":"stopped"}'
  fi
}

case "${1:-status}" in
  status) desktop_status ;;
  password)
    if systemctl --no-ask-password is-active --quiet "$desktop_unit"; then
      echo 'Stop your desktop before changing its password.' >&2
      exit 1
    fi
    mkdir -p "$desktop_config"
    desktop_temp=$(mktemp "$desktop_config/passwd.XXXXXX")
    trap 'rm -f "$desktop_temp"' EXIT
    vncpasswd "$desktop_temp"
    mv "$desktop_temp" "$desktop_password"
    echo 'Desktop password saved. Start it with ryra desktop start.'
    ;;
  start)
    if systemctl --no-ask-password is-active --quiet "$desktop_unit"; then
      desktop_status
      exit 0
    fi
    if [[ ! -s "$desktop_password" ]]; then
      printf '%s\n' '{"state":"needs_password"}'
      exit 0
    fi
    desktop_available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    if [[ ! "$desktop_available" =~ ^[0-9]+$ ]] || (( desktop_available < 524288 )); then
      desktop_fail 'Less than 512 MiB of available RAM. Free memory before starting a desktop.'
      exit 0
    fi
    if ! systemctl --no-ask-password start "$desktop_unit"; then
      desktop_fail "Could not start the desktop. Check journalctl -u $desktop_unit."
      exit 0
    fi
    for ((desktop_attempt=0; desktop_attempt<40; desktop_attempt++)); do
      if desktop_is_ready; then
        desktop_status
        exit 0
      fi
      if systemctl --no-ask-password is-failed --quiet "$desktop_unit"; then
        break
      fi
      sleep 0.25
    done
    desktop_fail "The desktop did not become ready. Check its status and journalctl -u $desktop_unit."
    ;;
  stop)
    systemctl --no-ask-password stop "$desktop_unit"
    if systemctl --no-ask-password is-failed --quiet "$desktop_unit"; then
      systemctl --no-ask-password reset-failed "$desktop_unit"
    fi
    printf '%s\n' '{"state":"stopped"}'
    ;;
  *) echo 'Usage: ryra-desktop {status|password|start|stop}' >&2; exit 2 ;;
esac
