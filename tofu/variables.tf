variable "pve_endpoint" { type = string }

variable "pve_api_token" {
  type        = string
  default     = null
  sensitive   = true
  description = "Set via TF_VAR_pve_api_token; never commit. See AGENTS.md."
  validation {
    condition     = var.pve_api_token != null && length(var.pve_api_token) > 0
    error_message = "pve_api_token is empty. Export TF_VAR_pve_api_token before running tofu (see AGENTS.md)."
  }
}

variable "ssh_public_key_path" {
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
  description = "Tilde-expanded path to the SSH public key cloud-init installs for the debian user."
}
