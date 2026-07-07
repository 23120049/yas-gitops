#!/usr/bin/env bash
set -uo pipefail

# Read-only diagnosis for k3s ServiceLB placement conflicts between Istio and
# Traefik. Override these values when the intended ingress endpoint changes.
EXPECTED_INGRESS_NODE="${EXPECTED_INGRESS_NODE:-laptop-hh13kan9}"
EXPECTED_INGRESS_IP="${EXPECTED_INGRESS_IP:-100.124.113.25}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
ISTIO_SERVICE="${ISTIO_SERVICE:-istio-ingressgateway}"
TRAEFIK_NAMESPACE="${TRAEFIK_NAMESPACE:-kube-system}"
TRAEFIK_SERVICE="${TRAEFIK_SERVICE:-traefik}"
FAILURES=0
WARNINGS=0

pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf 'FAIL  %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

if ! command -v kubectl >/dev/null 2>&1; then
  echo "FAIL  kubectl was not found in PATH." >&2
  exit 2
fi

echo "K3s ingress placement diagnosis"
echo "Expected Istio endpoint: ${EXPECTED_INGRESS_NODE} (${EXPECTED_INGRESS_IP})"
echo

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "FAIL  Kubernetes API is unreachable." >&2
  exit 2
fi

if ! kubectl get node "${EXPECTED_INGRESS_NODE}" >/dev/null 2>&1; then
  echo "FAIL  Expected node '${EXPECTED_INGRESS_NODE}' does not exist." >&2
  exit 2
fi

node_ready="$(kubectl get node "${EXPECTED_INGRESS_NODE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
node_internal_ip="$(kubectl get node "${EXPECTED_INGRESS_NODE}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
node_external_ip="$(kubectl get node "${EXPECTED_INGRESS_NODE}" -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}')"

if [[ "${node_ready}" == "True" ]]; then
  pass "Expected ingress node is Ready."
else
  fail "Expected ingress node is not Ready (Ready=${node_ready:-unknown})."
fi

if [[ "${node_external_ip}" == "${EXPECTED_INGRESS_IP}" || "${node_internal_ip}" == "${EXPECTED_INGRESS_IP}" ]]; then
  pass "Expected IP belongs to ${EXPECTED_INGRESS_NODE}."
else
  fail "Expected IP does not match node addresses (internal=${node_internal_ip:-none}, external=${node_external_ip:-none})."
fi

if ! kubectl get service "${ISTIO_SERVICE}" -n "${ISTIO_NAMESPACE}" >/dev/null 2>&1; then
  echo "FAIL  Istio LoadBalancer Service ${ISTIO_NAMESPACE}/${ISTIO_SERVICE} is absent." >&2
  exit 2
fi

istio_type="$(kubectl get service "${ISTIO_SERVICE}" -n "${ISTIO_NAMESPACE}" -o jsonpath='{.spec.type}')"
istio_ips="$(kubectl get service "${ISTIO_SERVICE}" -n "${ISTIO_NAMESPACE}" \
  -o jsonpath='{range .status.loadBalancer.ingress[*]}{.ip}{.hostname}{" "}{end}')"
istio_pool="$(kubectl get service "${ISTIO_SERVICE}" -n "${ISTIO_NAMESPACE}" \
  -o jsonpath='{.metadata.labels.svccontroller\.k3s\.cattle\.io/lbpool}')"

if [[ "${istio_type}" == "LoadBalancer" ]]; then
  pass "Istio ingress is a LoadBalancer Service."
else
  fail "Istio ingress Service type is ${istio_type}, not LoadBalancer."
fi

if [[ " ${istio_ips} " == *" ${EXPECTED_INGRESS_IP} "* ]]; then
  pass "Istio advertises the expected IP ${EXPECTED_INGRESS_IP}."
else
  fail "Istio advertises '${istio_ips:-none}', expected ${EXPECTED_INGRESS_IP}."
fi

if [[ -n "${istio_pool}" ]]; then
  pass "Istio Service is assigned to ServiceLB pool '${istio_pool}'."
else
  warn "Istio Service has no explicit ServiceLB pool label."
fi

expected_enablelb="$(kubectl get node "${EXPECTED_INGRESS_NODE}" \
  -o jsonpath='{.metadata.labels.svccontroller\.k3s\.cattle\.io/enablelb}')"
expected_pool="$(kubectl get node "${EXPECTED_INGRESS_NODE}" \
  -o jsonpath='{.metadata.labels.svccontroller\.k3s\.cattle\.io/lbpool}')"

if [[ "${expected_enablelb}" == "true" ]]; then
  pass "Expected node is enabled for ServiceLB."
else
  warn "Expected node does not have enablelb=true."
fi

if [[ -n "${istio_pool}" && "${expected_pool}" == "${istio_pool}" ]]; then
  pass "Expected node and Istio Service use matching pool '${istio_pool}'."
elif [[ -n "${istio_pool}" ]]; then
  fail "Pool mismatch: Istio='${istio_pool}', expected node='${expected_pool:-none}'."
else
  warn "Pool matching cannot be verified because Istio is not assigned to a pool."
fi

echo
echo "ServiceLB placement:"
kubectl get pods -n kube-system \
  -l "svccontroller.k3s.cattle.io/svcname=${ISTIO_SERVICE},svccontroller.k3s.cattle.io/svcnamespace=${ISTIO_NAMESPACE}" \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName,IP:.status.podIP' 2>/dev/null || true

istio_on_expected="$(kubectl get pods -n kube-system \
  -l "svccontroller.k3s.cattle.io/svcname=${ISTIO_SERVICE},svccontroller.k3s.cattle.io/svcnamespace=${ISTIO_NAMESPACE}" \
  --field-selector="spec.nodeName=${EXPECTED_INGRESS_NODE},status.phase=Running" \
  -o name 2>/dev/null)"

if [[ -n "${istio_on_expected}" ]]; then
  pass "A running Istio ServiceLB pod is placed on ${EXPECTED_INGRESS_NODE}."
else
  fail "No running Istio ServiceLB pod is placed on ${EXPECTED_INGRESS_NODE}."
fi

if kubectl get service "${TRAEFIK_SERVICE}" -n "${TRAEFIK_NAMESPACE}" >/dev/null 2>&1; then
  traefik_ips="$(kubectl get service "${TRAEFIK_SERVICE}" -n "${TRAEFIK_NAMESPACE}" \
    -o jsonpath='{range .status.loadBalancer.ingress[*]}{.ip}{.hostname}{" "}{end}')"
  traefik_pool="$(kubectl get service "${TRAEFIK_SERVICE}" -n "${TRAEFIK_NAMESPACE}" \
    -o jsonpath='{.metadata.labels.svccontroller\.k3s\.cattle\.io/lbpool}')"
  traefik_on_expected="$(kubectl get pods -n kube-system \
    -l "svccontroller.k3s.cattle.io/svcname=${TRAEFIK_SERVICE},svccontroller.k3s.cattle.io/svcnamespace=${TRAEFIK_NAMESPACE}" \
    --field-selector="spec.nodeName=${EXPECTED_INGRESS_NODE},status.phase=Running" \
    -o name 2>/dev/null)"

  if [[ -n "${traefik_on_expected}" ]]; then
    fail "Traefik ServiceLB is running on ${EXPECTED_INGRESS_NODE} and competes for ports 80/443."
  else
    pass "Traefik ServiceLB is not running on the expected Istio node."
  fi
  if [[ " ${traefik_ips} " == *" ${EXPECTED_INGRESS_IP} "* ]]; then
    fail "Traefik, not Istio, advertises the expected Istio IP ${EXPECTED_INGRESS_IP}."
  else
    pass "Traefik does not advertise the expected Istio IP."
  fi
  if [[ -z "${traefik_pool}" ]]; then
    warn "Traefik Service has no explicit ServiceLB pool label."
  fi
else
  warn "Traefik Service is not installed; no Traefik conflict exists to inspect."
fi

pending_istio="$(kubectl get pods -n kube-system \
  -l "svccontroller.k3s.cattle.io/svcname=${ISTIO_SERVICE},svccontroller.k3s.cattle.io/svcnamespace=${ISTIO_NAMESPACE}" \
  --field-selector=status.phase=Pending -o name 2>/dev/null)"
if [[ -n "${pending_istio}" ]]; then
  warn "Istio has Pending ServiceLB pods. Recent scheduling messages:"
  while read -r pod; do
    [[ -z "${pod}" ]] && continue
    kubectl get events -n kube-system \
      --field-selector="involvedObject.kind=Pod,involvedObject.name=${pod#pod/}" \
      --sort-by='.lastTimestamp' -o custom-columns='POD:.involvedObject.name,REASON:.reason,MESSAGE:.message' \
      2>/dev/null | tail -n 2 || true
  done <<< "${pending_istio}"
else
  pass "Istio has no Pending ServiceLB pods."
fi

echo
echo "Diagnosis: ${FAILURES} confirmed issue(s), ${WARNINGS} warning(s)."
if (( FAILURES > 0 )); then
  echo "VERDICT: REAL ISSUE — Istio ingress is not placed on the intended node/IP."
  exit 1
fi
echo "VERDICT: PASS — Istio ingress placement matches the intended node/IP."
