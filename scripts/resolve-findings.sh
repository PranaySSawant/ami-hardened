#!/usr/bin/env bash
# resolve-findings.sh - resolve (and roll back) the remaining Inspector findings
# of the CIS Ubuntu 24.04 image: 29 openssh + 1 SSM Agent (Go).
#
# Two places, two parts:
#   ON THE SERVER (sudo):        patch openssh + SSM Agent, verify, keep rollback copies
#       sudo ./resolve-findings.sh server-resolve
#       sudo ./resolve-findings.sh server-rollback
#   IN CLOUDSHELL / admin CLI:   mark the 29 Ubuntu-fixed openssh CVEs as resolved in Inspector
#       ./resolve-findings.sh inspector-resolve   [--region ap-south-1]
#       ./resolve-findings.sh inspector-rollback  [--region ap-south-1]
#   Either place:
#       ./resolve-findings.sh status
set -euo pipefail

ACTION=${1:-status}; shift || true
REGION=ap-south-1
while [ $# -gt 0 ]; do case "$1" in --region) REGION=$2; shift 2;; *) echo "unknown arg $1"; exit 2;; esac; done

STATE=/var/lib/resolve-findings            # server-side rollback data
FILTER_NAME=ubuntu-openssh-vendor-fixed     # Inspector suppression rule name
MIN_OPENSSH="1:9.6p1-3ubuntu13.20"          # highest Ubuntu fix among the 29 CVEs
OPENSSH_CVES="CVE-2026-60002 CVE-2024-6387 CVE-2026-106553 CVE-2026-106555 CVE-2026-106583
CVE-2026-123158 CVE-2026-35385 CVE-2026-35414 CVE-2026-59999 CVE-2026-60000 CVE-2025-26465
CVE-2025-26466 CVE-2026-106552 CVE-2026-106585 CVE-2026-106586 CVE-2026-35387 CVE-2026-59995
CVE-2026-59996 CVE-2026-59997 CVE-2026-59998 CVE-2026-60001 CVE-2026-73282 CVE-2025-32728
CVE-2026-106582 CVE-2026-106584 CVE-2026-106587 CVE-2026-35388 CVE-2026-73281 CVE-2026-73283"

log() { echo "==> $*"; }
need_root() { [ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }; }
ver() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || echo none; }

openssh_ok() {
  local v; v=$(ver openssh-server)
  [ "$v" != none ] && dpkg --compare-versions "$v" ge "$MIN_OPENSSH"
}

imds() {
  local tok
  tok=$(wget -qO- --method=PUT --header='X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)
  wget -qO- --header="X-aws-ec2-metadata-token: $tok" "http://169.254.169.254/latest/meta-data/$1"
}

server_resolve() {
  need_root
  install -d -m 700 "$STATE"
  # 1. remember current versions for rollback
  { echo "openssh-server=$(ver openssh-server)"; echo "openssh-client=$(ver openssh-client)";
    echo "amazon-ssm-agent=$(ver amazon-ssm-agent)"; } > "$STATE/versions.before"
  log "saved current versions to $STATE/versions.before"; cat "$STATE/versions.before"

  # 2. openssh: latest Ubuntu security update
  apt-get update -qq
  local ssh_debs; ssh_debs="$STATE/openssh-debs"; install -d "$ssh_debs"
  (cd "$ssh_debs" && apt-get download "openssh-server=$(ver openssh-server)" "openssh-client=$(ver openssh-client)" \
     "openssh-sftp-server=$(ver openssh-sftp-server)" >/dev/null 2>&1 || true)
  DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade -y openssh-server openssh-client openssh-sftp-server
  sshd -t && systemctl restart ssh.socket ssh.service 2>/dev/null || systemctl restart ssh

  # 3. SSM Agent: latest official .deb (fixes the Go finding once AWS ships a newer agent)
  local region; region=$(imds placement/region || echo "$REGION")
  local new=/tmp/ssm-new.deb
  wget -q -O "$new" "https://s3.${region}.amazonaws.com/amazon-ssm-${region}/latest/debian_amd64/amazon-ssm-agent.deb"
  local newv; newv=$(dpkg-deb -f "$new" Version)
  if dpkg --compare-versions "$newv" gt "$(ver amazon-ssm-agent)"; then
    wget -q -O "$STATE/ssm-previous.deb" \
      "https://s3.${region}.amazonaws.com/amazon-ssm-${region}/$(ver amazon-ssm-agent | cut -d- -f1)/debian_amd64/amazon-ssm-agent.deb" || true
    dpkg -i "$new"; systemctl restart amazon-ssm-agent
    log "SSM Agent updated to $newv"
  else
    log "SSM Agent $(ver amazon-ssm-agent) is already the latest - the Go finding clears when AWS releases a newer agent"
  fi
  rm -f "$new"

  # 4. verify
  if openssh_ok; then log "OK: openssh-server $(ver openssh-server) >= $MIN_OPENSSH -> all 29 openssh CVEs fixed by Ubuntu"
  else log "WARNING: openssh-server $(ver openssh-server) is below $MIN_OPENSSH - do not suppress yet"; exit 1; fi
}

server_rollback() {
  need_root
  [ -f "$STATE/versions.before" ] || { echo "nothing to roll back ($STATE/versions.before missing)"; exit 1; }
  log "rolling back to:"; cat "$STATE/versions.before"
  if ls "$STATE"/openssh-debs/*.deb >/dev/null 2>&1; then
    dpkg -i "$STATE"/openssh-debs/*.deb
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
      "openssh-server=$(grep ^openssh-server= "$STATE/versions.before" | cut -d= -f2-)" \
      "openssh-client=$(grep ^openssh-client= "$STATE/versions.before" | cut -d= -f2-)"
  fi
  sshd -t && { systemctl restart ssh.socket ssh.service 2>/dev/null || systemctl restart ssh; }
  if [ -s "$STATE/ssm-previous.deb" ]; then dpkg -i "$STATE/ssm-previous.deb"; systemctl restart amazon-ssm-agent; fi
  log "rollback done:"; status_server
}

inspector_resolve() {
  command -v aws >/dev/null || { echo "needs AWS CLI (run in CloudShell)"; exit 1; }
  local vals=""; for c in $OPENSSH_CVES; do vals+="{\"comparison\":\"EQUALS\",\"value\":\"$c\"},"; done
  local crit="{\"vulnerabilityId\":[${vals%,}]}"
  local arn; arn=$(aws inspector2 list-filters --region "$REGION" --query "filters[?name=='$FILTER_NAME'].arn" --output text)
  if [ -n "$arn" ] && [ "$arn" != None ]; then log "rule already exists: $arn"; return; fi
  arn=$(aws inspector2 create-filter --region "$REGION" --name "$FILTER_NAME" --action SUPPRESS \
        --reason "Fixed by Ubuntu in openssh $MIN_OPENSSH (security backports); CVE-2026-123158 affects musl/Alpine only" \
        --filter-criteria "$crit" --query arn --output text)
  log "created Inspector suppression rule: $arn  (29 openssh CVEs marked resolved)"
}

inspector_rollback() {
  command -v aws >/dev/null || { echo "needs AWS CLI (run in CloudShell)"; exit 1; }
  local arn; arn=$(aws inspector2 list-filters --region "$REGION" --query "filters[?name=='$FILTER_NAME'].arn" --output text)
  if [ -z "$arn" ] || [ "$arn" = None ]; then log "no rule named $FILTER_NAME - nothing to roll back"; return; fi
  aws inspector2 delete-filter --region "$REGION" --arn "$arn" >/dev/null
  log "deleted Inspector suppression rule $arn - the 29 openssh findings show again"
}

status_server() {
  echo "openssh-server : $(ver openssh-server)  (needs >= $MIN_OPENSSH) $(openssh_ok && echo OK || echo LOW)"
  echo "openssh-client : $(ver openssh-client)"
  echo "amazon-ssm-agent: $(ver amazon-ssm-agent)"
  [ -f "$STATE/versions.before" ] && echo "rollback data  : $STATE (available)" || echo "rollback data  : none"
}

case "$ACTION" in
  server-resolve)     server_resolve ;;
  server-rollback)    server_rollback ;;
  inspector-resolve)  inspector_resolve ;;
  inspector-rollback) inspector_rollback ;;
  status)
    command -v dpkg-query >/dev/null && status_server
    command -v aws >/dev/null && aws inspector2 list-filters --region "$REGION" \
      --query "filters[?name=='$FILTER_NAME'].[name,action,arn]" --output text || true ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
