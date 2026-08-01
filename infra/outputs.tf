output "vm_ips" {
  value = { for k, v in local.vms : k => split("/", v.ip)[0] }
}

output "vm_ids" {
  value = { for k, v in local.vms : k => v.vm_id }
}
