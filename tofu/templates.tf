# Debian 13 cloud image, pulled straight into Proxmox storage over the API.
resource "proxmox_download_file" "debian_13_genericcloud" {
  content_type = "import"
  datastore_id = "local"
  node_name    = "prox"
  url          = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
  file_name    = "debian-13-genericcloud-amd64.qcow2"
}

# Base template that the VMs in vms.tf clone from. Built purely from the cloud
# image with no software provisioning of any kind -- configure clones with
# Ansible instead.
resource "proxmox_virtual_environment_vm" "debian_13_template" {
  name        = "debian-13-template"
  description = "Managed by OpenTofu"
  node_name   = "prox"
  vm_id       = 2000

  template = true
  started  = false

  # No agent block on purpose: qemu-guest-agent is not in the cloud image, so
  # enabling it would make the provider wait on an agent that never answers.
  stop_on_destroy = true

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

  # The template itself never boots, but this block has to stay: dropping it
  # deletes the cloud-init drive that clones inherit.
  initialization {
    datastore_id = "fastpool"

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = "debian"
      keys     = [local.ssh_public_key]
    }
  }
}
