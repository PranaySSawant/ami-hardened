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
| Cloud hygiene | No SSH keys, passwords, logs, history or machine-id baked in; SSM Agent included (official `.deb`); no snapd, no curl, no cloud-init (see Usage notes) |

## CIS compliance score

Audited against **CIS Benchmark for Ubuntu Linux 24.04 LTS v1.0.0 – Level 1 + Level 2 Server**
(ansible-lockdown UBUNTU24-CIS-Audit). Manual-only recommendations are not scored.

| | Recommendations |
|---|---|
| Scored (automated) | 260 |
| **Passed** | **258 (99.2%)** – audited on ami-05f08490000b2d85d, 2026-11-19 |
| Intentionally not applied (below) | 2 |
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

### 3. Manual review – 7 checks (not scored)

| CIS | Recommendation | Why manual |
|---|---|---|
| 1.1.1.10 | Ensure unused filesystems kernel modules are not available | Depends on what filesystems your workload uses |
| 1.2.1.1 | Ensure GPG keys are configured | Depends on which repositories you add |
| 1.2.1.2 | Ensure package manager repositories are configured | Depends on your approved mirrors |
| 2.1.22 | Ensure only approved services are listening on a network interface | Depends on the services you install |
| 4.2.5 | Ensure ufw outbound connections are configured | Default allows 53/80/123/443 – adjust to your policy |
| 6.1.1.2 | Ensure journald log file access is configured | Site-specific log access policy |
| 7.1.13 | Ensure SUID and SGID files are reviewed | Requires review of your installed software |

## Vulnerability scan results (Amazon Inspector)

Scan of `ami-05f08490000b2d85d` on 2026-11-20: **67 findings** (was 230 before snapd, cloud-init and unused
Python libraries were removed). Every remaining finding is listed below with Ubuntu's own status.

| Package | Findings | Ubuntu status |
|---|---|---|
| openssh | 29 | **All resolved**: 28 fixed in the installed `1:9.6p1-3ubuntu13.20`, 1 does not affect Ubuntu |
| curl | 37 | 27 fixed in the installed `8.5.0-2ubuntu10.16`, 4 not affected, 4 not tracked by Ubuntu, **2 open** (CVE-2026-19931, CVE-2026-80231) awaiting an Ubuntu update |
| go/stdlib | 1 | Inside the AWS SSM Agent binaries (`/usr/bin/amazon-ssm-agent`, `ssm-*`); fixed when AWS ships a new agent |

**Why fixed CVEs still show:** Ubuntu applies security fixes to the same upstream version (OpenSSH stays
`9.6p1`, curl stays `8.5.0`) and only changes the `-ubuntuN` suffix. Inspector reads the upstream number
from the binary, so it reports CVEs that Ubuntu has already fixed. The monthly rebuild picks up every new fix.

### How to resolve the SSH (openssh) findings

All 29 openssh findings are fixed or not applicable on Ubuntu 24.04. To verify and close them:

1. **Check the installed version** is at least `1:9.6p1-3ubuntu13.20` (the highest fix version below):
   ```bash
   dpkg-query -W openssh-server openssh-client
   ```
2. **Confirm a specific CVE is patched** in Ubuntu's changelog, for example:
   ```bash
   apt changelog openssh-server 2>/dev/null | grep -E 'CVE-2026-60002|CVE-2024-6387'
   ```
3. **Keep it patched:** automatic security updates are enabled. To update now:
   ```bash
   sudo apt-get update && sudo apt-get install --only-upgrade -y openssh-server openssh-client && sudo systemctl restart ssh
   ```
4. **Close them in Inspector** (for instances launched from this image) with a suppression rule that records
   the reason. Review the rule after each Ubuntu OpenSSH update:
   ```bash
   aws inspector2 create-filter --action SUPPRESS --name ubuntu-openssh-vendor-fixed \
     --reason "Fixed by Ubuntu in openssh 1:9.6p1-3ubuntu13.20 (USN backports); CVE-2026-123158 is musl/Alpine-only" \
     --filter-criteria '{"vulnerabilityId":[{"comparison":"EQUALS","value":"CVE-2026-60002"},{"comparison":"EQUALS","value":"CVE-2024-6387"},{"comparison":"EQUALS","value":"CVE-2026-106553"},{"comparison":"EQUALS","value":"CVE-2026-106555"},{"comparison":"EQUALS","value":"CVE-2026-106583"},{"comparison":"EQUALS","value":"CVE-2026-123158"},{"comparison":"EQUALS","value":"CVE-2026-35385"},{"comparison":"EQUALS","value":"CVE-2026-35414"},{"comparison":"EQUALS","value":"CVE-2026-59999"},{"comparison":"EQUALS","value":"CVE-2026-60000"},{"comparison":"EQUALS","value":"CVE-2025-26465"},{"comparison":"EQUALS","value":"CVE-2025-26466"},{"comparison":"EQUALS","value":"CVE-2026-106552"},{"comparison":"EQUALS","value":"CVE-2026-106585"},{"comparison":"EQUALS","value":"CVE-2026-106586"},{"comparison":"EQUALS","value":"CVE-2026-35387"},{"comparison":"EQUALS","value":"CVE-2026-59995"},{"comparison":"EQUALS","value":"CVE-2026-59996"},{"comparison":"EQUALS","value":"CVE-2026-59997"},{"comparison":"EQUALS","value":"CVE-2026-59998"},{"comparison":"EQUALS","value":"CVE-2026-60001"},{"comparison":"EQUALS","value":"CVE-2026-73282"},{"comparison":"EQUALS","value":"CVE-2025-32728"},{"comparison":"EQUALS","value":"CVE-2026-106582"},{"comparison":"EQUALS","value":"CVE-2026-106584"},{"comparison":"EQUALS","value":"CVE-2026-106587"},{"comparison":"EQUALS","value":"CVE-2026-35388"},{"comparison":"EQUALS","value":"CVE-2026-73281"},{"comparison":"EQUALS","value":"CVE-2026-73283"}]}'
   ```

| CVE | Severity | Ubuntu 24.04 status | Fixed in `openssh` |
|---|---|---|---|
| [CVE-2026-60002](https://ubuntu.com/security/CVE-2026-60002) | Critical | Fixed | 9.6p1-3ubuntu13.18 |
| [CVE-2024-6387](https://ubuntu.com/security/CVE-2024-6387) | High | Fixed | 9.6p1-3ubuntu13.3 |
| [CVE-2026-106553](https://ubuntu.com/security/CVE-2026-106553) | High | Fixed | 9.6p1-3ubuntu13.20 |
| [CVE-2026-106555](https://ubuntu.com/security/CVE-2026-106555) | High | Fixed | 9.6p1-3ubuntu13.20 |
| [CVE-2026-106583](https://ubuntu.com/security/CVE-2026-106583) | High | Fixed | 9.6p1-3ubuntu13.20 |
| [CVE-2026-123158](https://ubuntu.com/security/CVE-2026-123158) | High | Not affected (musl/Alpine only) | – |
| [CVE-2026-35385](https://ubuntu.com/security/CVE-2026-35385) | High | Fixed | 9.6p1-3ubuntu13.16 |
| [CVE-2026-35414](https://ubuntu.com/security/CVE-2026-35414) | High | Fixed | 9.6p1-3ubuntu13.16 |
| [CVE-2026-59999](https://ubuntu.com/security/CVE-2026-59999) | High | Fixed | 9.6p1-3ubuntu13.18 |
| [CVE-2026-60000](https://ubuntu.com/security/CVE-2026-60000) | High | Fixed | 9.6p1-3ubuntu13.18 |
| [CVE-2025-26465](https://ubuntu.com/security/CVE-2025-26465) | Medium | Fixed | 9.6p1-3ubuntu13.8 |
| [CVE-2025-26466](https://ubuntu.com/security/CVE-2025-26466) | Medium | Fixed | 9.6p1-3ubuntu13.8 |
| [CVE-2026-106552](https://ubuntu.com/security/CVE-2026-106552) | Medium | Fixed | 9.6p1-3ubuntu13.20 |
| [CVE-2026-106585](https://ubuntu.com/security/CVE-2026-106585) | Medium | Fixed | 9.6p1-3ubuntu13.20 |
| [CVE-2026-106586](https://ubuntu.com/security/CVE-2026-106586) | Medium | Fixed | 9.6p1-3ubuntu13.20 |
| [CVE-2026-35387](https://ubuntu.com/security/CVE-2026-35387) | Medium | Fixed | 9.6p1-3ubuntu13.16 |
| [CVE-2026-59995](https://ubuntu.com/security/CVE-2026-59995) | Medium | Fixed | 9.6p1-3ubuntu13.18 |
| [CVE-2026-59996](https://ubuntu.com/security/CVE-2026-59996) | Medium | Fixed | 9.6p1-3ubuntu13.18 |
| [CVE-2026-59997](https://ubuntu.com/security/CVE-2026-59997) | Medium | Fixed | 9.6p1-3ubuntu13.18 |
| [CVE-2026-59998](https://ubuntu.com/security/CVE-2026-59998) | Medium | Fixed | 9.6p1-3ubuntu13.18 |
| [CVE-2026-60001](https://ubuntu.com/security/CVE-2026-60001) | Medium | Fixed | 9.6p1-3ubuntu13.18 |
| [CVE-2026-73282](https://ubuntu.com/security/CVE-2026-73282) | Medium | Fixed | 9.6p1-3ubuntu13.19 |
| [CVE-2025-32728](https://ubuntu.com/security/CVE-2025-32728) | Low | Fixed | 9.6p1-3ubuntu13.11 |
| [CVE-2026-106582](https://ubuntu.com/security/CVE-2026-106582) | Low | Fixed | 9.6p1-3ubuntu13.20 |
| [CVE-2026-106584](https://ubuntu.com/security/CVE-2026-106584) | Low | Fixed | 9.6p1-3ubuntu13.20 |
| [CVE-2026-106587](https://ubuntu.com/security/CVE-2026-106587) | Low | Fixed | 9.6p1-3ubuntu13.20 |
| [CVE-2026-35388](https://ubuntu.com/security/CVE-2026-35388) | Low | Fixed | 9.6p1-3ubuntu13.16 |
| [CVE-2026-73281](https://ubuntu.com/security/CVE-2026-73281) | Low | Fixed | 9.6p1-3ubuntu13.19 |
| [CVE-2026-73283](https://ubuntu.com/security/CVE-2026-73283) | Low | Fixed | 9.6p1-3ubuntu13.19 |

## Usage notes

- **No cloud-init.** A small boot script (`/usr/local/sbin/ec2-firstboot`) does its EC2 job: generates SSH host keys,
  sets the hostname, installs your launch key pair for `ubuntu`, and runs **user data that starts with `#!`**
  (shell/python scripts) once per instance. `#cloud-config` YAML is **not** supported. Log: `/var/log/ec2-user-data.log`.
- **No snapd, no curl, no EC2 Instance Connect** (removed to keep vulnerability scans clean). Log in with your
  EC2 key pair over SSH, or with SSM Session Manager. Use `wget`, or `sudo apt install curl` if you need curl.

- **SSH users:** new users must be in group `sshusers` or `sudo` to log in: `sudo usermod -aG sshusers <user>`.
- **Outbound traffic** is restricted to DNS, HTTP, HTTPS and NTP. Allow more with `sudo ufw allow out <port>/tcp`.
- **`/tmp` is `noexec`** – some installers that run binaries from `/tmp` need `TMPDIR=/var/tmp`.
- **IPv6 / multi-ENI:** `accept_ra=0` and strict `rp_filter=1` are set. For dual-stack or multiple ENIs, relax them in `/etc/sysctl.d/60-cis.conf` and `/etc/ufw/sysctl.conf`.
- **Security group:** open only 22/tcp from your own IP.

## Disclaimer

Built to align with the CIS Benchmark recommendations. This project is not affiliated with,
endorsed by, or certified by the Center for Internet Security (CIS). Review the settings and test
in your environment before production use. Provided as-is, without warranty.
