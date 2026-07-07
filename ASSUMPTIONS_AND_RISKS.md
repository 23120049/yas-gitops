# Deployment assumptions and risks

## Purpose

This document records assumptions introduced or accepted while building the
three-repository YAS deployment flow. These assumptions have not all been
confirmed by the team.

The affected repositories are:

- `yas`: application source and CI.
- `yas-helm`: application and infrastructure Helm charts.
- `yas-gitops`: desired state, bootstrap sequencing, and Istio routing.

The current implementation must be treated as a deployment candidate until the
high-risk assumptions below are confirmed and tested on the real k3s cluster.

## Risk levels

- **P0 - deployment blocker:** can prevent the system from starting or make it
  unreachable.
- **P1 - major behavior risk:** may break a subsystem, security, persistence,
  or release behavior.
- **P2 - operational risk:** deployment may work but be unreliable, expensive,
  difficult to recover, or different from team expectations.

## P0 assumptions

### A1. Kafka runs in KRaft mode on version 4.2

**Assumption**

Kafka no longer requires ZooKeeper. Strimzi can run Kafka `4.2.0` with metadata
version `4.2` and a combined controller/broker `KafkaNodePool`.

**Changes made**

- Replaced the old ZooKeeper-based Kafka resource with `KafkaNodePool` and
  KRaft configuration in `yas-helm/deploy/kafka/kafka-cluster`.
- Removed ZooKeeper from the active `yas-gitops` bootstrap phase.
- Set Kafka storage to `20Gi`.

**How this can break**

- The installed Strimzi operator may not support Kafka 4.2 or the selected CRD
  API version.
- Existing ZooKeeper-based Kafka data cannot automatically become a new KRaft
  cluster. Topics, offsets, or messages may be lost if this is treated as an
  in-place upgrade.
- The custom Debezium Connect image may not be compatible with this Kafka or
  Strimzi version.
- Applications may start while required topics are absent.

**Required decision and verification**

- Confirm the required Kafka and Strimzi versions.
- Confirm whether this is a fresh Kafka cluster or a migration.
- Run `kubectl get kafka,kafkanodepool -n infra` and verify `Ready=True`.
- Produce and consume a test message before merging.

### A2. Istio is the only external ingress

**Assumption**

The existing Istio installation and k3s ServiceLB configuration should be kept.
Nginx Ingress and Traefik are not needed for YAS external traffic.

**Changes made**

- Disabled Nginx Ingress generation through GitOps values.
- Added an Istio `Gateway` for `*.yas.local.com`.
- Added `VirtualService` routes for dev, staging, Keycloak, pgAdmin, and Kibana.
- Bootstrap installs an Istio ingress gateway only if one is missing.

**How this can break**

- If the teammate-installed gateway uses different labels, names, namespaces,
  ports, or an Istio profile without `istio-ingressgateway`, bootstrap fails.
- If ServiceLB is not pinned to node D, URLs may advertise another node or more
  than one address.
- If another controller already owns ports 80/443, the Istio LoadBalancer pods
  may remain Pending.
- Incorrect VirtualService path routing can return 404 responses even when all
  application pods are healthy.

**Required decision and verification**

- Confirm Istio is the sole ingress implementation.
- Confirm gateway Deployment and Service names.
- Confirm ServiceLB node labels and pool labels.
- Run `kubectl get svc istio-ingressgateway -n istio-system -o wide`.
- Test every public hostname from a teammate workstation.

### A3. Teammates resolve `*.yas.local.com` through hosts files

**Assumption**

Each teammate will map the public YAS hostnames to the address advertised by
`istio-ingressgateway`.

**Changes made**

- Restored all public URLs to `*.yas.local.com`.
- Added `yas-gitops/hostnames.txt` as a template.
- Removed all `sslip.io` and hardcoded Tailscale-IP logic.

**How this can break**

- Using the Windows Tailscale IP when k3s ServiceLB advertises the Linux/WSL IP,
  or the reverse, makes every URL unreachable.
- A stale hosts entry keeps routing to an old node after Tailscale addresses or
  ServiceLB ownership change.
- Hosts files affect workstations only; they do not provide DNS inside pods.

**Required decision and verification**

Use this value as the authoritative hosts-file address:

```bash
kubectl get service istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Verify it from each teammate machine with `ping`, `curl`, or a browser.

### A4. The Keycloak operator creates `keycloak-service.infra`

**Assumption**

The internal Keycloak Service is named `keycloak-service` in namespace `infra`.

**Changes made**

- Resource servers use the external issuer
  `http://identity.yas.local.com/realms/Yas` but fetch JWKs internally from
  `http://keycloak-service.infra`.
- BFF token, JWK, and user-info calls use the internal Service.
- Customer management calls use the internal Service.
- Browser-facing authorization redirects remain on `identity.yas.local.com`.

**How this can break**

- If the operator creates a different Service name, backend services can fail
  startup, authentication, token exchange, or user management.
- If Keycloak metadata or token issuer does not remain
  `identity.yas.local.com`, JWT issuer validation can reject every request.
- Explicit OAuth provider endpoints may behave differently from issuer-based
  discovery, especially logout and OIDC session handling.

**Required decision and verification**

```bash
kubectl get service -n infra
kubectl get keycloak -n infra
curl http://identity.yas.local.com/realms/Yas/.well-known/openid-configuration
```

Confirm login, callback, token refresh, logout, and an authenticated API call.

### A5. The Istio route table matches every application context path

**Assumption**

Public API prefixes such as `/product`, `/cart`, `/payment-paypal`, and
`/recommendation` match the Spring servlet context paths and Kubernetes Service
names.

**Changes made**

- Added explicit path-to-Service routes in dev and staging VirtualServices.
- Routed storefront and backoffice hostnames to their BFF Services.
- Routed `/swagger-ui` to the Swagger UI Service on port 8080.

**How this can break**

- A wrong prefix, Service name, or Service port produces 404, 503, or routing
  to the wrong microservice.
- A broad prefix such as `/payment` can shadow another route if route ordering
  changes.
- Swagger can load while individual OpenAPI endpoints fail.

**Required decision and verification**

- Confirm every service context path from application configuration.
- Run a smoke request against each public API prefix in both environments.
- Inspect `istioctl analyze` and Envoy route configuration.

### A6. HTTP without TLS is acceptable

**Assumption**

The initial YAS deployment only needs HTTP on port 80 inside the Tailscale
network.

**Changes made**

- Istio Gateway exposes HTTP only.
- Keycloak redirects and public URLs use `http://`.
- No certificate automation is installed in the core bootstrap.

**How this can break**

- Secure cookies, browser security policies, OAuth callbacks, or future
  SameSite requirements may fail.
- Credentials and tokens are not protected from other actors on the same
  network path.
- Migrating to HTTPS later changes issuer and redirect URLs and can invalidate
  existing Keycloak configuration.

**Required decision and verification**

Confirm whether tailnet-only HTTP is acceptable. If not, choose certificate
management and finalize HTTPS hostnames before production use.

## P1 assumptions

### A7. Resource and storage limits fit the k3s nodes

**Assumption**

The following approximate values are sufficient:

- PostgreSQL: `10Gi`, up to `500m` CPU and `500Mi` memory.
- Kafka: `20Gi`, up to `2` CPU and `2Gi` memory.
- Kafka Connect: up to `1` CPU and `1Gi` memory.
- Elasticsearch: up to `1` CPU and `1Gi` memory.
- Redis: `8Gi` persistent storage.

**Changes made**

Added these values to `yas-gitops/values/infra` and the supporting Helm charts.

**How this can break**

- Pods remain Pending when no node has enough allocatable CPU or memory.
- Elasticsearch, Kafka, or PostgreSQL may be OOMKilled under realistic load.
- Local disks may fill, corrupt data, or block scheduling.
- Limits can throttle services and cause readiness timeouts during bootstrap.

**Required decision and verification**

Compare requests and limits with `kubectl describe nodes`, then run a realistic
load test and monitor memory, disk, and restart counts.

### A8. `local-path` is the correct StorageClass

**Assumption**

The k3s `local-path` provisioner is available and acceptable for all persistent
data.

**Changes made**

Redis and pgAdmin values explicitly use `local-path`; other local persistent
workloads rely on the cluster's local storage behavior.

**How this can break**

- A PVC can bind to one node and prevent its pod from moving after node failure.
- Data may be lost when the node disk is lost.
- Multi-node scheduling can conflict with local volume affinity.

**Required decision and verification**

Confirm whether this is a disposable development cluster. For durable shared
environments, choose a replicated StorageClass and define backups.

### A9. Single-replica infrastructure is sufficient

**Assumption**

Development convenience is more important than high availability.

**Changes made**

PostgreSQL, Kafka, Elasticsearch, Redis, and related platform components are
configured primarily as single instances.

**How this can break**

- Restarting or losing one node causes a full subsystem outage.
- Maintenance interrupts both dev and staging because infrastructure is shared.
- No replica is available for failover.

**Required decision and verification**

Confirm the availability target for this cluster and whether staging is allowed
to share single-instance infrastructure with dev.

### A10. Both dev and staging deploy during initial bootstrap

**Assumption**

The cluster has enough capacity and the team wants both environments active.

**Changes made**

- Bootstrap creates both namespaces.
- Separate databases, configurations, workloads, and routes are created for
  both environments.

**How this can break**

- Resource usage roughly doubles for application workloads.
- A low-capacity node can leave many pods Pending and make bootstrap time out.
- Shared infrastructure changes affect both environments.

**Required decision and verification**

Confirm cluster capacity and whether bootstrap needs an option to deploy only
dev or only staging.

### A11. Observability is optional for core readiness

**Assumption**

YAS should start without Prometheus, Grafana, Loki, Tempo, Promtail, and their
operators.

**Changes made**

- Moved observability out of active infrastructure bootstrap.
- Disabled `ServiceMonitor` by default to avoid requiring the Prometheus CRD.
- Left an optional observability manifest for later work.

**How this can break**

- Applications still configured to export telemetry may log repeated connection
  failures or lose metrics and traces.
- The team may call bootstrap successful while having no operational visibility.
- Alerts and dashboards from the original deployment are absent.

**Required decision and verification**

Confirm whether observability is part of the minimum viable platform. If it is,
create a separate gated phase rather than applying the current optional file as
an unverified add-on.

### A12. Only Product requires Debezium CDC

**Assumption**

Only `product_dev` and `product_staging` need PostgreSQL connectors.

**Changes made**

- Created two Product KafkaConnector resources after database initialization.
- Disabled connector creation in the first Kafka Helm release.

**How this can break**

- Search, recommendation, webhook, or another service may depend on CDC from
  additional databases or differently named topics.
- Topic names may not match application environment variables.

**Required decision and verification**

Confirm the event topology and expected topic names with application owners.
Verify connector status and consumed events for search, recommendation, and
webhook.

### A13. GHCR account and access model are correct

**Assumption**

Images live under `ghcr.io/23120049`, and either packages are public or a single
read-packages token can be used in both application namespaces.

**Changes made**

- Charts and dynamic values reference this GHCR owner.
- Bootstrap optionally creates a `ghcr-pull` Secret from environment variables
  and patches each default ServiceAccount.

**How this can break**

- Images produce `ImagePullBackOff` if ownership, visibility, token scope, or
  package permissions differ.
- Patching only the default ServiceAccount is ineffective if a chart uses its
  own ServiceAccount and does not inherit the pull Secret.
- Tokens passed through shell environment or history can leak.

**Required decision and verification**

Confirm package ownership and visibility. Inspect each deployed pod's
ServiceAccount and test image pulls before the workload phase.

### A14. Fixed operator and platform versions are compatible

**Assumption**

Pinned PostgreSQL, Strimzi, ECK, Keycloak, Kafka, Elasticsearch, and Kibana
versions are mutually compatible with the cluster Kubernetes version.

**Changes made**

- Added explicit operator Applications and chart revisions.
- Kept fixed application versions inside infrastructure charts.

**How this can break**

- CRDs can reject resources when APIs or fields do not match the operator.
- Kubernetes upgrades can make old charts unsupported.
- Operator upgrades can perform irreversible data migrations.

**Required decision and verification**

Create and approve a compatibility matrix containing k3s/Kubernetes, operator,
CRD, and managed application versions.

## P2 assumptions

### A15. Remote `main` is the only deployable Git revision

**Assumption**

Feature branches are review artifacts; Argo CD always reconciles remote `main`.

**Changes made**

- All Applications use `targetRevision: main`.
- Bootstrap refuses to run from another local branch by default.

**How this can break**

- The team cannot run an end-to-end deployment test from `vibebranch` before
  merge.
- Merging both repositories in the wrong order can temporarily reference chart
  features that do not yet exist on `main`.

**Required decision and verification**

Confirm the merge order or introduce an explicit preview-environment revision
strategy.

### A16. Argo CD `stable` manifests are safe to consume

**Assumption**

Installing Argo CD from the moving upstream `stable` URL is acceptable.

**Changes made**

Bootstrap applies the upstream stable installation manifest.

**How this can break**

- A future bootstrap can install a different Argo CD version with changed CRDs
  or behavior.
- An upstream outage prevents cluster setup.

**Required decision and verification**

Pin an approved Argo CD release and optionally mirror the manifest.

### A17. Istio `demo` is an acceptable fallback profile

**Assumption**

When Istio is absent, the `demo` profile is the quickest valid way to obtain a
control plane and ingress gateway.

**Changes made**

`install-prerequisites.sh` runs `istioctl install --set profile=demo` only when
the required Istio resources are absent.

**How this can break**

- The demo profile has defaults intended for evaluation rather than a hardened
  shared environment.
- It may consume unexpected resources or differ from the teammate-managed
  installation.

**Required decision and verification**

Export the teammate's approved Istio configuration and manage that exact state
instead of relying on a fallback profile.

### A18. Legacy Argo migration may orphan workloads safely

**Assumption**

Deleting old parent and child Application objects with orphan propagation will
preserve workloads cleanly until phased Applications adopt them.

**Changes made**

Added `MIGRATE_LEGACY_ROOTS=true` behavior to bootstrap.

**How this can break**

- Resource tracking labels or finalizers may cause deletion, duplication, or
  shared-resource warnings.
- An interrupted migration leaves live resources without an owning Application.

**Required decision and verification**

Test migration in a disposable cluster and export all existing Applications
before using this option on a shared cluster.

## Confirmed requirements

The following are based on explicit user direction rather than unconfirmed
assumptions:

- The target runtime is k3s.
- GCP-specific deployment logic must not be used.
- Istio is already installed by a teammate.
- k3s ServiceLB is intended to advertise the Istio ingress gateway on node D.
- Teammates will edit their hosts files.
- Public names should use `*.yas.local.com`.
- `sslip.io` must not be used.

Even confirmed requirements still require live verification because the
current development environment cannot reach the real k3s API.

## Pre-merge decision checklist

Do not treat the branch as production-ready until the team records answers for:

1. Approved Kafka, Strimzi, Elasticsearch, Keycloak, and operator versions.
2. Fresh Kafka versus ZooKeeper-to-KRaft migration.
3. Istio gateway names, labels, ServiceLB pool, and advertised node-D address.
4. HTTP-only versus HTTPS requirements.
5. Actual Keycloak Service name and OAuth login/logout behavior.
6. Required API prefixes and ports.
7. Resource requests, limits, storage sizes, and StorageClass.
8. Whether both dev and staging must deploy together.
9. Whether observability is required for minimum readiness.
10. Required Debezium databases and topic names.
11. GHCR ownership, visibility, and pull-secret strategy.
12. Argo CD and Istio version-pinning policy.
13. Whether automatic orphan migration is acceptable.

## Live acceptance test

At minimum, the first cluster test must prove:

```bash
kubectl get applications -n argocd
kubectl get pods -n infra
kubectl get pods -n dev
kubectl get pods -n staging
kubectl get kafka,kafkanodepool,kafkaconnect,kafkaconnector -n infra
kubectl get postgresql,elasticsearch,kibana,keycloak -n infra
kubectl get gateway,virtualservice -A
kubectl get service istio-ingressgateway -n istio-system -o wide
```

Then verify:

- Every Argo CD Application is Synced and Healthy.
- Every required pod is Ready and persistent volumes are Bound.
- Database initialization completed.
- Kafka and Debezium pass a real event round trip.
- Keycloak login, callback, refresh, logout, and API authorization work.
- Every public dev and staging route responds from a teammate workstation.
- Restarting a node or critical pod has an understood recovery outcome.
