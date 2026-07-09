# Bootstrap operations

Tài liệu này mô tả cách vận hành `./scripts/bootstrap.sh`, cách đọc report, cách chạy best-effort và cách recover một Argo CD Application sau khi sửa lỗi.

## Bootstrap modes

Bootstrap có hai mode:

- `strict`: mode mặc định. Script dừng ngay khi một phase bắt buộc không đạt trạng thái `Synced` và `Healthy`.
- `best-effort`: các phase infrastructure vẫn bắt buộc, nhưng workload và routing có thể tiếp tục nếu một vài Application chưa Healthy. Mode này phù hợp khi cần demo hoặc cần một môi trường chạy được một phần.

Chạy strict:

```bash
./scripts/bootstrap.sh
```

Chạy best-effort:

```bash
BOOTSTRAP_MODE=best-effort BOOTSTRAP_TIMEOUT=5m ./scripts/bootstrap.sh
```

## Phase order

| Runtime phase | Nội dung | Chính sách lỗi |
| --- | --- | --- |
| `00-prerequisites` | Argo CD, Istio, ingress address | Blocking |
| `01-operators` | PostgreSQL, Strimzi, ECK, Keycloak operators | Blocking |
| `02-infrastructure` | PostgreSQL, Redis, Elasticsearch/Kibana | Blocking |
| `03-initialization` | Database creation and credentials | Blocking |
| `04-platform` | Kafka, Kafka Connect, Keycloak, pgAdmin | Blocking |
| `03-connectors` | Debezium connectors | Blocking |
| `04-configuration` | Namespaces, application config and secrets | Blocking |
| `05-workloads` | Dev and staging microservices/UIs | Non-blocking only in best-effort |
| `06-routing` | Istio gateway and routes | Non-blocking only in best-effort |

Tên file giữ theo cấu trúc repository hiện tại. Khi runtime, platform phải chạy trước connectors, nên `03-connectors` được apply sau `04-platform`.

Observability Applications có trong `infra/`, nhưng không nằm trong active bootstrap phase. Nếu cần cài observability, sync riêng các Application đó qua Argo CD.

## Timeout

Mặc định mỗi gate đợi tối đa 15 phút:

```bash
./scripts/bootstrap.sh
```

Đổi timeout:

```bash
BOOTSTRAP_TIMEOUT=30m ./scripts/bootstrap.sh
```

Timeout không có nghĩa service chắc chắn hỏng vĩnh viễn. Nó chỉ có nghĩa là service chưa đạt trạng thái sẵn sàng trong khoảng thời gian đã cấu hình.

## Private GHCR packages

Nếu GHCR packages private, truyền credential khi bootstrap:

```bash
GHCR_USERNAME='<github-user>' \
GHCR_TOKEN='<read-packages-token>' \
./scripts/bootstrap.sh
```

Script sẽ tạo docker-registry secret `ghcr-pull` trong namespace `dev` và `staging`, sau đó patch default ServiceAccount để workloads pull image được.

Nếu quên cấu hình credential, lỗi thường gặp ở phase workload là `ImagePullBackOff`.

## Migration từ legacy roots

Nếu cluster đã có các root Applications cũ, bootstrap sẽ dừng để tránh chạy song song hai cơ chế điều khiển.

Chạy migration:

```bash
MIGRATE_LEGACY_ROOTS=true ./scripts/bootstrap.sh
```

Lệnh này xóa các Argo CD Application controller cũ với orphan propagation, giữ lại Kubernetes workloads hiện có. Sau đó phased bootstrap sẽ apply desired state mới theo đúng thứ tự.

## Deployment reports

Mỗi lần bootstrap tạo report local:

```text
.bootstrap-reports/bootstrap-<UTC timestamp>.log
```

Report ghi:

- phase đang chạy;
- component/Application;
- kết quả;
- chi tiết lỗi nếu có;
- snapshot Argo CD Applications cuối run.

Nếu namespace `argocd` truy cập được, report mới nhất cũng được lưu trong cluster:

```bash
kubectl get configmap yas-bootstrap-last-report -n argocd \
  -o jsonpath='{.data.report}'
```

Xem summary nhanh:

```bash
bash ./scripts/bootstrap-status.sh
```

Xem một Application:

```bash
bash ./scripts/bootstrap-status.sh product-dev
```

Application có kết quả `CONTINUED` trong best-effort mode không bị xóa hay bị tắt. Điều đó chỉ có nghĩa bootstrap đã ngừng đợi Application đó và tiếp tục phase sau. Argo CD vẫn tiếp tục reconcile ở background.

## Recover một Application

Quy trình recover:

1. Inspect Application:

   ```bash
   bash ./scripts/bootstrap-status.sh product-dev
   ```

2. Sửa source of truth trong Git. Ví dụ:

   - sửa image tag trong `yas-gitops`;
   - publish lại image trong `yas`;
   - sửa Helm chart trong `yas-helm`;
   - sửa Secret, config, dependency hoặc resource request.

3. Commit và push thay đổi lên branch/revision mà Application đang đọc, thông thường là `main`.

4. Recover Application:

   ```bash
   BOOTSTRAP_TIMEOUT=10m bash ./scripts/recover-application.sh product-dev
   ```

Script recovery không chạy lại toàn bộ bootstrap. Nó yêu cầu Argo CD hard refresh Application được chọn, sau đó đợi Application đạt `Synced` và `Healthy`.

Nếu parent Application như `yas-bootstrap-workloads` lỗi, hãy inspect các child Applications trước. Recover child Applications bị lỗi, sau đó recover parent nếu cần.

## Đọc trạng thái Argo CD

| Trạng thái | Ý nghĩa | Hướng xử lý |
| --- | --- | --- |
| `OutOfSync` | Desired state và live state khác nhau | Xem sync/render error, sửa Git rồi refresh |
| `Synced/Progressing` | Resource đã apply nhưng chưa ready | Xem pod, probe, dependency và events |
| `Synced/Degraded` | Resource báo lỗi | Xem rollout, pod logs, image pull và health probe |
| Application missing | Parent chưa tạo app hoặc render source lỗi | Xem parent Application và repo revision |
| `Unknown` | Argo CD không đọc được health/source | Xem repo access và Application conditions |

Không nên patch trực tiếp Deployment do Git quản lý để làm fix lâu dài. Argo CD self-heal có thể revert manual change. Nếu bắt buộc sửa tạm trên cluster, cần commit thay đổi tương đương vào Git sau đó.

## Useful commands

Tất cả Applications:

```bash
kubectl get applications -n argocd
```

Pods theo namespace:

```bash
kubectl get pods -n infra
kubectl get pods -n dev
kubectl get pods -n staging
```

Events:

```bash
kubectl get events -n infra --sort-by=.lastTimestamp
kubectl get events -n dev --sort-by=.lastTimestamp
kubectl get events -n staging --sort-by=.lastTimestamp
```

Describe và logs:

```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

Istio routing:

```bash
kubectl get gateway,virtualservice,destinationrule -A
kubectl get service istio-ingressgateway -n istio-system -o wide
```

Cluster networking check:

```bash
bash ./scripts/check-cluster-networking.sh
```
