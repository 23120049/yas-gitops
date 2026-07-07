# Istio ingress is placed on the wrong k3s node

## Summary

The YAS Istio ingress gateway is intended to be exposed through node
`laptop-hh13kan9` at Tailscale IP `100.124.113.25`. The live cluster instead
exposes it through node `itaco` at `100.111.221.78`.

Traefik currently owns host ports `80` and `443` on `laptop-hh13kan9`, which
prevents the Istio ServiceLB pod from running there. Neither LoadBalancer
Service nor the nodes have explicit k3s ServiceLB pool labels, so placement is
determined accidentally by whichever ServiceLB pod obtains the host ports.

**Status:** Confirmed

**Severity:** High for external YAS access

## Expected behavior

External YAS traffic should follow this path:

```text
Client
  -> 100.124.113.25
  -> laptop-hh13kan9
  -> Istio ingress gateway
  -> YAS Kubernetes Services
```

The expected state is:

- `istio-ingressgateway` advertises `100.124.113.25`.
- A running `svclb-istio-ingressgateway-*` pod is scheduled on
  `laptop-hh13kan9`.
- Traefik does not bind ports `80/443` on `laptop-hh13kan9`.
- Istio and Traefik use explicit, non-overlapping ServiceLB pools.

## Actual behavior

The live state is:

```text
Istio external IP:          100.111.221.78
Istio ServiceLB node:       itaco
Expected Istio external IP: 100.124.113.25
Expected Istio node:        laptop-hh13kan9
```

Traefik is running a ServiceLB pod on `laptop-hh13kan9` and advertises
`100.124.113.25`. Istio has four Pending ServiceLB pods and only one Running
ServiceLB pod, on `itaco`.

Observed Istio placement:

```text
NAME                                        PHASE     NODE
svclb-istio-ingressgateway-508e0c5d-5qtts   Pending   <none>
svclb-istio-ingressgateway-508e0c5d-htlxm   Pending   <none>
svclb-istio-ingressgateway-508e0c5d-nf5mv   Running   itaco
svclb-istio-ingressgateway-508e0c5d-p85nq   Pending   <none>
svclb-istio-ingressgateway-508e0c5d-xz7gc   Pending   <none>
```

The scheduler reports:

```text
0/5 nodes are available:
1 node didn't have free ports for the requested pod ports,
4 nodes didn't satisfy NodeAffinity.
```

## Impact

- Requests sent to the intended address `100.124.113.25` reach Traefik rather
  than the YAS Istio gateway.
- Hosts-file or DNS entries that map `*.yas.local.com` to `100.124.113.25` do
  not reach the intended ingress controller.
- The currently working Istio endpoint depends on `itaco` and
  `100.111.221.78`.
- If `itaco` becomes unavailable, external access through Istio stops.
- Pending ServiceLB pods continuously produce scheduling warnings.
- Bootstrap can appear healthy without enforcing the intended ingress address
  unless `EXPECTED_INGRESS_IP` is supplied.

Internal Kubernetes networking is not implicated. Preflight checks confirmed
that cluster DNS, Pod-to-Pod traffic, Pod-to-Service traffic, storage, and
external egress work correctly.

## Root cause

k3s ServiceLB implements each `LoadBalancer` Service with a DaemonSet whose
pods bind the Service ports using `hostPort`.

Both Traefik and Istio request host ports `80` and `443`. The cluster has no
explicit ServiceLB placement configuration:

- The Istio Service has no `svccontroller.k3s.cattle.io/lbpool` label.
- The Traefik Service has no `svccontroller.k3s.cattle.io/lbpool` label.
- The intended node does not have
  `svccontroller.k3s.cattle.io/enablelb=true`.
- Nodes are not divided into matching Istio and Traefik pools.

Consequently, both ServiceLB DaemonSets compete for the same host ports.
Traefik obtained them on `laptop-hh13kan9`; Istio obtained them on `itaco`.

## Reproduction and diagnosis

Run the repository's read-only diagnostic:

```bash
cd /mnt/c/Users/huyen/source/repos/yas-gitops
bash ./scripts/diagnose-ingress-placement.sh
```

The confirmed result is:

```text
Diagnosis: 4 confirmed issue(s), 5 warning(s).
VERDICT: REAL ISSUE — Istio ingress is not placed on the intended node/IP.
```

Useful manual checks:

```bash
kubectl get svc -n istio-system istio-ingressgateway --show-labels
kubectl get svc -n kube-system traefik --show-labels
kubectl get pods -n kube-system -o wide | grep '^svclb-'
kubectl get nodes --show-labels
kubectl get nodes -o wide
```

## Proposed remediation

Create two explicit ServiceLB pools:

- Pool `istio`: `laptop-hh13kan9`
- Pool `traefik`: `desktop-a3m6ffm`, `hg`, `itaco`, and `yas-k3s`

Enable ServiceLB only on explicitly assigned nodes:

```bash
kubectl label nodes \
  desktop-a3m6ffm hg itaco laptop-hh13kan9 yas-k3s \
  svccontroller.k3s.cattle.io/enablelb=true \
  --overwrite
```

Assign node pools:

```bash
kubectl label node laptop-hh13kan9 \
  svccontroller.k3s.cattle.io/lbpool=istio \
  --overwrite

kubectl label nodes desktop-a3m6ffm hg itaco yas-k3s \
  svccontroller.k3s.cattle.io/lbpool=traefik \
  --overwrite
```

Assign the Services to matching pools:

```bash
kubectl label service istio-ingressgateway -n istio-system \
  svccontroller.k3s.cattle.io/lbpool=istio \
  --overwrite

kubectl label service traefik -n kube-system \
  svccontroller.k3s.cattle.io/lbpool=traefik \
  --overwrite
```

These labels should also be represented in the declarative Helm/k3s
configuration so that upgrades or reconciliation do not remove them.

## Acceptance criteria

The bug is resolved only when all of the following are true:

1. The diagnostic exits successfully:

   ```bash
   bash ./scripts/diagnose-ingress-placement.sh
   ```

2. Istio advertises the intended address:

   ```bash
   kubectl get service istio-ingressgateway -n istio-system \
     -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
   ```

   Expected output:

   ```text
   100.124.113.25
   ```

3. The Istio ServiceLB pod runs on `laptop-hh13kan9`.

4. Traefik has no running ServiceLB pod on `laptop-hh13kan9` and does not
   advertise `100.124.113.25`.

5. There are no Pending Istio ServiceLB pods caused by host-port conflicts.

6. Deployment is run with an address assertion:

   ```bash
   EXPECTED_INGRESS_IP=100.124.113.25 \
   ALLOW_NON_MAIN_BOOTSTRAP=true \
   ./scripts/bootstrap.sh
   ```

## Availability note

Correcting placement restores the intended design but does not make ingress
highly available. `laptop-hh13kan9` remains a single ingress node. High
availability requires at least one additional Istio-capable node and a stable
address or external load balancer that can fail over between those nodes.
