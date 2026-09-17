locals {
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))

  # The user cloud-init creates on every VM. Ansible connects as this, so it is
  # exported in vm_inventory rather than repeated in the inventory script.
  vm_username = "debian"
}
