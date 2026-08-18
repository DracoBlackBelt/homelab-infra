moved {
  from = proxmox_virtual_environment_vm.test_vm01
  to   = proxmox_virtual_environment_vm.debian_13_template
}

resource "proxmox_download_file" "debian_13_genericcloud" {
  content_type = "import"
  datastore_id = "local"
  node_name    = "prox"
  url          = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
  file_name    = "debian-13-genericcloud-amd64.qcow2"
}

# Base image for cloning VMs from. qemu-guest-agent is already installed
# and enabled on its disk, so clones don't need to install it on first boot.
resource "proxmox_virtual_environment_vm" "debian_13_template" {
  name        = "debian-13-template"
  description = "Managed by OpenTofu"
  node_name   = "prox"
  vm_id       = 2000

  template = true
  started  = false

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = "fastpool"
    import_from  = proxmox_download_file.debian_13_genericcloud.id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 8
  }

  network_device {
    bridge = "vmbr0"
  }

  initialization {
    datastore_id = "fastpool"

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = "debian"
      keys     = [trimspace(file("~/.ssh/id_ed25519.pub"))]
    }
  }
}

resource "proxmox_virtual_environment_vm" "vm01" {
  name        = "test-vm01"
  description = "Managed by OpenTofu"
  node_name   = "prox"
  vm_id       = 211

  clone {
    vm_id = proxmox_virtual_environment_vm.debian_13_template.vm_id
  }

  agent {
    enabled = true
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
  }

  network_device {
    bridge = "vmbr0"
  }

  initialization {
    datastore_id = "fastpool"

    ip_config {
      ipv4 {
        address = "10.0.0.41/24"
        gateway = "10.0.0.1"
      }
    }

    user_account {
      username = "debian"
      keys     = [trimspace(file("~/.ssh/id_ed25519.pub"))]
    }
  }
}
