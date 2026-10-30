terraform {
  required_providers {
    scaleway = { source = "scaleway/scaleway", version = "~> 2.89" }
  }
}

provider "scaleway" {
  region = var.region
}

variable "name" {
  default = "ha"
}

variable "region" {
  description = "it-mil or fr-par; the zones in server_types must belong to it."
  default     = "it-mil"
}

variable "server_types" {
  type        = map(string)
  description = "Machine type per zone. In fr-par, BASIC3 is not sold in fr-par-3, where PRO2-XXS is the cheapest available."
  default = {
    "it-mil-1" = "BASIC3-X2C-4G"
    "it-mil-2" = "BASIC3-X2C-4G"
    "it-mil-3" = "BASIC3-X2C-4G"
  }
}

variable "disk_iops" {
  description = "Block Storage tier of the system disk: 5000 or 15000."
  default     = 5000
}

variable "data_volume_gb" {
  description = "Size of a second Block Storage volume per machine, for replicated volumes (03-volumes). 0 means none."
  default     = 0
}

variable "ssh_public_key_file" {
  default = "~/.ssh/id_ed25519.pub"
}

variable "operator_cidr" {
  description = "Your public address in CIDR form, e.g. 203.0.113.7/32. SSH and the Kubernetes API accept only this."
}

resource "scaleway_iam_ssh_key" "this" {
  name       = var.name
  public_key = file(pathexpand(var.ssh_public_key_file))
}

resource "scaleway_vpc_private_network" "this" {
  name = var.name

  ipv4_subnet {
    subnet = "10.0.1.0/24"
  }
}

resource "scaleway_instance_security_group" "this" {
  for_each = var.server_types

  name                    = var.name
  zone                    = each.key
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 22
    ip_range = var.operator_cidr
  }

  inbound_rule {
    action   = "accept"
    protocol = "TCP"
    port     = 6443
    ip_range = var.operator_cidr
  }
}

resource "scaleway_instance_ip" "this" {
  for_each = var.server_types

  zone = each.key
  type = "routed_ipv4"
}

resource "scaleway_block_volume" "data" {
  for_each = var.data_volume_gb > 0 ? var.server_types : {}

  name       = "${var.name}-data-${each.key}"
  zone       = each.key
  size_in_gb = var.data_volume_gb
  iops       = var.disk_iops
}

resource "scaleway_instance_server" "node" {
  for_each = var.server_types

  name                  = "${var.name}-${each.key}"
  type                  = each.value
  image                 = "ubuntu_noble"
  zone                  = each.key
  ip_id                 = scaleway_instance_ip.this[each.key].id
  security_group_id     = scaleway_instance_security_group.this[each.key].id
  additional_volume_ids = var.data_volume_gb > 0 ? [scaleway_block_volume.data[each.key].id] : []
  user_data             = { cloud-init = file("${path.module}/../cloud-init.yaml") }

  # DEV1, GP1 and STARDUST1 carry a local SSD; the current families only take Block Storage.
  root_volume {
    volume_type = can(regex("^(DEV1|GP1|STARDUST1)-", each.value)) ? "l_ssd" : "sbs_volume"
    size_in_gb  = 40
    sbs_iops    = can(regex("^(DEV1|GP1|STARDUST1)-", each.value)) ? null : var.disk_iops
  }

  private_network {
    pn_id = scaleway_vpc_private_network.this.id
  }

  depends_on = [scaleway_iam_ssh_key.this]
}

output "nodes" {
  value = [
    for zone, s in scaleway_instance_server.node : {
      name       = s.name
      zone       = zone
      public_ip  = scaleway_instance_ip.this[zone].address
      private_ip = [for ip in s.private_ips : ip.address if !strcontains(ip.address, ":")][0]
      ssh_user   = "root"
      provider   = "scaleway"
      type       = var.server_types[zone]
    }
  ]
}
