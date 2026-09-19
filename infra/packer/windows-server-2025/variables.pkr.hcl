# ---------------------------------------------------------------------------
# Proxmox connection
# ---------------------------------------------------------------------------
variable "proxmox_url" {
  type        = string
  description = "Proxmox VE API URL, e.g. https://pve01.example.internal:8006/api2/json."
}

variable "proxmox_username" {
  type        = string
  description = "API token ID in the form user@realm!tokenname."
}

variable "proxmox_token" {
  type        = string
  description = "API token secret. Pass via PKR_VAR_proxmox_token, never commit it."
  sensitive   = true
}

variable "proxmox_insecure_skip_tls_verify" {
  type        = bool
  description = "Skip TLS verification of the Proxmox API (self-signed lab certificates)."
  default     = false
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node that runs the build VM."
}

# ---------------------------------------------------------------------------
# Template
# ---------------------------------------------------------------------------
variable "edition" {
  type        = string
  description = "Windows Server installation option: core (Server Core) or desktop (Desktop Experience)."
  default     = "core"

  validation {
    condition     = contains(["core", "desktop"], var.edition)
    error_message = "The edition must be either \"core\" or \"desktop\"."
  }
}

variable "template_vm_ids" {
  type        = map(number)
  description = "VM IDs of the resulting templates per edition. Terraform clones from these IDs."
  default = {
    core    = 9000
    desktop = 9001
  }
}

variable "image_indexes" {
  type        = map(number)
  description = "Index in install.wim per edition. 1/2 = Standard Core/Desktop, 3/4 = Datacenter Core/Desktop."
  default = {
    core    = 1
    desktop = 2
  }
}

variable "product_key" {
  type        = string
  description = "Product key. Leave empty for the evaluation ISO."
  default     = ""
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Media
# ---------------------------------------------------------------------------
variable "windows_iso_file" {
  type        = string
  description = "Windows Server 2025 ISO on a Proxmox storage, e.g. local:iso/SERVER_EVAL_x64FRE_en-us.iso."
}

variable "virtio_iso_file" {
  type        = string
  description = "virtio-win ISO (0.1.266 or newer, contains 2k25 drivers), e.g. local:iso/virtio-win.iso."
}

variable "iso_storage_pool" {
  type        = string
  description = "Storage for the temporary ISO that carries autounattend.xml and the bootstrap scripts."
  default     = "local"
}

# ---------------------------------------------------------------------------
# Hardware
# ---------------------------------------------------------------------------
variable "storage_pool" {
  type        = string
  description = "Storage for the VM disk and EFI disk."
  default     = "local-lvm"
}

variable "disk_size" {
  type        = string
  description = "System disk size of the template. Terraform can grow it per VM, never shrink."
  default     = "40G"
}

variable "cores" {
  type        = number
  description = "vCPU cores of the build VM."
  default     = 2
}

variable "memory" {
  type        = number
  description = "RAM of the build VM in MiB."
  default     = 4096
}

variable "bridge" {
  type        = string
  description = "Bridge for the build VM. The build network needs DHCP and internet access."
  default     = "vmbr0"
}

variable "build_vlan_tag" {
  type        = string
  description = "Optional VLAN tag for the build VM. Empty = untagged."
  default     = ""
}

# ---------------------------------------------------------------------------
# Guest configuration
# ---------------------------------------------------------------------------
variable "admin_password" {
  type        = string
  description = "Build-time password of the local Administrator. Reset per VM by Cloudbase-Init. Pass via PKR_VAR_admin_password."
  sensitive   = true
}

variable "organization" {
  type        = string
  description = "Registered organization."
  default     = "NRW Corp GmbH"
}

variable "time_zone" {
  type        = string
  description = "Windows time zone ID."
  default     = "W. Europe Standard Time"
}

variable "ui_language" {
  type        = string
  description = "Display language. Must exist on the ISO."
  default     = "en-US"
}

variable "input_locale" {
  type        = string
  description = "Keyboard layout."
  default     = "de-DE"
}

variable "system_locale" {
  type        = string
  description = "System locale (non-Unicode programs)."
  default     = "de-DE"
}

variable "user_locale" {
  type        = string
  description = "Formats for dates, numbers and currency."
  default     = "de-DE"
}

variable "powershell_version" {
  type        = string
  description = "PowerShell 7 version baked into the template."
  default     = "7.4.6"
}
