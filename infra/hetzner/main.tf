terraform {
  required_providers {
    hcloud = { source = "hetznercloud/hcloud", version = "~> 1.70" }
  }
}

variable "name" {
  default = "ha"
}

variable "server_type" {
  default = "cpx22"
}

variable "locations" {
  type    = list(string)
  default = ["fsn1", "nbg1", "hel1"]
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

resource "hcloud_ssh_key" "this" {
  name       = var.name
  public_key = file(pathexpand(var.ssh_public_key_file))
}

resource "hcloud_network" "this" {
  name     = var.name
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "this" {
  network_id   = hcloud_network.this.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = local.subnet
}

resource "hcloud_firewall" "this" {
  name = var.name

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.operator_cidr]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = [var.operator_cidr]
  }
}

resource "hcloud_server" "node" {
  for_each = { for i, location in var.locations : location => i }

  name         = "${var.name}-${each.key}"
  server_type  = var.server_type
  image        = "ubuntu-24.04"
  location     = each.key
  ssh_keys     = [hcloud_ssh_key.this.id]
  firewall_ids = [hcloud_firewall.this.id]
  user_data    = file("${path.module}/cloud-init.yaml")

  network {
    network_id = hcloud_network.this.id
    ip         = cidrhost(local.subnet, 10 + each.value)
  }

  depends_on = [hcloud_network_subnet.this]
}

output "nodes" {
  value = [
    for location in var.locations : {
      name       = hcloud_server.node[location].name
      zone       = location
      public_ip  = hcloud_server.node[location].ipv4_address
      private_ip = one(hcloud_server.node[location].network).ip
      ssh_user   = "root"
      provider   = "hetzner"
      type       = var.server_type
    }
  ]
}
