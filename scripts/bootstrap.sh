#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────
# bootstrap.sh — Bootstrap the Kiruz platform from scratch
# Run once on a fresh Kubernetes cluster.
# Prerequisites: kubectl, helm, argocd CLI, kubeseal configured.
# ──────────────────────────────────────────────────────────────────
set -euo pipefail

GITOPS_REPO="${GITOPS_REPO:-https://gitlab.kiruz.com/kiruz/e-commerceStack.git}"
ARGOCD_VERSION="${ARGOCD_VERSION:-2.11.0}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.15.0}"
LONGHORN_VERSION="${LONGHORN_VERSION:-1.6.2}"
CNPG_VERSION="${CNPG_VERSION:-0.21.5}"
ESO_VERSION="${ESO_VERSION:-0.10.0}"
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-4.10.1}"

log()  { echo -e "\n\033[1;32m[$(date -u +%H:%M:%S)] $*\033[0m"; }
warn() { echo -e "\033[1;33m[WARN] $*\033[0m" >&2; }

check_prerequisites() {
  for cmd in kubectl helm argocd; do
    command -v "$cmd" >/dev/null 2>&1 || { warn "$cmd not found — install it first"; exit 1; }
  done
  kubectl cluster-info >/dev/null 2>&1 || { warn "kubectl not connected to a cluster"; exit 1; }
  log "Prerequisites OK"
}

step_namespaces() {
  log "STEP 1 — Creating namespaces..."
  kubectl apply -f clusters/production/cluster-config.yaml
}

step_operators() {
  log "STEP 2 — Installing core operators (cert-manager, ingress-nginx, Longhorn, CNPG, ESO)..."

  # cert-manager
  helm repo add jetstack https://charts.jetstack.io --force-update
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --version "$CERT_MANAGER_VERSION" \
    --set installCRDs=true \
    --wait

  # ingress-nginx
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    --version "$INGRESS_NGINX_VERSION" \
    --set controller.replicaCount=2 \
    --wait

  # Longhorn storage
  helm repo add longhorn https://charts.longhorn.io --force-update
  helm upgrade --install longhorn longhorn/longhorn \
    --namespace longhorn-system --create-namespace \
    --version "$LONGHORN_VERSION" \
    --wait

  # CloudNativePG operator
  helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update
  helm upgrade --install cnpg cnpg/cloudnative-pg \
    --namespace cnpg-system --create-namespace \
    --version "$CNPG_VERSION" \
    --wait

  # External Secrets Operator
  helm repo add external-secrets https://charts.external-secrets.io --force-update
  helm upgrade --install external-secrets external-secrets/external-secrets \
    --namespace external-secrets --create-namespace \
    --version "$ESO_VERSION" \
    --set installCRDs=true \
    --wait

  log "Operators installed"
}

step_secrets() {
  log "STEP 3 — Generating initial secrets..."
  warn "Set VAULT_TOKEN and VAULT_ADDR environment variables before proceeding"
  read -rp "Press ENTER to generate secrets (or Ctrl+C to skip)..."
  bash scripts/generate-secrets.sh
}

step_argocd() {
  log "STEP 4 — Installing ArgoCD..."

  helm repo add argo https://argoproj.github.io/argo-helm --force-update
  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd --create-namespace \
    --version "$ARGOCD_VERSION" \
    -f apps/gitops-cicd/argocd/values.yaml \
    --wait

  # Retrieve initial admin password
  local admin_pass
  admin_pass=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)
  log "ArgoCD admin password: $admin_pass"
  log "ArgoCD UI: https://argocd.kiruz.com (after DNS propagation)"
}

step_argocd_apps() {
  log "STEP 5 — Registering all ArgoCD Applications..."

  # Login to ArgoCD
  local admin_pass
  admin_pass=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)

  argocd login argocd.kiruz.com \
    --username admin \
    --password "$admin_pass" \
    --grpc-web --insecure || \
  argocd login localhost:8080 \
    --username admin \
    --password "$admin_pass" \
    --grpc-web --insecure

  # Apply all ArgoCD Application manifests
  kubectl apply -f clusters/production/argocd-apps.yaml -n argocd

  log "Applications registered. Initial sync will begin automatically."
}

step_network_policies() {
  log "STEP 6 — Applying NetworkPolicies..."
  kubectl apply -f policies/network-policies.yaml
}

step_install_velero() {
  log "STEP 7 — Installing Velero..."
  local minio_pass
  minio_pass=$(kubectl get secret minio-root-secret -n storage \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "MINIO_PASSWORD")

  helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts --force-update
  helm upgrade --install velero vmware-tanzu/velero \
    --namespace velero --create-namespace \
    --set configuration.provider=aws \
    --set configuration.backupStorageLocation.name=minio \
    --set configuration.backupStorageLocation.bucket=velero-backups \
    --set configuration.backupStorageLocation.config.region=minio \
    --set "configuration.backupStorageLocation.config.s3ForcePathStyle=true" \
    --set "configuration.backupStorageLocation.config.s3Url=http://minio.storage.svc.cluster.local:9000" \
    --set "credentials.secretContents.cloud=[default]\naws_access_key_id=admin\naws_secret_access_key=${minio_pass}" \
    --set "initContainers[0].name=velero-plugin-for-aws" \
    --set "initContainers[0].image=velero/velero-plugin-for-aws:v1.9.0" \
    --set "initContainers[0].volumeMounts[0].mountPath=/target" \
    --set "initContainers[0].volumeMounts[0].name=plugins" \
    --wait

  kubectl apply -f monitoring/velero-schedules.yaml
  log "Velero installed and backup schedules created"
}

step_monitoring() {
  log "STEP 8 — Applying monitoring alert rules & dashboards..."
  kubectl apply -f monitoring/alert-rules.yaml

  # Create Grafana dashboard ConfigMap
  kubectl create configmap grafana-dashboards \
    --namespace monitoring \
    --from-file=monitoring/dashboards/ \
    --dry-run=client -o yaml | kubectl apply -f -

  log "Monitoring configured"
}

step_verify() {
  log "STEP 9 — Verification..."
  echo ""
  echo "=== Namespace Status ==="
  kubectl get namespaces | grep -E "core-ecommerce|identity|infrastructure|gitops|monitoring|storage|warehouse|marketing" || true
  echo ""
  echo "=== ArgoCD Applications ==="
  argocd app list 2>/dev/null | head -20 || kubectl get applications -n argocd 2>/dev/null || true
  echo ""
  echo "=== Running Pods (core-ecommerce) ==="
  kubectl get pods -n core-ecommerce 2>/dev/null | head -20 || true
  echo ""
  log "Bootstrap complete! Platform will sync over the next 5-10 minutes."
  log "Monitor ArgoCD at: https://argocd.kiruz.com"
  log "Monitor Grafana at: https://grafana.kiruz.com"
}

# ── Main  ─────────────────────────────────────────────────────────
main() {
  log "========================================"
  log " Kiruz Platform Bootstrap"
  log " GitOps Repo: $GITOPS_REPO"
  log "========================================"

  check_prerequisites

  local start_step="${1:-all}"

  case "$start_step" in
    all | 1) step_namespaces ;;&
    all | 2) step_operators ;;&
    all | 3) step_secrets ;;&
    all | 4) step_argocd ;;&
    all | 5) step_argocd_apps ;;&
    all | 6) step_network_policies ;;&
    all | 7) step_install_velero ;;&
    all | 8) step_monitoring ;;&
    all | 9) step_verify ;;
    *)
      echo "Usage: $0 [all|1|2|3|4|5|6|7|8|9]"
      echo "  1: Namespaces, 2: Operators, 3: Secrets, 4: ArgoCD"
      echo "  5: ArgoCD Apps, 6: NetPolicies, 7: Velero, 8: Monitoring, 9: Verify"
      exit 1
      ;;
  esac
}

main "$@"
