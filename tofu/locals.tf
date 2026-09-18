locals {
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))

  # User cloud-init creates on every VM; also exported in vm_inventory so the
  # inventory script does not repeat it.
  vm_username = "debian"
}
