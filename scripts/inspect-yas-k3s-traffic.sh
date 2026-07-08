#!/usr/bin/env bash
set -uo pipefail

# Read-only snapshot used to decide how to prefer yas-k3s for ingress traffic.
TARGET_NODE="${TARGET_NODE:-yas-k3s}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
ISTIO_SERVICE="${ISTIO_SERVICE:-istio-ingressgateway}"
TRAEFIK_NAMESPACE="${TRAEFIK_NAMESPACE:-kube-system}"
TRAEFIK_SERVICE="${TRAEFIK_SERVICE:-traefik}"

section() { printf '\n===== %s =====\n' "$1"; }
run() {
  printf '\n$'
  printf ' %q' "$@"
  printf '\n'
  "$@" 2>&1 || printf '[command failed: exit %s]\n' "$?"
}

wait_for_api() {
  local attempt
  for attempt in $(seq 1 24); do
    if kubectl --request-timeout=5s get --raw=/readyz >/dev/null 2>&1; then
      echo "Kubernetes API is ready (attempt ${attempt}/24)."
      return 0
    fi
    echo "Waiting for Kubernetes API at $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo unknown) (${attempt}/24)..." >&2
    sleep 5
  done
  echo "ERROR: Kubernetes API did not become ready within 120 seconds." >&2
  return 1
}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl was not found in PATH." >&2
  exit 2
fi

echo "YAS traffic placement snapshot"
echo "Generated (UTC): $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "Target node: ${TARGET_NODE}"
echo "This script is read-only; it does not apply labels or modify resources."

section "Cluster identity"
run kubectl config current-context
run kubectl version
run kubectl cluster-info

section "API readiness"
if ! wait_for_api; then
  echo "Stop here: restart/fix the k3s server, then rerun this script." >&2
  exit 3
fi

if ! kubectl get node "${TARGET_NODE}" >/dev/null 2>&1; then
  echo "ERROR: node '${TARGET_NODE}' does not exist or the current user cannot read it." >&2
  run kubectl get nodes -o wide
  exit 2
fi

section "Nodes and ServiceLB labels"
run kubectl get nodes -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,INTERNAL-IP:.status.addresses[?(@.type=="InternalIP")].address,EXTERNAL-IP:.status.addresses[?(@.type=="ExternalIP")].address,ENABLE-LB:.metadata.labels.svccontroller\.k3s\.cattle\.io/enablelb,LB-POOL:.metadata.labels.svccontroller\.k3s\.cattle\.io/lbpool,UNSCHEDULABLE:.spec.unschedulable'
run kubectl describe node "${TARGET_NODE}"

section "Ingress services"
for service_ref in "${ISTIO_NAMESPACE}/${ISTIO_SERVICE}" "${TRAEFIK_NAMESPACE}/${TRAEFIK_SERVICE}"; do
  namespace="${service_ref%%/*}"
  service="${service_ref#*/}"
  service_check="$(kubectl get service "${service}" -n "${namespace}" -o name 2>&1)"
  service_rc=$?
  if (( service_rc == 0 )); then
    run kubectl get service "${service}" -n "${namespace}" -o wide --show-labels
    run kubectl get service "${service}" -n "${namespace}" -o yaml
  elif grep -qi 'not found' <<< "${service_check}"; then
    echo "INFO: Service ${service_ref} is absent."
  else
    echo "ERROR: Could not inspect Service ${service_ref}: ${service_check}" >&2
  fi
done

section "ServiceLB DaemonSets and pods"
run kubectl get daemonsets -n kube-system -l svccontroller.k3s.cattle.io/svcname -o wide --show-labels
run kubectl get pods -n kube-system -l svccontroller.k3s.cattle.io/svcname -o wide --show-labels

section "Istio placement and endpoints"
run kubectl get deployments,pods -n "${ISTIO_NAMESPACE}" -o wide --show-labels
run kubectl get endpoints "${ISTIO_SERVICE}" -n "${ISTIO_NAMESPACE}" -o wide
run kubectl get endpointslices.discovery.k8s.io -n "${ISTIO_NAMESPACE}" -l "kubernetes.io/service-name=${ISTIO_SERVICE}" -o yaml

section "Traffic-policy and scheduling fields"
run kubectl get service "${ISTIO_SERVICE}" -n "${ISTIO_NAMESPACE}" -o jsonpath='{.metadata.name}{" externalTrafficPolicy="}{.spec.externalTrafficPolicy}{" internalTrafficPolicy="}{.spec.internalTrafficPolicy}{" trafficDistribution="}{.spec.trafficDistribution}{" healthCheckNodePort="}{.spec.healthCheckNodePort}{"\n"}'
run kubectl get deployment -n "${ISTIO_NAMESPACE}" -l istio=ingressgateway -o jsonpath='{range .items[*]}{.metadata.name}{" nodeSelector="}{.spec.template.spec.nodeSelector}{" affinity="}{.spec.template.spec.affinity}{" topologySpreadConstraints="}{.spec.template.spec.topologySpreadConstraints}{"\n"}{end}'

section "Recent placement-related events"
run kubectl get events -A --sort-by=.lastTimestamp --field-selector type=Warning

section "Compact summary"
run kubectl get node "${TARGET_NODE}" -o jsonpath='{.metadata.name}{" ready="}{.status.conditions[?(@.type=="Ready")].status}{" internalIP="}{.status.addresses[?(@.type=="InternalIP")].address}{" externalIP="}{.status.addresses[?(@.type=="ExternalIP")].address}{" enablelb="}{.metadata.labels.svccontroller\.k3s\.cattle\.io/enablelb}{" lbpool="}{.metadata.labels.svccontroller\.k3s\.cattle\.io/lbpool}{"\n"}'

echo
echo "END OF SNAPSHOT"
