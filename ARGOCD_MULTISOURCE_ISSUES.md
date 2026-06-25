# Phân Tích Chi Tiết: Vấn Đề Cấu Hình ArgoCD MultiSource

**Repository**: `yas-gitops`  
**Ngày**: 2026-06-25  
**Trạng thái**: ⚠️ Cấu hình không hoàn chỉnh để chạy MultiSource

---

## Tóm Tắt Tổng Quan

Repo `yas-gitops` được thiết kế để tương tác với repo `yas-helm` (chứa Helm charts) thông qua **pattern ArgoCD MultiSource**. Tuy nhiên, hiện tại còn **3 vấn đề chính** ngăn ArgoCD hoạt động đúng cách:

1. **Values cơ sở hạ tầng (Infrastructure) không được áp dụng** → Applications sử dụng chart mặc định
2. **Dynamic image tags không được sử dụng** → CI/CD không thể cập nhật phiên bản
3. **MultiSource chưa được kích hoạt** → Không thể lấy values từ 2 repository khác nhau

---

## 🔴 Vấn Đề #1: Infrastructure Values Không Được Áp Dụng

### Mô Tả Vấn Đề

**Hiện tại** trong `infra/postgresql.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: postgresql
  namespace: argocd
spec:
  project: default
  source:                              # ← Single source (nguồn duy nhất)
    repoURL: 'https://github.com/23120049/yas-helm.git'
    targetRevision: HEAD
    path: charts/postgresql
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: postgres
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    createNamespace: true
```

**Nhận diện vấn đề:**

- File `values/infra/postgres.yaml` chứa các values tuỳ chỉnh cho môi trường:
  ```yaml
  username: yasadminuser
  password: admin
  replicas: 1
  postgresqlVersion: "15"
  volumeSize: "10Gi"
  maxConnections: "500"
  resources:
    requests:
      cpu: 100m
      memory: 100Mi
    limits:
      cpu: 500m
      memory: 500Mi
  nodeSelector:
    kubernetes.io/hostname: "laptop-hh13kan9"
  ```

- Nhưng những values này **KHÔNG được tham chiếu** trong `infra/postgresql.yaml`
- **Kết quả**: PostgreSQL được deploy với giá trị mặc định của chart, không phải custom values của bạn

**Những services bị ảnh hưởng:**
- `infra/postgresql.yaml` - Database PostgreSQL
- `infra/elasticsearch.yaml` - Elasticsearch cluster
- `infra/kafka.yaml` - Kafka cluster
- `infra/keycloak.yaml` - Keycloak IAM
- `infra/observability.yaml` - OpenTelemetry & Grafana
- `infra/zookeeper.yaml` - Zookeeper
- `infra/pgadmin.yaml` - PgAdmin
- `infra/elastic.yaml` - Elastic configuration

**Tác động:**
- Thông tin xác thực database (username, password) bị bỏ qua
- Cấu hình replicas, resource limits, node selectors không được áp dụng
- Cấu hình Elasticsearch/Kibana tuỳ chỉnh không được load
- Pod có thể được schedule lên sai node hoặc không có đủ tài nguyên

### Giải Pháp

Chuyển đổi từ `source` (đơn lẻ) sang `sources` (đa số) để bật MultiSource:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: postgresql
  namespace: argocd
spec:
  project: default
  sources:                             # ← Multiple sources (nhiều nguồn)
    # Nguồn 1: Helm chart từ yas-helm
    - repoURL: 'https://github.com/23120049/yas-helm.git'
      targetRevision: HEAD
      path: charts/postgresql
      helm:
        releaseName: postgresql
    
    # Nguồn 2: Values tuỳ chỉnh từ yas-gitops
    - repoURL: 'https://github.com/23120049/yas-gitops.git'
      targetRevision: HEAD
      path: values/infra
      helm:
        valueFiles:
          - 'postgres.yaml'
  
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: postgres
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    createNamespace: true
```

**Cách ArgoCD xử lý MultiSource:**
1. Lấy Helm chart từ `yas-helm/charts/postgresql`
2. Merge values từ `yas-gitops/values/infra/postgres.yaml` vào chart
3. Apply kết quả đã merge lên cluster
4. Kết quả: Database được deploy với username, password, resource limits tuỳ chỉnh ✅

**Danh sách files cần sửa:**
```
infra/
├── postgresql.yaml    ← Sửa (thêm values/infra/postgres.yaml)
├── elasticsearch.yaml ← Sửa (thêm values/infra/elastic.yaml)
├── kafka.yaml         ← Sửa (có thể thêm values/infra/kafka.yaml)
├── keycloak.yaml      ← Sửa (có thể thêm values/infra/keycloak.yaml)
├── observability.yaml ← Sửa
├── zookeeper.yaml     ← Sửa
└── pgadmin.yaml       ← Sửa
```

---

## 🔴 Vấn Đề #2: Dynamic Image Tags Không Được Sử Dụng

### Mô Tả Vấn Đề

**Hiện tại** trong `applications/dev/services.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: product-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'https://github.com/23120049/yas-helm.git'
    targetRevision: HEAD
    path: charts/product
    # ← KHÔNG có tham chiếu đến values/dev/dynamic-tags/image-tags.yaml
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: yas-dev
```

**Nhận diện vấn đề:**

1. Thư mục `values/dev/dynamic-tags/` tồn tại nhưng **RỖNG** (không có file)
2. Không có file `image-tags.yaml` để CI/CD cập nhật
3. ArgoCD không kéo values từ folder này

**Quy trình CI/CD bị đứt:**
```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Developer push code lên yas repo                              │
│    → Feature: Update product service v1.2.3                      │
│    ↓                                                              │
│ 2. GitHub Actions CI workflow chạy                               │
│    → Build Docker image: ghcr.io/23120049/product:main-abc1234   │
│    → Push to GHCR                                                 │
│    ↓                                                              │
│ 3. ❌ BỊ ĐỨT TẠI ĐÂY                                             │
│    → Không biết cần cập nhật image tag ở đâu?                    │
│    → values/dev/dynamic-tags/image-tags.yaml không tồn tại      │
│    → Kubernetes vẫn chạy image cũ: v1.2.2                        │
│    ↓ (bổ sung: nên)                                              │
│ 4. Cập nhật values/dev/dynamic-tags/image-tags.yaml             │
│    → Thay đổi: tag: "main-abc1234"                               │
│    ↓                                                              │
│ 5. ArgoCD auto-sync phát hiện thay đổi                          │
│    → Pull Helm chart và values mới                               │
│    → Update Pod với image mới                                    │
│    ↓                                                              │
│ 6. Kubernetes redeploy service với image mới ✅                  │
└─────────────────────────────────────────────────────────────────┘
```

**Tác động:**
- CI/CD pipeline không hoàn chỉnh → Phải deploy thủ công
- Không thể tự động cập nhật phiên bản service
- Quá trình release trở nên chậm và dễ lỗi

### Giải Pháp

#### Bước 1: Tạo file `values/dev/dynamic-tags/image-tags.yaml`

```yaml
# values/dev/dynamic-tags/image-tags.yaml
# File này sẽ được CI/CD tự động cập nhật
# DO NOT EDIT MANUALLY - được cập nhật bởi GitHub Actions

image:
  tag: "main-latest"  # Format: main-<commit-sha> hoặc branch-latest

# Tuỳ chỉnh theo từng service (tuỳ chọn)
services:
  product:
    image:
      tag: "main-latest"
  cart:
    image:
      tag: "main-latest"
  customer:
    image:
      tag: "main-latest"
  inventory:
    image:
      tag: "main-latest"
  order:
    image:
      tag: "main-latest"
  payment:
    image:
      tag: "main-latest"
  # ... etc cho tất cả services
```

#### Bước 2: Tạo file `values/staging/dynamic-tags/image-tags.yaml`

```yaml
# values/staging/dynamic-tags/image-tags.yaml
# Cho môi trường staging - được cập nhật khi merge vào branch staging

image:
  tag: "staging-latest"

services:
  product:
    image:
      tag: "staging-latest"
  cart:
    image:
      tag: "staging-latest"
  # ... etc
```

#### Bước 3: Cập nhật `applications/dev/services.yaml` để sử dụng MultiSource

**Trước:**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: product-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'https://github.com/23120049/yas-helm.git'
    targetRevision: HEAD
    path: charts/product
```

**Sau:**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: product-dev
  namespace: argocd
spec:
  project: default
  sources:
    # Nguồn 1: Helm chart từ yas-helm
    - repoURL: 'https://github.com/23120049/yas-helm.git'
      targetRevision: HEAD
      path: charts/product
      helm:
        releaseName: product-dev
    
    # Nguồn 2: Dynamic image tags từ yas-gitops
    - repoURL: 'https://github.com/23120049/yas-gitops.git'
      targetRevision: HEAD
      path: values/dev/dynamic-tags
      helm:
        valueFiles:
          - 'image-tags.yaml'  # ← ArgoCD sẽ merge file này vào chart values
  
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: yas-dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    createNamespace: true
```

**Áp dụng cho tất cả services trong:**
- `applications/dev/services.yaml` (tất cả ~20 applications)
- `applications/staging/services.yaml` (tất cả ~20 applications)

#### Bước 4: Cấu hình GitHub Actions để cập nhật image tags

**Tạo workflow file `.github/workflows/deploy-dev.yml` trong repo `yas` (không phải yas-gitops):**

```yaml
name: Deploy to Dev Environment

on:
  push:
    branches:
      - main
    paths:
      - 'src/**'
      - 'pom.xml'

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    
    steps:
      - name: Checkout yas repo
        uses: actions/checkout@v3
      
      - name: Set up JDK
        uses: actions/setup-java@v3
        with:
          java-version: '17'
          distribution: 'temurin'
      
      - name: Build and test
        run: mvn clean package
      
      - name: Build Docker image
        env:
          REGISTRY: ghcr.io
          IMAGE_NAME: ${{ github.repository }}
        run: |
          IMAGE_TAG="${{ github.ref_name }}-${{ github.sha }}"
          docker build -t $REGISTRY/$IMAGE_NAME:$IMAGE_TAG .
          docker push $REGISTRY/$IMAGE_NAME:$IMAGE_TAG
          echo "IMAGE_TAG=$IMAGE_TAG" >> $GITHUB_ENV
      
      - name: Checkout yas-gitops repo
        uses: actions/checkout@v3
        with:
          repository: 23120049/yas-gitops
          token: ${{ secrets.GIT_TOKEN }}  # ← Cần tạo Personal Access Token
          path: gitops
      
      - name: Update image tags in yas-gitops
        run: |
          cd gitops
          
          # Lấy service name từ repository
          SERVICE_NAME=$(basename ${{ github.repository }})
          
          # Cập nhật image tag cho dev environment
          # Giả sử Helm chart có cấu trúc: services.<service>.image.tag
          cat > values/dev/dynamic-tags/image-tags.yaml <<EOF
          image:
            tag: "${{ env.IMAGE_TAG }}"
          
          services:
            $SERVICE_NAME:
              image:
                tag: "${{ env.IMAGE_TAG }}"
          EOF
          
          # Git commit và push
          git config user.name "GitHub Actions"
          git config user.email "actions@github.com"
          git add values/dev/dynamic-tags/image-tags.yaml
          git commit -m "chore: update $SERVICE_NAME image tag to ${{ env.IMAGE_TAG }} [skip ci]" || true
          git push
```

**Hoặc nếu muốn update từng service cụ thể:**

```yaml
- name: Update specific service image tag
  run: |
    cd gitops
    
    # Sử dụng sed hoặc yq để cập nhật
    # Ví dụ với yq:
    yq eval '.services.product.image.tag = "${{ env.IMAGE_TAG }}"' \
      -i values/dev/dynamic-tags/image-tags.yaml
    
    git add values/dev/dynamic-tags/image-tags.yaml
    git commit -m "chore: update product image to ${{ env.IMAGE_TAG }} [skip ci]"
    git push
```

---

## 🔴 Vấn Đề #3: MultiSource Pattern Chưa Được Kích Hoạt Hoàn Toàn

### Mô Tả Vấn Đề

**Hiện tại:**
- `applications/dev/services.yaml` và `applications/staging/services.yaml` sử dụng **single `source`**
- Không kéo values từ folder `values/dev/` và `values/staging/`
- Không thể tuỳ chỉnh từng environment

**Ý tưởng MultiSource của ArgoCD:**

```
┌─────────────────────────────────────────────────────────────┐
│                    ArgoCD Application                        │
│                                                              │
│  sources:                                                    │
│    ├─ Source 1: https://github.com/23120049/yas-helm       │
│    │  └─ path: charts/product                              │
│    │  └─ Cung cấp: Helm template, default values          │
│    │                                                         │
│    ├─ Source 2: https://github.com/23120049/yas-gitops    │
│    │  └─ path: values/dev/dynamic-tags                    │
│    │  └─ Cung cấp: Environment-specific overrides         │
│    │                                                         │
│    └─ Source 3 (tuỳ chọn):                                 │
│       └─ Thêm values từ ConfigMap, Secret, etc.           │
│                                                              │
│  ▼▼▼ ArgoCD Merge ▼▼▼                                       │
│                                                              │
│  Result: Template + Dev Values + Overrides                 │
│  ↓                                                           │
│  Applied to Kubernetes Cluster                             │
└─────────────────────────────────────────────────────────────┘
```

### Giải Pháp

**Cách 1: Enable MultiSource cho từng Application (Khuyến nghị)**

Thay đổi mỗi Application trong `applications/dev/services.yaml`:

```yaml
# TRƯỚC (single source)
spec:
  source:
    repoURL: 'https://github.com/23120049/yas-helm.git'
    path: charts/product

# SAU (multiple sources)
spec:
  sources:
    - repoURL: 'https://github.com/23120049/yas-helm.git'
      path: charts/product
      helm:
        releaseName: product-dev
    
    - repoURL: 'https://github.com/23120049/yas-gitops.git'
      path: values/dev/dynamic-tags
      helm:
        valueFiles:
          - 'image-tags.yaml'
```

**Cách 2: Sử dụng Kustomize hoặc Helm overlay (Nâng cao)**

Tạo thêm layer tuỳ chỉnh mà không cần sửa từng Application:

```yaml
# applications/dev/kustomization.yaml (Nếu dùng Kustomize)
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - services.yaml

patchesStrategicMerge:
  - patch.yaml

# patch.yaml sẽ thêm values từ dev environment
```

---

## 🟡 Vấn đề #4: Cấu Trúc Thư Mục Values Không Hoàn Chỉnh

### Mô Tả Vấn Đề

**Hiện tại:**
```
values/
├── dev/
│   └── dynamic-tags/
│       └── (RỖNG - không có file)              ← ❌ Cần tạo
├── infra/
│   ├── elastic.yaml                            ← ✓ Tồn tại
│   └── postgres.yaml                           ← ✓ Tồn tại
└── staging/
    └── dynamic-tags/
        └── (RỖNG - không có file)              ← ❌ Cần tạo
```

**Các file bị thiếu:**

1. `values/dev/dynamic-tags/image-tags.yaml` - Cho dev environment
2. `values/staging/dynamic-tags/image-tags.yaml` - Cho staging environment
3. Các file values cho infrastructure services (tùy chọn)

### Giải Pháp

**Tạo cấu trúc folder hoàn chỉnh:**

```
values/
├── dev/
│   ├── dynamic-tags/
│   │   └── image-tags.yaml           ← Tạo mới: Image tags cho dev
│   └── overrides.yaml                ← Tuỳ chọn: Dev-specific overrides
├── infra/
│   ├── postgres.yaml                 ← Hiện có: PostgreSQL config
│   ├── elastic.yaml                  ← Hiện có: Elasticsearch config
│   ├── kafka.yaml                    ← Tuỳ chọn: Kafka config
│   ├── keycloak.yaml                 ← Tuỳ chọn: Keycloak config
│   ├── elasticsearch.yaml            ← Tuỳ chọn: ES-specific config
│   └── observability.yaml            ← Tuỳ chọn: Observability config
└── staging/
    ├── dynamic-tags/
    │   └── image-tags.yaml           ← Tạo mới: Image tags cho staging
    └── overrides.yaml                ← Tuỳ chọn: Staging-specific overrides
```

---

## 📋 Lộ Trình Thực Hiện

### Phase 1: Bật MultiSource cho Infrastructure (Ưu tiên: CAO)

**Các file cần sửa:**
- [ ] `infra/postgresql.yaml` → MultiSource + tham chiếu `values/infra/postgres.yaml`
- [ ] `infra/elasticsearch.yaml` → MultiSource + tham chiếu `values/infra/elastic.yaml`
- [ ] `infra/kafka.yaml` → MultiSource + tham chiếu `values/infra/kafka.yaml`
- [ ] `infra/keycloak.yaml` → MultiSource + tham chiếu `values/infra/keycloak.yaml`
- [ ] `infra/observability.yaml` → MultiSource
- [ ] `infra/zookeeper.yaml` → MultiSource
- [ ] `infra/pgadmin.yaml` → MultiSource

**Xác minh:**
```bash
# Kiểm tra PostgreSQL có sử dụng custom values không
kubectl describe pod -n postgres -l app=postgresql | grep -i "replicas\|cpu\|memory"

# Kiểm tra ArgoCD Application đã dùng MultiSource
kubectl get application -n argocd postgresql -o yaml | grep "sources:"
```

**Dự kiến thời gian**: 1-2 giờ

---

### Phase 2: Bật Dynamic Image Tags (Ưu tiên: CAO)

**Các file cần tạo:**
- [ ] `values/dev/dynamic-tags/image-tags.yaml` 
- [ ] `values/staging/dynamic-tags/image-tags.yaml`

**Các file cần sửa:**
- [ ] `applications/dev/services.yaml` → MultiSource (tất cả ~20 Applications)
- [ ] `applications/staging/services.yaml` → MultiSource (tất cả ~20 Applications)

**Xác minh:**
```bash
# Kiểm tra Application có 2 sources
kubectl get application -n argocd product-dev -o jsonpath='{.spec.sources}' | jq

# Kiểm tra values được merge
kubectl get application -n argocd product-dev -o yaml | grep -A5 "valueFiles"
```

**Dự kiến thời gian**: 2-3 giờ

---

### Phase 3: Tích Hợp GitHub Actions (Ưu tiên: TRUNG)

**Công việc:**
- [ ] Tạo Personal Access Token cho GitHub Actions
- [ ] Tạo workflow file `.github/workflows/deploy-dev.yml` trong repo `yas`
- [ ] Test pipeline với một commit thử nghiệm
- [ ] Xác minh image tag được cập nhật tự động

**Dự kiến thời gian**: 1-2 giờ

---

### Phase 4: Hoàn Thiện Staging Environment (Ưu tiên: TRUNG)

- [ ] Cấu hình values cho staging
- [ ] Tạo workflow cho staging environment
- [ ] Test end-to-end deployment

**Dự kiến thời gian**: 1 giờ

---

## ✅ Checklist Kiểm Chứng

### Trước khi sửa
```
❌ kubectl logs -n postgres -l app=postgresql | grep "password"
   → Không thấy "password: yasadminuser" (mặc định được dùng)

❌ kubectl get pod -n elasticsearch -o yaml | grep nodeSelector
   → Không thấy tuỳ chỉnh node selector

❌ kubectl get application -n argocd postgresql -o yaml | grep sources
   → Không tìm thấy (chỉ có "source" duy nhất)

❌ Container image tag không tự động cập nhật
   → Phải deploy thủ công khi có version mới
```

### Sau khi sửa
```
✅ kubectl logs -n postgres -l app=postgresql | grep "password"
   → Hiển thị: "password: yasadminuser"

✅ kubectl get pod -n elasticsearch -o yaml | grep nodeSelector
   → Hiển thị: kubernetes.io/hostname: "laptop-hh13kan9"

✅ kubectl get application -n argocd postgresql -o yaml | grep sources
   → Hiển thị 2 sources (yas-helm + yas-gitops)

✅ Sau push code → GitHub Actions build → image tag tự động cập nhật → Pod redeploy
   → Quá trình CI/CD hoàn chỉnh
```

---

## 📊 Bảng So Sánh Tác Động

| Vấn Đề | Trạng Thái Hiện Tại | Hành Động Cần Làm | Tác Động |
|--------|-----------------|-------------------|---------|
| **Infrastructure Values** | Single source (values bị bỏ) | Bật MultiSource + tham chiếu values/infra/ | Database credentials, resource limits được áp dụng |
| **Dynamic Image Tags** | File không tồn tại, không được tham chiếu | Tạo file + update Applications + CI/CD | CI/CD tự động deploy phiên bản mới |
| **Applications Config** | Single source | Bật MultiSource + valueFiles | Có thể tuỳ chỉnh per-environment |
| **Folder Structure** | Rỗng/không hoàn chỉnh | Tạo file còn thiếu | CI/CD có chỗ để cập nhật tags |
| **GitHub Actions** | Không có workflow | Tạo deploy workflow | Tự động build → push → update gitops repo |

---

## 🔗 Tài Liệu Tham Khảo

- [ArgoCD MultiSource Documentation](https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/)
- [Helm values merging trong ArgoCD](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/#multiple-helm-value-files)
- [App-of-Apps Pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/app-of-apps/)
- [GitHub Actions with ArgoCD](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Git/)

---

## 📞 Ghi Chú

- **GIT_TOKEN**: Để GitHub Actions có thể push vào `yas-gitops`, cần tạo Personal Access Token với quyền `repo` trong GitHub Settings → Developer settings → Personal access tokens
- **Merge Strategy**: ArgoCD merge values từ các sources theo thứ tự - source sau ghi đè source trước
- **Auto-sync**: Bật `automated: true` để ArgoCD tự động deploy khi phát hiện thay đổi trong repo

---

**Cập nhật cuối**: 2026-06-25  
**Trạng thái**: Cần thực hiện ngay
