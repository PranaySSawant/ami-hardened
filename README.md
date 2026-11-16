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

## CIS compliance score

Audited against **CIS Benchmark for Ubuntu Linux 24.04 LTS v1.0.0 – Level 1 + Level 2 Server**
(ansible-lockdown UBUNTU24-CIS-Audit). Manual-only recommendations are not scored.

| | Recommendations |
|---|---|
| Scored (automated) | 260 |
| Intentionally not applied (below) | 21 |
| Manual review – not scored | 7 |

## Intentional failures (by design)

These recommendations are **deliberately not applied** because they would break the image on AWS
or cannot be decided for every user. Each one lists the reason and how to apply it yourself if your policy requires it.

Control IDs are from the CIS Ubuntu 24.04 v1.0.0 (L1+L2) compliance policy used for scanning.
Manual-review items are inactive in that policy and have no control ID.

### 1. Separate partitions – 18 checks

| CIS | Recommendation | Control ID |
|---|---|---|
| 1.1.2.3.1 | Ensure separate partition exists for `/home` | 29044 |
| 1.1.2.3.2 | Ensure `nodev` option set on `/home` partition | 29045 |
| 1.1.2.3.3 | Ensure `nosuid` option set on `/home` partition | 29046 |
| 1.1.2.4.1 | Ensure separate partition exists for `/var` | 29055 |
| 1.1.2.4.2 | Ensure `nodev` option set on `/var` partition | – |
| 1.1.2.4.3 | Ensure `nosuid` option set on `/var` partition | 29057 |
| 1.1.2.5.1 | Ensure separate partition exists for `/var/tmp` | 29058 |
| 1.1.2.5.2 | Ensure `nodev` option set on `/var/tmp` partition | 29059 |
| 1.1.2.5.3 | Ensure `nosuid` option set on `/var/tmp` partition | 29060 |
| 1.1.2.5.4 | Ensure `noexec` option set on `/var/tmp` partition | 29061 |
| 1.1.2.6.1 | Ensure separate partition exists for `/var/log` | 29062 |
| 1.1.2.6.2 | Ensure `nodev` option set on `/var/log` partition | 29063 |
| 1.1.2.6.3 | Ensure `nosuid` option set on `/var/log` partition | 29064 |
| 1.1.2.6.4 | Ensure `noexec` option set on `/var/log` partition | 29065 |
| 1.1.2.7.1 | Ensure separate partition exists for `/var/log/audit` | 29066 |
| 1.1.2.7.2 | Ensure `nodev` option set on `/var/log/audit` partition | 29067 |
| 1.1.2.7.3 | Ensure `nosuid` option set on `/var/log/audit` partition | 29068 |
| 1.1.2.7.4 | Ensure `noexec` option set on `/var/log/audit` partition | 29069 |

**Why:** Canonical's Ubuntu cloud image ships with a single root volume. Re-partitioning inside an AMI
needs a custom disk layout, risks an unbootable image and prevents simply resizing the root volume at launch.
The mount-option checks fail automatically because the partitions do not exist.
**If you need it:** attach extra EBS volumes, mount them at these paths with `nodev,nosuid,noexec` in `/etc/fstab`.

### 2. Bootloader password – 1 check

| CIS | Recommendation | Control ID |
|---|---|---|
| 1.4.1 | Ensure bootloader password is set | 13271 |

**Why:** a GRUB password prompts on the EC2 Serial Console and blocks unattended recovery / single-user boot.
A password baked into a public image would also be identical for every user, which is insecure.
**If you need it:** `grub-mkpasswd-pbkdf2`, add the superuser + hash to `/etc/grub.d/40_custom`, run `update-grub`.

### 3. Password for privilege escalation – 1 check

| CIS | Recommendation | Control ID |
|---|---|---|
| 5.2.4 | Ensure users must provide password for privilege escalation | 29136 |

**Why:** the default `ubuntu` user logs in with an SSH key only and has no password (AWS standard),
so `sudo` cannot ask for one. Passwordless sudo is kept **only for `ubuntu`**; the rule applies to all other users.
**If you need it:** set a password for `ubuntu` and remove `NOPASSWD` from `/etc/sudoers.d/90-cloud-init-users`.

### 4. squashfs kernel module – 1 check (Level 2)

| CIS | Recommendation | Control ID |
|---|---|---|
| 1.1.1.7 | Ensure squashfs kernel module is not available | 28961, 29284, 29289 |

**Why:** snaps are squashfs images. The **Amazon SSM Agent** is installed as a snap, so disabling squashfs
would break Session Manager / Run Command on every instance.
**If you need it:** remove all snaps (install SSM Agent from the `.deb`), then blacklist `squashfs`.

### 5. Manual review – 7 checks (not scored)

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
