# Observability Services Deployment Plan (GitOps & k3s)

This document describes the current state of the observability configurations in the YAS workspace, the desired state under the GitOps model, the data flow, and the step-by-step instructions to deploy these services onto your k3s cluster.

---

## 1. Flow of Data

The observability stack follows the modern standard recommended by **OpenTelemetry (OTel)**, integrating Metrics, Logs, and Traces (M.L.T.) into a unified pane of glass (Grafana).

```mermaid
graph TD
    %% Applications & Log Scrapers
    subgraph Microservices ["YAS Microservices (Node A / App Namespace)"]
        app[Service Pods]
    end

    subgraph LogCollector ["Log Collection (DaemonSet)"]
        promtail[Promtail]
    end

    subgraph OTel ["Collector Layer (Observability Namespace)"]
        otel_col[OpenTelemetry Collector]
    end

    %% Storage Backends
    subgraph Backends ["Observability Storage Backends"]
        loki[Loki (Log DB)]
        tempo[Tempo (Trace DB)]
        prometheus[Prometheus (Metric DB)]
    end

    %% Visualizer
    subgraph Visualization ["Visualization Layer"]
        grafana[Grafana Dashboard]
    end

    %% Data Flow Connections
    app -- "Writes Logs to stdout" --> promtail
    promtail -- "Pushes logs (HTTP:3500)" --> otel_col
    otel_col -- "Processes & Pushes Logs" --> loki
    
    app -- "Sends Traces (gRPC:4317 / HTTP:4318)" --> otel_col
    otel_col -- "Pushes Traces" --> tempo
    
    tempo -- "Generates Metrics from Traces" --> prometheus
    app -- "Exposes metrics endpoint" --> prometheus
    
    loki --> grafana
    tempo --> grafana
    prometheus --> grafana
```

### Detailed Flow:
* **Logs Flow:**
  1. Microservices write logs to stdout.
  2. **Promtail** (running as a DaemonSet on each node) monitors container log files, scrapes them, and sends them to the **OpenTelemetry Collector** at port `3500` (`http://opentelemetry-collector:3500/loki/api/v1/push`).
  3. The **OTel Collector** receives the logs, injects metadata attributes (such as `namespace`, `container`, `pod`, `level`, and `traceId`), and exports them to **Loki** at `http://loki-gateway/loki/api/v1/push`.
  4. **Loki** indexes and stores the logs.
* **Traces Flow:**
  1. Microservices (instrumented with OpenTelemetry SDK) send distributed trace spans directly to the **OTel Collector** on port `4317` (gRPC) or `4318` (HTTP).
  2. The **OTel Collector** batches these traces and exports them to **Tempo** at `http://tempo:4318` (OTLP/HTTP).
  3. **Tempo** stores the traces and generates system metrics (such as request rates, durations, and error counts) from the tracing spans using its `metricsGenerator`.
  4. Tempo writes these trace-derived metrics to **Prometheus** via Remote Write (`/api/v1/write`).
* **Metrics Flow:**
  1. **Prometheus** scrapes application endpoints and cluster metrics.
  2. It also receives trace-derived metrics remote-written from **Tempo**.
* **Visualization Flow:**
  1. **Grafana** queries **Prometheus** (metrics), **Loki** (logs), and **Tempo** (traces).
  2. Because the OTel Collector stamps logs with `traceId`, Grafana links logs directly to traces, allowing developers to jump from a log error line straight to its distributed trace graph.

---

## 2. Current State vs. Desired State

### Current State:
* **Local config (`yas` repo):** Observability is defined for local Docker Compose (`docker-compose.o11y.yml`). The k8s configuration exists in `k8s/deploy/observability/` as static templates with hardcoded values (such as `nginx` as ingress controller in `prometheus.values.yaml` and postgres database passwords).
* **GitOps config (`yas-gitops` repo):** The `infra/observability.yaml` file in `yas-gitops` only registers two ArgoCD Applications:
  1. `observability` (pointing to the custom OTel Collector chart: `deploy/observability/opentelemetry`).
  2. `grafana` (pointing to the custom Grafana provisioning chart: `deploy/observability/grafana`).
* **Missing Components:** There are **no definitions** in `yas-gitops` for:
  - **Cert-Manager** (needed for OTel Operator webhooks)
  - **OpenTelemetry Operator**
  - **Loki** (log database)
  - **Tempo** (tracing database)
  - **Promtail** (log forwarder)
  - **Kube-Prometheus-Stack** (Prometheus engine)

### Desired State:
* All observability components must be declared as **ArgoCD Application manifests** in the `infra/` folder of `yas-gitops`.
* Custom Helm values must be placed in `values/infra/` inside `yas-gitops` to override defaults (e.g., setting the Ingress class to `traefik` since you are deploying on k3s).

---

## 3. Step-by-Step Deployment Instructions

To deploy the observability stack using GitOps on your k3s cluster, follow these steps:

### Step 1: Add Custom Values Files to `yas-gitops`
We need to copy the custom `.values.yaml` configs from `yas` to `yas-gitops` values folder so ArgoCD can apply them.

Copy these files into `yas-gitops/values/infra/`:
1. `loki.yaml` (copied from `yas/k8s/deploy/observability/loki.values.yaml`)
2. `tempo.yaml` (copied from `yas/k8s/deploy/observability/tempo.values.yaml`)
3. `promtail.yaml` (copied from `yas/k8s/deploy/observability/promtail.values.yaml`)
4. `prometheus.yaml` (copied from `yas/k8s/deploy/observability/prometheus.values.yaml` but updated for k3s `traefik` ingress class).

> [!NOTE]
> When copying `prometheus.yaml`, edit the Ingress section to use `traefik`:
> ```yaml
>   ingress:
>     ingressClassName: traefik
>     enabled: true
> ```

### Step 2: Define ArgoCD Application manifests in `yas-gitops/infra/`
Create the following Application files in `yas-gitops/infra/` to instruct ArgoCD to fetch these charts and apply your value files.

* **`infra/cert-manager.yaml`** (Installs Cert-Manager from Jetstack):
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: cert-manager
    namespace: argocd
  spec:
    project: default
    source:
      repoURL: 'https://charts.jetstack.io'
      chart: cert-manager
      targetRevision: v1.12.0
      helm:
        parameters:
          - name: installCRDs
            value: "true"
    destination:
      server: 'https://kubernetes.default.svc'
      namespace: cert-manager
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
  ```

* **`infra/otel-operator.yaml`** (Installs OTel Operator from OpenTelemetry):
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: opentelemetry-operator
    namespace: argocd
  spec:
    project: default
    source:
      repoURL: 'https://open-telemetry.github.io/opentelemetry-helm-charts'
      chart: opentelemetry-operator
      targetRevision: HEAD
    destination:
      server: 'https://kubernetes.default.svc'
      namespace: observability
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
  ```

* **`infra/loki.yaml`** (Installs Loki using your custom values):
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: loki
    namespace: argocd
  spec:
    project: default
    sources:
      - repoURL: 'https://grafana.github.io/helm-charts'
        chart: loki
        targetRevision: HEAD
        helm:
          valueFiles:
            - $values/values/infra/loki.yaml
      - repoURL: 'https://github.com/23120049/yas-gitops.git'
        targetRevision: HEAD
        ref: values
    destination:
      server: 'https://kubernetes.default.svc'
      namespace: observability
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
  ```

* **`infra/tempo.yaml`** (Installs Tempo using your custom values):
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: tempo
    namespace: argocd
  spec:
    project: default
    sources:
      - repoURL: 'https://grafana.github.io/helm-charts'
        chart: tempo
        targetRevision: HEAD
        helm:
          valueFiles:
            - $values/values/infra/tempo.yaml
      - repoURL: 'https://github.com/23120049/yas-gitops.git'
        targetRevision: HEAD
        ref: values
    destination:
      server: 'https://kubernetes.default.svc'
      namespace: observability
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
  ```

* **`infra/promtail.yaml`** (Installs Promtail log forwarder):
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: promtail
    namespace: argocd
  spec:
    project: default
    sources:
      - repoURL: 'https://grafana.github.io/helm-charts'
        chart: promtail
        targetRevision: HEAD
        helm:
          valueFiles:
            - $values/values/infra/promtail.yaml
      - repoURL: 'https://github.com/23120049/yas-gitops.git'
        targetRevision: HEAD
        ref: values
    destination:
      server: 'https://kubernetes.default.svc'
      namespace: observability
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
  ```

* **`infra/prometheus.yaml`** (Installs Kube-Prometheus-Stack):
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: prometheus
    namespace: argocd
  spec:
    project: default
    sources:
      - repoURL: 'https://prometheus-community.github.io/helm-charts'
        chart: kube-prometheus-stack
        targetRevision: HEAD
        helm:
          valueFiles:
            - $values/values/infra/prometheus.yaml
      - repoURL: 'https://github.com/23120049/yas-gitops.git'
        targetRevision: HEAD
        ref: values
    destination:
      server: 'https://kubernetes.default.svc'
      namespace: observability
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
  ```

* **`infra/grafana-operator.yaml`** (Installs Grafana Operator):
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: grafana-operator
    namespace: argocd
  spec:
    project: default
    source:
      repoURL: 'oci://ghcr.io/grafana-operator/helm-charts/grafana-operator'
      chart: grafana-operator
      targetRevision: v5.0.2
    destination:
      server: 'https://kubernetes.default.svc'
      namespace: observability
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
  ```

### Step 3: Register everything in the bootstrap root
Make sure these applications are picked up by the GitOps bootstrap process by editing the root app [bootstrap/root.yaml](file:///c:/Users/huyen/source/repos/yas-gitops/bootstrap/root.yaml) to point to the `infra` directory (which already watches all YAML files inside `infra/` recursively).

### Step 4: Commit and push the changes
Push all new application manifests and value files to the `yas-gitops` repository. ArgoCD will instantly notice them and roll out the entire observability ecosystem onto the k3s cluster!
