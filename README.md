# YAS GitOps

`yas-gitops` là repository khai báo desired state cho hệ thống YAS trên Kubernetes. Repo này chứa Argo CD `Application`, values theo môi trường, bootstrap manifests, Istio routing và các script vận hành.

Hệ thống được chia thành 3 repository:

- `23120049/yas`: source code microservices, GitHub Actions CI/CD, build image và push lên GHCR.
- `23120049/yas-helm`: Helm charts cho application, UI và infrastructure.
- `23120049/yas-gitops`: GitOps state để Argo CD sync vào cluster.

Argo CD không lấy image từ Docker Hub. Các workload dùng image từ GHCR theo format:

```text
ghcr.io/23120049/yas-<service>:<tag>
```

Tài liệu liên quan:

- [Three-repository deployment](THREE_REPO_DEPLOYMENT.md): giải thích kiến trúc 3 repo và cách các repo tương tác.
- [Bootstrap operations](BOOTSTRAP_OPERATIONS.md): giải thích chi tiết phase bootstrap, chế độ `strict`/`best-effort`, report và recovery.

## Cấu trúc repo

```text
yas-gitops/
├── applications/
│   ├── dev/services.yaml
│   └── staging/services.yaml
├── bootstrap/
│   ├── 01-operators.yaml
│   ├── 02-infrastructure.yaml
│   ├── 03-initialization.yaml
│   ├── 04-platform.yaml
│   ├── 03-connectors.yaml
│   ├── 04-configuration.yaml
│   ├── 05-workloads.yaml
│   └── 06-routing.yaml
├── infra/
├── istio/
│   ├── dev/
│   └── staging/
├── scripts/
└── values/
    ├── dev/dynamic-tags/
    ├── staging/dynamic-tags/
    └── infra/
```

## Điều kiện trước khi bootstrap

Máy chạy bootstrap cần có:

- k3s cluster đang hoạt động.
- `kubectl` trỏ đúng vào cluster.
- `git` có trong `PATH`.
- Repo local `yas-gitops` đang ở branch `main`.
- Remote `main` của `yas-gitops` và `yas-helm` đã có các thay đổi cần deploy.
- Máy có quyền truy cập cluster qua Tailscale nếu cluster chạy trong mạng Tailscale.

Kiểm tra nhanh:

```bash
git branch --show-current
kubectl cluster-info
kubectl get nodes -o wide
```

Bootstrap đọc state từ remote `main` thông qua Argo CD. Vì vậy không nên chạy bootstrap khi thay đổi chỉ mới nằm local mà chưa commit/push.

## Cấu hình DNS/hosts

Istio là external ingress duy nhất. Sau khi gateway có IP, các máy cần truy cập UI/API phải map các domain `*.yas.local.com` về IP của `istio-ingressgateway`.

Kiểm tra IP gateway:

```bash
kubectl get service istio-ingressgateway -n istio-system -o wide
kubectl get service istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Cập nhật file hosts trên máy local theo nội dung trong:

```text
hostnames.txt
```

Các URL chính:

```text
http://dev-storefront.yas.local.com
http://dev-backoffice.yas.local.com
http://dev-api.yas.local.com/swagger-ui
http://staging-storefront.yas.local.com
http://staging-backoffice.yas.local.com
http://staging-api.yas.local.com/swagger-ui
http://identity.yas.local.com
http://kibana.yas.local.com
```

## Chạy bootstrap lần đầu

Từ thư mục repo `yas-gitops`, chạy:

```bash
./scripts/bootstrap.sh
```

Lệnh này sẽ:

1. Cài hoặc kiểm tra Argo CD và Istio.
2. Apply operator Applications.
3. Deploy infrastructure core như PostgreSQL, Redis, Elasticsearch.
4. Chạy job khởi tạo database.
5. Deploy Kafka, Kafka Connect, Keycloak và pgAdmin.
6. Deploy Debezium connectors.
7. Tạo configuration/secrets cho `dev` và `staging`.
8. Deploy workloads của cả hai môi trường.
9. Apply Istio routing.
10. Ghi bootstrap report local và trong cluster.

Mặc định mỗi gate có timeout 15 phút. Có thể đổi timeout:

```bash
BOOTSTRAP_TIMEOUT=30m ./scripts/bootstrap.sh
```

Nếu Argo CD và Istio đã được cài sẵn, có thể bỏ qua prerequisite:

```bash
SKIP_PREREQUISITES=true ./scripts/bootstrap.sh
```

Nếu GHCR package đang private, truyền credential để script tạo pull secret trong namespace `dev` và `staging`:

```bash
GHCR_USERNAME='<github-user>' \
GHCR_TOKEN='<token-có-quyền-read-packages>' \
./scripts/bootstrap.sh
```

Nếu cluster đang có legacy Argo CD root Applications cũ, migrate sang phased bootstrap:

```bash
MIGRATE_LEGACY_ROOTS=true ./scripts/bootstrap.sh
```

Lệnh này xóa các Application controller cũ bằng orphan propagation, giữ lại workload Kubernetes hiện có, sau đó phased bootstrap sẽ adopt desired state mới.

## Chế độ best-effort

Mặc định bootstrap chạy `strict`: gặp phase lỗi thì dừng. Khi cần demo hoặc muốn hệ thống lên được một phần, dùng `best-effort`:

```bash
BOOTSTRAP_MODE=best-effort BOOTSTRAP_TIMEOUT=5m ./scripts/bootstrap.sh
```

Trong mode này, phase infrastructure vẫn fail-fast. Riêng workload và routing có thể tiếp tục nếu một vài service chưa Healthy. Argo CD vẫn giữ automated sync và sẽ tiếp tục reconcile.

Chi tiết xem [Bootstrap operations](BOOTSTRAP_OPERATIONS.md).

## Kiểm tra sau bootstrap

Kiểm tra Argo CD Applications:

```bash
kubectl get applications -n argocd
```

Kiểm tra namespace và pod:

```bash
kubectl get ns
kubectl get pods -n infra
kubectl get pods -n dev
kubectl get pods -n staging
```

Kiểm tra routing:

```bash
kubectl get gateway,virtualservice,destinationrule -A
kubectl get service istio-ingressgateway -n istio-system -o wide
```

Kiểm tra bootstrap report:

```bash
bash ./scripts/bootstrap-status.sh
kubectl get configmap yas-bootstrap-last-report -n argocd \
  -o jsonpath='{.data.report}'
```

Kiểm tra một Application cụ thể:

```bash
bash ./scripts/bootstrap-status.sh product-dev
```

Recover một Application sau khi đã fix Git:

```bash
BOOTSTRAP_TIMEOUT=10m bash ./scripts/recover-application.sh product-dev
```

## Kiểm tra networking

Sau khi thêm node, join lại k3s, đổi Tailscale IP, hoặc nghi ngờ lỗi routing, chạy:

```bash
bash ./scripts/check-cluster-networking.sh
```

Script này kiểm tra node readiness, CoreDNS, traffic Pod-to-Service, Pod-to-Pod, egress tùy chọn, IP ingress của Istio và mapping trong `hostnames.txt`.

## Dev và staging

Hai môi trường `dev` và `staging` dùng chung infrastructure trong namespace `infra`, nhưng workload chạy trong namespace riêng:

```text
dev
staging
```

Mỗi service trong Argo CD lấy chart từ `yas-helm`, và lấy values từ repo này bằng multi-source.

Ví dụ service `cart` trong dev:

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

File tag tương ứng:

```yaml
backend:
  image:
    repository: ghcr.io/23120049/yas-cart
    tag: <image-tag>
```

UI services như `storefront` và `backoffice` dùng key `ui.image.tag`; backend services dùng `backend.image.tag`.

## CD image tag flow

CD workflow nằm trong repo `yas`.

Với dev:

```text
push vào yas/main
-> CI build image và push GHCR với tag commit SHA + latest
-> CD cập nhật values/dev/dynamic-tags/<service>.yaml bằng commit SHA
-> push vào yas-gitops
-> Argo CD sync dev
```

Khi root `pom.xml` thay đổi, CD xem tất cả service bị ảnh hưởng và cập nhật tag dev cho tất cả service sau khi image mới đã tồn tại trên GHCR.

Với staging:

```text
publish GitHub Release trong repo yas
-> release tag có dạng <service>-<version>
-> CD xác định service từ release tag
-> tag image latest trên GHCR bằng release tag
-> cập nhật values/staging/dynamic-tags/<service>.yaml bằng release tag
-> push vào yas-gitops
-> Argo CD sync staging
```

Ví dụ release tag:

```text
storefront-0.1.2
payment-paypal-0.1.2
```

Staging không ghi `latest` vào GitOps; GitOps lưu release tag cụ thể.

## Developer test deploy và rollback

Developer test deploy được chạy thủ công trong repo `yas`:

```text
GitHub Actions -> Developer Build & Test Deploy -> Run workflow
```

Input:

- `service`: service cần deploy.
- `image_tag`: image tag hoặc branch name.

Nếu input là branch, workflow resolve thành commit SHA. Trước khi ghi tag mới vào dev values, workflow backup tag hiện tại của service đó vào `rollback_state.yaml`.

Rollback dev:

```text
GitHub Actions -> Rollback Dev Environment -> Run workflow
```

Rollback yêu cầu chọn service từ dropdown. Workflow đọc tag cũ của service đó trong `rollback_state.yaml` và ghi lại vào dev values. Rollback chỉ ảnh hưởng đúng service được chọn.

## Secrets cần cấu hình trong repo yas

Repo `yas` cần các secrets sau để CI/CD hoạt động:

- `GITOPS_TOKEN`: PAT có quyền checkout và push vào `23120049/yas-gitops`.
- `SONAR_TOKEN`: dùng cho SonarCloud nếu bật workflow scan.
- `SNYK_TOKEN`: dùng cho Snyk nếu bật workflow scan.

`GITOPS_TOKEN` thường là PAT tạo từ GitHub account có quyền write vào `yas-gitops`, sau đó lưu trong repo `yas` ở Settings -> Secrets and variables -> Actions.

## Các lệnh vận hành nhanh

Xem tất cả Applications:

```bash
kubectl get applications -n argocd
```

Refresh/sync bằng Argo CD UI nếu cần:

```text
Argo CD UI -> Application -> Refresh / Sync
```

Xem event lỗi theo namespace:

```bash
kubectl get events -n dev --sort-by=.lastTimestamp
kubectl get events -n staging --sort-by=.lastTimestamp
kubectl get events -n infra --sort-by=.lastTimestamp
```

Xem pod lỗi:

```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

Kiểm tra image đang chạy:

```bash
kubectl get pods -n dev -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\n"}{end}'
kubectl get pods -n staging -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\n"}{end}'
```

## Thứ tự nộp/chạy để demo

1. Đảm bảo `yas`, `yas-helm`, `yas-gitops` đã merge và push lên `main`.
2. Kiểm tra secrets trong repo `yas`, đặc biệt `GITOPS_TOKEN`.
3. Kiểm tra cluster bằng `kubectl cluster-info`.
4. Chạy `./scripts/bootstrap.sh` trong repo `yas-gitops`.
5. Kiểm tra `kubectl get applications -n argocd`.
6. Cập nhật hosts file theo `hostnames.txt`.
7. Mở các URL dev/staging để test UI và API.
8. Push thay đổi nhỏ vào `yas/main` để test dev CD.
9. Tạo GitHub Release dạng `<service>-<version>` để test staging CD.
