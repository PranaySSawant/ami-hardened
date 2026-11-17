# Hardened Ubuntu 24.04 LTS – CIS Benchmark AMI

A free, public Amazon Machine Image (AMI) of **Ubuntu 24.04 LTS** hardened to the
**CIS Benchmark for Ubuntu Linux 24.04 LTS v1.0.0 – Level 1 + Level 2 Server** profile.
Rebuilt and patched automatically every month.

## Version info

| Item | Value |
|---|---|
| OS | Ubuntu 24.04 LTS (Noble Numbat) |
| Base image | Canonical official `ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*` |
| Architecture | x86_64 (amd64) |
| Kernel | `linux-aws` (latest at build time) |
| Hardening standard | CIS Benchmark for Ubuntu Linux 24.04 LTS **v1.0.0** |
| Profile | Level 1 + Level 2 – Server (~700 controls) |
| Region | `ap-south-1` (Mumbai) |
| AMI name | `ubuntu-2404-cis-l2-<YYYY.MM.DD>-amd64-<timestamp>` |
| Disk | **One 30 GiB gp3 disk** with separate CIS partitions (see *Disk layout*) |
| Boot / metadata | HVM, ENA, IMDSv2 required |
| Release cadence | Monthly (5th of each month) – latest OS patches + CIS settings |
| Default user | `ubuntu` (SSH key only) |

## Find and launch

**Console:** EC2 → AMIs → *Public images* → search `ubuntu-2404-cis-l2` (region ap-south-1) → pick the newest → **Launch instance from AMI**.

**CLI:**
```bash
AMI=$(aws ec2 describe-images --region ap-south-1 --owners 080369785465 \
  --filters "Name=name,Values=ubuntu-2404-cis-l2-*" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)

aws ec2 run-instances --region ap-south-1 --image-id "$AMI" \
  --instance-type t3.micro --key-name <your-key> \
  --security-group-ids <sg-allowing-22/tcp> \
  --metadata-options HttpTokens=required
```
Then: `ssh -i <your-key>.pem ubuntu@<public-ip>`

## Disk layout

One 30 GiB disk (GPT). `/var`, `/var/log`, `/var/log/audit`, `/var/tmp` and `/home` are separate
LVM volumes so they can carry the CIS mount options (CIS 1.1.2.3 – 1.1.2.7).

| Partition | Size | Mount | Options |
|---|---|---|---|
| p14 | 4 MiB | BIOS boot (legacy GRUB) | – |
| p15 | 106 MiB | `/boot/efi` | `umask=0077` |
| p1 | 10 GiB | `/` | `errors=remount-ro` |
| p2 → LV `cis/var` | 8 GiB | `/var` | `nodev,nosuid` |
| p2 → LV `cis/varlog` | 4 GiB | `/var/log` | `nodev,nosuid,noexec` |
| p2 → LV `cis/audit` | 2 GiB | `/var/log/audit` | `nodev,nosuid,noexec` |
| p2 → LV `cis/vartmp` | 2 GiB | `/var/tmp` | `nodev,nosuid,noexec` |
| p2 → LV `cis/home` | 3 GiB | `/home` | `nodev,nosuid` |
| tmpfs | 50% RAM | `/tmp`, `/dev/shm` | `nodev,nosuid,noexec` |

**Grow a volume** (e.g. `/var` +10 GiB): increase the EBS volume size in the console, then
```bash
sudo growpart /dev/nvme0n1 2 && sudo pvresize /dev/nvme0n1p2
sudo lvextend -r -L +10G /dev/cis/var
```

## What is hardened

| Area | Highlights |
|---|---|
| Filesystem | Unused filesystem modules disabled; `/tmp` and `/dev/shm` mounted `nodev,nosuid,noexec` |
| Boot | AppArmor enabled in enforce mode; bootloader config permissions locked |
| Kernel / network | ASLR, ptrace restriction, no IP forwarding/redirects/source routing, SYN cookies, martian logging |
| Firewall | `ufw` only; default deny in/out; inbound 22/tcp; outbound 53, 80, 123, 443 |
| SSH | Key-only, no root login, strong ciphers/KEX/MACs only, idle timeout, `MaxAuthTries 4`, login banner |
| Accounts / PAM | Password quality + history, `faillock` lockout, password aging, umask 027, 15-min shell timeout |
| sudo | `use_pty`, sudo logging, auth timeout |
| Logging & audit | `auditd` with CIS rule set, `journald` persistent + compressed, log file permissions |
| Integrity | AIDE installed with daily check timer |
| Time | `systemd-timesyncd` → Amazon Time Sync (169.254.169.123) |
| Cloud hygiene | No SSH keys, passwords, logs, history or machine-id baked in; SSM Agent included (official `.deb`, not the snap) |

## CIS compliance score

Audited against **CIS Benchmark for Ubuntu Linux 24.04 LTS v1.0.0 – Level 1 + Level 2 Server**
(ansible-lockdown UBUNTU24-CIS-Audit). Manual-only recommendations are not scored.

| | Recommendations |
|---|---|
| Scored (automated) | 260 |
| **Passed** | **257 (98.8%)** – audited on ami-0b70f5b724dbf2b6d, 2026-11-17 |
| Intentionally not applied (below) | 3 |
| Manual review – not scored | 7 |

## Intentional failures (by design)

These recommendations are **deliberately not applied** because they would break the image on AWS
or cannot be decided for every user. Each one lists the reason and how to apply it yourself if your policy requires it.

Control IDs are from the CIS Ubuntu 24.04 v1.0.0 (L1+L2) compliance policy used for scanning.
Manual-review items are inactive in that policy and have no control ID.

### 1. Bootloader password – 1 check

| CIS | Recommendation | Control ID |
|---|---|---|
| 1.4.1 | Ensure bootloader password is set | 13271 |

**Why:** a GRUB password prompts on the EC2 Serial Console and blocks unattended recovery / single-user boot.
A password baked into a public image would also be identical for every user, which is insecure.
**If you need it:** `grub-mkpasswd-pbkdf2`, add the superuser + hash to `/etc/grub.d/40_custom`, run `update-grub`.

### 2. Password for privilege escalation – 1 check

| CIS | Recommendation | Control ID |
|---|---|---|
| 5.2.4 | Ensure users must provide password for privilege escalation | 29136 |

**Why:** the default `ubuntu` user logs in with an SSH key only and has no password (AWS standard),
so `sudo` cannot ask for one. Passwordless sudo is kept **only for `ubuntu`**; the rule applies to all other users.
**If you need it:** set a password for `ubuntu` and remove `NOPASSWD` from `/etc/sudoers.d/90-cloud-init-users`.

### 3. squashfs kernel module – 1 check (Level 2)

| CIS | Recommendation | Control ID |
|---|---|---|
| 1.1.1.7 | Ensure squashfs kernel module is not available | 28961, 29284, 29289 |

**Why:** snaps are squashfs images. `snapd` ships with Ubuntu and many tools (e.g. `aws-cli`, `certbot`) are
installed as snaps, so disabling squashfs would silently break `snap install` for every user.
(The SSM Agent in this image is the `.deb`, so it is not affected.)
**If you need it:** `snap list` must be empty, then `printf 'install squashfs /bin/false\nblacklist squashfs\n' > /etc/modprobe.d/squashfs.conf`.

### 4. Manual review – 7 checks (not scored)

| CIS | Recommendation | Why manual |
|---|---|---|
| 1.1.1.10 | Ensure unused filesystems kernel modules are not available | Depends on what filesystems your workload uses |
| 1.2.1.1 | Ensure GPG keys are configured | Depends on which repositories you add |
| 1.2.1.2 | Ensure package manager repositories are configured | Depends on your approved mirrors |
| 2.1.22 | Ensure only approved services are listening on a network interface | Depends on the services you install |
| 4.2.5 | Ensure ufw outbound connections are configured | Default allows 53/80/123/443 – adjust to your policy |
| 6.1.1.2 | Ensure journald log file access is configured | Site-specific log access policy |
| 7.1.13 | Ensure SUID and SGID files are reviewed | Requires review of your installed software |

## Usage notes

- **SSH users:** new users must be in group `sshusers` or `sudo` to log in: `sudo usermod -aG sshusers <user>`.
- **Outbound traffic** is restricted to DNS, HTTP, HTTPS and NTP. Allow more with `sudo ufw allow out <port>/tcp`.
- **`/tmp` is `noexec`** – some installers that run binaries from `/tmp` need `TMPDIR=/var/tmp`.
- **IPv6 / multi-ENI:** `accept_ra=0` and strict `rp_filter=1` are set. For dual-stack or multiple ENIs, relax them in `/etc/sysctl.d/60-cis.conf` and `/etc/ufw/sysctl.conf`.
- **Security group:** open only 22/tcp from your own IP.

## Disclaimer

Built to align with the CIS Benchmark recommendations. This project is not affiliated with,
endorsed by, or certified by the Center for Internet Security (CIS). Review the settings and test
in your environment before production use. Provided as-is, without warranty.
