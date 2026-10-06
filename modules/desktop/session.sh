[[ -s "$desktop_password" ]] || { echo 'Set your desktop password first.' >&2; exit 1; }
mkdir -p "$desktop_runtime"

# Load the NixOS GNOME schema, icon and application search paths.
desktop_path=$PATH
set +u
# shellcheck disable=SC1091
source /etc/profile
set -u
export PATH="$desktop_path:$PATH"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_DESKTOP=gnome
export XDG_CURRENT_DESKTOP=GNOME
export WAYLAND_DISPLAY=wayland-ryra
unset DISPLAY XAUTHORITY
systemctl --user unset-environment DISPLAY XAUTHORITY
dbus-update-activation-environment --systemd PATH XDG_SESSION_TYPE XDG_SESSION_DESKTOP XDG_CURRENT_DESKTOP WAYLAND_DISPLAY XDG_DATA_DIRS NIX_GSETTINGS_OVERRIDES_DIR

# shellcheck disable=SC2329
desktop_cleanup() {
  systemctl --user start gnome-session-shutdown.target || true
  for desktop_pid in "${desktop_wm_pid:-}" "${desktop_remote_pid:-}" "${desktop_web_pid:-}"; do
    if [[ -n "$desktop_pid" ]]; then
      kill "$desktop_pid" 2>/dev/null || true
    fi
  done
  wait || true
  rm -rf "$desktop_runtime/credentials"
  rm -f "$desktop_runtime/vnc.sock"
}
trap 'desktop_cleanup' EXIT
trap 'exit 0' TERM INT HUP

# The client stores TigerVNC's encrypted eight-byte password. Keep GNOME's
# decoded credential in this account's private runtime directory only.
mkdir -p "$desktop_runtime/credentials"
{ head -c 8 "$desktop_password" | openssl enc -d -des-ecb -provider default -provider legacy -K e84ad660c4721ae0 -nopad | tr -d '\000'; printf '\n'; } \
  | XDG_DATA_HOME="$desktop_runtime/credentials" grdctl --headless vnc set-password

systemctl --user start pipewire.socket wireplumber.service
gnome-session --session=gnome &
desktop_wm_pid=$!
XDG_DATA_HOME="$desktop_runtime/credentials" "$RYRA_GNOME_REMOTE_DESKTOP" --headless &
desktop_remote_pid=$!
websockify --web "$RYRA_NOVNC" --unix-target "$desktop_runtime/vnc.sock" \
  "127.0.0.1:$desktop_port" &
desktop_web_pid=$!
wait -n "$desktop_wm_pid" "$desktop_remote_pid" "$desktop_web_pid"
echo 'A desktop component exited. The session has ended.' >&2
exit 1
