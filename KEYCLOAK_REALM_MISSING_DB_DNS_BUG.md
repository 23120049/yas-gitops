# Keycloak realm missing because PostgreSQL host is not resolvable

## Summary

Opening `http://dev-backoffice.yas.local.com` redirects to Keycloak, but
Keycloak returns a `Page not found` screen.

The redirect itself is working. The failure happens after the browser reaches:

```text
http://identity.yas.local.com/realms/Yas/protocol/openid-connect/auth
```

## Observed error

The OpenID Connect discovery endpoint returns:

```text
HTTP/1.1 404 Not Found
{"error":"Realm does not exist"}
```

The failing endpoint is:

```text
http://identity.yas.local.com/realms/Yas/.well-known/openid-configuration
```

The `KeycloakRealmImport` resource exists:

```text
NAME           AGE
yas-realm-kc   3d5h
```

Keycloak is also running:

```text
keycloak-0   1/1   Running
```

However, Keycloak logs show repeated database connection failures:

```text
Caused by: java.net.UnknownHostException: postgresql.infra
```

## Root cause

The Keycloak custom resource was configured with this database host:

```yaml
host: postgresql.infra
```

Keycloak cannot resolve that hostname from the pod, so it cannot reliably reach
PostgreSQL. Because Keycloak stores realms and clients in PostgreSQL, the `Yas`
realm is unavailable or was never successfully imported.

That is why the browser reaches Keycloak but receives:

```text
Realm does not exist
```

This is not primarily an Istio routing issue. Istio is routing
`identity.yas.local.com` to Keycloak successfully.

## Current repo status

Latest local repo check shows the issue is not fully fixed yet.

`yas-gitops` now contains the intended Keycloak value override:

```yaml
postgresql:
  host: postgresql.infra.svc.cluster.local
  database: keycloak
  port: 5432
```

However, `yas-helm/deploy/keycloak/keycloak/templates/keycloak.yaml` still
hardcodes the old database host:

```yaml
spec:
  db:
    host: postgresql.infra
    database: keycloak
    port: 5432
```

Because the Helm template does not read `.Values.postgresql.host`, Argo CD will
still render the broken host even though the GitOps values file is correct.
This means the bug remains until the `yas-helm` chart is updated.

## Recommended fix

Configure Keycloak to use the fully qualified Kubernetes service DNS name for
PostgreSQL:

```yaml
postgresql:
  host: postgresql.infra.svc.cluster.local
  database: keycloak
  port: 5432
```

The Helm chart should render these values into the Keycloak CR:

```yaml
spec:
  db:
    vendor: postgres
    host: {{ .Values.postgresql.host | quote }}
    database: {{ .Values.postgresql.database | quote }}
    port: {{ .Values.postgresql.port }}
```

The `yas-helm/deploy/keycloak/keycloak/values.yaml` defaults should include:

```yaml
postgresql:
  username: yasadminuser
  password: admin
  host: postgresql.infra.svc.cluster.local
  database: keycloak
  port: 5432
```

After applying the chart/value change:

```bash
kubectl get svc postgresql -n infra
kubectl get keycloak keycloak -n infra -o yaml | grep -A8 "db:"
kubectl rollout restart statefulset/keycloak -n infra
kubectl logs -n infra keycloak-0 --tail=100
curl -i http://identity.yas.local.com/realms/Yas/.well-known/openid-configuration
```

If the PostgreSQL DNS error is gone but the realm still does not exist, re-sync
or recreate the `KeycloakRealmImport` so the `Yas` realm import runs again.

## Expected result

The discovery endpoint should return `200 OK` with OpenID Connect metadata:

```text
http://identity.yas.local.com/realms/Yas/.well-known/openid-configuration
```

After that, `dev-backoffice.yas.local.com` should redirect to a real Keycloak
login page instead of the Keycloak `Page not found` screen.
