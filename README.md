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
| Root volume | 10 GiB gp3, unencrypted (enable EBS encryption-by-default in your account if required) |
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
| Cloud hygiene | No SSH keys, passwords, logs, history or machine-id baked in; SSM Agent included |

## CIS exceptions (by design)

| CIS | Recommendation | Why not applied |
|---|---|---|
| 1.1.2.3 – 1.1.2.7 | Separate partitions for `/home`, `/var`, `/var/tmp`, `/var/log`, `/var/log/audit` | Single-volume cloud image. Add EBS volumes and mount them if your policy requires it |
| 1.4.1 | Bootloader password | Would break EC2 Serial Console and unattended recovery |
| 5.1.4 | `AllowUsers` | Access controlled with `AllowGroups sshusers sudo` + `DenyUsers root` instead (CIS requires any one) |
| 5.2.4 | Password for sudo | `ubuntu` is key-only with no password, so passwordless sudo is kept for that user only |
| 6.1.3.6 | Remote log host | Environment-specific – point rsyslog/journald at your own log server |

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
