#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────
# backup-restore.sh — Velero backup management utility
# Usage:
#   ./backup-restore.sh backup   [namespace] [--wait]
#   ./backup-restore.sh restore  <backup-name> [namespace]
#   ./backup-restore.sh list
#   ./backup-restore.sh status   <backup-name>
# ──────────────────────────────────────────────────────────────────
set -euo pipefail

VELERO_NAMESPACE="${VELERO_NAMESPACE:-velero}"
BACKUP_STORAGE_LOCATION="${BACKUP_STORAGE_LOCATION:-minio}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

check_velero() {
  command -v velero >/dev/null 2>&1 || die "velero CLI not found"
  kubectl get namespace "$VELERO_NAMESPACE" >/dev/null 2>&1 || die "Velero namespace not found"
}

# ── List all backups ──────────────────────────────────────────────
cmd_list() {
  log "Available backups:"
  velero backup get -n "$VELERO_NAMESPACE"
}

# ── Trigger an ad-hoc backup ─────────────────────────────────────
cmd_backup() {
  local namespace="${1:-}"
  local wait="${2:-false}"
  local backup_name

  if [[ -n "$namespace" ]]; then
    backup_name="adhoc-${namespace}-${TIMESTAMP}"
    log "Creating backup of namespace: $namespace"
    velero backup create "$backup_name" \
      --include-namespaces "$namespace" \
      --storage-location "$BACKUP_STORAGE_LOCATION" \
      --snapshot-volumes \
      --ttl 168h \
      -n "$VELERO_NAMESPACE"
  else
    backup_name="adhoc-full-${TIMESTAMP}"
    log "Creating full cluster backup"
    velero backup create "$backup_name" \
      --storage-location "$BACKUP_STORAGE_LOCATION" \
      --snapshot-volumes \
      --ttl 168h \
      -n "$VELERO_NAMESPACE"
  fi

  log "Backup '$backup_name' initiated"

  if [[ "$wait" == "--wait" ]]; then
    log "Waiting for backup completion..."
    velero backup wait "$backup_name" -n "$VELERO_NAMESPACE"
    velero backup describe "$backup_name" -n "$VELERO_NAMESPACE"
  else
    log "Check status with: $0 status $backup_name"
  fi
}

# ── Restore from backup ───────────────────────────────────────────
cmd_restore() {
  local backup_name="${1:-}"
  local namespace="${2:-}"

  [[ -z "$backup_name" ]] && die "Usage: $0 restore <backup-name> [namespace]"

  # Safety check
  read -rp "WARNING: Restore will OVERWRITE existing resources. Continue? [yes/N] " confirm
  [[ "$confirm" != "yes" ]] && { log "Aborted"; exit 0; }

  local restore_name="restore-${backup_name}-${TIMESTAMP}"

  if [[ -n "$namespace" ]]; then
    log "Restoring namespace '$namespace' from backup '$backup_name'..."
    velero restore create "$restore_name" \
      --from-backup "$backup_name" \
      --include-namespaces "$namespace" \
      --existing-resource-policy update \
      -n "$VELERO_NAMESPACE"
  else
    log "Restoring ALL namespaces from backup '$backup_name'..."
    velero restore create "$restore_name" \
      --from-backup "$backup_name" \
      --existing-resource-policy update \
      -n "$VELERO_NAMESPACE"
  fi

  log "Restore '$restore_name' initiated. Waiting..."
  velero restore wait "$restore_name" -n "$VELERO_NAMESPACE"
  velero restore describe "$restore_name" -n "$VELERO_NAMESPACE"

  log "=== Post-restore checklist ==="
  log "1. Verify ArgoCD apps are in sync:"
  log "   argocd app get --selector env=production"
  log "2. Verify database connectivity:"
  log "   kubectl exec -n storage deploy/pg-primary-pgbouncer -- psql -U saleor -c 'SELECT 1;'"
  log "3. Verify robot MQTT connections:"
  log "   kubectl logs -n warehouse-robots deploy/amr-controller --tail=50"
  log "4. Run smoke tests:"
  log "   curl -sf https://shop.kiruz.com/api/health"
}

# ── Check backup status ───────────────────────────────────────────
cmd_status() {
  local backup_name="${1:-}"
  [[ -z "$backup_name" ]] && die "Usage: $0 status <backup-name>"
  velero backup describe "$backup_name" --details -n "$VELERO_NAMESPACE"
}

# ── Disaster recovery runbook ─────────────────────────────────────
cmd_dr_runbook() {
  cat <<'EOF'
══════════════════════════════════════════════════════════════
  Kiruz Platform — Disaster Recovery Runbook
══════════════════════════════════════════════════════════════

STEP 1 — Bootstrap new K8s cluster
  kubeadm init --config cluster-init.yaml
  kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml

STEP 2 — Install critical operators
  helm install cert-manager jetstack/cert-manager --namespace cert-manager \
    --set installCRDs=true
  helm install longhorn longhorn/longhorn --namespace longhorn-system
  helm install velero vmware-tanzu/velero --namespace velero \
    -f scripts/velero-values.yaml
  helm install cnpg cloudnative-pg/cloudnative-pg --namespace cnpg-system \
    --set installCRDs=true

STEP 3 — Restore from latest backup
  ./scripts/backup-restore.sh list
  ./scripts/backup-restore.sh restore <latest-full-backup>

STEP 4 — Restore ArgoCD
  kubectl create namespace argocd
  helm install argocd argo/argo-cd -n argocd -f apps/gitops-cicd/argocd/values.yaml
  kubectl apply -f clusters/production/argocd-apps.yaml -n argocd

STEP 5 — Verify PostgreSQL primary election
  kubectl get cluster pg-primary -n storage -o jsonpath='{.status.currentPrimary}'

STEP 6 — Force ArgoCD sync
  argocd login argocd.kiruz.com --username admin
  argocd app sync --selector env=production --force

STEP 7 — Verify services
  curl -sf https://shop.kiruz.com/api/health
  curl -sf https://api.kiruz.com/graphql/ -d '{"query":"{shop{name}}"}'
  curl -sf https://auth.kiruz.com/health/ready

STEP 8 — Re-connect warehouse robots
  # Robots auto-reconnect via WireGuard SD-WAN once Mosquitto is up
  kubectl rollout restart deployment/amr-controller -n warehouse-robots

STEP 9 — Notify stakeholders
  # Update status page, Slack #platform channel

RTO Target: 4 hours | RPO Target: 1 hour

EOF
}

# ── Dispatch ─────────────────────────────────────────────────────
check_velero

case "${1:-help}" in
  backup)   shift; cmd_backup "$@" ;;
  restore)  shift; cmd_restore "$@" ;;
  list)     cmd_list ;;
  status)   shift; cmd_status "$@" ;;
  runbook)  cmd_dr_runbook ;;
  *)
    echo "Usage: $0 {backup|restore|list|status|runbook} [args]"
    exit 1
    ;;
esac
