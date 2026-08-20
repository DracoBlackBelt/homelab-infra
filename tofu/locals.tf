locals {
  ssh_public_key = trimspace(file("~/.ssh/id_ed25519.pub"))

  # The user cloud-init creates on every VM. Ansible connects as this, so it is
  # exported in vm_inventory rather than repeated in the inventory script.
  vm_username = "debian"
}
