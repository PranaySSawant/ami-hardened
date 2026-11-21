#!/usr/bin/env bash
# Build-time only (runs while the AMI is being built; nothing is added to the image).
# Goal: 0 scanner findings for the two components that scanners flag by *upstream* version:
#   1. OpenSSH  -> latest upstream release compiled from source (Ubuntu's 9.6p1 is patched but
#                  scanners only read "9.6p1"); Ubuntu openssh packages are held so apt never
#                  overwrites it. The monthly rebuild picks up each new OpenSSH release.
#   2. SSM Agent -> the same agent release rebuilt with the latest Go toolchain (the official
#                  binaries embed an older Go standard library).
# All compilers, sources and the Go toolchain are removed again before the image is captured.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

OPENSSH_VER=${OPENSSH_VER:-10.6p2}
GO_VER=${GO_VER:-1.27.4}
W=/root/zf-build
# idempotent: skip what is already at the target version (quick builds from an up-to-date base)
NEED_SSH=1; ssh -V 2>&1 | grep -q "OpenSSH_${OPENSSH_VER}" && NEED_SSH=0
# rebuild an older 10.x build that was compiled without GSSAPI (CIS 5.1.x needs GSSAPIAuthentication)
ldd /usr/lib/openssh/sshd-auth 2>/dev/null | grep -q gssapi_krb5 || NEED_SSH=1
NEED_SSM=0; [ -x /usr/bin/amazon-ssm-agent ] && ! grep -a -q "go${GO_VER}" /usr/bin/amazon-ssm-agent && NEED_SSM=1
if [ "$NEED_SSH$NEED_SSM" = 00 ]; then echo "ZERO-FINDINGS: already up to date ($(ssh -V 2>&1))"; exit 0; fi
rm -rf "$W"; mkdir -p "$W"; cd "$W"

BDEPS="build-essential zlib1g-dev libssl-dev libpam0g-dev libkrb5-dev git"
NEW_BDEPS=""
for p in $BDEPS; do dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null | grep -q '^ii' || NEW_BDEPS="$NEW_BDEPS $p"; done
apt-get update -qq
apt-get install -y --no-install-recommends $BDEPS

############################ 1. OpenSSH (upstream) ############################
if [ "$NEED_SSH" = 1 ]; then
wget -q "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VER}.tar.gz"
tar xzf "openssh-${OPENSSH_VER}.tar.gz"
cd "openssh-${OPENSSH_VER}"
# Compatibility patch: OpenSSH 10.x prints "sshd -T" keywords in CamelCase; Ubuntu's sshd, the CIS
# benchmark audit commands and CIS scanners expect lowercase (e.g. "permitrootlogin no").
python3 - <<'PY'
p = 'servconf.c'; s = open(p).read()
old = "\t\t\treturn(keywords[i].name);\n\treturn \"UNKNOWN\";"
assert old in s, "servconf.c layout changed"
s = s.replace(old, "\t\t\treturn(lc_kw(keywords[i].name));\n\treturn \"UNKNOWN\";", 1)
helper = ("static const char *\nlc_kw(const char *s)\n{\n\tstatic char b[64];\n\tsize_t i;\n\n"
          "\tfor (i = 0; s[i] != '\\0' && i < sizeof(b) - 1; i++)\n\t\tb[i] = tolower((u_char)s[i]);\n"
          "\tb[i] = '\\0';\n\treturn b;\n}\n\n")
anchor = "static const char *\nlookup_opcode_name(ServerOpCodes code)"
assert anchor in s
s = s.replace(anchor, helper + anchor, 1)
open(p, 'w').write(s)
PY
./configure --prefix=/usr --sysconfdir=/etc/ssh --libexecdir=/usr/lib/openssh \
  --with-pam --with-kerberos5=/usr --with-privsep-path=/run/sshd --with-pid-dir=/run \
  --with-default-path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  --with-mantype=man --disable-strip
make -j"$(nproc)"
# keep Ubuntu's packages registered but never let apt overwrite the upstream binaries
apt-mark hold openssh-server openssh-client openssh-sftp-server 2>/dev/null || true
cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.zf-keep 2>/dev/null || true
make install-nokeys
[ -f /etc/ssh/sshd_config.zf-keep ] && mv -f /etc/ssh/sshd_config.zf-keep /etc/ssh/sshd_config
cd "$W"

# Upstream sshd does not support Ubuntu's ssh.socket activation -> run ssh.service directly
if [ -d /run/systemd/system ]; then
  mkdir -p /etc/systemd/system/ssh.service.d
  cat > /etc/systemd/system/ssh.service.d/10-upstream-openssh.conf <<'EOF'
[Unit]
# never pull in Ubuntu's ssh.socket (upstream sshd binds port 22 itself)
Requires=
Wants=
After=network.target auditd.service

[Service]
Type=exec
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755
ExecStartPre=
ExecStartPre=/usr/sbin/sshd -t
ExecStart=
ExecStart=/usr/sbin/sshd -D $SSHD_OPTS
EOF
  systemctl daemon-reload
  systemctl disable ssh.socket 2>/dev/null || true
  systemctl mask ssh.socket 2>/dev/null || true
  systemctl enable ssh.service
fi
mkdir -p /run/sshd
# host keys may be absent at build time (they are regenerated at first boot) -> test with temp keys
TK=$(mktemp -d); ssh-keygen -q -t ed25519 -N '' -f "$TK/k"
/usr/sbin/sshd -t -h "$TK/k"
DUMP=$(/usr/sbin/sshd -T -h "$TK/k")    # capture first (grep -q + pipefail = SIGPIPE)
grep -q "^permitrootlogin " <<<"$DUMP" || { echo "sshd -T output not lowercase/compatible"; exit 1; }
grep -q "^gssapiauthentication " <<<"$DUMP" || { echo "GSSAPI support missing"; exit 1; }
rm -rf "$TK"
# switch the running listener to the new sshd now (open sessions stay connected), so the next
# connections - including the build tool's own - use the upstream binary
if [ -d /run/systemd/system ] && ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
  # upstream sshd refuses group-readable host keys (Ubuntu allows 0640 root:ssh_keys) -> 0600
  chown root:root /etc/ssh/ssh_host_*_key; chmod 0600 /etc/ssh/ssh_host_*_key
  systemctl stop ssh.socket ssh.service 2>/dev/null || true
  # stop any leftover LISTENING sshd on :22 (old listeners survive KillMode=process);
  # established sessions (the build tool's own connection) are not listeners and keep running
  for pid in $(ss -Hltnp 'sport = :22' | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do kill "$pid" || true; done
  sleep 1
  systemctl start ssh.service || true
  sleep 2
  if ! systemctl is-active ssh.service; then
    journalctl -u ssh.service -n 30 --no-pager || true
    /usr/sbin/sshd -t || true
    exit 1
  fi
fi
ssh -V 2>&1 | grep -q "OpenSSH_${OPENSSH_VER}" || { echo "ssh is not ${OPENSSH_VER}"; exit 1; }
fi

############################ 2. SSM Agent (latest Go) ##########################
if [ "$NEED_SSM" = 1 ]; then
  SSM_VER=$(dpkg-query -W -f='${Version}' amazon-ssm-agent | cut -d- -f1)
  GOTGZ="go${GO_VER}.linux-$(dpkg --print-architecture).tar.gz"
  wget -q "https://go.dev/dl/${GOTGZ}"
  SUM=$(wget -qO- "https://go.dev/dl/?mode=json&include=all" | python3 -c "
import json,sys
for r in json.load(sys.stdin):
    for f in r['files']:
        if f['filename']=='${GOTGZ}': print(f['sha256'])")
  echo "${SUM}  ${GOTGZ}" | sha256sum -c -
  tar -C "$W" -xzf "$GOTGZ"
  mkdir -p "$W/gotmp"   # /tmp is noexec (CIS) -> go run needs an exec-able temp dir
  export PATH="$W/go/bin:$PATH" GOTOOLCHAIN=local GOFLAGS=-mod=vendor GOPATH="$W/gopath" GOCACHE="$W/gocache" GOTMPDIR="$W/gotmp"
  git clone -q --depth 1 -b "$SSM_VER" https://github.com/aws/amazon-ssm-agent "$W/ssm"
  cd "$W/ssm"
  go run agent/version/versiongenerator/version-gen.go
  b() { go build -ldflags '-s -w' -buildmode=pie -trimpath "$@"; }
  mkdir -p out
  b -o out/amazon-ssm-agent     core/agent.go core/agent_unix.go core/agent_parser.go
  b -o out/ssm-agent-worker     agent/agent.go agent/agent_unix.go agent/agent_parser.go
  b -o out/ssm-cli              agent/cli-main/cli-main.go
  b -o out/ssm-document-worker  agent/framework/processor/executer/outofproc/worker/main.go
  b -o out/ssm-session-logger   agent/session/logging/main.go
  b -o out/ssm-session-worker   agent/framework/processor/executer/outofproc/sessionworker/main.go
  for f in out/*; do
    go version "$f" | grep -q "go${GO_VER}" || { echo "bad build $f"; exit 1; }
    install -m 0755 "$f" "/usr/bin/$(basename "$f")"
  done
  /usr/bin/amazon-ssm-agent -version || true
  cd "$W"
fi

############################ cleanup ###########################################
cd /
rm -rf "$W"
# shellcheck disable=SC2086
[ -n "$NEW_BDEPS" ] && apt-get purge -y $NEW_BDEPS
apt-get autoremove -y --purge
echo "ZERO-FINDINGS: $(ssh -V 2>&1); SSM agent rebuilt with go${GO_VER}"
