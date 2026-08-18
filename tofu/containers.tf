resource "proxmox_virtual_environment_container" "test01" {
  node_name    = "prox"
  vm_id        = 210
  description  = "Managed by OpenTofu"
  unprivileged = true
  started      = true

  features {
    nesting = true
  }

  cpu { cores = 2 }
  memory { dedicated = 1024 }

  disk {
    datastore_id = "fastpool"
    size         = 8
  }

  network_interface {
    name   = "veth0"
    bridge = "vmbr0"
  }

  operating_system {
    template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
    type             = "debian"
  }

  initialization {
    hostname = "test01"
    ip_config {
      ipv4 {
        address = "10.0.0.40/24"
        gateway = "10.0.0.1"
      }
    }
    user_account {
      keys = [local.ssh_public_key]
    }
  }
}
