# ---------------------------------------------------------------------------
# RTR01 — OPNsense router/firewall (installed interactively from ISO)
# ---------------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "router" {
  count = var.deploy_router ? 1 : 0

  name        = "RTR01"
  description = "OPNsense router, firewall, DNS resolver and DHCP relay. Managed by Terraform (nrw-corp-lab)."
  node_name   = var.proxmox_node
  vm_id       = 100
  tags        = sort(concat(var.tags, ["router"]))
  on_boot     = true

  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  boot_order    = ["scsi0", "ide3"]

  operating_system {
    type = "other"
  }

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = var.datastore_vm
    interface    = "scsi0"
    size         = var.disk_sizes_gb.router
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  cdrom {
    file_id   = var.opnsense_iso_file_id
    interface = "ide3"
  }

  # vtnet0 — WAN
  network_device {
    bridge = var.bridge_wan
    model  = "virtio"
  }

  # vtnet1 — trunk with all lab VLANs; OPNsense creates one VLAN interface per segment.
  network_device {
    bridge = var.bridge_lan
    model  = "virtio"
    trunks = join(";", [for id in values(var.vlan_ids) : tostring(id)])
  }

  lifecycle {
    precondition {
      condition     = var.opnsense_iso_file_id != null
      error_message = "Set opnsense_iso_file_id or disable the router with deploy_router = false."
    }
  }
}

# ---------------------------------------------------------------------------
# Windows VMs — cloned from Packer templates, configured by Cloudbase-Init
# ---------------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "windows" {
  for_each = local.windows_vms

  name        = each.key
  description = "Managed by Terraform (nrw-corp-lab)."
  node_name   = var.proxmox_node
  vm_id       = each.value.vm_id
  tags        = sort(concat(var.tags, ["windows"], each.value.role_tags))
  on_boot     = true
  started     = each.value.started

  machine         = "q35"
  bios            = "ovmf"
  scsi_hardware   = "virtio-scsi-single"
  stop_on_destroy = true

  clone {
    vm_id = each.value.template_id
    full  = true
  }

  operating_system {
    type = "win11"
  }

  agent {
    enabled = true
    timeout = "20m"
  }

  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory_mb
  }

  efi_disk {
    datastore_id = var.datastore_vm
    type         = "4m"
  }

  disk {
    datastore_id = var.datastore_vm
    interface    = "scsi0"
    size         = each.value.disk_gb
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  dynamic "disk" {
    for_each = { for index, size in each.value.extra_disks : "scsi${index + 1}" => size }

    content {
      datastore_id = var.datastore_vm
      interface    = disk.key
      size         = disk.value
      iothread     = true
      discard      = "on"
      ssd          = true
      file_format  = "raw"
    }
  }

  network_device {
    bridge  = var.bridge_lan
    model   = "virtio"
    vlan_id = var.vlan_ids[each.value.segment]
  }

  # Proxmox cloud-init drive in ConfigDrive v2 format, read by Cloudbase-Init.
  initialization {
    type         = "configdrive2"
    datastore_id = var.datastore_vm
    interface    = "ide2"

    dns {
      domain  = var.ad_domain
      servers = each.value.dns_servers
    }

    ip_config {
      ipv4 {
        address = each.value.host_number == null ? "dhcp" : "${cidrhost(local.subnets[each.value.segment], each.value.host_number)}/24"
        gateway = each.value.host_number == null ? null : local.gateway[each.value.segment]
      }
    }

    user_account {
      username = "Administrator"
      password = var.windows_admin_password
    }
  }
}

# ---------------------------------------------------------------------------
# Ubuntu VMs — cloud image + cloud-init (NoCloud)
# ---------------------------------------------------------------------------
resource "proxmox_download_file" "ubuntu_cloud_image" {
  count = var.linux_count > 0 ? 1 : 0

  node_name           = var.proxmox_node
  datastore_id        = var.datastore_files
  content_type        = "iso"
  file_name           = "nrw-corp-lab-${basename(var.ubuntu_cloud_image_url)}"
  url                 = var.ubuntu_cloud_image_url
  checksum            = var.ubuntu_cloud_image_checksum
  checksum_algorithm  = var.ubuntu_cloud_image_checksum == null ? null : "sha256"
  overwrite_unmanaged = true
}

resource "proxmox_virtual_environment_file" "ubuntu_user_data" {
  for_each = local.linux_vms

  node_name    = var.proxmox_node
  datastore_id = var.datastore_files
  content_type = "snippets"

  source_raw {
    file_name = "${lower(each.key)}-user-data.yaml"
    data = templatefile("${path.module}/../cloud-init/ubuntu-user-data.yaml.tftpl", {
      hostname        = lower(each.key)
      domain          = var.ad_domain
      admin_username  = var.linux_admin_username
      ssh_public_keys = var.ssh_public_keys
      ntp_servers     = local.dc_ips
    })
  }
}

resource "proxmox_virtual_environment_vm" "linux" {
  for_each = local.linux_vms

  name            = each.key
  description     = "Ubuntu member server. Managed by Terraform (nrw-corp-lab)."
  node_name       = var.proxmox_node
  vm_id           = each.value.vm_id
  tags            = sort(concat(var.tags, ["linux"]))
  on_boot         = true
  stop_on_destroy = true

  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true
    timeout = "10m"
  }

  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory_mb
  }

  # Ubuntu cloud images log to the serial console.
  serial_device {}

  disk {
    datastore_id = var.datastore_vm
    file_id      = proxmox_download_file.ubuntu_cloud_image[0].id
    interface    = "scsi0"
    size         = each.value.disk_gb
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge  = var.bridge_lan
    model   = "virtio"
    vlan_id = var.vlan_ids[each.value.segment]
  }

  initialization {
    datastore_id      = var.datastore_vm
    interface         = "ide2"
    user_data_file_id = proxmox_virtual_environment_file.ubuntu_user_data[each.key].id

    dns {
      domain  = var.ad_domain
      servers = local.dc_ips
    }

    ip_config {
      ipv4 {
        address = "${cidrhost(local.subnets[each.value.segment], each.value.host_number)}/24"
        gateway = local.gateway[each.value.segment]
      }
    }
  }

  lifecycle {
    precondition {
      condition     = length(var.ssh_public_keys) > 0
      error_message = "Linux VMs allow SSH key login only. Set at least one entry in ssh_public_keys."
    }
  }
}
