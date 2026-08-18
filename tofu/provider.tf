provider "proxmox" {
  endpoint  = var.pve_endpoint          # "https://pve.lan:8006/"
  api_token = var.pve_api_token         # "terraform@pve!tf=xxxxxxxx-..."
  insecure  = false                     # true only if still on the self-signed cert
}
