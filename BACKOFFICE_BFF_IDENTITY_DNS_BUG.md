# Phase 5 BFF startup failure: invalid Keycloak issuer hostname

## Summary

The GitOps bootstrap stops during phase 5 because `backoffice-bff` enters
`CrashLoopBackOff`. Spring Boot attempts OpenID Connect discovery through the
hostname `identity`, but no Kubernetes Service or DNS record named `identity`
exists.

The same configuration is present in `storefront-bff`, so it is expected to
fail after `backoffice-bff` is repaired unless both services are fixed.

## Observed failure

The application exits with code 1 during Spring context initialization:

```text
Unable to resolve Configuration with the provided Issuer of
"http://identity/realms/Yas"

GET http://identity/realms/Yas/.well-known/openid-configuration

Caused by: java.net.UnknownHostException: identity
```

The affected pod remains partially ready because the Istio sidecar is healthy
while the application container repeatedly crashes:

```text
READY   STATUS
1/2     CrashLoopBackOff
```

Phase 5 waits for every workload Argo CD Application to become Healthy.
`backoffice-bff-dev` never becomes Healthy, so bootstrap exits before phase 6.
Consequently, the absence of phase-6 Istio `Gateway` and `VirtualService`
resources is a downstream effect, not the cause of this failure.

## Evidence

The live shared ConfigMap contains the intended resource-server settings:

```yaml
issuer-uri: http://identity.yas.local.com/realms/Yas
jwk-set-uri: http://keycloak-service.infra/realms/Yas/protocol/openid-connect/certs
```

The BFF-specific ConfigMap also contains valid explicit provider endpoints:

```yaml
spring:
  security:
    oauth2:
      client:
        provider:
          keycloak:
            authorization-uri: http://identity.yas.local.com/realms/Yas/protocol/openid-connect/auth
            token-uri: http://keycloak-service.infra/realms/Yas/protocol/openid-connect/token
            jwk-set-uri: http://keycloak-service.infra/realms/Yas/protocol/openid-connect/certs
            user-info-uri: http://keycloak-service.infra/realms/Yas/protocol/openid-connect/userinfo
```

The required Keycloak and Redis Secrets exist. Despite those correct live
resources, the process still uses `http://identity/realms/Yas`, demonstrating
that the value comes from application configuration packaged in the image.

The source of the stale setting is:

```text
yas/backoffice-bff/src/main/resources/application.yaml
yas/storefront-bff/src/main/resources/application.yaml
```

Both files define:

```yaml
spring:
  security:
    oauth2:
      client:
        provider:
          keycloak:
            issuer-uri: http://identity/realms/Yas
```

## Root cause

The BFF container image includes an obsolete OAuth provider `issuer-uri`.
Spring Boot sees this property and performs issuer discovery during startup.
The explicit `authorization-uri`, `token-uri`, `jwk-set-uri`, and
`user-info-uri` supplied by GitOps do not remove the packaged `issuer-uri`.

Kubernetes DNS cannot resolve the short hostname `identity` because the actual
Keycloak Service is:

```text
keycloak-service.infra.svc.cluster.local
```

The workstation hosts-file entry for `identity.yas.local.com` does not create a
DNS record inside Kubernetes pods.

## Impact

- `backoffice-bff` enters `CrashLoopBackOff`.
- The `backoffice-bff-dev` Argo CD Application cannot become Healthy.
- Bootstrap phase 5 times out or fails.
- Phase 6 routing is never applied.
- `storefront-bff` is vulnerable to the same startup failure.
- External YAS URLs remain unavailable because deployment never completes.

## Immediate GitOps mitigation

Override the packaged issuer in both `backofficeBffExtraConfig` and
`storefrontBffExtraConfig` while retaining the explicit Keycloak endpoints.
The override must make Spring ignore issuer discovery; for the current Spring
Boot property binding, this can be expressed as:

```yaml
provider:
  keycloak:
    issuer-uri: ""
```

Render the Helm chart before deployment and confirm that the resulting
ConfigMaps contain the empty override plus all four explicit provider
endpoints. Then sync both configuration Applications and restart both BFF
Deployments.

## Permanent fix

Remove the obsolete `issuer-uri: http://identity/realms/Yas` property from both
BFF source configuration files. The BFFs already receive environment-specific
provider endpoints from GitOps, so the image should not embed a cluster DNS
assumption.

After changing the source:

1. Build and publish new `backoffice-bff` and `storefront-bff` images.
2. Update their GitOps image tags.
3. Sync the configuration and workload Applications.
4. Verify both Deployments become Ready.
5. Rerun bootstrap so phase 5 completes and phase 6 installs Istio routing.

## Verification

```bash
kubectl logs -n dev deployment/backoffice-bff -c backoffice-bff --tail=200
kubectl logs -n dev deployment/storefront-bff -c storefront-bff --tail=200

kubectl rollout status deployment/backoffice-bff -n dev
kubectl rollout status deployment/storefront-bff -n dev

kubectl get applications -n argocd
kubectl get gateway,virtualservice -A
```

Successful startup must no longer contain requests to:

```text
http://identity/realms/Yas/.well-known/openid-configuration
```

