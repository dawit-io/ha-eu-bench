terraform {
  required_providers {
    openstack = { source = "terraform-provider-openstack/openstack", version = "~> 3.4" }
  }
}

provider "openstack" {
  region = var.region
}

variable "name" {
  default = "ha"
}

variable "region" {
  default = "EU-SOUTH-MIL"
}

variable "zones" {
  type    = list(string)
  default = ["eu-south-mil-a", "eu-south-mil-b", "eu-south-mil-c"]
}

variable "flavor" {
  default = "c3-4"
}

variable "ssh_public_key_file" {
  default = "~/.ssh/id_ed25519.pub"
}

variable "operator_cidr" {
  description = "Your public address in CIDR form, e.g. 203.0.113.7/32. SSH and the Kubernetes API accept only this."
}

locals {
  subnet = "10.0.1.0/24"
}

resource "openstack_compute_keypair_v2" "this" {
  name       = var.name
  public_key = file(pathexpand(var.ssh_public_key_file))
}

resource "openstack_networking_network_v2" "this" {
  name = var.name
}

resource "openstack_networking_subnet_v2" "this" {
  name       = var.name
  network_id = openstack_networking_network_v2.this.id
  cidr       = local.subnet
  no_gateway = true
}

resource "openstack_compute_instance_v2" "node" {
  for_each = { for i, zone in var.zones : zone => i }

  name              = "${var.name}-${each.key}"
  availability_zone = each.key
  flavor_name       = var.flavor
  image_name        = "Ubuntu 24.04"
  key_pair          = openstack_compute_keypair_v2.this.name
  security_groups   = ["default"]
  user_data         = templatefile("${path.module}/cloud-init.yaml.tftpl", { subnet = local.subnet, operator_cidr = var.operator_cidr })

  network {
    name = "Ext-Net"
  }

  network {
    uuid        = openstack_networking_network_v2.this.id
    fixed_ip_v4 = cidrhost(local.subnet, 10 + each.value)
  }

  depends_on = [openstack_networking_subnet_v2.this]
}

output "nodes" {
  value = [
    for zone, s in openstack_compute_instance_v2.node : {
      name       = s.name
      zone       = zone
      public_ip  = s.access_ip_v4
      private_ip = s.network[1].fixed_ip_v4
      ssh_user   = "ubuntu"
      provider   = "ovh"
      type       = var.flavor
    }
  ]
}
