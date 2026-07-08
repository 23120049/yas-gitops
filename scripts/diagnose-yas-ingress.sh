#!/usr/bin/env bash
set -uo pipefail

# End-to-end, non-destructive diagnosis for the YAS Istio ingress path.
# A temporary curl pod is created and deleted automatically.
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
ISTIO_SERVICE="${ISTIO_SERVICE:-istio-ingressgateway}"
TEST_HOST="${TEST_HOST:-dev-storefront.yas.local.com}"
EXPECTED_INGRESS_IP="${EXPECTED_INGRESS_IP:-100.124.113.25}"
TIMEOUT="${DIAG_TIMEOUT:-60s}"
RUN_ID="$(date +%s)-$$"
CURL_POD="yas-ingress-diag-${RUN_ID}"
FAILURES=0
WARNINGS=0

pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf 'FAIL  %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

cleanup() {
  kubectl delete pod "${CURL_POD}" --ignore-not-found --wait=false \
    >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

if ! command -v kubectl >/dev/null 2>&1; then
  echo "FAIL  kubectl was not found in PATH." >&2
  exit 2
fi

echo "YAS ingress end-to-end diagnosis"
echo "Host: ${TEST_HOST}"
echo "Expected external IP: ${EXPECTED_INGRESS_IP}"
echo

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "FAIL  Kubernetes API is unreachable." >&2
  exit 2
fi
pass "Kubernetes API is reachable (context: $(kubectl config current-context 2>/dev/null || echo unknown))."

if ! kubectl get service "${ISTIO_SERVICE}" -n "${ISTIO_NAMESPACE}" >/dev/null 2>&1; then
  echo "FAIL  Service ${ISTIO_NAMESPACE}/${ISTIO_SERVICE} does not exist." >&2
  exit 2
fi

service_type="$(kubectl get service "${ISTIO_SERVICE}" -n "${ISTIO_NAMESPACE}" -o jsonpath='{.spec.type}')"
cluster_ip="$(kubectl get service "${ISTIO_SERVICE}" -n "${ISTIO_NAMESPACE}" -o jsonpath='{.spec.clusterIP}')"
http_port="$(kubectl get service "${ISTIO_SERVICE}" -n "${ISTIO_NAMESPACE}" -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')"
target_port="$(kubectl get service "${ISTIO_SERVICE}" -n "${ISTIO_NAMESPACE}" -o jsonpath='{.spec.ports[?(@.name=="http2")].targetPort}')"
node_port="$(kubectl get service "${ISTIO_SERVICE}" -n "${ISTIO_NAMESPACE}" -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')"
advertised_ips="$(kubectl get service "${ISTIO_SERVICE}" -n "${ISTIO_NAMESPACE}" -o jsonpath='{range .status.loadBalancer.ingress[*]}{.ip}{" "}{end}')"

[[ "${service_type}" == "LoadBalancer" ]] && pass "Istio Service is type LoadBalancer." || fail "Istio Service type is ${service_type}, expected LoadBalancer."
[[ -n "${http_port}" ]] && pass "HTTP mapping is ${http_port} -> ${target_port}, NodePort ${node_port}." || fail "Istio Service has no port named http2."
[[ " ${advertised_ips} " == *" ${EXPECTED_INGRESS_IP} "* ]] && pass "Service advertises ${EXPECTED_INGRESS_IP}." || fail "Service advertises '${advertised_ips:-none}', not ${EXPECTED_INGRESS_IP}."

endpoint_rows="$(kubectl get endpoints "${ISTIO_SERVICE}" -n "${ISTIO_NAMESPACE}" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{" "}{end}' 2>/dev/null || true)"
if [[ -n "${endpoint_rows}" ]]; then
  pass "Istio Service has endpoint pod IP(s): ${endpoint_rows}."
else
  fail "Istio Service has no ready endpoint addresses."
fi

gateway_pod="$(kubectl get pods -n "${ISTIO_NAMESPACE}" \
  -l 'app=istio-ingressgateway,istio=ingressgateway' \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
gateway_pod_ip="$(kubectl get pod "${gateway_pod}" -n "${ISTIO_NAMESPACE}" \
  -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
gateway_node="$(kubectl get pod "${gateway_pod}" -n "${ISTIO_NAMESPACE}" \
  -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"

if [[ -n "${gateway_pod}" && -n "${gateway_pod_ip}" ]]; then
  pass "Running gateway ${gateway_pod} is ${gateway_pod_ip} on ${gateway_node}."
else
  fail "No Running Istio ingress gateway pod with a pod IP was found."
fi

echo
echo "K3s ServiceLB pods:"
kubectl get pods -n kube-system \
  -l "svccontroller.k3s.cattle.io/svcname=${ISTIO_SERVICE},svccontroller.k3s.cattle.io/svcnamespace=${ISTIO_NAMESPACE}" \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,PHASE:.status.phase,NODE:.spec.nodeName,IP:.status.podIP' \
  2>/dev/null || true

bad_lb_pods="$(kubectl get pods -n kube-system \
  -l "svccontroller.k3s.cattle.io/svcname=${ISTIO_SERVICE},svccontroller.k3s.cattle.io/svcnamespace=${ISTIO_NAMESPACE}" \
  --no-headers 2>/dev/null | awk '$3 != "Running" {print $1 ":" $3}')"
[[ -z "${bad_lb_pods}" ]] && pass "All Istio ServiceLB pods are Running." || warn "Some Istio ServiceLB pods are not Running: ${bad_lb_pods//$'\n'/, }."

if kubectl get service traefik -n kube-system >/dev/null 2>&1; then
  fail "Traefik Service is installed and may compete with Istio for ports 80/443."
else
  pass "Traefik Service is absent."
fi

gateway_count="$(kubectl get gateway.networking.istio.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
virtualservice_count="$(kubectl get virtualservice.networking.istio.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[[ "${gateway_count}" -gt 0 ]] && pass "Found ${gateway_count} Istio Gateway resource(s)." || fail "No Istio Gateway resources exist."
[[ "${virtualservice_count}" -gt 0 ]] && pass "Found ${virtualservice_count} Istio VirtualService resource(s)." || fail "No Istio VirtualService resources exist."

host_routes="$(kubectl get virtualservice.networking.istio.io -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{range .spec.hosts[*]}{.}{" "}{end}{"\n"}{end}' \
  2>/dev/null | grep -F "${TEST_HOST}" || true)"
[[ -n "${host_routes}" ]] && pass "A VirtualService contains ${TEST_HOST}: ${host_routes}." || fail "No VirtualService contains host ${TEST_HOST}."

echo
echo "Creating temporary curl pod..."
if kubectl run "${CURL_POD}" --restart=Never --image=curlimages/curl:8.12.1 \
  --command -- sleep 300 >/dev/null 2>&1 && \
  kubectl wait pod "${CURL_POD}" --for=condition=Ready --timeout="${TIMEOUT}" >/dev/null 2>&1; then
  pass "Temporary curl pod is Ready."
else
  fail "Temporary curl pod did not become Ready; network probes cannot run."
  echo
  echo "Diagnosis: ${FAILURES} failure(s), ${WARNINGS} warning(s)."
  exit 1
fi

probe() {
  local label="$1"
  local url="$2"
  local result
  result="$(kubectl exec "${CURL_POD}" -- curl -sS -o /dev/null \
    -w '%{http_code}' --connect-timeout 5 --max-time 10 \
    -H "Host: ${TEST_HOST}" "${url}" 2>&1)"
  if [[ "$?" -eq 0 ]]; then
    pass "${label} is reachable (HTTP ${result})."
    return 0
  fi
  fail "${label} is unreachable: ${result}."
  return 1
}

direct_ok=false
cluster_ok=false
if [[ -n "${gateway_pod_ip}" ]]; then
  probe "Direct gateway pod ${gateway_pod_ip}:${target_port}" "http://${gateway_pod_ip}:${target_port}/" && direct_ok=true
fi
probe "Istio ClusterIP ${cluster_ip}:${http_port}" "http://${cluster_ip}:${http_port}/" && cluster_ok=true

echo
echo "Diagnosis: ${FAILURES} failure(s), ${WARNINGS} warning(s)."
if [[ "${gateway_count}" -eq 0 || "${virtualservice_count}" -eq 0 ]]; then
  echo "VERDICT: Istio routing resources are missing, so Envoy has no HTTP listener for the application."
  echo "NEXT: apply/sync the yas-bootstrap-routing Argo CD application."
elif [[ "${direct_ok}" != true ]]; then
  echo "VERDICT: The ingress gateway pod is not accepting HTTP on its target port, or pod networking is broken."
  echo "NEXT: kubectl logs -n ${ISTIO_NAMESPACE} ${gateway_pod:-<gateway-pod>} --tail=200"
elif [[ "${cluster_ok}" != true ]]; then
  echo "VERDICT: The gateway pod responds directly, but the Kubernetes Service path is broken (kube-proxy/CNI)."
  echo "NEXT: inspect k3s/k3s-agent logs and the KUBE-SERVICES/KUBE-NODEPORTS rules on every node."
elif (( FAILURES > 0 )); then
  echo "VERDICT: Connectivity exists, but configuration conflicts remain; review FAIL lines above."
else
  echo "VERDICT: Internal ingress checks pass. Test http://${TEST_HOST} from the workstation."
fi

(( FAILURES == 0 ))
