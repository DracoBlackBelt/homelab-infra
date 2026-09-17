pve_endpoint = "https://prox.int.huisman.dev"

# The PVE API token is exported as TF_VAR_pve_api_token in the shell -- never
# committed. See AGENTS.md.
#
# Declare VMs here (this file is COMMITTED -- it is the inventory the repo
# rebuilds from; vms.tf only defines the schema).
# Every entry becomes a clone of the golden template AND an Ansible host after
# the next `tofu apply`. cores/memory/disk_size/gateway are optional
# (1 / 1024MB / 16GiB / 10.0.0.1).
#
# Managers hold the 3-node raft quorum and the Traefik edge; workers run the
# app tasks. Applying a memory change reboots a VM, so resize managers with
# -parallelism=1 to keep quorum (never all three at once).
vms = {
  # --- managers: raft quorum + edge (control plane only) ---
  komodo-srv-01 = { vm_id = 211, name = "komodo-srv-01", address = "10.0.0.41/24", cores = 2, memory = 2048 }
  komodo-srv-02 = { vm_id = 212, name = "komodo-srv-02", address = "10.0.0.42/24", cores = 2, memory = 2048 }
  komodo-srv-03 = { vm_id = 213, name = "komodo-srv-03", address = "10.0.0.43/24", cores = 2, memory = 2048 }

  # --- workers: application tasks ---
  swarm-wrk-01 = { vm_id = 214, name = "swarm-wrk-01", address = "10.0.0.44/24", cores = 4, memory = 5120, disk_size = 32 }
  swarm-wrk-02 = { vm_id = 215, name = "swarm-wrk-02", address = "10.0.0.45/24", cores = 4, memory = 5120, disk_size = 32 }
  swarm-wrk-03 = { vm_id = 216, name = "swarm-wrk-03", address = "10.0.0.46/24", cores = 4, memory = 5120, disk_size = 64 }
}
