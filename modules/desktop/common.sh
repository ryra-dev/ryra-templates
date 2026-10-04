umask 077
desktop_uid=$(id -u)
if (( desktop_uid < 1000 || desktop_uid > 49000 )); then
  echo 'Ryra desktop requires a regular account with a UID between 1000 and 49000.' >&2
  exit 1
fi
desktop_port=$((16000 + desktop_uid))
desktop_unit="ryra-desktop@$(id -un).service"
export desktop_unit
desktop_config="${XDG_CONFIG_HOME:-$HOME/.config}/ryra-desktop"
desktop_password="$desktop_config/passwd"
desktop_runtime="${XDG_RUNTIME_DIR:?No user session is available}/ryra-desktop"
