#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────
# generate-secrets.sh — Bootstrap secrets for Kiruz platform
# Creates sealed secrets / ESO-ready secrets from prompts or env vars.
# NEVER commit plain secrets to Git — this script generates
# Kubernetes Secrets that are then sealed or pushed to Vault.
# ──────────────────────────────────────────────────────────────────
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.kiruz.com}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
DRY_RUN="${DRY_RUN:-false}"
NAMESPACE_PREFIX=""

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# ── Helper: write secret to Vault ────────────────────────────────
vault_put() {
  local path="$1"; shift
  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY] vault kv put $path $*"
    return
  fi
  vault kv put "$path" "$@"
}

# ── Helper: generate random password ─────────────────────────────
gen_pass() {
  local length="${1:-32}"
  openssl rand -base64 "$length" | tr -d "=+/" | cut -c1-"$length"
}

# ── Helper: generate Django secret key ───────────────────────────
gen_django_key() {
  python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters + string.digits + '!@#\$%^&*(-_=+)') for _ in range(50)))"
}

check_dependencies() {
  for cmd in vault kubectl openssl python3 kubeseal; do
    command -v "$cmd" >/dev/null 2>&1 || warn "$cmd not found — some operations may fail"
  done
}

# ── 1. Saleor Secrets ─────────────────────────────────────────────
generate_saleor_secrets() {
  log "Generating Saleor secrets..."
  local db_pass; db_pass=$(gen_pass 32)
  local secret_key; secret_key=$(gen_django_key)
  local minio_key; minio_key=$(gen_pass 20)
  local minio_secret; minio_secret=$(gen_pass 40)

  vault_put secret/saleor \
    database_url="postgresql://saleor:${db_pass}@postgresql-primary.storage.svc.cluster.local:5432/saleor" \
    secret_key="$secret_key" \
    minio_access_key="$minio_key" \
    minio_secret_key="$minio_secret" \
    stripe_secret_key="${STRIPE_SECRET_KEY:-CHANGE_ME}"

  # PostgreSQL user password
  vault_put secret/postgresql/saleor \
    password="$db_pass"

  log "Saleor secrets stored in Vault at secret/saleor"
}

# ── 2. Keycloak Secrets ───────────────────────────────────────────
generate_keycloak_secrets() {
  log "Generating Keycloak secrets..."
  local admin_pass; admin_pass=$(gen_pass 24)
  local db_pass;    db_pass=$(gen_pass 32)

  vault_put secret/keycloak \
    admin_password="$admin_pass" \
    db_password="$db_pass"

  log "Keycloak admin password: $admin_pass (store this securely!)"
}

# ── 3. Database user passwords (all services) ────────────────────
generate_database_secrets() {
  log "Generating database user passwords..."
  for svc in odoo gitlab n8n strapi plausible; do
    local pass; pass=$(gen_pass 32)
    vault_put "secret/postgresql/$svc" password="$pass"
    log "  $svc DB password generated"
  done
}

# ── 4. Redis password ─────────────────────────────────────────────
generate_redis_secrets() {
  log "Generating Redis password..."
  local pass; pass=$(gen_pass 32)
  vault_put secret/redis password="$pass"

  # Create K8s secret directly (for Redis chart)
  if [[ "$DRY_RUN" != "true" ]]; then
    kubectl create secret generic redis-secret \
      --namespace storage \
      --from-literal=password="$pass" \
      --dry-run=client -o yaml \
      | kubeseal --format yaml > policies/sealed-secrets/redis-sealed.yaml
    log "Sealed secret written to policies/sealed-secrets/redis-sealed.yaml"
  fi
}

# ── 5. MinIO root credentials ─────────────────────────────────────
generate_minio_secrets() {
  log "Generating MinIO credentials..."
  local access_key; access_key=$(gen_pass 20)
  local secret_key; secret_key=$(gen_pass 40)

  vault_put secret/minio \
    root_user="admin" \
    root_password="$(gen_pass 32)" \
    velero_access_key="$access_key" \
    velero_secret_key="$secret_key"
}

# ── 6. Mosquitto passwords ────────────────────────────────────────
generate_mqtt_secrets() {
  log "Generating MQTT passwords..."
  local amr_pass; amr_pass=$(gen_pass 24)
  local influx_pass; influx_pass=$(gen_pass 24)

  # Mosquitto password file format: user:hashed_password
  local passwd_file
  passwd_file=$(mktemp)
  docker run --rm eclipse-mosquitto:2.0 \
    mosquitto_passwd -c -b /tmp/passwd amr-controller "$amr_pass" 2>/dev/null || \
    echo "amr-controller:$(openssl passwd -5 "$amr_pass")" > "$passwd_file"

  vault_put secret/mosquitto \
    amr_controller_password="$amr_pass" \
    influxdb_subscriber_password="$influx_pass"

  rm -f "$passwd_file"
  log "MQTT passwords generated"
}

# ── 7. Cloudflare API token ───────────────────────────────────────
generate_cloudflare_secrets() {
  log "Cloudflare API token (from environment)..."
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    warn "CLOUDFLARE_API_TOKEN not set — skipping"
    return
  fi

  vault_put secret/cloudflare api_token="$CLOUDFLARE_API_TOKEN"

  kubectl create secret generic cloudflare-api-token \
    --namespace infrastructure \
    --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
    --dry-run=client -o yaml \
    | kubeseal --format yaml > policies/sealed-secrets/cloudflare-sealed.yaml 2>/dev/null || \
    warn "kubeseal not available — plain secret created (DO NOT COMMIT)"
}

# ── 8. WireGuard peers ────────────────────────────────────────────
generate_wireguard_secrets() {
  log "Generating WireGuard keys..."
  local private_key; private_key=$(wg genkey 2>/dev/null || openssl rand -base64 32)
  local public_key; public_key=$(echo "$private_key" | wg pubkey 2>/dev/null || echo "GENERATE_MANUALLY")

  vault_put secret/wireguard \
    server_private_key="$private_key" \
    server_public_key="$public_key"

  log "WireGuard server public key: $public_key"
}

# ── 9. ArgoCD GitLab credentials ─────────────────────────────────
generate_argocd_secrets() {
  log "ArgoCD GitLab credentials (from environment)..."
  if [[ -z "${GITLAB_ARGOCD_TOKEN:-}" ]]; then
    warn "GITLAB_ARGOCD_TOKEN not set — skipping"
    return
  fi

  kubectl create secret generic argocd-gitlab-secret \
    --namespace argocd \
    --from-literal=username=argocd-bot \
    --from-literal=password="$GITLAB_ARGOCD_TOKEN" \
    --dry-run=client -o yaml \
    | kubeseal --format yaml > policies/sealed-secrets/argocd-gitlab-sealed.yaml 2>/dev/null || \
    kubectl apply -f - || true
}

# ── Main ──────────────────────────────────────────────────────────
main() {
  log "=== Kiruz Platform Secret Generator ==="
  log "Vault: $VAULT_ADDR | DryRun: $DRY_RUN"

  check_dependencies

  mkdir -p policies/sealed-secrets

  generate_saleor_secrets
  generate_keycloak_secrets
  generate_database_secrets
  generate_redis_secrets
  generate_minio_secrets
  generate_mqtt_secrets
  generate_cloudflare_secrets
  generate_wireguard_secrets
  generate_argocd_secrets

  log "=== Secret generation complete ==="
  log "Next: kubectl apply -f policies/sealed-secrets/ (if using Sealed Secrets)"
  log "      OR: ensure ESO ClusterSecretStore is configured to read from Vault"
}

main "$@"
