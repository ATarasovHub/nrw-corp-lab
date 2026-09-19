provider "proxmox" {
  endpoint = var.proxmox_endpoint
  # null falls back to the PROXMOX_VE_API_TOKEN environment variable (recommended).
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  # SSH is required to upload cloud-init snippets to the node.
  ssh {
    agent    = true
    username = var.proxmox_ssh_username
  }
}
