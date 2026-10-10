# The adapters Ryra uses to speak to agents installed through the service catalog.
#
# Ryra drives an agent over ACP rather than over its terminal, which is what makes a session
# structured instead of a wall of characters. Neither CLI speaks it: `codex` offers `mcp`,
# `mcp-server` and `app-server` and no `acp` at all, so the adapters are a requirement rather
# than a convenience.
#
# The adapters come from ../agent-runtime, the same locked package set Ryra installs privately
# on a machine that is not built from a flake. Fetching from npm on first use would mean a
# network round trip, tens of seconds before a pane opens, and whatever version npm published
# that morning. These arrive in the closure, work with no network, and start immediately.
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    (import ../agent-runtime { inherit pkgs; })
  ];
}
