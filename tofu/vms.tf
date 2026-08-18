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

  # enabled attaches the virtio-serial channel the agent daemon BindsTo, so the
  # agent works as soon as ansible/guest-agent.yml installs it. wait_for_ip
  # stays disabled permanently: a freshly cloned VM never has the agent yet, and
  # waiting on it is what made apply hang for 15m.
  agent {
    enabled = true
    wait_for_ip { disabled = true }
  }

  # Without the agent an ACPI shutdown can hang, so force-stop on destroy.
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
