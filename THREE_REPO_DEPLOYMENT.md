# YAS three-repository deployment

## Purpose

This document explains how the original self-contained `yas` deployment was
translated into the current three-repository GitOps design:

- `yas`: application source code, CI tests, container builds, and image publishing.
- `yas-helm`: reusable Helm charts for YAS applications and infrastructure.
- `yas-gitops`: environment state, image tags, Argo CD Applications, Istio routing,
  and the one-command bootstrap.

The target runtime is a k3s cluster connected through Tailscale. GCP-specific
deployment logic is not part of this design.

## Short answer: where is the deployment button?

The old repository had several shell scripts that acted as deployment buttons:

```bash
./setup-keycloak.sh
./setup-redis.sh
./setup-cluster.sh
./deploy-yas-configuration.sh
./deploy-yas-applications.sh
```

The new equivalent is one command in `yas-gitops`:

```bash
./scripts/bootstrap.sh
```

That command is the initial-install button. It installs or verifies the
deployment controllers, starts each GitOps phase, waits for readiness, and
stops immediately when a dependency is unhealthy.

After the initial bootstrap, pushing or merging application code becomes the
normal deployment button:

```text
push to yas/main
  -> GitHub Actions tests and builds the changed service
  -> image is pushed to GHCR with a commit SHA
  -> CI updates the matching tag in yas-gitops
  -> Argo CD detects the Git commit
  -> Argo CD reconciles the affected workload
```

Operators do not rerun the complete bootstrap for every application release.

## How the old logic maps to the new design

| Original `yas` behavior | New owner | Replacement |
| --- | --- | --- |
| Build application source | `yas` | Per-service GitHub Actions workflows |
| Build and publish images | `yas` | GHCR images tagged with commit SHA and `latest` |
| Store Helm charts beside source | `yas-helm` | Dedicated application and infrastructure chart repository |
| Run `setup-keycloak.sh` | `yas-gitops` + `yas-helm` | Keycloak operator Application and Keycloak chart |
| Run `setup-redis.sh` | `yas-gitops` | Argo CD Redis Application |
| Run `setup-cluster.sh` | `yas-gitops` + `yas-helm` | Phased operator and infrastructure Applications |
| Run `deploy-yas-configuration.sh` | `yas-gitops` | Configuration phase for `dev` and `staging` |
| Run `deploy-yas-applications.sh` | `yas-gitops` | Workload phase containing all service Applications |
| Use sleeps between Helm commands | `yas-gitops` | Argo health checks and explicit `kubectl wait` gates |
| Use Minikube Nginx ingress | `yas-gitops` | Istio Gateway through k3s ServiceLB on node D |
| Edit the hosts file | Team workstations | Map `*.yas.local.com` to the Istio gateway's advertised Tailscale IP |
| Run Kafka with ZooKeeper | `yas-helm` | Strimzi Kafka in KRaft mode with `KafkaNodePool` |

## What happens when bootstrap runs

The script performs the following ordered sequence.

### 1. Preflight

- Requires `kubectl` and `git`.
- Requires the local branch to be `main`, because Argo CD reads remote `main`.
- Confirms that the Kubernetes API is reachable.
- Detects legacy all-at-once root Applications and refuses unsafe concurrent
  deployment unless migration is explicitly requested.

### 2. Argo CD and Istio

- Installs or updates Argo CD.
- Keeps an existing Istio installation when its gateway is present.
- Installs Istio with an ingress gateway only when Istio is absent.
- Waits for `istiod` and `istio-ingressgateway`.
- Verifies that k3s ServiceLB publishes an address for node D. When
  `EXPECTED_INGRESS_IP` is supplied, bootstrap also checks the exact address.

This keeps Istio as the only external ingress. Nginx is not installed.

### 3. Operators

Argo CD installs and waits for:

- Zalando PostgreSQL operator
- Strimzi Kafka operator
- Elastic ECK operator
- Keycloak operator

### 4. Core infrastructure

Argo CD deploys:

- PostgreSQL
- Redis
- Elasticsearch and Kibana

The script checks both Argo CD health and actual pod readiness.

### 5. Database initialization

The script waits for the PostgreSQL credential Secret and then runs
`postgres-init-job`. The job creates separate databases for `dev` and
`staging`, including `product_dev` and `product_staging`.

### 6. Dependent platform services

After database initialization, Argo CD deploys and waits for:

- Kafka in KRaft mode
- Kafka Connect
- Keycloak
- pgAdmin

### 7. Debezium connectors

Debezium PostgreSQL connectors are created only after both product databases
and Kafka Connect exist. This removes the former circular dependency in which
Kafka waited for a connector whose database had not yet been created.

### 8. Shared application configuration

Argo CD creates the `dev` and `staging` namespaces with Istio sidecar injection
enabled, then installs environment-specific configuration and credentials.
The script verifies the shared ConfigMaps and Secrets before workloads start.

### 9. Application workloads

Argo CD deploys both environments:

- Storefront and backoffice UIs
- Storefront and backoffice BFFs
- Swagger UI
- Cart, customer, inventory, location, media, order, payment
- PayPal payment, product, promotion, rating, recommendation
- Search, tax, webhook, and sample data

Each child Application must become `Synced` and `Healthy` before bootstrap can
finish.

### 10. External routing

The final phase creates an Istio Gateway and environment-specific
VirtualServices. Kubernetes Nginx Ingress resources are disabled.

Example URLs are:

```text
http://dev-storefront.yas.local.com
http://dev-backoffice.yas.local.com
http://dev-api.yas.local.com
http://staging-storefront.yas.local.com
http://identity.yas.local.com
```

Each teammate maps these names to the address advertised by the
`istio-ingressgateway` Service. ServiceLB determines the traffic endpoint but
does not configure workstation DNS or hosts files.

Pods do not rely on workstation hosts files. Browser-facing OAuth authorization
URLs use `identity.yas.local.com`, while token, JWK, user-info, and Keycloak
administration calls use the internal `keycloak-service.infra` Service.

## Commands to use

### Fresh cluster with public GHCR packages

After both deployment branches have been merged and the repositories are on
`main`:

```bash
cd yas-gitops
./scripts/bootstrap.sh
```

### Private GHCR packages

```bash
GHCR_USERNAME='<github-user>' \
GHCR_TOKEN='<read-packages-token>' \
./scripts/bootstrap.sh
```

The script creates pull Secrets after the namespaces exist and before workload
deployment.

### Migrating the old Argo CD roots

```bash
MIGRATE_LEGACY_ROOTS=true ./scripts/bootstrap.sh
```

The migration orphans existing workloads while replacing the old concurrent
root Applications with phased roots.

### Non-default gateway IP

```bash
EXPECTED_INGRESS_IP='<tailscale-ip>' ./scripts/bootstrap.sh
```

Use the gateway Service's advertised address rather than assuming whether the
correct Tailscale IP belongs to Windows or the Linux/WSL k3s environment.

## Does this reproduce the original deployment logic?

For the core YAS application, yes, after both feature branches are merged:

- All original application services have Helm charts and Argo CD Applications.
- Shared configuration is installed before workloads.
- Infrastructure and operators are installed before dependent services.
- Databases are initialized before Debezium connectors.
- External storefront, backoffice, API, identity, pgAdmin, and Kibana routes are
  represented through Istio.
- A single bootstrap command replaces the original sequence of shell scripts.
- Subsequent releases are driven by Git commits rather than manual Helm runs.

Some behavior is intentionally different:

- There are separate `dev` and `staging` namespaces instead of one `yas`
  namespace.
- Shared infrastructure lives in `infra`.
- Kafka uses KRaft, so ZooKeeper is not part of the active bootstrap.
- Istio replaces Nginx as the external ingress.
- Observability is optional and is not required for core application startup.
- ServiceMonitor generation is disabled until a Prometheus operator is added.

## Current readiness verdict

The implementation has passed local static checks:

- Both bootstrap scripts pass Bash syntax validation.
- 155 YAML files parse successfully.
- Helm renders show no core Nginx Ingress resources.
- Helm renders show no early KafkaConnector resources.
- Helm renders show no ServiceMonitor dependency on a missing Prometheus CRD.
- Istio hosts and Keycloak redirects consistently use `*.yas.local.com`.
- Every active child Argo CD Application has a bootstrap readiness gate.

However, it is not correct to call the deployment fully proven yet:

1. `yas-gitops/vibebranch` and `yas-helm/vibebranch` must both be merged into
   `main`; the Applications intentionally read remote `main`.
2. The command must be run against the real k3s cluster.
3. The live test must confirm that `istio-ingressgateway` advertises node D's
   reachable Tailscale IP, all Applications become Healthy, and the external
   URLs respond through the teammates' hosts-file mappings.

Therefore, the one-command mechanism exists and the deployment logic is
represented, but production readiness remains conditional on the first
successful end-to-end k3s execution.

## Post-bootstrap verification

```bash
kubectl get applications -n argocd
kubectl get pods -n infra
kubectl get pods -n dev
kubectl get pods -n staging
kubectl get gateway,virtualservice -A
kubectl get service istio-ingressgateway -n istio-system -o wide
```

Expected final state:

- All Argo CD Applications are `Synced` and `Healthy`.
- Infrastructure pods are Ready.
- Application pods in `dev` and `staging` are Ready with Istio sidecars.
- `postgres-init-job` is Complete.
- Both Debezium connectors report Ready.
- The Istio gateway advertises node D's Tailscale IP.
