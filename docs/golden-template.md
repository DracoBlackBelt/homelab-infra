# Golden template (vmid 9000)

The template OpenTofu clones VMs from. Built by hand on the Proxmox host and deliberately
**not** an OpenTofu resource: baking software into a disk means booting a guest and running
apt, which OpenTofu cannot express. Keeping it out of state also means OpenTofu never
claims to know what is on the disk.

`tofu/templates.tf` only *reads* it, through a data source, so a missing or renumbered
template fails at plan time instead of half-way through a clone.

Contents:

- Debian 13 (trixie) genericcloud image
- `qemu-guest-agent`, with `agent: 1` on the VM config so clones inherit the virtio-serial
  channel the daemon needs

Nothing else. tailscale, Docker Engine, swarm membership, and the Komodo agent all arrive
via the Ansible chain after each clone — deliberately: the image stays minimal so every
guest change is a reviewable playbook edit, not an image rebuild.

## What the OpenTofu config depends on

`tofu/vms.tf` inherits most hardware from the clone, but a few things it has to state
explicitly, because the provider has defaults of its own that would otherwise overwrite
them. These must keep matching `qm config 9000`:

| Setting     | Value               | Why tofu cares                                     |
| ----------- | ------------------- | -------------------------------------------------- |
| `bios`      | `ovmf`              | provider default is seabios; the image is UEFI      |
| `efidisk0`  | `efitype=4m`        | OVMF requires an EFI vars disk in the config        |
| `cpu`       | `host`              | provider default is qemu64                          |
| `scsi0`     | disk on `fastpool`  | the disk block is matched by interface name         |
| `scsihw`    | `virtio-scsi-single`| tofu pins this; iothread is only legal with it      |
| `ide2`      | cloudinit drive     | per-VM IP, hostname and SSH key come from cloud-init |
| `agent`     | `enabled=1`         | tofu waits on the agent for a real IP before it calls a VM created |

Change any of these on 9000 and change `tofu/vms.tf` with it. Note the direction of
authority for the disk: `scsihw`, `discard`, `iothread` and `ssd` are written onto every
clone by tofu, so the values on 9000 only matter for clones made by hand.

## Rebuild

Run on the Proxmox host unless marked otherwise. This reproduces the config 9000 has
today. `10.0.0.99` is a throwaway build-time address — the agent isn't installed yet, so
there is no way to discover a DHCP lease.

```bash
wget -O /var/lib/vz/template/iso/debian-13-genericcloud-amd64.qcow2 \
  https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2

qm create 9000 --name debian13-cloud-template --ostype l26 \
  --machine q35 --bios ovmf --cpu host --cores 2 --memory 2048 \
  --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr0 \
  --serial0 socket --vga serial0 --agent enabled=1,fstrim_cloned_disks=1
qm set 9000 --efidisk0 fastpool:0,efitype=4m,pre-enrolled-keys=0
qm set 9000 --scsi0 fastpool:0,discard=on,iothread=1,ssd=1,import-from=/var/lib/vz/template/iso/debian-13-genericcloud-amd64.qcow2
qm set 9000 --ide2 fastpool:cloudinit --boot order=scsi0
qm set 9000 --ipconfig0 ip=10.0.0.99/24,gw=10.0.0.1 --ciuser debian --sshkeys ~/.ssh/authorized_keys
qm set 9000 --description "Golden template - see docs/golden-template.md"
qm start 9000
```

Then, from your workstation:

```bash
ssh debian@10.0.0.99 'sudo apt-get update && sudo apt-get install -y qemu-guest-agent'
ssh debian@10.0.0.99 sudo systemctl reboot
```

The reboot is required, and `systemctl is-active` right after the install is **not** a
valid check — it reports `inactive` even on a correct build. The unit is `static` (no
`[Install]` section); it is started by a udev rule when the virtio port appears. Installing
the package after the VM booted leaves that rule untriggered against an already-present
device. Clones never hit this, because the package is in the image before they boot — which
is the whole point of baking it in.

After the reboot:

```bash
ssh debian@10.0.0.99 systemctl is-active qemu-guest-agent
```

This must print `active`. It is the real proof the build worked: the service `BindsTo`
`/dev/virtio-ports/org.qemu.guest_agent.0`, so it cannot be active unless
`--agent enabled=1` above actually attached the channel.

## Seal it

This part is not optional. Skipping it gives every clone the same machine-id and a
cloud-init that thinks it has already run, so clones silently ignore their own hostname,
SSH key, and network config.

```bash
ssh debian@10.0.0.99 'sudo cloud-init clean --logs && \
  sudo truncate -s 0 /etc/machine-id && \
  sudo rm -f /home/debian/.ssh/authorized_keys && \
  sudo poweroff'
```

Removing `authorized_keys` leaves cloud-init as the only source of SSH keys, so a clone
cannot inherit a key its own config never granted.

Do **not** boot 9000 again after this — cloud-init would re-run and re-bake an instance
id. Go straight to sealing it, back on the Proxmox host:

```bash
qm set 9000 --ipconfig0 ip=dhcp   # drop the build address; OpenTofu sets per-VM IPs
qm template 9000
```

A template can never be started again, only cloned. To change what's in the image,
destroy 9000 and rebuild from the top.

## Verify through OpenTofu

`tofu apply` already waits on the agent — with `agent { enabled = true }` the provider does
not consider a VM created until the guest reports an IP, so an apply that finishes at all
is itself evidence the agent works. To check by hand afterwards:

```bash
ssh debian@<vm-ip> systemctl is-active qemu-guest-agent   # active, with no manual steps
```

The host side should answer too — this returns HTTP 200 once the agent is responding:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H "Authorization: PVEAPIToken=$PVE_TOKEN" \
  "$PVE_ENDPOINT/api2/json/nodes/prox/qemu/<vmid>/agent/ping"
```
