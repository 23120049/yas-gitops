#!/usr/bin/env bash
set -uo pipefail

# Non-destructive cluster readiness and networking preflight. Temporary resources
# are isolated in two namespaces and removed on exit.
TIMEOUT="${PREFLIGHT_TIMEOUT:-120s}"
RUN_STORAGE_CHECK="${RUN_STORAGE_CHECK:-true}"
REQUIRE_EGRESS="${REQUIRE_EGRESS:-false}"
REQUIRE_ARGOCD="${REQUIRE_ARGOCD:-false}"
REQUIRE_ISTIO="${REQUIRE_ISTIO:-false}"
RUN_ID="$(date +%s)-$$"
NS_SERVER="yas-preflight-server-${RUN_ID}"
NS_CLIENT="yas-preflight-client-${RUN_ID}"
FAILURES=0
WARNINGS=0

pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf 'FAIL  %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

cleanup() {
  kubectl delete namespace "${NS_SERVER}" "${NS_CLIENT}" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

if ! command -v kubectl >/dev/null 2>&1; then
  echo "FAIL  kubectl was not found in PATH." >&2
  exit 1
fi

echo "YAS cluster preflight (timeout: ${TIMEOUT})"
echo

if kubectl cluster-info >/dev/null 2>&1; then
  pass "Kubernetes API is reachable (context: $(kubectl config current-context 2>/dev/null || echo unknown))."
else
  echo "FAIL  Kubernetes API is not reachable using the current context." >&2
  exit 1
fi

not_ready_nodes="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 !~ /^Ready/ {print $1 ":" $2}')"
if [[ -z "${not_ready_nodes}" ]]; then
  pass "All Kubernetes nodes are Ready."
else
  fail "Some nodes are not Ready: ${not_ready_nodes//$'\n'/, }."
fi

if kubectl get deployment coredns -n kube-system >/dev/null 2>&1 && \
   kubectl rollout status deployment/coredns -n kube-system --timeout="${TIMEOUT}" >/dev/null 2>&1; then
  pass "CoreDNS is available."
else
  fail "CoreDNS is missing or unavailable."
fi

bad_system_pods="$(kubectl get pods -n kube-system --field-selector=status.phase!=Running,status.phase!=Succeeded \
  --no-headers 2>/dev/null | awk '{print $1 ":" $3}')"
if [[ -z "${bad_system_pods}" ]]; then
  pass "No active kube-system pods are Pending, Failed, or Unknown."
else
  warn "Unhealthy kube-system pods: ${bad_system_pods//$'\n'/, }."
fi

if ! kubectl auth can-i create namespaces 2>/dev/null | grep -qx yes; then
  fail "Current identity cannot create namespaces required by deployment/preflight."
else
  pass "Current identity can create namespaces."
fi

if (( FAILURES == 0 )); then
  kubectl create namespace "${NS_SERVER}" >/dev/null || fail "Could not create server test namespace."
  kubectl create namespace "${NS_CLIENT}" >/dev/null || fail "Could not create client test namespace."
fi

if (( FAILURES == 0 )); then
  kubectl run net-server -n "${NS_SERVER}" \
    --image=busybox:1.36.1 \
    --labels=app=net-server --restart=Never --command -- /bin/sh -c \
    'mkdir -p /www && hostname > /www/index.html && httpd -f -p 8080 -h /www' >/dev/null || \
    fail "Could not create network server pod."
  kubectl expose pod net-server -n "${NS_SERVER}" --name=net-server --port=80 --target-port=8080 >/dev/null || \
    fail "Could not create ClusterIP test service."
  kubectl wait pod/net-server -n "${NS_SERVER}" --for=condition=Ready --timeout="${TIMEOUT}" >/dev/null 2>&1 || \
    fail "Network server pod did not become Ready (image pull or CNI problem)."
fi

if (( FAILURES == 0 )); then
  server_ip="$(kubectl get pod net-server -n "${NS_SERVER}" -o jsonpath='{.status.podIP}')"
  kubectl run net-client -n "${NS_CLIENT}" \
    --image=busybox:1.36.1 \
    --restart=Never --command -- /bin/sh -c \
    "set -e
     nslookup kubernetes.default.svc.cluster.local
     nslookup net-server.${NS_SERVER}.svc.cluster.local
     wget -qO- --timeout=10 http://net-server.${NS_SERVER}.svc.cluster.local/
     wget -qO- --timeout=10 http://${server_ip}:8080/" >/dev/null || \
    fail "Could not create network client pod."
  if kubectl wait pod/net-client -n "${NS_CLIENT}" --for=jsonpath='{.status.phase}'=Succeeded \
      --timeout="${TIMEOUT}" >/dev/null 2>&1; then
    pass "Cluster DNS resolves Kubernetes and cross-namespace service names."
    pass "Pod-to-Service traffic works across namespaces (ClusterIP/CNI)."
    pass "Pod-to-Pod traffic works across namespaces (CNI routing)."
  else
    fail "Internal DNS or pod/service networking test failed."
    kubectl logs net-client -n "${NS_CLIENT}" 2>/dev/null || true
  fi
fi

if kubectl run egress-test -n "${NS_CLIENT}" \
    --image=busybox:1.36.1 --restart=Never \
    --command -- /bin/sh -c 'nslookup github.com && wget -qO- --timeout=15 https://github.com >/dev/null' \
    >/dev/null 2>&1 && \
   kubectl wait pod/egress-test -n "${NS_CLIENT}" --for=jsonpath='{.status.phase}'=Succeeded \
    --timeout="${TIMEOUT}" >/dev/null 2>&1; then
  pass "Pods have external DNS and HTTPS egress."
else
  if [[ "${REQUIRE_EGRESS}" == "true" ]]; then
    fail "Pod external DNS/HTTPS egress failed."
  else
    warn "Pod external DNS/HTTPS egress failed (set REQUIRE_EGRESS=true to make this fatal)."
  fi
  kubectl logs egress-test -n "${NS_CLIENT}" 2>/dev/null || true
fi

if [[ "${RUN_STORAGE_CHECK}" == "true" ]]; then
  default_sc="$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null)"
  if [[ -z "${default_sc}" ]]; then
    fail "No default StorageClass exists."
  else
    cat <<EOF | kubectl apply -n "${NS_CLIENT}" -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: storage-test
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 16Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: storage-test
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: busybox:1.36.1
      command: [/bin/sh, -c, "echo preflight-ok > /data/check && grep -q preflight-ok /data/check"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: storage-test
EOF
    if kubectl wait pod/storage-test -n "${NS_CLIENT}" --for=jsonpath='{.status.phase}'=Succeeded \
        --timeout="${TIMEOUT}" >/dev/null 2>&1; then
      pass "Default StorageClass '${default_sc}' dynamically provisions writable storage."
    else
      fail "Dynamic storage provisioning/write test failed for '${default_sc}'."
    fi
  fi
else
  warn "Storage test skipped (RUN_STORAGE_CHECK=false)."
fi

check_addon() {
  local namespace="$1" workload="$2" label="$3" required="$4"
  if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    if [[ "${required}" == "true" ]]; then fail "${label} namespace is absent."; else warn "${label} is not installed yet."; fi
  elif kubectl rollout status "${workload}" -n "${namespace}" --timeout="${TIMEOUT}" >/dev/null 2>&1; then
    pass "${label} is healthy."
  else
    if [[ "${required}" == "true" ]]; then fail "${label} is installed but unhealthy."; else warn "${label} is installed but unhealthy."; fi
  fi
}

check_addon argocd deployment/argocd-server "Argo CD" "${REQUIRE_ARGOCD}"
check_addon istio-system deployment/istiod "Istio control plane" "${REQUIRE_ISTIO}"
check_addon istio-system deployment/istio-ingressgateway "Istio ingress gateway" "${REQUIRE_ISTIO}"

if kubectl get service istio-ingressgateway -n istio-system >/dev/null 2>&1; then
  ingress_address="$(kubectl get service istio-ingressgateway -n istio-system \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
  if [[ -n "${ingress_address}" ]]; then
    pass "Istio ingress has advertised address ${ingress_address}."
  elif [[ "${REQUIRE_ISTIO}" == "true" ]]; then
    fail "Istio ingress has no LoadBalancer address."
  else
    warn "Istio ingress has no LoadBalancer address yet."
  fi
fi

echo
echo "Preflight result: ${FAILURES} failure(s), ${WARNINGS} warning(s)."
if (( FAILURES > 0 )); then
  echo "Cluster is NOT ready for YAS deployment."
  exit 1
fi
echo "Cluster passed all required checks."
