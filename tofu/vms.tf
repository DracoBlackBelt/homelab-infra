# VMs cloned from the golden template (templates.tf). This file is the schema,
# not the inventory: the actual VMs live in terraform.tfvars, which is committed.
# cores/memory/gateway/disk_size are optional -- omit them for the type defaults.
#
# disk_size must be >= the template's (16 GiB): a clone inherits its volume and
# Proxmox can only grow a disk, never shrink it, so a smaller value fails at apply.
variable "vms" {
  type = map(object({
    vm_id     = number
    name      = string
    address   = string
    gateway   = optional(string, "10.0.0.1")
    cores     = optional(number, 1)
    memory    = optional(number, 1024)
    disk_size = optional(number, 16)
  }))

  default = {}

  validation {
    condition     = alltrue([for v in var.vms : can(cidrhost(v.address, 0))])
    error_message = "Each vm.address must be CIDR, e.g. \"10.0.0.41/24\"."
  }
}

# Not proxmox_cloned_vm (experimental): it cannot manage the cloud-init
# initialization block, EFI or the guest agent -- all load-bearing here.
resource "proxmox_virtual_environment_vm" "vms" {
  for_each = var.vms

  name      = each.value.name
  node_name = "prox"
  vm_id     = each.value.vm_id

  clone {
    vm_id = data.proxmox_vm.golden_template.id
  }

  # The agent is on the template's disk; enabling it here attaches the
  # virtio-serial channel it binds to, so it answers on first boot. The provider
  # then waits for a real guest IP before reporting the VM created. timeout beats
  # the 15m default: no answer in 5m means the template is broken.
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

  # Pinned: a clone inherits boot order from the template, but the template's
  # --boot order=scsi0 (docs/golden-template.md) is the only thing keeping it
  # off ide2 (the cloud-init drive) here. Explicit beats implicit.
  boot_order = ["scsi0"]

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
    model  = "virtio"
  }

  initialization {
    datastore_id = "fastpool"

    ip_config {
      ipv4 {
        address = each.value.address
        gateway = each.value.gateway
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
    precondition {
      condition     = each.key == each.value.name
      error_message = "vm map key (${each.key}) must equal vm.name (${each.value.name}); pick one or the other."
    }
  }
}

# Consumed by ansible/inventory/tofu.py -- the inventory for the VMs (prox.yml
# adds the Proxmox host). Add a VM in terraform.tfvars, apply, and Ansible picks
# it up with nothing to sync by hand. Addresses come from the config, not the
# agent's report, so they cannot go stale between an apply and a play.
output "vm_inventory" {
  description = "name => host vars, consumed by the Ansible inventory script."

  value = {
    for k, v in var.vms : v.name => {
      ansible_host = split("/", v.address)[0]
      ansible_user = local.vm_username
    }
  }
}
