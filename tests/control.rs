//! Run with rustc --test tests/control.rs -o /tmp/ryra-desktop-tests.
use std::fs;
use std::os::unix::{fs::PermissionsExt, net::UnixListener};
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

static NEXT: AtomicUsize = AtomicUsize::new(0);

struct Machine(PathBuf);

impl Machine {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "ryra-desktop-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).expect("isolated fixture");
        let this = Self(path);
        for dir in ["bin", "config/ryra-desktop", "run/ryra-desktop"] {
            fs::create_dir_all(this.0.join(dir)).expect("fixture folder");
        }
        fs::write(
            this.0.join("common.sh"),
            include_str!("../modules/desktop/common.sh"),
        )
        .expect("common");
        fs::write(
            this.0.join("control.sh"),
            include_str!("../modules/desktop/control.sh"),
        )
        .expect("control");
        fs::write(
            this.0.join("computer-control.sh"),
            include_str!("../modules/desktop/computer-control.sh"),
        )
        .expect("computer control");
        this.executable("id", "if [ \"$1\" = -un ]; then echo alice; else echo 1000; fi");
        this.executable("xprop", "echo '_NET_SUPPORTING_WM_CHECK(WINDOW): window id # 0x1'");
        this.executable("curl", "exit 0");
        this.executable("awk", "echo \"${TEST_MEMORY:-1048576}\"");
        this.executable("vncpasswd", "printf password > \"$1\"");
        this.executable("xdpyinfo", "exit 0");
        this.executable("timeout", "shift; exec \"$@\"");
        this.executable(
            "cua-driver",
            r#"
printf '%s\n' "$@"
printf '%s\n' "$DISPLAY" "$XAUTHORITY" "$DBUS_SESSION_BUS_ADDRESS" "$XDG_SESSION_TYPE"
printf '%s\n' "$CUA_DRIVER_RS_TELEMETRY_ENABLED" "$CUA_DRIVER_RS_UPDATE_CHECK"
printf '%s\n' "${WAYLAND_DISPLAY-unset}" "${SWAYSOCK-unset}" "${HYPRLAND_INSTANCE_SIGNATURE-unset}"
"#,
        );
        this.executable(
            "systemctl",
            r#"
case "$2" in
  is-active) test "$(cat "$TEST_ROOT/state")" = active ;;
  is-failed) test "$(cat "$TEST_ROOT/state")" = failed ;;
  start) test "${TEST_START_FAIL:-0}" = 0 || exit 1; echo active > "$TEST_ROOT/state" ;;
  stop) echo stopped > "$TEST_ROOT/state" ;;
  reset-failed) exit 0 ;;
  *) exit 2 ;;
esac
"#,
        );
        this.state("stopped");
        this
    }

    fn executable(&self, name: &str, body: &str) {
        let path = self.0.join("bin").join(name);
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).expect("mock command");
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).expect("executable");
    }

    fn state(&self, state: &str) {
        fs::write(self.0.join("state"), state).expect("service state");
    }

    fn password(&self) {
        fs::write(self.0.join("config/ryra-desktop/passwd"), "old-password")
            .expect("password fixture");
    }

    fn run(&self, action: &str, env: &[(&str, &str)]) -> std::process::Output {
        Command::new("bash")
            .args([
                "-c",
                "set -euo pipefail; source \"$1\"; source \"$2\" \"$3\"",
                "desktop-test",
            ])
            .arg(self.0.join("common.sh"))
            .arg(self.0.join("control.sh"))
            .arg(action)
            .env(
                "PATH",
                format!(
                    "{}:{}",
                    self.0.join("bin").display(),
                    std::env::var("PATH").expect("PATH")
                ),
            )
            .env("XDG_CONFIG_HOME", self.0.join("config"))
            .env("XDG_RUNTIME_DIR", self.0.join("run"))
            .env("TEST_ROOT", &self.0)
            .envs(env.iter().copied())
            .output()
            .expect("run helper against mocks")
    }

    fn computer_control(&self, args: &[&str]) -> std::process::Output {
        Command::new("bash")
            .args(["-eu", "-o", "pipefail"])
            .arg(self.0.join("computer-control.sh"))
            .args(args)
            .env(
                "PATH",
                format!(
                    "{}:{}",
                    self.0.join("bin").display(),
                    std::env::var("PATH").expect("PATH")
                ),
            )
            .env("XDG_RUNTIME_DIR", self.0.join("run"))
            .env("TEST_ROOT", &self.0)
            .env("RYRA_CUA_DRIVER", self.0.join("bin/cua-driver"))
            // Stale forwarded display and user overrides must not redirect control.
            .env("DISPLAY", "localhost:10.0")
            .env("XAUTHORITY", "/wrong/cookie")
            .env("DBUS_SESSION_BUS_ADDRESS", "unix:path=/wrong/bus")
            .env("XDG_SESSION_TYPE", "wayland")
            .env("WAYLAND_DISPLAY", "wayland-0")
            .env("SWAYSOCK", "/wrong/sway")
            .env("HYPRLAND_INSTANCE_SIGNATURE", "wrong-hyprland")
            .env("CUA_DRIVER_RS_TELEMETRY_ENABLED", "true")
            .env("CUA_DRIVER_RS_UPDATE_CHECK", "true")
            .output()
            .expect("run computer control against mocks")
    }

    fn said(&self, action: &str, env: &[(&str, &str)]) -> String {
        let out = self.run(action, env);
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).expect("UTF-8")
    }
}

impl Drop for Machine {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).expect("remove own fixture");
    }
}

#[test]
fn inspection_and_missing_password_never_start_a_session() {
    let machine = Machine::new();
    for action in ["status", "start"] {
        assert!(machine.said(action, &[]).contains("needs_password"));
        assert_eq!(
            fs::read_to_string(machine.0.join("state")).expect("state"),
            "stopped"
        );
    }
    machine.password();
    assert!(machine.said("status", &[]).contains("stopped"));
}

#[test]
fn low_memory_and_start_failures_are_actionable() {
    let machine = Machine::new();
    machine.password();
    assert!(machine
        .said("start", &[("TEST_MEMORY", "100")])
        .contains("512 MiB"));
    assert_eq!(
        fs::read_to_string(machine.0.join("state")).expect("state"),
        "stopped"
    );
    assert!(machine
        .said("start", &[("TEST_START_FAIL", "1")])
        .contains("Could not start"));
}

#[test]
fn active_service_requires_a_vnc_socket_and_http_viewer() {
    let machine = Machine::new();
    machine.password();
    machine.state("active");
    assert!(machine.said("status", &[]).contains("failed"));
    let _socket =
        UnixListener::bind(machine.0.join("run/ryra-desktop/vnc.sock")).expect("VNC socket");
    assert_eq!(
        machine.said("status", &[]).trim(),
        r#"{"state":"running","port":17000}"#
    );
    assert!(machine
        .said("start", &[("TEST_MEMORY", "0")])
        .contains("running"));
    machine.executable("curl", "exit 7");
    assert!(machine.said("status", &[]).contains("failed"));
}

#[test]
fn explicit_stop_releases_the_session_and_preserves_password() {
    let machine = Machine::new();
    machine.password();
    machine.state("active");
    assert!(machine.said("stop", &[]).contains("stopped"));
    assert_eq!(
        fs::read_to_string(machine.0.join("config/ryra-desktop/passwd")).expect("password"),
        "old-password"
    );
    assert!(machine.said("stop", &[]).contains("stopped"));
    fs::remove_file(machine.0.join("config/ryra-desktop/passwd")).expect("remove fixture password");
    assert!(machine.said("stop", &[]).contains("stopped"));
}

#[test]
fn password_change_is_atomic_and_refused_while_running() {
    let machine = Machine::new();
    machine.password();
    machine.executable("vncpasswd", "echo partial > \"$1\"; exit 1");
    assert!(!machine.run("password", &[]).status.success());
    assert_eq!(
        fs::read_to_string(machine.0.join("config/ryra-desktop/passwd")).expect("password"),
        "old-password"
    );
    machine.state("active");
    assert!(!machine.run("password", &[]).status.success());
}

#[test]
fn computer_control_selects_the_accounts_desktop_from_an_ssh_environment() {
    let machine = Machine::new();
    machine.state("active");
    fs::write(machine.0.join("run/ryra-desktop/Xauthority"), "cookie").unwrap();
    let out = machine.computer_control(&["mcp", "--direct"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(
        String::from_utf8(out.stdout).unwrap(),
        format!(
            "mcp\n--direct\n:1000\n{}/run/ryra-desktop/Xauthority\nunix:path={}/run/bus\nx11\nfalse\nfalse\nunset\nunset\nunset\n",
            machine.0.display(), machine.0.display()
        )
    );
}

#[test]
fn computer_control_rejects_stopped_unready_or_wrong_account_desktops() {
    let machine = Machine::new();
    let rejected = || {
        let out = machine.computer_control(&["mcp", "--direct"]);
        assert!(!out.status.success());
        assert!(out.stdout.is_empty(), "failed preflight must not start MCP");
        assert!(String::from_utf8_lossy(&out.stderr).contains("ryra desktop start"));
    };
    rejected();
    assert_eq!(
        fs::read_to_string(machine.0.join("state")).unwrap(),
        "stopped"
    );
    machine.state("active");
    rejected();
    fs::write(machine.0.join("run/ryra-desktop/Xauthority"), "cookie").unwrap();
    machine.executable("xdpyinfo", "exit 1");
    rejected();
    machine.executable("xdpyinfo", "exit 0");
    for uid in ["0", "999", "49001"] {
        machine.executable("id", &format!("echo {uid}"));
        let out = machine.computer_control(&["mcp", "--direct"]);
        assert!(!out.status.success());
        assert!(out.stdout.is_empty());
        assert!(String::from_utf8_lossy(&out.stderr).contains("regular desktop account"));
    }
}

#[test]
fn computer_control_version_needs_no_desktop() {
    let machine = Machine::new();
    machine.executable("cua-driver", "printf '%s %s %s' \"$1\" \"$CUA_DRIVER_RS_TELEMETRY_ENABLED\" \"$CUA_DRIVER_RS_UPDATE_CHECK\"");
    let out = machine.computer_control(&["--version"]);
    assert!(out.status.success());
    assert_eq!(
        String::from_utf8(out.stdout).unwrap(),
        "--version false false"
    );
}
