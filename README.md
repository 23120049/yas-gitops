# YAS GitOps Repository

This repository defines the **desired state** of the YAS (Yet Another Shop) system on the Kubernetes (k3s) cluster. It follows the declarative GitOps pattern using [ArgoCD](https://argo-cd.readthedocs.io/). ArgoCD watches this repository and automatically reconciles the cluster state to match what is declared here.

All Helm charts (both microservices and infrastructure) live in the separate [`yas-helm`](https://github.com/<your-username>/yas-helm) repository. This repository only contains ArgoCD `Application` manifests that **point to** those charts.

---

## Repository Structure

```
yas-gitops/
├── bootstrap/
├── infra/
├── applications/
├── istio/
└── values/
```

### `bootstrap/`
The entry point for the entire cluster. Apply this once manually to bootstrap ArgoCD and hand off control to GitOps.

| File | Description |
|---|---|
| `root.yaml` | Defines two root ArgoCD `Application` resources using the **App-of-Apps** pattern. One manages everything under `infra/` and the other manages everything under `applications/`. Applying this single file causes ArgoCD to discover and sync all other manifests automatically. |

**How to bootstrap a new cluster:**
```bash
kubectl apply -f bootstrap/root.yaml
```

---

### `infra/`
Contains ArgoCD `Application` manifests for **stateful infrastructure services** that must be running before the YAS microservices can start. Each file instructs ArgoCD to deploy the corresponding Helm chart from the `yas-helm` repository.

| File | Namespace | Description |
|---|---|---|
| `postgresql.yaml` | `postgres` | Deploys the PostgreSQL database cluster (Zalando Postgres Operator). |
| `pgadmin.yaml` | `postgres` | Deploys pgAdmin, the web-based database management console. |
| `kafka.yaml` | `kafka` | Deploys the Strimzi Kafka cluster and Debezium CDC connectors. |
| `zookeeper.yaml` | `zookeeper` | Deploys Apache Zookeeper, required for Kafka coordination. |
| `elasticsearch.yaml` | `elasticsearch` | Deploys the ECK Elasticsearch cluster and Kibana. |
| `keycloak.yaml` | `keycloak` | Deploys the Keycloak Identity and Access Management (IAM) server. |
| `observability.yaml` | `observability` | Deploys OpenTelemetry Collector and the Grafana observability stack. |

---

### `applications/`
Contains ArgoCD `Application` manifests for all **YAS microservices and frontends**. Each entry points to a Helm chart in the `yas-helm` repository and deploys to the `yas` namespace.

| File | Description |
|---|---|
| `services.yaml` | A unified manifest containing ArgoCD `Application` resources for all YAS services: `yas-configuration`, `product`, `cart`, `customer`, `order`, `inventory`, `location`, `media`, `payment`, `payment-paypal`, `promotion`, `rating`, `recommendation`, `search`, `tax`, `webhook`, `sampledata`, `storefront-bff`, `storefront-ui`, `backoffice-bff`, `backoffice-ui`, and `swagger-ui`. |

---

### `istio/`
Contains Istio service mesh manifests for cross-service networking policies. These are applied as plain Kubernetes manifests (not via ArgoCD Helm).

| File | Description |
|---|---|
| `authorization-policy.yaml` | Defines which services are allowed to communicate with each other. |
| `peer-authentication.yaml` | Configures mutual TLS (mTLS) settings between services. |
| `retry-policy.yaml` | Defines retry and timeout policies for inter-service traffic. |

---

### `values/`
Contains environment-specific value override files used to customize deployments without modifying the Helm charts themselves.

```
values/
├── dev/
│   └── dynamic-tags/
│       └── image-tags.yaml    # Docker image tags for the dev environment
└── staging/
    └── dynamic-tags/
        └── image-tags.yaml    # Docker image tags for the staging environment
```

| Path | Description |
|---|---|
| `values/dev/` | Value overrides for the **development** environment (e.g. image tags, replica counts). |
| `values/staging/` | Value overrides for the **staging** environment. |

---

## How It Works (End-to-End Flow)

```
Developer pushes code to yas
        │
        ▼
GitHub Actions CI (in yas)
  - Builds Docker image
  - Pushes to GHCR
  - Updates image tag in values/dev/dynamic-tags/image-tags.yaml
        │
        ▼
ArgoCD detects change in yas-gitops
        │
        ▼
ArgoCD pulls Helm chart from yas-helm
  and applies values from yas-gitops/values/
        │
        ▼
Kubernetes (k3s) cluster is updated
```

> [!IMPORTANT]
> Replace all placeholder URLs (`https://github.com/<your-username>/yas-helm.git` and `https://github.com/<your-username>/yas-gitops.git`) in the manifest files with your actual Git repository URLs before bootstrapping.