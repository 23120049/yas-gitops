# Phân Tích Chi Tiết: Vấn Đề Cấu Hình ArgoCD MultiSource

**Repository**: `yas-gitops`  
**Ngày**: 2026-06-25  
**Trạng thái**: ⚠️ Cấu hình MultiSource chưa hoàn toàn kích hoạt

---

## Tóm Tắt Tổng Quan

Repo `yas-gitops` được thiết kế để tương tác với:
- **`yas-helm`**: Chứa Helm charts (Kho tài nguyên tài chính cấu hình)
- **`yas`**: Chứa source code, CI/CD build images và push vào GHCR
- **ArgoCD**: Quan sát `yas-gitops` để deploy ứng dụng

Hiện tại, **cấu hình gần như hoàn chỉnh** nhưng vẫn còn **2 vấn đề chính** cần sửa:

1. **Infrastructure Services không sử dụng MultiSource** → Custom values không được áp dụng
2. **Application Services không sử dụng MultiSource** → Dynamic image tags từ `values/dev/dynamic-tags/` không được merge vào Helm charts

---

## 🔴 Vấn Đề #1: Infrastructure Services Không Sử Dụng MultiSource

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

File `values/infra/postgres.yaml` chứa custom values cho PostgreSQL:
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

Tuy nhiên, **những values này KHÔNG được tham chiếu** trong `infra/postgresql.yaml` vì:
- ArgoCD chỉ fetch từ **1 source duy nhất** (yas-helm repo)
- Không cách nào để kéo values từ yas-gitops repo cùng lúc
- **Kết quả**: PostgreSQL được deploy với **giá trị mặc định của chart**, không phải custom values

**Các infrastructure services bị ảnh hưởng:**
```
✗ infra/postgresql.yaml     → values/infra/postgres.yaml (không được dùng)
✗ infra/elasticsearch.yaml  → values/infra/elastic.yaml (không được dùng)
✗ infra/kafka.yaml          → Không có values file (default chart)
✗ infra/keycloak.yaml       → Không có values file (default chart)
✗ infra/observability.yaml  → Không có values file (default chart)
✗ infra/zookeeper.yaml      → Không có values file (default chart)
✗ infra/pgadmin.yaml        → Không có values file (default chart)
```

**Tác động cụ thể:**
- Database credentials (username/password) bị bỏ qua → sử dụng default (không an toàn)
- Resource limits không được áp dụng → Pods có thể bị OOM hoặc cạnh tranh resources
- Pod scheduling: `nodeSelector` không được áp dụng → Pods có thể schedule lên sai node
- Cấu hình database tuỳ chỉnh (replicas, max connections, volume size) không có hiệu lực

### Giải Pháp

**Chuyển đổi từ `source` (đơn) sang `sources` (đa) để bật MultiSource:**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: postgresql
  namespace: argocd
spec:
  project: default
  sources:                             # ← Chuyển từ source → sources
    # Source 1: Helm chart từ yas-helm
    - repoURL: 'https://github.com/23120049/yas-helm.git'
      targetRevision: HEAD
      path: charts/postgresql
      helm:
        releaseName: postgresql
    
    # Source 2: Custom values từ yas-gitops
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
```
1. Lấy Helm chart từ yas-helm/charts/postgresql
2. Lấy values từ yas-gitops/values/infra/postgres.yaml
3. Merge: Chart Template + Custom Values
4. Deploy lên cluster với thông tin tuỳ chỉnh
✓ Kết quả: PostgreSQL chạy với credentials, resource limits, node selector tuỳ chỉnh
```

**Danh sách files infrastructure cần sửa:**
```
infra/
├── postgresql.yaml      ← Thêm source 2: values/infra/postgres.yaml
├── elasticsearch.yaml   ← Thêm source 2: values/infra/elastic.yaml
├── kafka.yaml           ← Tạo values/infra/kafka.yaml + thêm MultiSource
├── keycloak.yaml        ← Tạo values/infra/keycloak.yaml + thêm MultiSource
├── observability.yaml   ← Tạo values/infra/observability.yaml + thêm MultiSource
├── zookeeper.yaml       ← Tạo values/infra/zookeeper.yaml + thêm MultiSource
└── pgadmin.yaml         ← Tạo values/infra/pgadmin.yaml + thêm MultiSource
```

---

## 🔴 Vấn Đề #2: Application Services Không Sử Dụng MultiSource Cho Dynamic Tags

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
  source:                                    # ← Single source
    repoURL: 'https://github.com/23120049/yas-helm.git'
    targetRevision: HEAD
    path: charts/product
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: yas-dev
```

**Nhận diện vấn đề:**

File `values/dev/dynamic-tags/image-tags.yaml` **đã tồn tại** với đầy đủ cấu trúc:
```yaml
product:
  image:
    tag: initial
cart:
  image:
    tag: initial
# ... 18 services khác
```

Tuy nhiên, **Application `product-dev` không tham chiếu** file này, do đó:
- ArgoCD chỉ fetch từ **yas-helm repo** (Helm chart default)
- **Không có cách nào** để merge image tags từ `values/dev/dynamic-tags/image-tags.yaml`
- **Kết quả**: Pods chạy với image tag mặc định của chart (không phải từ CI/CD)

**Quy trình CI/CD bị đứt:**

```
1. Developer push code vào yas repo
   → Build microservice (VD: product service v1.2.3)
   
2. GitHub Actions CI workflow chạy
   → Build Docker image: ghcr.io/23120049/product:main-abc1234
   → Push image vào GHCR
   
3. ✗ CI/CD BỊ ĐỨTẠI ĐÂY ✗
   → GitHub Actions cập nhật values/dev/dynamic-tags/image-tags.yaml
   → Thay đổi: tag: "main-abc1234"
   → Push vào yas-gitops
   
4. ArgoCD phát hiện thay đổi trong yas-gitops
   ✗ NHƯNG: Không tham chiếu tới image-tags.yaml
   ✗ Image tag mới KHÔNG được áp dụng
   ✗ Kubernetes vẫn chạy image cũ
   
5. ✓ NÊU ĐƯỢC FIX: ArgoCD merge values + deploy pod mới
   → Kubernetes redeploy service với image mới
   ✓ CI/CD hoàn chỉnh!
```

**Tác động:**
- CI/CD pipeline **không hoàn chỉnh** → Phải deploy thủ công
- Không thể tự động cập nhật phiên bản service từ GHCR
- Quá trình release trở nên chậm và dễ lỗi
- ~20 applications trong `applications/dev/services.yaml` bị ảnh hưởng

### Giải Pháp

**Bước 1: Cập nhật tất cả Applications trong `applications/dev/services.yaml`**

Chuyển từ `source` (đơn) sang `sources` (đa) để kéo dynamic tags:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: product-dev
  namespace: argocd
spec:
  project: default
  sources:                             # ← Chuyển từ source → sources
    # Source 1: Helm chart từ yas-helm
    - repoURL: 'https://github.com/23120049/yas-helm.git'
      targetRevision: HEAD
      path: charts/product
      helm:
        releaseName: product-dev
    
    # Source 2: Dynamic image tags từ yas-gitops
    - repoURL: 'https://github.com/23120049/yas-gitops.git'
      targetRevision: HEAD
      path: values/dev/dynamic-tags
      helm:
        valueFiles:
          - 'image-tags.yaml'
  
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: yas-dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    createNamespace: true
```

**Bước 2: Tương tự với `applications/staging/services.yaml`**

Sử dụng path `values/staging/dynamic-tags` thay vì `values/dev/dynamic-tags`:

```yaml
sources:
  - repoURL: 'https://github.com/23120049/yas-helm.git'
    path: charts/product
    helm:
      releaseName: product-staging
  
  - repoURL: 'https://github.com/23120049/yas-gitops.git'
    path: values/staging/dynamic-tags
    helm:
      valueFiles:
        - 'image-tags.yaml'
```

**Bước 3: Cấu hình GitHub Actions để tự động cập nhật image tags**

Tạo workflow file `.github/workflows/deploy.yml` **trong repo `yas`** (không phải yas-gitops):

```yaml
name: Build & Deploy to Dev

on:
  push:
    branches:
      - main
    paths:
      - 'src/**'
      - 'pom.xml'

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    
    outputs:
      image-tag: ${{ steps.meta.outputs.tags }}
    
    steps:
      - name: Checkout code
        uses: actions/checkout@v3
      
      - name: Set up JDK
        uses: actions/setup-java@v3
        with:
          java-version: '17'
          distribution: 'temurin'
      
      - name: Build and test with Maven
        run: mvn clean package -DskipTests
      
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v2
      
      - name: Build and push Docker image
        id: meta
        uses: docker/build-push-action@v4
        with:
          context: .
          push: true
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
          tags: |
            ghcr.io/${{ github.repository }}:${{ github.ref_name }}-${{ github.sha }}
            ghcr.io/${{ github.repository }}:latest

  update-gitops:
    needs: build-and-push
    runs-on: ubuntu-latest
    
    steps:
      - name: Checkout yas-gitops
        uses: actions/checkout@v3
        with:
          repository: 23120049/yas-gitops
          token: ${{ secrets.GIT_TOKEN }}
          path: gitops
      
      - name: Update image tag
        working-directory: gitops
        env:
          IMAGE_TAG: ${{ github.ref_name }}-${{ github.sha }}
          SERVICE_NAME: product  # ← Thay đổi theo service
        run: |
          # Sử dụng yq để cập nhật YAML
          yq eval \
            ".[${{ env.SERVICE_NAME }}].image.tag = \"${{ env.IMAGE_TAG }}\"" \
            -i values/dev/dynamic-tags/image-tags.yaml
      
      - name: Commit and push
        working-directory: gitops
        run: |
          git config user.name "GitHub Actions"
          git config user.email "actions@github.com"
          git add values/dev/dynamic-tags/image-tags.yaml
          git commit -m "chore: update product image tag to ${{ github.ref_name }}-${{ github.sha }} [skip ci]" || true
          git push
```

**Lưu ý quan trọng:**
- Cần tạo **Personal Access Token** (GIT_TOKEN) với quyền `repo` trong GitHub Settings
- Hoặc sử dụng `${{ secrets.GITHUB_TOKEN }}` nếu repo owner cho phép cross-repo push
- Cần cài `yq` hoặc sử dụng `sed` để cập nhật YAML

**Bước 4: ArgoCD sẽ tự động sync khi phát hiện thay đổi**

```
GitHub Actions cập nhật image-tags.yaml
    ↓
ArgoCD detect change (auto-sync enabled)
    ↓
Merge: Helm chart + image-tags.yaml
    ↓
Render final manifests
    ↓
Update Kubernetes deployment
    ↓
Pod redeploy với image mới ✓
```

---

## 📊 Tóm Tắt Hai Vấn Đề

| Vấn Đề | Hiện Tại | Cần Làm | Tác Động |
|--------|----------|---------|---------|
| **#1: Infra Services** | `source` (đơn) | Thêm `sources` + values/infra/ | Credentials, resources, scheduling được áp dụng ✓ |
| **#2: App Services** | `source` (đơn) | Thêm `sources` + values/dev-or-staging/dynamic-tags/ | CI/CD tự động deploy phiên bản mới ✓ |

---

## 📋 Lộ Trình Thực Hiện

### Phase 1: Bật MultiSource cho Infrastructure (Ưu tiên: CAO)

**Các files cần sửa (7 files):**

1. [ ] `infra/postgresql.yaml` → Thêm source 2 từ `values/infra/postgres.yaml`
2. [ ] `infra/elasticsearch.yaml` → Thêm source 2 từ `values/infra/elastic.yaml`
3. [ ] `infra/kafka.yaml` → Thêm source 2 từ `values/infra/kafka.yaml` (tạo mới nếu cần)
4. [ ] `infra/keycloak.yaml` → Thêm source 2 từ `values/infra/keycloak.yaml` (tạo mới nếu cần)
5. [ ] `infra/observability.yaml` → Thêm source 2 từ `values/infra/observability.yaml` (tạo mới nếu cần)
6. [ ] `infra/zookeeper.yaml` → Thêm source 2 từ `values/infra/zookeeper.yaml` (tạo mới nếu cần)
7. [ ] `infra/pgadmin.yaml` → Thêm source 2 từ `values/infra/pgadmin.yaml` (tạo mới nếu cần)

**Xác minh:**
```bash
# Kiểm tra PostgreSQL có sử dụng custom values không
kubectl logs -n postgres -l app=postgresql | grep -i "password"

# Kiểm tra ArgoCD Application đã dùng MultiSource
kubectl get application -n argocd postgresql -o yaml | grep -A2 "sources:"
```

**Dự kiến thời gian**: 1-2 giờ

---

### Phase 2: Bật MultiSource cho Application Services (Ưu tiên: CAO)

**Các files cần sửa (2 files):**

1. [ ] `applications/dev/services.yaml` → Chuyển tất cả 20+ applications từ `source` → `sources`
2. [ ] `applications/staging/services.yaml` → Chuyển tất cả 20+ applications từ `source` → `sources`

**Xác minh:**
```bash
# Kiểm tra Application có 2 sources
kubectl get application -n argocd product-dev -o jsonpath='{.spec.sources}' | jq 'length'
# Kết quả: 2

# Kiểm tra image tag được áp dụng từ values
kubectl get pod -n yas-dev -l app=product | grep -i image
```

**Dự kiến thời gian**: 1-2 giờ (có thể tự động hoá)

---

### Phase 3: Tích Hợp GitHub Actions (Ưu tiên: TRUNG)

**Công việc:**

1. [ ] Tạo Personal Access Token trong GitHub Account
2. [ ] Tạo workflow file `.github/workflows/deploy.yml` trong repo `yas`
3. [ ] Test pipeline với một commit thử nghiệm
4. [ ] Xác minh image tag được cập nhật tự động trong `values/dev/dynamic-tags/image-tags.yaml`

**Dự kiến thời gian**: 1-2 giờ

---

### Phase 4: Tích Hợp Staging Environment (Ưu tiên: TRUNG)

- [ ] Tạo workflow cho staging environment
- [ ] Test end-to-end deployment
- [ ] Verify tags được cập nhật trong `values/staging/dynamic-tags/image-tags.yaml`

**Dự kiến thời gian**: 1 giờ

---

## ✅ Checklist Kiểm Chứng

### Trước khi sửa (Current State - ❌)

```
❌ infra/postgresql.yaml sử dụng single source
   → Custom values từ values/infra/postgres.yaml không được áp dụng

❌ applications/dev/services.yaml ~20 applications dùng single source
   → Image tags từ values/dev/dynamic-tags/image-tags.yaml không được merge

❌ CI/CD workflow không tồn tại
   → Phải cập nhật tags thủ công

❌ GitHub Actions không tự động push vào yas-gitops
   → Pipeline không hoàn chỉnh
```

### Sau khi sửa (Target State - ✅)

```
✅ infra/postgresql.yaml sử dụng MultiSource
   → Custom values được merge → Database chạy với credentials tuỳ chỉnh

✅ applications/dev/services.yaml ~20 applications dùng MultiSource
   → Image tags được merge từ image-tags.yaml → Pods chạy đúng phiên bản

✅ CI/CD workflow tồn tại và chạy tự động
   → Sau push code → build image → update tags → ArgoCD sync → Pod redeploy ✓

✅ Pipeline CI/CD hoàn chỉnh
   → End-to-end: code change → image build → automatic deployment
```

---

## 🔗 Tài Liệu Tham Khảo

- [ArgoCD MultiSource Documentation](https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/)
- [Helm values merging trong ArgoCD](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/#multiple-helm-value-files)
- [GitHub Actions - docker/build-push-action](https://github.com/docker/build-push-action)
- [yq - YAML processor](https://github.com/mikefarah/yq)

---

## 📝 Ghi Chú Kỹ Thuật

### MultiSource Merge Order
ArgoCD merge values theo **thứ tự các sources** - source sau ghi đè source trước:
```yaml
sources:
  - repoURL: yas-helm.git        # Source 1: Default values
    helm:
      values: ...
  
  - repoURL: yas-gitops.git      # Source 2: Overrides (ghi đè source 1)
    helm:
      valueFiles:
        - 'postgres.yaml'
```

### Auto-Sync
Khi `syncPolicy.automated: true`, ArgoCD sẽ:
1. Poll yas-helm repo mỗi 3 phút
2. Poll yas-gitops repo mỗi 3 phút
3. Detect changes → tự động apply

### GIT_TOKEN
GitHub Actions cần token để push vào yas-gitops:
```
Settings → Developer settings → Personal access tokens → Tokens (classic)
→ Create new → Chọn "repo" scope → Copy token
→ yas repo Settings → Secrets → GIT_TOKEN
```

---

**Cập nhật cuối**: 2026-06-25  
**Trạng thái**: ✅ Cần thực hiện ngay để hoàn chỉnh CI/CD pipeline
