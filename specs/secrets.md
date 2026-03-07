deployment.apps/external-secrets-cert-controller serverside-applied
deployment.apps/external-secrets serverside-applied
deployment.apps/external-secrets-webhook serverside-applied
validatingwebhookconfiguration.admissionregistration.k8s.io/secretstore-validate serverside-applied
validatingwebhookconfiguration.admissionregistration.k8s.io/externalsecret-validate serverside-applied
namespace/secret-store serverside-applied
serviceaccount/eso-store-sa serverside-applied
clusterrole.rbac.authorization.k8s.io/eso-secret-store-reader serverside-applied
clusterrolebinding.rbac.authorization.k8s.io/eso-secret-store-reader serverside-applied
persistentvolumeclaim/registry serverside-applied
service/registry serverside-applied
deployment.apps/registry serverside-applied
Error from server (InternalError): Internal error occurred: failed calling webhook "validate.clustersecretstore.external-secrets.io": failed to call webhook: Post "https://external-secrets-webhook.external-secrets.svc:443/validate-external-secrets-io-v1-clustersecretstore?timeout=5s": no endpoints available for service "external-secrets-webhook"
# HOW-TO: Adding and Managing Secrets

This guide explains how secrets flow through the cluster, how to add a new
secret, and the edge cases to watch for.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Secret Categories](#secret-categories)
3. [Step-by-Step: Adding a New Secret](#step-by-step-adding-a-new-secret)
4. [Edge Cases](#edge-cases)
5. [Retrieving Secrets](#retrieving-secrets)
6. [Reference: All Source Secrets](#reference-all-source-secrets)

---

## Architecture Overview

All application secrets are managed through a three-stage pipeline:

```
Stage 1: Generation          Stage 2: Storage           Stage 3: Distribution
(bootstrap Job)              (secret-store namespace)   (ESO ExternalSecrets)

┌─────────────────┐    ┌──────────────────────┐    ┌─────────────────────────┐
│ generate-secrets │───>│ secret-store/         │───>│ windmill/               │
│ Job (alpine)     │    │   windmill-pg-creds   │    │   windmill-pg-creds     │
│                  │    │   authelia            │    │                         │
│ openssl rand     │    │   basic-git-creds     │    │ authelia/               │
│ ssh-keygen       │    │   lldap-credentials   │    │   authelia              │
│ openssl genrsa   │    │   ...                 │    │                         │
└─────────────────┘    └──────────────────────┘    │ argocd/                 │
                              ▲                     │   argocd-repo-basic-git │
                              │                     │                         │
                        ClusterSecretStore          │ basic-git/              │
                        (kubernetes provider)       │   basic-git-ssh-keys    │
                              │                     │   ...                   │
                        ┌─────┴──────┐              └─────────────────────────┘
                        │ ESO        │─────────────────────────┘
                        │ Operator   │
                        └────────────┘
```

### Stage 1: Generation (`cluster/bootstrap/secret-generator.nix`)

A Kubernetes Job running in the `secret-store` namespace. Uses an `alpine`
image with `openssl`, `openssh-keygen`, and `kubectl`. Generates random
values and writes them as K8s Secrets into `secret-store`.

**Idempotent** — if a secret already exists, the Job skips it. This means
secrets survive cluster restarts and re-applies. Deleting a source secret
and re-running the Job will regenerate it (with new random values).

### Stage 2: Storage (`secret-store` namespace)

A dedicated namespace that acts as the single source of truth for all
application secrets. Nothing runs here — it's purely a storage namespace.

The External Secrets Operator's `ClusterSecretStore` (named `kubernetes`)
is configured to read from this namespace using the Kubernetes provider.

### Stage 3: Distribution (`cluster/modules/external-secrets/`)

The ESO module in the management set defines `ExternalSecret` CRs. Each CR
tells ESO to read keys from a source secret in `secret-store` and create a
target secret in the application's namespace.

ESO owns the target secrets (`creationPolicy: Owner`). It re-syncs every
hour by default.

### What lives where

| Component | Location | Deployed by |
|-----------|----------|-------------|
| ESO operator + CRDs | `external-secrets` namespace | Bootstrap (`cluster/bootstrap/default.nix`) |
| ClusterSecretStore + RBAC | `external-secrets` namespace | Bootstrap (via ESO module) |
| `secret-store` namespace | — | Bootstrap (via ESO module's `sourceNamespace`) |
| Generator Job + RBAC | `secret-store` namespace | Bootstrap (`cluster/bootstrap/secret-generator.nix`) |
| Source secrets | `secret-store` namespace | Generator Job |
| ExternalSecret CRs | Per-app namespaces | Management set (`cluster/sets/management/default.nix`) |
| Target secrets | Per-app namespaces | ESO (created automatically from ExternalSecrets) |

---

## Secret Categories

### 1. Random credentials (most common)

Generated with `openssl rand -hex <length>`. Examples: database passwords,
session keys, HMAC secrets, JWT secrets, API keys.

```sh
openssl rand -hex 24   # 48-char hex string — good for passwords
openssl rand -hex 32   # 64-char hex string — good for encryption keys
```

### 2. Cryptographic keys

Generated with specific tools:

| Type | Tool | Example |
|------|------|---------|
| Ed25519 SSH keypair | `ssh-keygen -t ed25519` | basic-git credentials |
| RSA 2048 private key | `openssl genrsa 2048` | Authelia OIDC JWKS |

### 3. Static values

Not generated — hardcoded strings baked into the source secret alongside
generated values. Examples: usernames, email addresses, LDAP base DNs,
OIDC client secret strings.

### 4. Derived values

Composed from other generated values. Example: a database URL that
embeds the generated password:

```
postgres://windmill:$PASSWORD@windmill-pg-rw.windmill.svc:5432/windmill?sslmode=require
```

These must be generated in the same Job invocation as the password they
reference, since the Job is idempotent and won't re-read an existing
secret to compose a new one.

### 5. Cross-referenced values

A value from one source secret that must appear in another. Example:
the LLDAP admin password must also appear in the Authelia secret as
`authentication.ldap.password.txt`.

The generator Job handles this by storing the value in a shell variable
and reusing it across multiple `kubectl create secret` calls.

---

## Step-by-Step: Adding a New Secret

### Example: Adding secrets for a new app called `myapp`

Suppose `myapp` needs a database password and a session key.

### 1. Add generation to the bootstrap Job

Edit `cluster/bootstrap/secret-generator.nix`. Add your secret inside the
Job's shell script, following the existing pattern:

```sh
# ── MyApp ──
MYAPP_PG_PASS=$(openssl rand -hex 24)
create_secret myapp-pg-credentials \
  --from-literal=username=myapp \
  --from-literal=password="$MYAPP_PG_PASS"

create_secret myapp-session \
  --from-literal=key="$(openssl rand -hex 32)"
```

The `create_secret` helper is idempotent — it skips creation if the secret
already exists.

**If you also need a derived secret** (e.g. a database URL), generate it
in the same block while the password variable is still in scope:

```sh
create_secret myapp-db-url \
  --from-literal=url="postgres://myapp:$MYAPP_PG_PASS@myapp-pg-rw.myapp.svc.cluster.local:5432/myapp?sslmode=require"
```

### 2. Add ExternalSecret mappings in the management set

Edit `cluster/sets/management/default.nix`, in the
`apps.external-secrets.config.secrets` block:

```nix
myapp-pg-credentials = { namespace = "myapp"; keys = [ "username" "password" ]; };
myapp-db-url         = { namespace = "myapp"; keys = [ "url" ]; };
myapp-session        = { namespace = "myapp"; keys = [ "key" ]; };
```

This tells ESO: read the source secret `myapp-pg-credentials` from
`secret-store`, and create a target secret with the same name in the
`myapp` namespace containing the listed keys.

### 3. Reference the secret in your app module

In your app's Helm values or raw resources, reference the target secret:

```nix
# In helm.nix
defaults = {
  env = [
    { name = "DATABASE_URL"; valueFrom.secretKeyRef = {
      name = "myapp-db-url"; key = "url";
    }; }
    { name = "SESSION_KEY"; valueFrom.secretKeyRef = {
      name = "myapp-session"; key = "key";
    }; }
  ];
};
```

### 4. Test

```sh
# Rebuild manifests
nix build .#manifests

# Check the ExternalSecret was generated
nix build .#management-external-secrets && cat result | grep myapp

# Check the bootstrap secret-generator includes your secret
nix build .#bootstrap && cat result | grep myapp
```

---

## Edge Cases

### Key renaming

When the source key name doesn't match what the app expects, use the
`{sourceKey, targetKey}` form:

```nix
basic-git-ssh-keys = {
  namespace = "basic-git";
  remoteSecretName = "basic-git-credentials";
  keys = [
    { sourceKey = "sshPublicKey"; targetKey = "authorized_keys"; }
  ];
};
```

`sourceKey` is the key in the `secret-store` source secret.
`targetKey` is the key in the target secret the app sees.

### Different source and target secret names

By default, the ESO mapping name is used as both the source secret name
(in `secret-store`) and the target secret name (in the app namespace).
Override with `remoteSecretName` when they differ:

```nix
argocd-repo-basic-git = {
  namespace = "argocd";
  remoteSecretName = "basic-git-credentials";   # source in secret-store
  # target secret name defaults to "argocd-repo-basic-git"
  keys = [
    { sourceKey = "sshPrivateKey"; targetKey = "sshPrivateKey"; }
  ];
};
```

### Mixing static and dynamic values (templateData)

Some target secrets need a mix of generated values (from ESO) and static
values (hardcoded). Use `templateData` for the static parts:

```nix
argocd-repo-basic-git = {
  namespace = "argocd";
  remoteSecretName = "basic-git-credentials";
  labels = { "argocd.argoproj.io/secret-type" = "repository"; };
  templateData = {
    type = "git";
    url = "ssh://git@basic-git.basic-git.svc.cluster.local/srv/git/manifests.git";
    insecure = "true";
  };
  keys = [
    { sourceKey = "sshPrivateKey"; targetKey = "sshPrivateKey"; }
  ];
};
```

The resulting target secret contains both the static `type`, `url`,
`insecure` keys and the dynamic `sshPrivateKey` from ESO.

Under the hood, ESO's `template.data` uses Go template syntax. The module
automatically generates `{{ .sshPrivateKey }}` placeholders for each key
entry alongside the static values.

### Adding labels to target secrets

Some consumers require specific labels on secrets (e.g. ArgoCD repo
secrets need `argocd.argoproj.io/secret-type: repository`). Use the
`labels` option:

```nix
my-secret = {
  namespace = "argocd";
  labels = { "argocd.argoproj.io/secret-type" = "repository"; };
  keys = [ "token" ];
};
```

### Cross-referenced secrets

When two source secrets must share a value (e.g. LLDAP admin password =
Authelia LDAP bind password), generate it once and use the shell variable
in both `create_secret` calls within the Job script:

```sh
LLDAP_PASS=$(openssl rand -hex 16)

create_secret lldap-credentials \
  --from-literal=lldap-ldap-user-pass="$LLDAP_PASS" \
  ...

create_secret authelia \
  --from-literal=authentication.ldap.password.txt="$LLDAP_PASS" \
  ...
```

**Caution:** Because the Job is idempotent (skips existing secrets), if
you delete only one of the two cross-referenced secrets and re-run the
Job, the regenerated secret will have a different password than the
surviving one. Always delete both and re-run together, or delete neither.

### Derived secrets and ordering

Derived secrets (like database URLs) must be generated in the same
`create_secret` block as the password they embed. The `create_secret`
helper skips each secret independently, so if the password secret exists
but the URL secret doesn't, the Job will try to create the URL with a
freshly-generated password that won't match the existing one.

**Fix:** Always treat a set of related secrets (e.g. `myapp-pg-credentials`
+ `myapp-db-url`) as atomic. If you need to regenerate, delete all of them:

```sh
kubectl -n secret-store delete secret myapp-pg-credentials myapp-db-url
```

Then re-run the Job (delete and re-apply, or let ArgoCD sync).

### SSH keypairs

SSH keys require special handling because `kubectl create secret` can't
generate them inline. The Job uses a temp directory:

```sh
if ! kubectl -n "$NS" get secret my-ssh-credentials >/dev/null 2>&1; then
  TMPDIR=$(mktemp -d)
  ssh-keygen -t ed25519 -C "description" -N "" -f "$TMPDIR/id" >/dev/null 2>&1
  kubectl -n "$NS" create secret generic my-ssh-credentials \
    --from-file=sshPrivateKey="$TMPDIR/id" \
    --from-file=sshPublicKey="$TMPDIR/id.pub"
  rm -rf "$TMPDIR"
fi
```

Note: `--from-file` is used instead of `--from-literal` because the
private key contains newlines.

### Re-running the generator Job

The Job has a fixed name (`generate-secrets`). Kubernetes won't re-run a
completed Job. To re-run it:

```sh
kubectl -n secret-store delete job generate-secrets
```

Then re-apply the bootstrap manifests. ArgoCD or `kubectl apply` will
recreate the Job, and it will run again (skipping existing secrets).

### Host-level secrets (not managed here)

The following secrets are **not** part of this system. They are generated
on the NixOS host via `clan.core.vars.generators` and used outside
Kubernetes:

| Generator | Purpose |
|-----------|---------|
| `generators/user-ssh.nix` | Nathan's SSH key for host access |
| `generators/k3s.nix` | K3s cluster join token |
| `generators/wireguard.nix` | WireGuard VPN keys |

Do not add these to the bootstrap Job or ESO config.

---

## Retrieving Secrets

### Read a source secret

```sh
kubectl -n secret-store get secret <name> -o jsonpath='{.data.<key>}' | base64 -d
```

### Read a target secret (in app namespace)

```sh
kubectl -n <namespace> get secret <name> -o jsonpath='{.data.<key>}' | base64 -d
```

### Check ESO sync status

```sh
kubectl get externalsecret -A
```

Look for `SecretSynced` condition = `True`.

### Force ESO to re-sync

```sh
kubectl annotate externalsecret -n <namespace> <name> force-sync=$(date +%s) --overwrite
```

---

## Reference: All Source Secrets

Every secret in `secret-store` and its keys:

| Source secret | Keys | Type |
|---------------|------|------|
| `lldap-credentials` | `lldap-jwt-secret`, `lldap-key-seed`, `lldap-ldap-user-name`, `lldap-ldap-user-email`, `lldap-ldap-user-pass`, `base-dn` | random + static |
| `authelia` | `authentication.ldap.password.txt`, `session.encryption.key`, `storage.encryption.key`, `identity_validation.reset_password.jwt.hmac.key`, `identity_providers.oidc.hmac_secret`, `identity_providers.oidc.jwks.0.key` | random + cross-ref + RSA key |
| `argocd-oidc-secret` | `oidc.authelia.clientSecret` | static |
| `windmill-pg-credentials` | `username`, `password` | static + random |
| `windmill-db-url` | `url` | derived |
| `windmill-oidc-secret` | `clientSecret` | static |
| `harbor-oidc-secret` | `clientSecret` | static |
| `platform-pg-credentials` | `username`, `password` | static + random |
| `librechat-credentials-env` | `CREDS_KEY`, `CREDS_IV`, `JWT_SECRET`, `JWT_REFRESH_SECRET`, `MEILI_MASTER_KEY` | random |
| `docuseal-pg-credentials` | `username`, `password` | static + random |
| `docuseal-db-url` | `url` | derived |
| `docuseal-credentials-env` | `SECRET_KEY_BASE` | random |
| `nextcloud-pg-credentials` | `username`, `password` | static + random |
| `nextcloud-credentials` | `admin-user`, `admin-password` | static + random |
| `nextcloud-oidc-secret` | `clientSecret` | static |
| `basic-git-credentials` | `sshPrivateKey`, `sshPublicKey` | SSH keypair |
| `default-runner-secret` | `secret` | random |
| `opencode-runner-secret` | `secret` | random |

### ExternalSecret option reference

| Option | Default | Description |
|--------|---------|-------------|
| `namespace` | (required) | Target namespace for the synced secret |
| `keys` | (required) | List of key mappings (string or `{sourceKey, targetKey}`) |
| `remoteSecretName` | same as entry name | Source secret name in `secret-store` |
| `targetSecretName` | same as entry name | Target secret name in the app namespace |
| `refreshInterval` | `"1h"` | How often ESO re-syncs |
| `labels` | `{}` | Extra labels on the target secret |
| `templateData` | `{}` | Static key/value pairs mixed into the target secret |
