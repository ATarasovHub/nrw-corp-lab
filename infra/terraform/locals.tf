locals {
  # docs/02-network.md: one /24 per VLAN, third octet = VLAN ID, gateway = .1
  subnets = { for segment, id in var.vlan_ids : segment => "${var.network_prefix}.${id}.0/24" }
  gateway = { for segment, cidr in local.subnets : segment => cidrhost(cidr, 1) }

  dc01_ip = cidrhost(local.subnets.servers, 11)
  dc02_ip = cidrhost(local.subnets.servers, 12)
  dc_ips  = [local.dc01_ip, local.dc02_ip]

  client_template_id = coalesce(var.windows_client_template_id, var.windows_desktop_template_id)

  # host_number = null means DHCP.
  windows_servers = {
    MGMT01 = {
      vm_id        = 110
      template_id  = var.windows_desktop_template_id
      segment      = "mgmt"
      host_number  = 10
      cores        = 2
      memory_mb    = 4096
      disk_gb      = var.disk_sizes_gb.mgmt
      data_disk_gb = 0
      dns_servers  = local.dc_ips
      started      = true
      role_tags    = ["mgmt"]
    }
    # DCs: partner first, loopback second (docs/02-network.md#dc-dns-client-settings).
    DC01 = {
      vm_id        = 211
      template_id  = var.windows_core_template_id
      segment      = "servers"
      host_number  = 11
      cores        = 2
      memory_mb    = 3072
      disk_gb      = var.disk_sizes_gb.dc
      data_disk_gb = 0
      dns_servers  = [local.dc02_ip, "127.0.0.1"]
      started      = true
      role_tags    = ["dc"]
    }
    DC02 = {
      vm_id        = 212
      template_id  = var.windows_core_template_id
      segment      = "servers"
      host_number  = 12
      cores        = 2
      memory_mb    = 3072
      disk_gb      = var.disk_sizes_gb.dc
      data_disk_gb = 0
      dns_servers  = [local.dc01_ip, "127.0.0.1"]
      started      = true
      role_tags    = ["dc"]
    }
    FS01 = {
      vm_id        = 221
      template_id  = var.windows_core_template_id
      segment      = "servers"
      host_number  = 21
      cores        = 2
      memory_mb    = 3072
      disk_gb      = var.disk_sizes_gb.fs_os
      data_disk_gb = var.disk_sizes_gb.fs_data
      dns_servers  = local.dc_ips
      started      = true
      role_tags    = ["fileserver"]
    }
  }

  windows_clients = {
    for index in range(var.client_count) : format("WS%03d", index + 1) => {
      vm_id        = 301 + index
      template_id  = local.client_template_id
      segment      = "clients"
      host_number  = null
      cores        = 2
      memory_mb    = 4096
      disk_gb      = var.disk_sizes_gb.client
      data_disk_gb = 0
      dns_servers  = local.dc_ips
      started      = var.start_clients
      role_tags    = ["client"]
    }
  }

  windows_vms = merge(local.windows_servers, local.windows_clients)

  linux_vms = {
    for index in range(var.linux_count) : format("LNX%02d", index + 1) => {
      vm_id       = 231 + index
      segment     = "servers"
      host_number = 31 + index
      cores       = 2
      memory_mb   = 2048
      disk_gb     = var.disk_sizes_gb.linux
    }
  }
}
