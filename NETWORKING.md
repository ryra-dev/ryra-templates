# Machine networking

Use the same machine template with either public SSH or Tailscale. All compatibility presets use the same shared networking module; there is no
separate Tailscale machine type. Set these options in `configuration.nix` or a
module in the machine's own `modules/` directory.

With the defaults, the firewall permits inbound TCP 22 for OpenSSH. To enable
Tailscale, add this to a module in the machine's `modules/` directory:

```nix
{ ... }: {
  ryra.tailscale.enable = true;
}
```

This automatically enrolls using the SOPS secret named `tailscale-auth`, closes
public SSH, and allows TCP 22 on `tailscale0`. The interface is not globally
trusted: other private services need their own interface-specific port rules.
Tailscale's automatic netfilter rules are disabled so they cannot bypass the
NixOS port policy. Exit-node and subnet-router forwarding are not enabled by
this setting.
UDP 41641 is opened for Tailscale's encrypted transport. Tailscale SSH is disabled;
Ryra continues using OpenSSH and its existing certificate authentication.
Outbound connections, loopback and established connections retain normal NixOS
behavior. Azure also retains its DHCP client rule (UDP 68).

An explicitly configured public web service may still open its own ports. This
setting controls SSH reachability; it does not erase an application's deliberate
firewall rules. Conflicting rules exposing SSH through public interfaces, port
ranges, or trusted interfaces fail evaluation in private mode.

## Enrollment through Ryra, SOPS and age

Connect the organization's Tailscale integration with an OAuth client authorized
to create auth keys for the intended tag. Configure that tag and access policy in
Tailscale. Then declare a secret in `organization.toml`, adapting the vault and
group to the organization:

```toml
[[secrets]]
name = "tailscale-auth"
vault = "Infra"
access = ["admins"]
path = "/run/secrets/tailscale-auth"
restart = ["tailscaled-autoconnect.service"]
mint = { from = "tailscale", tags = ["tag:server"] }
```

The machine must be reached by the declared access group. Ryra's existing secret
deployment mints a separate single-use key for each machine, encrypts it to the
machine's age recipient, and generates its SOPS module. The template waits for
SOPS to install that root-only secret before enrollment. The OAuth credential
stays in the organization vault; it is not copied to the machine or Nix store.
If the secret already has another name, set
`ryra.tailscale.authKeySecret = "that-name"`.

The machine's Tailscale identity persists in `/var/lib/tailscale` across reboots.
If that state is lost or the device is revoked, a spent enrollment key cannot
register it again: deploy a fresh key. Login failures retry and remain visible in
`tailscaled-autoconnect.service` rather than being reported as enrollment success.

## Moving an existing machine to private SSH

With the updated Ryra CLI, a saved organization checkout, a trusted installed
host and a declared enrollment secret, run:

```sh
ryra org machines tailscale <org> <machine>
```

This exports the encrypted secret through Ryra's existing minting integration,
enrolls with public SSH temporarily available, verifies a fresh connection using
the same host key, saves the private address, and deploys the private-only policy
with rollback checks. The deploying device must already have tailnet access.
The equivalent manual sequence follows.

First install the normal template and establish its host identity and SOPS
secrets. Enrollment needs an initial route to the machine. For the first
Tailscale deployment, temporarily keep that route:

```nix
{ ... }: {
  ryra.tailscale.enable = true;
  ryra.access.publicSSH = true; # Temporary enrollment step.
}
```

After enrollment, use the machine's Tailscale IP or MagicDNS name as its Ryra SSH
connection address. The device running the deployment must have access to that
tailnet and the policy must permit SSH. Verify access using the same stored SSH
host identity. Remove the `publicSSH` override and deploy again through that
private address.

Ryra's updated deployment path reads the access policy from the staged system
and requires a fresh SSH connection whose destination is one of the machine's
Tailscale addresses before activating private-only access. It repeats this check
after activation before confirming the existing rollback timer. SSH connection
multiplexing is disabled for these probes so an old public connection cannot
stand in for a working private connection. A failed preflight leaves the running
configuration untouched; a failed post-switch check leaves rollback armed.

This guard is in Ryra's deployment code. Direct `nixos-rebuild` does not perform
that client-side verification. Use an updated Ryra client when changing access.
The setting does not change a cloud provider firewall or enroll your laptop or
phone into Tailscale.

To restore public SSH, set `ryra.access.publicSSH = true` while you still have
private access and deploy. You can then disable Tailscale in a subsequent change.

## App access

Catalog web apps use nginx and listen on loopback by default. Open their address
from `/etc/ryra/apps.json` through Ryra's encrypted connection to the machine.
Public access is explicit in `modules/ryra/web.json`:

```json
{ "ryra/linkding": { "access": "public", "domain": "bookmarks.example.com" } }
```

Point the domain at the machine and allow ports 80 and 443 through the hosting
provider's firewall. NixOS opens its own web ports, configures the app route,
requests the certificate and renews it automatically. Application logins remain
enabled. Private apps can choose a different loopback port with
`{ "access": "private", "port": 8083 }`; ports 80 and 443 are reserved for public
web access. These choices are part of the exported organization configuration.

`nix eval --impure --json --expr 'import ./tests/hosting.nix {}'` checks routing and
HTTPS configuration without building a VM. On a Linux x86-64 host with Nix and
KVM, `bash tests/hosting/run.sh` tests real sign-in, backup restore, HTTPS issuance
and renewal against a disposable ACME server, and cold boot. An optional flake
reference selects a local service checkout, for example `path:/work/ryra-services`.
The test generates its own credentials and removes its VM and disk on exit.

## Network policy checks

`python3 tests/check_access.py` evaluates all four templates in public, private,
and enrollment modes and checks that unsafe SSH rules and missing enrollment
secrets are rejected. These are configuration checks, not a live tailnet test.
