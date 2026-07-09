# YAS three-repository deployment

## Mục đích

Tài liệu này giải thích kiến trúc GitOps 3 repository được dùng để deploy YAS.

- `yas`: source code, CI tests, container builds, image publishing và CD workflows cập nhật image tag vào GitOps.
- `yas-helm`: Helm charts tái sử dụng cho YAS applications và infrastructure.
- `yas-gitops`: environment state, image tags, Argo CD Applications, Istio routing và bootstrap scripts.

Môi trường chạy đích là k3s cluster kết nối qua Tailscale. Application images được publish lên GitHub Container Registry (GHCR), không dùng Docker Hub.

## Điểm bắt đầu deployment

Bootstrap cluster ban đầu được chạy từ repository này:

```bash
cd yas-gitops
./scripts/bootstrap.sh
```

Sau bootstrap, application deployment thông thường được điều khiển bởi GitHub Actions và Argo CD:

```text
push vào yas/main
  -> CI build và publish service image lên GHCR
  -> CD cập nhật image tags trong yas-gitops
  -> Argo CD phát hiện GitOps commit mới
  -> Argo CD reconcile workload bị ảnh hưởng
```

Không nên chạy lại toàn bộ bootstrap cho mỗi thay đổi ứng dụng. Bootstrap dành cho việc cài đặt hoặc sửa trạng thái nền tảng. Release service thông thường được xử lý bởi GitHub Actions CD và Argo CD sync.

## Trách nhiệm của từng repo

| Repository | Trách nhiệm |
| --- | --- |
| `yas` | Source code, tests, CI builds, GHCR image publishing, CD automation |
| `yas-helm` | Helm charts cho backend services, UI services, infrastructure và configuration |
| `yas-gitops` | Argo CD Applications, image tag values, bootstrap phases, Istio policies |

GitOps repository là source of truth cho những gì phải chạy trong cluster. Các thay đổi manual trực tiếp trong Kubernetes chỉ nên được xem là bước debug tạm thời và cần được chuyển ngược lại thành thay đổi trong Git.

## Luồng image qua GHCR

Mỗi service image được push lên GHCR với các tag như:

```text
ghcr.io/23120049/yas-cart:<commit-sha>
ghcr.io/23120049/yas-cart:latest
ghcr.io/23120049/yas-cart:cart-0.1.2
```

Dev thông thường dùng immutable commit SHA tags. Staging dùng release tags được tạo từ GitHub Releases. GitOps values không nên lưu `latest` làm desired state vì `latest` có thể thay đổi.

## Luồng deploy dev

Dev deployment được kích hoạt bởi push lên `yas/main`.

```text
Developer push vào yas/main
  -> service CI build Docker image
  -> image được push lên GHCR với commit SHA và latest tags
  -> CD đợi tới khi commit SHA image tồn tại
  -> CD ghi commit SHA vào values/dev/dynamic-tags/<service>.yaml
  -> CD push GitOps update vào yas-gitops/main
  -> Argo CD sync dev Application
```

Khi root `pom.xml` thay đổi, CD workflow xem tất cả services đều bị ảnh hưởng. Điều này cần thiết vì parent Maven configuration có thể làm thay đổi build output của toàn bộ service.

## Luồng release staging

Staging deployment được kích hoạt khi publish GitHub Release trong `yas`.

Release tag phải bắt đầu bằng tên service:

```text
cart-0.1.2
payment-paypal-0.1.2
storefront-0.1.2
```

Workflow sẽ suy ra service name từ release tag. Với các service có dấu gạch ngang, workflow chọn service prefix dài nhất khớp với release tag, ví dụ `payment-paypal-0.1.2` sẽ map vào `payment-paypal`.

```text
Publish GitHub Release
  -> CD xác định service từ release tag
  -> CD đăng nhập vào GHCR
  -> CD tag ghcr.io/23120049/yas-<service>:latest thành <release-tag>
  -> CD ghi <release-tag> vào values/staging/dynamic-tags/<service>.yaml
  -> CD push GitOps update vào yas-gitops/main
  -> Argo CD sync staging Application
```

Release tag có thể ghi đè một GHCR tag đã tồn tại nếu trùng tên. Tuy vậy, staging value vẫn luôn trỏ tới đúng release tag mà workflow vừa ghi.

## Cách bootstrap thay thế các script deploy cũ

Deployment YAS ban đầu dùng nhiều script như `setup-keycloak.sh`, `setup-redis.sh`, `setup-cluster.sh`, `deploy-yas-configuration.sh` và `deploy-yas-applications.sh`.

GitOps replacement là:

```bash
./scripts/bootstrap.sh
```

Mapping tương ứng:

| Hành vi cũ | Repo owner mới | Thay thế |
| --- | --- | --- |
| Build application source | `yas` | Per-service GitHub Actions workflows |
| Publish images | `yas` | GHCR images tagged với commit SHA, `latest` và release tags |
| Lưu deployment charts | `yas-helm` | Dedicated Helm chart repository |
| Cài operators và infrastructure | `yas-gitops` + `yas-helm` | Phased Argo CD Applications |
| Deploy application config | `yas-gitops` | Configuration phase |
| Deploy workloads | `yas-gitops` | Workload phase |
| Chờ giữa các lệnh Helm | `yas-gitops` | Argo CD health checks và `kubectl wait` gates |
| Expose HTTP traffic | `yas-gitops` | Istio Gateway và VirtualServices |

## Thứ tự phase bootstrap

`./scripts/bootstrap.sh` chạy các phase theo thứ tự:

1. Preflight, Argo CD và Istio prerequisites.
2. Operators: PostgreSQL, Strimzi, ECK và Keycloak.
3. Core infrastructure: PostgreSQL, Redis, Elasticsearch và Kibana.
4. Database initialization.
5. Platform services: Kafka, Kafka Connect, Keycloak và pgAdmin.
6. Debezium connectors.
7. Shared configuration cho `dev` và `staging`.
8. Workloads cho cả hai môi trường.
9. Istio routing.

Để xem chi tiết runtime behavior, timeout handling, best-effort mode và recovery, xem [Bootstrap operations](BOOTSTRAP_OPERATIONS.md).

## Argo CD multi-source pattern

Mỗi workload Application đọc:

- chart source từ `yas-helm`;
- value override source từ `yas-gitops`.

Ví dụ:

```yaml
sources:
  - repoURL: 'https://github.com/23120049/yas-helm.git'
    targetRevision: main
    path: charts/cart
    helm:
      valueFiles:
        - $values/values/dev/dynamic-tags/cart.yaml
  - repoURL: 'https://github.com/23120049/yas-gitops.git'
    targetRevision: main
    ref: values
```

Cách này giúp chart templates tái sử dụng được, đồng thời cho phép mỗi môi trường pin image tags và runtime overrides riêng.

## Network và ingress design

Istio là external ingress layer duy nhất. k3s ServiceLB expose `istio-ingressgateway`, và các máy trong nhóm map `*.yas.local.com` hostnames về gateway IP.

Kiểm tra gateway address:

```bash
kubectl get service istio-ingressgateway -n istio-system -o wide
```

Sau đó cập nhật local hosts entries theo `hostnames.txt`.

Ví dụ URLs:

```text
http://dev-storefront.yas.local.com
http://dev-backoffice.yas.local.com
http://dev-api.yas.local.com/swagger-ui
http://staging-storefront.yas.local.com
http://identity.yas.local.com
```

Pods không phụ thuộc vào workstation hosts files. Internal service calls dùng Kubernetes service DNS. Browser-facing URLs dùng các local domains đã được map.

## Các lệnh thường dùng

Fresh cluster:

```bash
cd yas-gitops
./scripts/bootstrap.sh
```

Private GHCR packages:

```bash
GHCR_USERNAME='<github-user>' \
GHCR_TOKEN='<read-packages-token>' \
./scripts/bootstrap.sh
```

Dùng timeout dài hơn:

```bash
BOOTSTRAP_TIMEOUT=30m ./scripts/bootstrap.sh
```

Chạy degraded workload bootstrap cho demo:

```bash
BOOTSTRAP_MODE=best-effort BOOTSTRAP_TIMEOUT=5m ./scripts/bootstrap.sh
```

Migrate old concurrent root Applications:

```bash
MIGRATE_LEGACY_ROOTS=true ./scripts/bootstrap.sh
```

Post-bootstrap verification:

```bash
kubectl get applications -n argocd
kubectl get pods -n infra
kubectl get pods -n dev
kubectl get pods -n staging
kubectl get gateway,virtualservice -A
kubectl get service istio-ingressgateway -n istio-system -o wide
```
