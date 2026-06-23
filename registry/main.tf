# Provisionnement de l'infrastructure du registre Docker (TP IaC).
# `terraform init` puis `terraform apply` créent : la clé SSH, le Security Group
# et l'instance EC2. L'IP publique est exposée en sortie, pour Ansible.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.92"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "aws" {
  region = "eu-west-3" # Paris
}

# 1. AMI Ubuntu 24.04 LTS (Canonical), la plus récente
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# 2. Clé SSH générée par Terraform
resource "tls_private_key" "pk" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated_key" {
  key_name   = "registry-key-terraform"
  public_key = tls_private_key.pk.public_key_openssh
}

# Sauvegarde de la clé privée en local, pour qu'Ansible se connecte en SSH.
# (Fichier *.pem ignoré par git — voir .gitignore.)
resource "local_file" "ssh_key" {
  filename        = "${path.module}/registry-key-terraform.pem"
  content         = tls_private_key.pk.private_key_pem
  file_permission = "0400"
}

# 3. Security Group (pare-feu) : SSH (22), UI (80), Registry Docker (5000)
resource "aws_security_group" "registry_sg" {
  name        = "registry-sg-simple"
  description = "Allow SSH and HTTPS"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 4. Instance EC2
resource "aws_instance" "registry_server" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
  key_name      = aws_key_pair.generated_key.key_name

  vpc_security_group_ids = [aws_security_group.registry_sg.id]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name = "Terraform-Registry-Server"
  }
}

# 5. Sortie : l'IP publique (à reporter dans l'inventaire Ansible)
output "instance_ip" {
  value = aws_instance.registry_server.public_ip
}
