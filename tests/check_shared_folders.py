"""Evaluate shared-space access and home shortcuts across all machine presets."""
import json
from pathlib import Path
import subprocess
import shlex
import sys

ROOT = Path(__file__).resolve().parents[1]
if len(sys.argv) == 2:
    results = json.loads(Path(sys.argv[1]).read_text())
else:
    results = json.loads(subprocess.check_output(
        ["nix", "eval", "--impure", "--json", "--file", str(ROOT / "tests/shared-folders.nix")],
        text=True,
    ))

for preset, cases in results["presets"].items():
    enabled = cases["enabled"]
    assert not enabled["failures"], (preset, enabled["failures"])
    assert cases["disabled"] == [], (preset, "shared storage unexpectedly enabled")
    assert enabled["groups"] == {
        "ryra-shared-company": ["alice", "bob"],
        "ryra-shared-research": ["alice"],
    }, (preset, enabled["groups"])
    assert "acl" in enabled["packages"], preset
    assert enabled["mountPaths"] == enabled["activationMountPaths"], preset
    expected_mounts = {
        "/srv/shared", "/srv/shared/company", "/srv/shared/research",
        "/home/alice", "/home/bob work",
    }
    # Verify the rendered unit, where an unquoted home with a space becomes
    # two mount requirements even though the Nix list looked correct.
    mounted = []
    for line in enabled["activationUnit"].splitlines():
        if line.startswith("RequiresMountsFor="):
            mounted.extend(shlex.split(line.split("=", 1)[1]))
    assert set(mounted) == expected_mounts, (preset, mounted)
    rules = enabled["rules"]
    assert len(rules) == 10, (preset, rules)
    assert not any("carol" in rule for rule in rules), preset
    links = [rule for rule in rules if rule.startswith("L ")]
    assert len(links) == 3, (preset, links)
    assert not any(rule.startswith(("L+", "D ", "R ", "r ", "Z ")) for rule in rules), rules
    assert any('"/home/bob work/Shared/Company"' in rule for rule in links), links
    print(f"{preset}: optional spaces, separate groups, personal shortcuts and mount ordering passed")

removed = results["removedMember"]
assert removed["groups"]["ryra-shared-company"] == ["alice"], removed
assert not any("bob" in rule for rule in removed["rules"]), removed
for case, failures in results["rejected"].items():
    assert failures, (case, "invalid shared-space configuration accepted")
assert results["invalidLabelRejected"], "path traversal in a shortcut label accepted"
print("Membership removal and invalid membership, names and shortcut collisions passed")
