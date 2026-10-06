# Keep machine control local. These also apply to direct CLI use of this wrapper.
export CUA_DRIVER_RS_TELEMETRY_ENABLED=false
export CUA_DRIVER_RS_UPDATE_CHECK=false

case "${1:-}" in
  --help|-h|--version|-V|help) exec "$RYRA_CUA_DRIVER" "$@" ;;
esac

desktop_uid=$(id -u)
if (( desktop_uid < 1000 || desktop_uid > 49000 )); then
  echo 'Ryra computer control requires a regular desktop account.' >&2
  exit 1
fi
# SSH agents need not inherit the desktop's environment. Select this account's
# display explicitly, including when SSH forwarded a different DISPLAY.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$desktop_uid}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
export XDG_SESSION_TYPE=wayland
export WAYLAND_DISPLAY=wayland-ryra
export CUA_DRIVER_RS_ENABLE_WAYLAND=1
export NO_AT_BRIDGE=0
export GTK_A11Y=atspi
unset DISPLAY XAUTHORITY SWAYSOCK HYPRLAND_INSTANCE_SIGNATURE

if ! systemctl --no-ask-password is-active --quiet "ryra-desktop@$(id -un).service" \
  || [[ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] \
  || ! busctl --user --timeout=2 status org.gnome.Shell >/dev/null 2>&1; then
  echo 'Start your desktop with ryra desktop start before using computer control.' >&2
  exit 1
fi

exec "$RYRA_CUA_DRIVER" "$@"
