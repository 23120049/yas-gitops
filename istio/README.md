# Hướng Dẫn Triển Khai & Kiểm Thử Service Mesh (Istio) cho YAS Microservices

Tài liệu này hướng dẫn chi tiết từng bước triển khai, cấu hình và kiểm thử các tính năng của **Service Mesh (Istio)** trên Kubernetes (K3s) cho ứng dụng YAS, bao gồm cấu hình mTLS, Phân quyền truy cập (AuthorizationPolicy), Chính sách tự động thử lại (Retry Policy), và Giám sát trực quan với Kiali.

---

## Kiến Trúc Service Mesh YAS
Hệ thống sử dụng **Istio Service Mesh** làm control plane để quản lý giao tiếp nội bộ giữa các microservice chạy trong 2 namespace `dev` và `staging`.

*   **Ingress Gateway**: Tiếp nhận traffic từ bên ngoài qua host `*.yas.local.com` (cổng 80) và chuyển tiếp tới các BFF (`storefront-bff`, `backoffice-bff`) hoặc Swagger UI.
*   **mTLS STRICT**: Bắt buộc mọi giao tiếp giữa các pod trong mesh phải được mã hóa TLS hai chiều.
*   **AuthorizationPolicy**: Quản lý phân quyền chi tiết (Zero-Trust), ví dụ: giới hạn dịch vụ nào được gọi vào service `cart`.
*   **Retry Policy**: Tự động cấu hình gọi lại nếu một dịch vụ (ví dụ `tax`) gặp sự cố kết nối hoặc trả lỗi 5xx.

---

## Bước 1: Triển Khai Istio Control Plane và Ingress Gateway

Nếu chưa cài đặt Istio trên cluster, thực hiện cài đặt phiên bản Istio bằng công cụ CLI `istioctl`:

```bash
# 1. Tải và cài đặt istioctl (phiên bản khuyến nghị: 1.20.x trở lên)
# 2. Thực hiện cài đặt profile demo để tự động cấu hình Istio Core, Istiod và Ingress Gateway
istioctl install -y --set profile=demo
```

> [!NOTE]
> Profile `demo` của Istio đi kèm cấu hình mặc định rất phù hợp cho mục đích Lab/Dev và tự động cài đặt các thành phần phụ trợ cần thiết.

Kiểm tra trạng thái sẵn sàng của các Pod trong namespace `istio-system`:
```bash
kubectl get pods -n istio-system
```
*Yêu cầu:* Cả `istiod-*` và `istio-ingressgateway-*` đều phải ở trạng thái `Running`.

---

## Bước 2: Cấu Hình Gateway Toàn Cục & Routing

Triển khai Ingress Gateway và các tuyến định tuyến cơ sở hạ tầng (Keycloak, pgAdmin, Kibana):

1.  **Cấu hình Ingress Gateway**: tiếp nhận các host tên miền dạng `*.yas.local.com`:
    ```bash
    kubectl apply -f istio/gateway.yaml
    ```
2.  **Cấu hình Ingress Routing cho Infra**:
    ```bash
    kubectl apply -f istio/infra-routing.yaml
    ```
    *Lệnh này định tuyến các host:*
    *   `identity.yas.local.com` -> `keycloak-service.infra`
    *   `pgadmin.yas.local.com` -> `pgadmin.infra`
    *   `kibana.yas.local.com` -> `kibana-kb-http.infra`

---

## Bước 3: Triển Khai Service Mesh Cho Môi Trường (Dev & Staging)

Trong kiến trúc GitOps của dự án, các tài nguyên Istio được tự động đồng bộ hóa bởi ArgoCD qua hai ứng dụng:
*   `yas-root-istio-dev` (quản lý [istio/dev](yas-gitops/istio/dev))
*   `yas-root-istio-staging` (quản lý [istio/staging](yas-gitops/istio/staging))

Nếu cần triển khai thủ công bằng lệnh `kubectl`, thực hiện chạy lệnh sau tại thư mục gốc của repository `yas-gitops`:

```bash
# Triển khai cho môi trường Dev
kubectl apply -f istio/dev/

# Triển khai cho môi trường Staging
kubectl apply -f istio/staging/
```

Các manifest được áp dụng gồm:
*   `peer-authentication.yaml`: Bật STRICT mTLS.
*   `destinationrule-cart-metrics.yaml`: Tắt mTLS cho port metrics 8090.
*   `authorization-policy.yaml`: Phân quyền gọi service `cart`.
*   `retry-policy.yaml`: Cấu hình retry cho service `tax`.
*   `external-routing.yaml`: VirtualServices định tuyến traffic từ ngoài vào các BFF/Services.

---

## Bước 4: Chi Tiết Cấu Hình Bảo Mật & Kết Nối

### 1. STRICT mTLS
Tập tin [peer-authentication.yaml](yas-gitops/istio/dev/peer-authentication.yaml) bắt buộc mTLS toàn namespace:
```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default-strict-mtls
  namespace: dev # tương tự với staging
spec:
  mtls:
    mode: STRICT
```
Để Prometheus (chạy trong namespace `observability`) có thể cào thông tin metrics từ cổng `/actuator/prometheus` (port 8090) của service `cart` mà không cần xác thực mTLS, cấu hình [destinationrule-cart-metrics.yaml](yas-gitops/istio/dev/destinationrule-cart-metrics.yaml) vô hiệu hóa TLS trên cổng này:
```yaml
spec:
  host: cart.dev.svc.cluster.local
  trafficPolicy:
    portLevelSettings:
      - port:
          number: 8090
        tls:
          mode: DISABLE
```

### 2. Authorization Policy (Chống Lỗ Hổng Bảo Mật)
Tập tin [authorization-policy.yaml](yas-gitops/istio/dev/authorization-policy.yaml) quản lý bảo mật Zero-Trust cho dịch vụ `cart`:
*   **Quy tắc 1**: Chỉ cho phép các Service Account `storefront-bff` và `order` trong cùng namespace được truy cập **tất cả** các endpoint của `cart`.
*   **Quy tắc 2**: Chỉ cho phép Service Account của Prometheus (`prometheus-kube-prometheus-prometheus`) trong namespace `observability` được phép gọi tới các cổng/đường dẫn Actuator/Prometheus thu thập chỉ số.
*   **An toàn tuyệt đối**: Chặn mọi truy cập ẩn danh (anonymous) từ các Pod khác.

### 3. Retry Policy
Tập tin [retry-policy.yaml](yas-gitops/istio/dev/retry-policy.yaml) định nghĩa chính sách tự động gọi lại cho service `tax`:
```yaml
      retries:
        attempts: 3
        perTryTimeout: 2s
        retryOn: gateway-error,connect-failure,refused-stream,5xx
```
Khi client gọi vào `tax` mà service trả lỗi 5xx hoặc mất kết nối mạng, sidecar proxy (Envoy) sẽ tự động thực hiện lại tối đa 3 lần, mỗi lần cách nhau tối đa 2 giây trước khi trả lỗi thực sự về cho client.

---

## Bước 5: Kịch Bản Kiểm Thử & Xác Thực (Test Plan)

### Lệnh 1: Kiểm tra trạng thái đồng bộ mTLS
```bash
# Liệt kê các chính sách xác thực mTLS trong cluster
kubectl get peerauthentication -A
```
*Kết quả đạt:* Dòng `default-strict-mtls` trong các namespace `dev` và `staging` phải hiển thị mode `STRICT`.

---

### Lệnh 2: Xác thực chính sách Authorization Policy trên `cart`

1.  **Thử nghiệm truy cập hợp lệ (Được phép)**:
    Gọi từ pod `storefront-bff` sang `cart` (giao tiếp được phép trong cấu hình):
    ```bash
    # Lấy tên của pod bff đang chạy
    BFF_POD=$(kubectl get pod -n dev -l app.kubernetes.io/name=storefront-bff -o jsonpath='{.items[0].metadata.name}')
    
    # Thực hiện lệnh curl kiểm tra kết nối nội bộ
    kubectl exec -n dev "$BFF_POD" -c storefront-bff -- curl -s -o /dev/null -w "%{http_code}\n" http://cart.dev.svc.cluster.local/cart/actuator/health
    ```
    *Kết quả mong đợi:* Trả về HTTP Code `200` hoặc `401/403` tùy theo cơ chế xác thực tầng ứng dụng, nhưng **không bị chặn bởi network policy**.

2.  **Thử nghiệm truy cập bất hợp pháp (Bị chặn bởi Istio)**:
    Gọi từ pod `tax` sang `cart` (`tax` không được khai báo trong AuthorizationPolicy của `cart`):
    ```bash
    TAX_POD=$(kubectl get pod -n dev -l app.kubernetes.io/name=tax -o jsonpath='{.items[0].metadata.name}')
    
    kubectl exec -n dev "$TAX_POD" -c tax -- curl -i -s http://cart.dev.svc.cluster.local/
    ```
    *Kết quả mong đợi:* Trả về lỗi chặn mạng trực tiếp từ Envoy:
    ```text
    HTTP/1.1 403 Forbidden
    content-length: 19
    content-type: text/plain
    date: ...
    server: istio-envoy
    
    RBAC: access denied
    ```
    *(Dòng chữ `RBAC: access denied` chứng minh AuthorizationPolicy của Istio đang hoạt động chính xác).*

3.  **Thử nghiệm kiểm tra endpoint Actuator (Phòng chống lỗ hổng)**:
    Gọi endpoint Actuator của `cart` từ pod `tax` (không có quyền Prometheus):
    ```bash
    kubectl exec -n dev "$TAX_POD" -c tax -- curl -i -s http://cart.dev.svc.cluster.local/actuator/prometheus
    ```
    *Kết quả mong đợi:* Phải trả về `HTTP/1.1 403 Forbidden` thay vì cho phép truy cập.

---

### Lệnh 3: Xác thực cơ chế Retry Policy trên `tax`

1.  Theo dõi log sidecar Envoy của pod `tax` ở chế độ realtime:
    ```bash
    kubectl logs -n dev "$TAX_POD" -c istio-proxy -f
    ```
2.  Gửi request giả lập lỗi từ một client. Hoặc lập lịch tắt tạm thời ứng dụng trong Container `tax` (chừa sidecar Envoy chạy) để tạo lỗi `connect-failure`, sau đó thực hiện lệnh gọi:
    ```bash
    kubectl exec -n dev "$BFF_POD" -c storefront-bff -- curl -i http://tax.dev.svc.cluster.local/tax
    ```
3.  *Quan sát log Envoy:* Bạn sẽ thấy 3 dòng log ghi nhận nỗ lực kết nối lại (retries) trước khi Envoy trả mã lỗi cuối cùng về cho client.

---

## Bước 6: Giám Sát và Quan Sát Với Kiali

Kiali được sử dụng để hiển thị sơ đồ kết nối (Topology Graph) thực tế giữa các dịch vụ.

1.  **Mở Dashboard Kiali**:
    Nếu sử dụng máy local có kết nối trực tiếp với Cluster, khởi chạy dashboard bằng lệnh:
    ```bash
    istioctl dashboard kiali
    ```
2.  **Truy cập trên Browser**: Mở đường dẫn hiển thị trên console (mặc định: `http://localhost:20001`).
3.  **Xem Topology Graph**:
    *   Truy cập menu **Graph** bên thanh trái.
    *   Chọn Namespace là `dev` hoặc `staging`.
    *   Trong mục *Display*, chọn các tùy chọn: *Traffic Animation*, *Security* (để hiển thị biểu tượng ổ khóa (🔒) đại diện cho kết nối đang được mã hóa bằng mTLS STRICT).
    *   Thực hiện click tạo các request trên ứng dụng YAS (mua hàng, xem sản phẩm) để thấy các đường truyền nhấp nháy hiển thị lưu lượng traffic thời gian thực.
