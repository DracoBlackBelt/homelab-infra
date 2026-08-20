# The template that vms.tf clones from is built by hand on the Proxmox host and
# is deliberately not an OpenTofu resource -- see docs/golden-template.md.
# Baking software into a disk means booting a guest and running apt, which
# OpenTofu cannot express, so anything it claimed to know about the disk would
# be a guess.
#
# This data source only reads the template. Its one job is to fail at plan time
# with a clear message if the vmid is missing or renumbered, instead of failing
# half-way through a clone.
variable "template_vm_id" {
  type        = number
  default     = 9000
  description = "vmid of the hand-built golden template (docs/golden-template.md)."
}

data "proxmox_vm" "golden_template" {
  node_name = "prox"
  id        = var.template_vm_id
}
