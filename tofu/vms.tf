# VMs cloned from the golden template looked up in templates.tf. Add an entry to
# create one. cores/memory/disk_size are optional -- omit them for the defaults.
variable "vms" {
  type = map(object({
    vm_id     = number
    name      = string
    address   = string
    cores     = optional(number, 2)
    memory    = optional(number, 2048)
    disk_size = optional(number, 8)
  }))

  default = {
    vm01 = { vm_id = 211, name = "test-vm01", address = "10.0.0.41/24" }
  }
}

resource "proxmox_virtual_environment_vm" "vms" {
  for_each = var.vms

  name        = each.value.name
  description = "Managed by OpenTofu"
  node_name   = "prox"
  vm_id       = each.value.vm_id

  clone {
    vm_id = data.proxmox_vm.golden_template.id
  }

  # qemu-guest-agent is already on the template's disk, so enabling the agent
  # here attaches the virtio-serial channel the daemon binds to and it answers
  # on first boot -- no provisioning step. The provider therefore waits for a
  # real guest IP before calling the VM created. timeout cuts the 15m default
  # down: if the agent has not answered within 5m the template is broken, and
  # failing fast beats a quarter-hour hang.
  agent {
    enabled = true
    timeout = "5m"
    trim    = true
  }

  # These VMs are disposable, so force-stop on destroy rather than waiting out a
  # graceful shutdown.
  stop_on_destroy = true

  # Hardware is otherwise inherited from the template, but these two cannot be:
  # the provider has defaults of its own for them, and would push seabios and a
  # qemu64 CPU onto an image built as UEFI with cpu=host.
  bios = "ovmf"

  # The clone brings its own EFI vars disk along; this block exists because the
  # provider requires one whenever bios is ovmf. Values match the template's.
  efi_disk {
    datastore_id      = "fastpool"
    type              = "4m"
    pre_enrolled_keys = false
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  # virtio-scsi-single gives the disk its own controller, which is what makes
  # iothread legal -- on virtio-scsi-pci Proxmox ignores the flag. The provider
  # would send its own virtio-scsi-pci default here, so this line is what keeps
  # clones off it, whatever the template says.
  scsi_hardware = "virtio-scsi-single"

  # scsi0 because that is where the template's disk lives and what its boot
  # order points at. discard lets a guest fstrim return blocks to the ZFS pool,
  # which is also what makes the template's fstrim_cloned_disks=1 do anything.
  # ssd only advertises the zvol as non-rotational, so the guest stops treating
  # it like a spindle.
  disk {
    datastore_id = "fastpool"
    interface    = "scsi0"
    discard      = "on"
    iothread     = true
    ssd          = true
    size         = each.value.disk_size
  }

  network_device {
    bridge = "vmbr0"
  }

  initialization {
    datastore_id = "fastpool"

    ip_config {
      ipv4 {
        address = each.value.address
        gateway = "10.0.0.1"
      }
    }

    user_account {
      username = local.vm_username
      keys     = [local.ssh_public_key]
    }
  }

  lifecycle {
    precondition {
      condition     = data.proxmox_vm.golden_template.template
      error_message = "vmid ${var.template_vm_id} exists but is not a Proxmox template -- run `qm template ${var.template_vm_id}`, or see docs/golden-template.md."
    }
  }
}

# Read by ansible/inventory/tofu.py, which is Ansible's only inventory: add a VM
# to the map above and Ansible picks it up on the next run, with nothing to keep
# in sync by hand.
#
# The addresses come from the config rather than from the agent's report. They
# are what cloud-init was told to set, so they are known before the VM boots and
# cannot go stale between an apply and a play.
output "vm_inventory" {
  description = "name => host vars, consumed by the Ansible inventory script."

  value = {
    for k, v in var.vms : v.name => {
      ansible_host = split("/", v.address)[0]
      ansible_user = local.vm_username
    }
  }
}
