packer {
  required_plugins {
    amazon  = { source = "github.com/hashicorp/amazon",  version = ">= 1.3.0" }
    ansible = { source = "github.com/hashicorp/ansible", version = ">= 1.1.0" }
  }
}

variable "region"        { default = "ap-south-1" }     # use us-east-1 for Marketplace ingestion
variable "instance_type" { default = "c7i.xlarge" }  # build box only (~₹15/hr); buyers pick their own size
variable "arch"          { default = "amd64" }          # amd64 | arm64 (use t4g.medium for arm64)
variable "product_name"  { default = "ubuntu-2404-cis-l2" }
variable "version"       { default = "1.0.0" }

locals {
  ts = formatdate("YYYYMMDD-hhmm", timestamp())
}

source "amazon-ebs" "ubuntu" {
  region        = var.region
  instance_type = var.instance_type
  ssh_username  = "ubuntu"

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${var.arch}-server-*"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["099720109477"] # Canonical
    most_recent = true
  }

  ami_name        = "${var.product_name}-${var.version}-${var.arch}-${local.ts}"
  ami_description = "Ubuntu 24.04 LTS hardened to CIS Level 1 + Level 2 Server (v1.0.0)"
  # Dedicated build subnet (created by bootstrap/setup-aws.sh) – no default VPC needed
  subnet_filter {
    filters   = { "tag:Name" = "packer-build" }
    most_free = true
    random    = false
  }
  associate_public_ip_address               = true
  temporary_security_group_source_public_ip = true

  ena_support     = true
  sriov_support   = true
  imds_support    = "v2.0"

  # Marketplace: keep root volume unencrypted; buyers can enable EBS encryption-by-default
  encrypt_boot = false

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 10
    volume_type           = "gp3"
    # gp3 baseline 3000 IOPS / 125 MB/s (no extra cost)
    delete_on_termination = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name        = "${var.product_name}-${var.version}"
    OS          = "Ubuntu 24.04"
    Hardening   = "CIS Ubuntu 24.04 v1.0.0 L1+L2 Server"
    BaseAMI     = "{{ .SourceAMI }}"
    BuildDate   = local.ts
  }
}

build {
  sources = ["source.amazon-ebs.ubuntu"]

  # 1. Patch fully + base packages
  provisioner "shell" {
    script          = "scripts/01-prep.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }

  provisioner "shell" {
    inline       = ["sudo reboot"]
    expect_disconnect = true
  }

  # 2. CIS hardening (ansible-lockdown UBUNTU24-CIS)
  provisioner "ansible" {
    playbook_file   = "ansible/site.yml"
    user            = "ubuntu"
    use_proxy       = false
    pause_before    = "5s"
    galaxy_file     = "ansible/requirements.yml"
    roles_path      = "ansible/roles"
    extra_arguments = [
      "--become",
      "--tags", "level1-server,level2-server",
      "--extra-vars", "@ansible/cis-vars.yml",
      "--scp-extra-args", "'-O'"
    ]
    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_PIPELINING=True",                                   # ~3-5x fewer SSH round-trips
      "ANSIBLE_SSH_ARGS=-o ControlMaster=auto -o ControlPersist=30m",
      "ANSIBLE_CALLBACK_RESULT_FORMAT=yaml",
      "ANSIBLE_DISPLAY_SKIPPED_HOSTS=False"                        # smaller logs
    ]
  }

  # 3. Close gaps vs Qualys CIS Ubuntu 24.04 v1.0.0 policy
  provisioner "shell" {
    script          = "scripts/50-qualys-cis-align.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }

  # 4. Marketplace hygiene (MUST be last)
  provisioner "shell" {
    script          = "scripts/99-marketplace-cleanup.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output = "manifest.json"
  }
}
