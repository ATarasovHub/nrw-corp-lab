# ---------------------------------------------------------------------------
# Proxmox connection
# ---------------------------------------------------------------------------
variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox VE API endpoint, e.g. https://pve01.example.internal:8006/."
}

variable "proxmox_api_token" {
  type        = string
  description = "API token as user@realm!tokenid=secret. Leave null and set PROXMOX_VE_API_TOKEN instead."
  default     = null
  sensitive   = true
}

variable "proxmox_insecure" {
  type        = bool
  description = "Skip TLS verification of the Proxmox API (self-signed lab certificates)."
  default     = false
}

variable "proxmox_ssh_username" {
  type        = string
  description = "SSH user on the Proxmox node, used to upload cloud-init snippets. Authentication via ssh-agent."
  default     = "root"
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node that hosts the lab."
  default     = "pve01"
}

# ---------------------------------------------------------------------------
# Storage and bridges
# ---------------------------------------------------------------------------
variable "datastore_vm" {
  type        = string
  description = "Datastore for VM disks, EFI disks and cloud-init drives."
  default     = "local-lvm"
}

variable "datastore_files" {
  type        = string
  description = "File-based datastore with the 'iso' and 'snippets' content types enabled."
  default     = "local"
}

variable "bridge_lan" {
  type        = string
  description = "VLAN-aware Linux bridge that carries all lab VLANs."
  default     = "vmbr1"
}

variable "bridge_wan" {
  type        = string
  description = "Bridge with upstream/internet connectivity, used for the router's WAN interface."
  default     = "vmbr0"
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
variable "vlan_ids" {
  type = object({
    mgmt    = number
    servers = number
    clients = number
    guest   = number
  })
  description = "802.1Q VLAN IDs per network segment (docs/02-network.md)."
  default = {
    mgmt    = 10
    servers = 20
    clients = 30
    guest   = 40
  }

  validation {
    # The third octet of each subnet mirrors the VLAN ID, so it must be a valid octet.
    condition     = alltrue([for id in values(var.vlan_ids) : id >= 2 && id <= 254])
    error_message = "VLAN IDs must be between 2 and 254 because they are used as the third octet of the subnet."
  }

  validation {
    condition     = length(distinct(values(var.vlan_ids))) == length(values(var.vlan_ids))
    error_message = "VLAN IDs must be unique."
  }
}

variable "network_prefix" {
  type        = string
  description = "First two octets of the lab supernet. Subnets are <prefix>.<vlan_id>.0/24."
  default     = "10.10"

  validation {
    condition     = can(regex("^(\\d{1,3})\\.(\\d{1,3})$", var.network_prefix))
    error_message = "The network prefix must look like \"10.10\"."
  }
}

variable "ad_domain" {
  type        = string
  description = "DNS name of the AD domain, used as DNS search domain."
  default     = "ad.nrwcorp.internal"
}

# ---------------------------------------------------------------------------
# Sizing
# ---------------------------------------------------------------------------
variable "client_count" {
  type        = number
  description = "Number of Windows client VMs (WS001, WS002, ...)."
  default     = 2

  validation {
    condition     = var.client_count >= 0 && var.client_count <= 30 && floor(var.client_count) == var.client_count
    error_message = "The client count must be a whole number between 0 and 30."
  }
}

variable "linux_count" {
  type        = number
  description = "Number of Ubuntu member servers (LNX01, ...)."
  default     = 1

  validation {
    condition     = var.linux_count >= 0 && var.linux_count <= 9 && floor(var.linux_count) == var.linux_count
    error_message = "The Linux server count must be a whole number between 0 and 9."
  }
}

variable "disk_sizes_gb" {
  type = object({
    dc      = optional(number, 60)
    fs_os   = optional(number, 60)
    fs_data = optional(number, 100)
    mgmt    = optional(number, 60)
    client  = optional(number, 64)
    linux   = optional(number, 32)
    router  = optional(number, 20)
  })
  description = "Disk sizes in GB per role. Windows disks must be at least the template disk size."
  default     = {}

  validation {
    condition     = alltrue([for size in values(var.disk_sizes_gb) : size >= 16 && size <= 2048])
    error_message = "Disk sizes must be between 16 and 2048 GB."
  }
}

variable "start_clients" {
  type        = bool
  description = "Start client VMs after creation. Keep false until DHCP runs on the DCs (clients use DHCP)."
  default     = false
}

# ---------------------------------------------------------------------------
# Templates and images
# ---------------------------------------------------------------------------
variable "windows_core_template_id" {
  type        = number
  description = "VM ID of the Windows Server 2025 Core template built by Packer."
  default     = 9000
}

variable "windows_desktop_template_id" {
  type        = number
  description = "VM ID of the Windows Server 2025 Desktop Experience template built by Packer."
  default     = 9001
}

variable "windows_client_template_id" {
  type        = number
  description = "VM ID of the client template (e.g. Windows 11 with Cloudbase-Init). null = use the Desktop Experience template."
  default     = null
}

variable "ubuntu_cloud_image_url" {
  type        = string
  description = "Ubuntu cloud image URL."
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "ubuntu_cloud_image_checksum" {
  type        = string
  description = "Optional SHA256 of the cloud image (from SHA256SUMS next to the image)."
  default     = null
}

variable "opnsense_iso_file_id" {
  type        = string
  description = "Pre-uploaded OPNsense DVD ISO, e.g. local:iso/OPNsense-dvd-amd64.iso. Required if deploy_router is true."
  default     = null
}

variable "deploy_router" {
  type        = bool
  description = "Create the RTR01 router VM (OPNsense, installed interactively from ISO)."
  default     = true
}

# ---------------------------------------------------------------------------
# Credentials (never commit values)
# ---------------------------------------------------------------------------
variable "windows_admin_password" {
  type        = string
  description = "Local Administrator password set by Cloudbase-Init on every Windows VM. Pass via TF_VAR_windows_admin_password."
  sensitive   = true

  validation {
    condition     = length(var.windows_admin_password) >= 14
    error_message = "The Administrator password must be at least 14 characters (docs/03-ad-design.md)."
  }
}

variable "linux_admin_username" {
  type        = string
  description = "Administrative user created by cloud-init on Linux VMs."
  default     = "labadmin"
}

variable "ssh_public_keys" {
  type        = list(string)
  description = "SSH public keys authorized for the Linux admin user. Password login is disabled."
  default     = []
}

variable "tags" {
  type        = list(string)
  description = "Tags added to every VM."
  default     = ["nrw-corp-lab", "terraform"]
}
