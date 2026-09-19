output "subnets" {
  description = "Subnet per network segment."
  value       = local.subnets
}

output "windows_vms" {
  description = "Windows VMs with VM ID, VLAN and planned IPv4 address (dhcp for clients)."
  value = {
    for name, vm in local.windows_vms : name => {
      vm_id   = proxmox_virtual_environment_vm.windows[name].vm_id
      vlan_id = var.vlan_ids[vm.segment]
      ipv4    = vm.host_number == null ? "dhcp" : cidrhost(local.subnets[vm.segment], vm.host_number)
    }
  }
}

output "linux_vms" {
  description = "Linux VMs with VM ID, VLAN and IPv4 address."
  value = {
    for name, vm in local.linux_vms : name => {
      vm_id   = proxmox_virtual_environment_vm.linux[name].vm_id
      vlan_id = var.vlan_ids[vm.segment]
      ipv4    = cidrhost(local.subnets[vm.segment], vm.host_number)
    }
  }
}

output "router_vm_id" {
  description = "VM ID of RTR01, or null if the router is not deployed."
  value       = one(proxmox_virtual_environment_vm.router[*].vm_id)
}
