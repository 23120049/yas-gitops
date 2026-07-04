# GCP single-node YAS runtime

This VM runs Kubernetes workloads only. GitHub Actions builds and publishes all
application images; no Maven, Node.js, or Docker build tooling is required on
the VM.

## 1. Install K3s

Run on the `yas-k3s` VM. Replace `<STATIC_PUBLIC_IP>` with the reserved GCP IP.

```sh
curl -sfL https://get.k3s.io | sudo sh -s - server \
  --disable traefik \
  --tls-san <STATIC_PUBLIC_IP> \
  --write-kubeconfig-mode 640

sudo systemctl enable --now k3s
sudo kubectl get nodes -o wide
sudo kubectl get storageclass
```

K3s uses containerd, so Docker is not needed. The bundled `local-path`
StorageClass provides persistent volumes on the VM's 200 GB persistent disk.

## 2. Install Istio before GitOps policies

```sh
curl -L https://istio.io/downloadIstio | sh -
cd istio-*
sudo cp bin/istioctl /usr/local/bin/istioctl
istioctl install --set profile=demo -y
sudo kubectl get pods -n istio-system
```

K3s Traefik is disabled so the Istio ingress gateway can own ports 80 and 443.

## 3. Install Argo CD

```sh
sudo kubectl create namespace argocd
sudo kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
sudo kubectl rollout status deployment/argocd-server -n argocd --timeout=5m
```

Read the initial password:

```sh
sudo kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Use an SSH/IAP tunnel for the UI until Istio routing for Argo CD is explicitly
configured:

```sh
sudo kubectl port-forward -n argocd service/argocd-server 8080:443
```

## 4. Configure private GHCR access if required

Skip this section when all `ghcr.io/23120049/*` packages are public. Otherwise,
create a GitHub token with `read:packages`, then run:

```sh
sudo kubectl create namespace dev --dry-run=client -o yaml | sudo kubectl apply -f -
sudo kubectl create namespace staging --dry-run=client -o yaml | sudo kubectl apply -f -

for ns in dev staging; do
  sudo kubectl -n "$ns" create secret docker-registry ghcr-pull \
    --docker-server=ghcr.io \
    --docker-username='<GITHUB_USERNAME>' \
    --docker-password='<GITHUB_READ_PACKAGES_TOKEN>'
  sudo kubectl -n "$ns" patch serviceaccount default \
    -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}'
done
```

Do not commit the token to either repository.

## 5. Bootstrap GitOps

Review, commit, and push the local `yas-gitops` and `yas-helm` changes before
this step. Argo CD reads GitHub, not the developer's local working tree.

```sh
sudo kubectl apply -f \
  https://raw.githubusercontent.com/23120049/yas-gitops/main/bootstrap/root.yaml
```

Watch the dependency rollout:

```sh
sudo kubectl get applications -n argocd -w
sudo kubectl get pods -n infra -w
```

Expected order:

1. PostgreSQL, Strimzi, ECK, and Keycloak operators
2. PostgreSQL, Redis, Kafka, Elasticsearch, Keycloak
3. Dev and staging configuration
4. Dev and staging application workloads

## 6. Verify the core platform

```sh
sudo kubectl get nodes
sudo kubectl get pods -A
sudo kubectl get pvc -A
sudo kubectl get kafka,kafkanodepool,kafkaconnect -n infra
sudo kubectl get elasticsearch,kibana -n infra
sudo kubectl get keycloak -n infra
sudo kubectl get postgresql -n infra
```

Core internal endpoints:

- PostgreSQL: `postgresql.infra:5432`
- Redis: `redis-master.infra:6379`
- Kafka: `yas-kafka-kafka-bootstrap.infra:9092`
- Elasticsearch: `elasticsearch-es-http.infra:9200`
- Keycloak: `keycloak-service.infra` (operator-generated service; verify name)

## 7. Group access

Each member signs in with their own Google identity and connects through IAP:

```sh
gcloud compute ssh yas-k3s \
  --project=cedar-helper-501413-j3 \
  --zone=asia-southeast1-b \
  --tunnel-through-iap
```

Administrative Kubernetes commands use `sudo kubectl`. Do not distribute the
K3s admin kubeconfig or a shared SSH private key.

