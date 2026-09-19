packer {
  required_version = ">= 1.11.0"

  required_plugins {
    proxmox = {
      source  = "github.com/hashicorp/proxmox"
      version = "~> 1.2"
    }
  }
}

locals {
  template_name = "tpl-ws2025-${var.edition}"
  build_time    = formatdate("YYYY-MM-DD hh:mm ZZZ", timestamp())

  # Escape XML special characters so any password can be embedded in autounattend.xml.
  admin_password_xml = replace(replace(replace(var.admin_password, "&", "&amp;"), "<", "&lt;"), ">", "&gt;")

  driver_paths = flatten([
    for drive in ["D", "E", "F", "G", "H"] : [
      "${drive}:\\vioscsi\\2k25\\amd64",
      "${drive}:\\NetKVM\\2k25\\amd64",
    ]
  ])

  staging_dir = "C:\\Windows\\Temp\\packer"
}

source "proxmox-iso" "windows_server_2025" {
  # Connection
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  insecure_skip_tls_verify = var.proxmox_insecure_skip_tls_verify
  node                     = var.proxmox_node

  # Template metadata
  vm_id                = var.template_vm_ids[var.edition]
  vm_name              = local.template_name
  template_name        = local.template_name
  template_description = "Windows Server 2025 (${var.edition}) — nrw-corp-lab — built ${local.build_time}"
  tags                 = "nrw-corp-lab;template;windows"

  # Hardware
  os              = "win11"
  machine         = "q35"
  bios            = "ovmf"
  cpu_type        = "x86-64-v2-AES"
  cores           = var.cores
  memory          = var.memory
  scsi_controller = "virtio-scsi-single"
  qemu_agent      = true
  cloud_init      = false

  efi_config {
    efi_storage_pool  = var.storage_pool
    efi_type          = "4m"
    pre_enrolled_keys = true
  }

  disks {
    type         = "scsi"
    disk_size    = var.disk_size
    storage_pool = var.storage_pool
    format       = "raw"
    io_thread    = true
    discard      = true
    ssd          = true
  }

  network_adapters {
    model    = "virtio"
    bridge   = var.bridge
    vlan_tag = var.build_vlan_tag
    firewall = false
  }

  # Installation media. SATA keeps IDE free for the Terraform cloud-init drive (ide2).
  boot_iso {
    type     = "sata"
    index    = 0
    iso_file = var.windows_iso_file
    unmount  = true
  }

  additional_iso_files {
    type     = "sata"
    index    = 1
    iso_file = var.virtio_iso_file
    unmount  = true
  }

  additional_iso_files {
    type             = "sata"
    index            = 2
    iso_storage_pool = var.iso_storage_pool
    unmount          = true
    cd_label         = "PACKER"
    cd_files = [
      "${path.root}/scripts/Install-VirtIOGuestTool.ps1",
      "${path.root}/scripts/Enable-PackerWinRM.ps1",
    ]
    cd_content = {
      "autounattend.xml" = templatefile("${path.root}/templates/autounattend.xml.pkrtpl", {
        admin_password = local.admin_password_xml
        driver_paths   = local.driver_paths
        image_index    = var.image_indexes[var.edition]
        product_key    = var.product_key
        organization   = var.organization
        time_zone      = var.time_zone
        ui_language    = var.ui_language
        input_locale   = var.input_locale
        system_locale  = var.system_locale
        user_locale    = var.user_locale
      })
    }
  }

  # "Press any key to boot from CD or DVD..."
  boot_wait    = "3s"
  boot_command = ["<spacebar><wait1s><spacebar><wait1s><spacebar>"]

  # WinRM over HTTPS with the self-signed certificate created by Enable-PackerWinRM.ps1.
  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.admin_password
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "2h"

  # No shutdown_command: after the last provisioner (sysprep /quit) the Proxmox builder shuts
  # the VM down via ACPI and converts it into a template.
}

build {
  sources = ["source.proxmox-iso.windows_server_2025"]

  provisioner "powershell" {
    inline = ["New-Item -Path '${local.staging_dir}' -ItemType Directory -Force | Out-Null"]
  }

  provisioner "file" {
    sources = [
      "${path.root}/scripts",
      "${path.root}/files/cloudbase-init",
    ]
    destination = "${local.staging_dir}\\"
  }

  provisioner "powershell" {
    inline = [
      "& '${local.staging_dir}\\scripts\\Install-PowerShell.ps1' -Version '${var.powershell_version}'",
    ]
  }

  provisioner "powershell" {
    inline = [
      "& '${local.staging_dir}\\scripts\\Install-CloudbaseInit.ps1' -ConfigurationPath '${local.staging_dir}\\cloudbase-init'",
    ]
  }

  # Must be last: removes the staging directory and generalizes the image for Cloudbase-Init.
  provisioner "powershell" {
    inline = [
      "& '${local.staging_dir}\\scripts\\Invoke-Sysprep.ps1' -CleanupPath '${local.staging_dir}'",
    ]
  }

  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
  }
}
