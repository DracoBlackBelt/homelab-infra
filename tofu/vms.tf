# VMs cloned from the template in templates.tf. Add an entry to create one.
# cores/memory/disk_size are optional -- omit them to take the defaults.
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
    vm_id = proxmox_virtual_environment_vm.debian_13_template.vm_id
  }

  # No agent block on purpose: qemu-guest-agent is not in the cloud image, so
  # enabling it would make the provider wait ~15m on an agent that never
  # answers. stop_on_destroy avoids an ACPI shutdown that hangs for the same
  # reason.
  stop_on_destroy = true

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = "fastpool"
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
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
      username = "debian"
      keys     = [local.ssh_public_key]
    }
  }
}

# Static IPs for the Ansible inventory. The guest agent is off, so Proxmox
# cannot report guest IPs and these config values are the source of truth.
output "vm_addresses" {
  value = { for k, v in var.vms : v.name => split("/", v.address)[0] }
}
