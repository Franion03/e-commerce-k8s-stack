# Calzados Kiruz — GitOps eCommerce + Warehouse Kubernetes Infrastructure

## Architecture Summary

This repository implements a **GitOps-first Kubernetes infrastructure** for a multi-vendor ecommerce company with a robot-driven warehouse. All services are self-hosted on Kubernetes, managed by **ArgoCD** which continuously reconciles this Git repository as the single source of truth.

### Platform Overview

| Layer | Services |
|---|---|
| **Ecommerce** | Saleor (GraphQL API), Next.js Storefront, Odoo ERP/WMS |
| **Identity & Security** | Keycloak, Vaultwarden, WireGuard, OPNsense |
| **Infrastructure** | HAProxy, Keepalived, Cloudflare, Pi-hole, PowerDNS |
| **GitOps / CI-CD** | GitLab, ArgoCD, n8n, Ollama, Strapi |
| **Monitoring** | Prometheus, Grafana, Loki, Tempo, Alertmanager |
| **Storage** | PostgreSQL (Patroni), Redis, MinIO, Velero |
| **Warehouse / Robots** | AMR Controller, Mosquitto MQTT, InfluxDB |
| **Marketing** | Mailcow, Plausible, content-pipeline |

### Architecture Diagrams

See [docs/architecture.md](docs/architecture.md) for the three Mermaid diagrams:
- High-Level Architecture (User → Cloudflare → HAProxy → K8s)
- GitOps Flow (GitLab → ArgoCD → Helm Charts → Apps)
- Robot Warehouse Integration (Odoo WMS → AMR → Robots → Inventory)

---

## Repository Structure

```
e-commerceStack/
├── apps/                   # All Helm charts, one sub-dir per service
├── clusters/               # Per-cluster ArgoCD app manifests + config
├── policies/               # Kubernetes NetworkPolicies
├── monitoring/             # Prometheus rules, Grafana dashboards, Velero
├── scripts/                # Bootstrap and utility scripts
└── docs/                   # Architecture diagrams and runbooks
```

---

## Quick Bootstrap

```bash
# 1. Install ArgoCD into the cluster
kubectl create namespace argocd
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd -f apps/gitops-cicd/argocd/values.yaml

# 2. Register this repository
kubectl apply -f clusters/production/argocd-apps.yaml -n argocd

# 3. Sync all applications
argocd app sync --selector env=production
```

See [docs/deployment-guide.md](docs/deployment-guide.md) for the full step-by-step guide.

---

## Namespace Plan

| Namespace | Purpose |
|---|---|
| `core-ecommerce` | Saleor, Next.js, Stripe Connect |
| `identity-security` | Keycloak, Vaultwarden, WireGuard |
| `infrastructure` | HAProxy, Keepalived, Pi-hole, PowerDNS |
| `gitops-cicd` | GitLab, ArgoCD, n8n, Ollama |
| `monitoring` | Prometheus, Grafana, Loki, Tempo |
| `storage` | PostgreSQL, Redis, MinIO |
| `warehouse-robots` | AMR Controller, Mosquitto, InfluxDB |
| `marketing` | Mailcow, Plausible, content-pipeline |
