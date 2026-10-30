terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region = var.region
}

variable "name" {
  default = "ha"
}

variable "region" {
  description = "eu-south-1 (Milan) is an opt-in region: enable it in the account first."
  default     = "eu-south-1"
}

variable "zones" {
  type    = list(string)
  default = ["eu-south-1a", "eu-south-1b", "eu-south-1c"]
}

variable "instance_type" {
  default = "c7i.large"
}

variable "disk_iops" {
  description = "gp3 IOPS of both disks. 5000 matches the Scaleway Block Storage tier used in Milan; gp3 includes 3000."
  default     = 5000
}

variable "data_volume_gb" {
  description = "Size of a second gp3 volume per machine, for replicated volumes (03-volumes). 0 means none."
  default     = 20
}

variable "ssh_public_key_file" {
  default = "~/.ssh/id_ed25519.pub"
}

variable "operator_cidr" {
  description = "Your public address in CIDR form, e.g. 203.0.113.7/32. SSH and the Kubernetes API accept only this."
}

locals {
  vpc_cidr = "10.0.0.0/16"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_key_pair" "this" {
  key_name   = var.name
  public_key = file(pathexpand(var.ssh_public_key_file))
}

resource "aws_vpc" "this" {
  cidr_block = local.vpc_cidr
  tags       = { Name = var.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
}

resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}

resource "aws_subnet" "this" {
  for_each = { for i, zone in var.zones : zone => i }

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(local.vpc_cidr, 8, each.value + 1)
  map_public_ip_on_launch = true
}

resource "aws_route_table_association" "this" {
  for_each = aws_subnet.this

  subnet_id      = each.value.id
  route_table_id = aws_route_table.this.id
}

resource "aws_security_group" "this" {
  name   = var.name
  vpc_id = aws_vpc.this.id

  ingress {
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = [var.operator_cidr]
  }

  ingress {
    protocol    = "tcp"
    from_port   = 6443
    to_port     = 6443
    cidr_blocks = [var.operator_cidr]
  }

  ingress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = [local.vpc_cidr]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "node" {
  for_each = aws_subnet.this

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = each.value.id
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.this.id]
  user_data              = file("${path.module}/../cloud-init.yaml")
  tags                   = { Name = "${var.name}-${each.key}" }

  root_block_device {
    volume_type = "gp3"
    volume_size = 40
    iops        = var.disk_iops
  }
}

resource "aws_ebs_volume" "data" {
  for_each = var.data_volume_gb > 0 ? aws_subnet.this : {}

  availability_zone = each.key
  type              = "gp3"
  size              = var.data_volume_gb
  iops              = var.disk_iops
}

resource "aws_volume_attachment" "data" {
  for_each = aws_ebs_volume.data

  device_name = "/dev/sdf"
  volume_id   = each.value.id
  instance_id = aws_instance.node[each.key].id
}

output "nodes" {
  value = [
    for zone in var.zones : {
      name       = split(".", aws_instance.node[zone].private_dns)[0]
      zone       = zone
      public_ip  = aws_instance.node[zone].public_ip
      private_ip = aws_instance.node[zone].private_ip
      ssh_user   = "ubuntu"
      provider   = "aws"
      type       = var.instance_type
    }
  ]
}
