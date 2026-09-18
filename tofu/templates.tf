# The golden template (docs/golden-template.md) is deliberately not an OpenTofu
# resource: baking software into a disk means booting a guest and running apt,
# which OpenTofu cannot express. This data source only reads it -- its one job is
# to fail at plan time if the vmid is missing or renumbered, instead of half-way
# through a clone.
variable "template_vm_id" {
  type        = number
  default     = 9000
  description = "vmid of the hand-built golden template (docs/golden-template.md)."
}

data "proxmox_vm" "golden_template" {
  node_name = "prox"
  id        = var.template_vm_id
}
