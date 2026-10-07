desktop_fail() {
  jq -cn --arg message "$1" '{state:"failed", message:$message}'
}

desktop_starting() {
  jq -cn --arg message "$1" '{state:"starting", message:$message}'
}

desktop_status() {
  if systemctl --no-ask-password is-active --quiet "$desktop_unit"; then
    if [[ ! -S "$XDG_RUNTIME_DIR/wayland-ryra" ]]; then
      desktop_starting 'Starting the desktop display…'
    elif [[ ! -S "$desktop_runtime/vnc.sock" ]]; then
      desktop_starting 'Preparing the desktop connection…'
    elif ! curl --fail --silent --max-time 2 "http://127.0.0.1:$desktop_port/vnc.html" >/dev/null; then
      desktop_starting 'Waiting for the desktop viewer…'
    else
      jq -cn --argjson port "$desktop_port" '{state:"running",port:$port}'
    fi
  elif systemctl --no-ask-password is-failed --quiet "$desktop_unit"; then
    desktop_result=$(systemctl --no-ask-password show "$desktop_unit" --property=Result --value)
    desktop_exit=$(systemctl --no-ask-password show "$desktop_unit" --property=ExecMainStatus --value)
    desktop_fail "The desktop service failed: $desktop_result (process status $desktop_exit). Inspect systemctl status $desktop_unit and journalctl _UID=$desktop_uid, then retry ryra desktop start."
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
    if ! desktop_start_error=$(systemctl --no-ask-password start "$desktop_unit" 2>&1); then
      desktop_fail "Could not start the desktop: $desktop_start_error"
      exit 0
    fi
    desktop_status
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
