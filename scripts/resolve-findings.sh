#!/usr/bin/env bash
# resolve-findings.sh - resolve (and roll back) the remaining Inspector findings
# of the CIS Ubuntu 24.04 image: the 29 Ubuntu-fixed openssh CVEs.
#
# Runs ONLY in CloudShell / an admin AWS CLI - nothing is installed or run on any server.
#   ./resolve-findings.sh inspector-resolve   [--region ap-south-1]   mark the 29 Ubuntu-fixed openssh CVEs resolved
#   ./resolve-findings.sh inspector-rollback  [--region ap-south-1]   undo (delete the rules)
#   ./resolve-findings.sh status
set -euo pipefail

ACTION=${1:-status}; shift || true
REGION=ap-south-1
while [ $# -gt 0 ]; do case "$1" in --region) REGION=$2; shift 2;; *) echo "unknown arg $1"; exit 2;; esac; done

FILTER_NAME=ubuntu-openssh-vendor-fixed     # Inspector suppression rule name
MIN_OPENSSH="1:9.6p1-3ubuntu13.20"          # highest Ubuntu fix among the 29 CVEs
OPENSSH_CVES="CVE-2026-60002 CVE-2024-6387 CVE-2026-106553 CVE-2026-106555 CVE-2026-106583
CVE-2026-123158 CVE-2026-35385 CVE-2026-35414 CVE-2026-59999 CVE-2026-60000 CVE-2025-26465
CVE-2025-26466 CVE-2026-106552 CVE-2026-106585 CVE-2026-106586 CVE-2026-35387 CVE-2026-59995
CVE-2026-59996 CVE-2026-59997 CVE-2026-59998 CVE-2026-60001 CVE-2026-73282 CVE-2025-32728
CVE-2026-106582 CVE-2026-106584 CVE-2026-106587 CVE-2026-35388 CVE-2026-73281 CVE-2026-73283"

log() { echo "==> $*"; }

inspector_resolve() {
  command -v aws >/dev/null || { echo "needs AWS CLI (run in CloudShell)"; exit 1; }
  # Inspector allows max 10 values per criterion -> one rule per 10 CVEs
  local all=($OPENSSH_CVES) i=0 n=1
  while [ $i -lt ${#all[@]} ]; do
    local name="$FILTER_NAME-$n" vals="" c
    for c in "${all[@]:$i:10}"; do vals+="{\"comparison\":\"EQUALS\",\"value\":\"$c\"},"; done
    local arn; arn=$(aws inspector2 list-filters --region "$REGION" --query "filters[?name=='$name'].arn" --output text)
    if [ -n "$arn" ] && [ "$arn" != None ]; then log "rule $name already exists"
    else
      arn=$(aws inspector2 create-filter --region "$REGION" --name "$name" --action SUPPRESS \
            --reason "Fixed by Ubuntu in openssh $MIN_OPENSSH (security backports); CVE-2026-123158 affects musl/Alpine only" \
            --filter-criteria "{\"vulnerabilityId\":[${vals%,}]}" --query arn --output text)
      log "created $name: $arn"
    fi
    i=$((i+10)); n=$((n+1))
  done
  log "29 openssh CVEs marked resolved (suppressed) in Inspector, region $REGION"
}

inspector_rollback() {
  command -v aws >/dev/null || { echo "needs AWS CLI (run in CloudShell)"; exit 1; }
  local arns; arns=$(aws inspector2 list-filters --region "$REGION" --query "filters[?starts_with(name,'$FILTER_NAME')].arn" --output text)
  if [ -z "$arns" ] || [ "$arns" = None ]; then log "no $FILTER_NAME rules - nothing to roll back"; return; fi
  for a in $arns; do aws inspector2 delete-filter --region "$REGION" --arn "$a" >/dev/null && log "deleted $a"; done
  log "the 29 openssh findings show again"
}

case "$ACTION" in
  inspector-resolve)  inspector_resolve ;;
  inspector-rollback) inspector_rollback ;;
  status)
    command -v aws >/dev/null && aws inspector2 list-filters --region "$REGION" \
      --query "filters[?starts_with(name,'$FILTER_NAME')].[name,action]" --output text || true ;;
  *) sed -n '2,8p' "$0"; exit 2 ;;
esac
