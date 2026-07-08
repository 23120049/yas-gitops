# Bootstrap operation, degraded deployment, and recovery

## Goals

The bootstrap has two operating modes:

- `strict` (default) stops at the first failed readiness gate. Use it for a
  normal production deployment.
- `best-effort` keeps phases 1-4 strict, but treats workload and routing
  failures as degraded results. Use it when a partially working environment is
  more useful than no environment, for example during a demo.

Best effort does not delete, disable, or permanently skip an application. The
Argo CD `Application` remains installed with automated sync and self-healing,
so Argo CD continues retrying it after the bootstrap process has moved on.

## Execution order and failure policy

| Runtime phase | Content | Policy |
| --- | --- | --- |
| `00-prerequisites` | Argo CD, Istio, ingress address | Always blocking |
| `01-operators` | PostgreSQL, Strimzi, ECK, Keycloak operators | Always blocking |
| `02-infrastructure` | PostgreSQL, Redis, Elasticsearch/Kibana | Always blocking |
| `03-initialization` | Database creation and credentials | Always blocking |
| `04-platform` | Kafka, Kafka Connect, Keycloak, pgAdmin | Always blocking |
| `03-connectors` | Debezium connectors | Always blocking |
| `04-configuration` | Namespaces, application config and secrets | Always blocking |
| `05-workloads` | Dev and staging microservices/UIs | Non-blocking only in best effort |
| `06-routing` | Istio gateway and routes | Non-blocking only in best effort |

The file names preserve the repository's existing phase names. At runtime the
platform must precede connectors, which is why `03-connectors` appears after
`04-platform`.

Observability Applications currently exist under `infra/`, but no active
bootstrap phase includes them. Therefore Loki, Tempo, Prometheus, Promtail,
Grafana Operator, and OpenTelemetry cannot block the active bootstrap. If they
are installed separately, they are still displayed by the status tool because
it reads every Argo CD Application.

## Running a partial/degraded bootstrap

```bash
BOOTSTRAP_MODE=best-effort BOOTSTRAP_TIMEOUT=5m ./scripts/bootstrap.sh
```

All phase 5 child Application names are discovered directly from
`applications/dev/services.yaml` and `applications/staging/services.yaml`.
Adding a service there automatically adds it to bootstrap readiness tracking;
there is no second hard-coded service list to update.

Workload waits run concurrently. Several failed services therefore consume
roughly one timeout window instead of one timeout per failed service.

Possible final outcomes are:

- `SUCCESS`: every checked component became `Synced` and `Healthy`.
- `DEGRADED`: bootstrap reached the end, but at least one best-effort
  Application timed out or was unhealthy.
- `FAILED`: a required phase/gate failed, or bootstrap terminated unexpectedly.

## Deployment reports

Every run writes a timestamped report:

```text
.bootstrap-reports/bootstrap-<UTC timestamp>.log
```

The report records the phase, component, result, detail, final outcome, and a
snapshot of every Argo CD Application. It is written even when `set -e` stops
the script. Reports are ignored by Git.

When the `argocd` namespace is reachable, the latest report is also persisted
in the cluster:

```bash
kubectl get configmap yas-bootstrap-last-report -n argocd \
  -o jsonpath='{.data.report}'
```

Use this for a quick current summary:

```bash
bash ./scripts/bootstrap-status.sh
```

Inspect one failed service, including Argo CD conditions, pods, and recent
warning events:

```bash
bash ./scripts/bootstrap-status.sh product-dev
```

An Application reported as `CONTINUED` was not removed. It means the
best-effort bootstrap stopped waiting for it and continued to the next phase.

## Repairing a continued or failed service

1. Inspect it:

   ```bash
   bash ./scripts/bootstrap-status.sh product-dev
   ```

2. Fix the source of truth. Common fixes are:

   - publish or correct the container image/tag in `yas`;
   - correct chart templates/defaults in `yas-helm`;
   - correct the Application values or revision in `yas-gitops`;
   - restore a missing Secret, credential, dependency, or cluster capacity.

3. Commit and push the fix to the revision used by the Application (normally
   `main`). Local-only changes are invisible to Argo CD.

4. Request a hard refresh and wait only for that component:

   ```bash
   BOOTSTRAP_TIMEOUT=10m bash ./scripts/recover-application.sh product-dev
   ```

The recovery script does not rerun database initialization or other bootstrap
phases. Automated sync/self-heal performs the deployment; the script verifies
that the selected Application reaches both `Synced` and `Healthy`. It also
annotates that Application with the time and result of the latest explicit
recovery attempt; `bootstrap-status.sh <application>` displays those values.

If the failed item is a bootstrap parent such as `yas-bootstrap-workloads`,
first inspect its child Applications. Recover the unhealthy children, then
recover the parent. Rerunning the complete bootstrap is safe and idempotent but
normally unnecessary.

## Diagnostic interpretation

| Argo CD state | Meaning | Typical action |
| --- | --- | --- |
| `OutOfSync` | Desired and live resources differ | Inspect sync/render errors; refresh after fixing Git |
| `Synced/Progressing` | Resources applied but are not ready | Inspect pods, probes, dependencies, and events |
| `Synced/Degraded` | A managed resource reports failure | Inspect rollout, pod logs, image pulls, and health probes |
| Application missing | Parent did not create it or source rendering failed | Inspect the parent Application and repository revision |
| `Unknown` | Argo CD cannot calculate health or load desired state | Inspect repository access and Application conditions |

Do not manually patch a Git-managed Deployment as a lasting fix: self-heal may
revert it. Emergency changes should be followed by the equivalent Git change.

## Known limits

- A timeout is not proof that a service is permanently broken; it only records
  that readiness was not reached within the configured window.
- Phase 1-4 remain blocking because workloads share their database, identity,
  messaging, and configuration dependencies. Continuing past those failures
  would mark many downstream services degraded without producing a useful
  environment.
- The report ConfigMap stores only the latest run. Timestamped local reports
  retain earlier runs on the machine that executed bootstrap.

## Audit findings and operational risks

- Bootstrap manifests point to remote `main`. A locally edited manifest is not
  deployed until it is committed and pushed. The branch guard reduces, but
  cannot eliminate, the risk of local `main` being ahead of or behind remote.
- Argo CD installation currently uses the mutable upstream `stable` manifest.
  A future bootstrap can therefore install a different Argo CD release. Pin an
  approved Argo CD version before treating bootstrap as reproducible.
- `install-prerequisites.sh` reads only
  `.status.loadBalancer.ingress[0].ip`. Environments that expose a hostname
  instead of an IP need a corresponding hostname-aware check.
- Each workload Application uses automated prune and self-heal. Fixes must be
  made in Git; lasting manual cluster edits will be reconciled away.
- The database initialization Job is safe to wait on when already complete,
  but changing immutable Job fields later may require a deliberate Job
  replacement before Argo CD can sync the new definition.
- Private GHCR images require `GHCR_USERNAME` and `GHCR_TOKEN` during bootstrap,
  or an equivalent pre-existing pull secret. Missing credentials commonly
  appear as `ImagePullBackOff` during phase 5.
- The status report reflects Kubernetes/Argo CD health, not an end-to-end
  business transaction. Run smoke tests for the exact demo flow after a
  degraded bootstrap.
