# QUICK build (~10 min): starts from the latest private, fully hardened BASE image
# (made monthly by scripts/make-base-ami.sh), applies the newest Ubuntu security updates,
# re-checks SSH/SSM, cleans the instance identity and captures the public image.
packer {
  required_plugins {
    amazon = { source = "github.com/hashicorp/amazon", version = ">= 1.3.0" }
  }
}

variable "region"        { default = "ap-south-1" }
variable "instance_type" { default = "c7i.2xlarge" }  # faster compile + copy; billed per second
variable "product_name"  { default = "ubuntu-2404-cis-l2" }
variable "version"       { default = "1.0.0" }

locals { ts = formatdate("YYYYMMDD-hhmm", timestamp()) }

source "amazon-ebs" "quick" {
  region        = var.region
  instance_type = var.instance_type
  ssh_username  = "ubuntu"
  ssh_timeout   = "10m"
  temporary_key_pair_type = "ed25519"

  source_ami_filter {
    filters     = { "tag:Stage" = "cis-base", "state" = "available" }
    owners      = ["self"]
    most_recent = true
  }

  ami_name        = "${var.product_name}-${var.version}-amd64-${local.ts}"
  ami_description = "Ubuntu 24.04 LTS hardened to CIS Level 1 + Level 2 Server (v1.0.0)"
  subnet_filter {
    filters   = { "tag:Name" = "packer-build" }
    most_free = true
  }
  associate_public_ip_address               = true
  temporary_security_group_source_public_ip = true

  ena_support   = true
  sriov_support = true
  imds_support  = "v2.0"

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name      = "${var.product_name}-${var.version}"
    OS        = "Ubuntu 24.04"
    Hardening = "CIS Ubuntu 24.04 v1.0.0 L1+L2 Server"
    Stage     = "public"
    BaseAMI   = "{{ .SourceAMI }}"
    BuildDate = local.ts
  }
}

build {
  sources = ["source.amazon-ebs.quick"]

  provisioner "shell" {      # no-op when the base already has them
    script          = "scripts/97-zero-findings.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }
  provisioner "shell" {
    script          = "scripts/quick-refresh.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }
  provisioner "shell" {
    script          = "scripts/99-marketplace-cleanup.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }
  post-processor "manifest" {
    output = "manifest.json"
  }
}
