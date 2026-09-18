#!/usr/bin/env python3
"""Ansible inventory built from the OpenTofu `vm_inventory` output.

The VMs declared in tofu/terraform.tfvars are the only source of truth: this
reads what tofu knows and hands it to Ansible, so adding a VM there is enough
to make Ansible see it.

Reads state only -- no Proxmox API calls, so it does not care whether the VMs
are up. Before the first apply there are no outputs yet and the inventory is
simply empty, which makes plays report "no hosts matched" instead of failing.
"""

import json
import os
import shutil
import subprocess
import sys

TOFU_DIR = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tofu")
)
GROUP = "vms"


def warn(message):
    print(f"tofu inventory: {message}", file=sys.stderr)


def tofu_outputs():
    """Every output as a dict, or an empty dict if tofu cannot tell us."""
    if shutil.which("tofu") is None:
        warn("tofu is not on PATH, returning an empty inventory")
        return {}

    try:
        result = subprocess.run(
            ["tofu", f"-chdir={TOFU_DIR}", "output", "-json"],
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=60,
        )
    except subprocess.TimeoutExpired:
        warn("`tofu output` timed out after 60s, returning an empty inventory")
        return {}
    if result.returncode != 0:
        warn(f"`tofu output` failed, returning an empty inventory: {result.stderr.strip()}")
        return {}

    try:
        return json.loads(result.stdout or "{}")
    except json.JSONDecodeError as exc:
        warn(f"could not parse `tofu output` as JSON: {exc}")
        return {}


def inventory():
    # The `or {}` fallbacks matter: dict defaults only cover a missing key, so a
    # present-but-null vm_inventory would otherwise reach sorted(None) and crash
    # the whole inventory instead of degrading to empty.
    hostvars = (tofu_outputs().get("vm_inventory") or {}).get("value") or {}
    if not hostvars:
        warn(f"no VMs in the tofu state -- has `tofu -chdir={TOFU_DIR} apply` run?")

    return {
        GROUP: {"hosts": sorted(hostvars)},
        "_meta": {"hostvars": hostvars},
    }


def main():
    args = sys.argv[1:]
    if args[:1] == ["--host"]:
        # Everything is in _meta already, so per-host lookups have nothing to add.
        print(json.dumps({}))
        return 0
    if args[:1] != ["--list"]:
        print(f"usage: {os.path.basename(sys.argv[0])} --list | --host <hostname>", file=sys.stderr)
        return 2

    print(json.dumps(inventory(), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
