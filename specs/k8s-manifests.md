# K8s Manifest System — Build, Output & Deployment

How the Nix module system produces Kubernetes YAML manifests for both the
management cluster and tenant clusters, and how to add new apps to each.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Directory Layout](#directory-layout)
3. [Build Pipeline](#build-pipeline)
4. [Management vs Tenant Clusters](#management-vs-tenant-clusters)
5. [HOW-TO: Add a New App to the Management Cluster](#how-to-add-a-new-app-to-the-management-cluster)
6. [HOW-TO: Add a New App to the Tenant Cluster](#how-to-add-a-new-app-to-the-tenant-cluster)
7. [HOW-TO: Add an Existing Management App to Tenants](#how-to-add-an-existing-management-app-to-tenants)
8. [Deployment Flow](#deployment-flow)
9. [Tenant Bootstrap](#tenant-bootstrap)
10. [Checklist Reference](#checklist-reference)

---

## Architecture Overview

The system uses **NixOS-style modules** (`lib.evalModules`) to declare
Kubernetes resources as Nix attrsets.  Each app is a reusable module under
`cluster/modules/`.  Application sets enable and parameterize modules for a
specific cluster type.

The architecture uses a **single sub-flake** (`cluster/flake.nix`) that
auto-discovers both modules and application sets:

| Component | Path | Purpose |
|---|---|---|
| **Sub-flake** | `cluster/flake.nix` | Auto-discovers modules + sets, runs mkCluster per set |
| **Modules** | `cluster/modules/<name>/` | Auto-discovered app modules (28 total) |
| **Base options** | `cluster/modules/default.nix` | Declares `cluster.domain`, `cluster.resources`, `cluster.argocd` |
| **Management set** | `cluster/sets/management/default.nix` | Enables/configures apps for `cia.net` |
| **Tenant set** | `cluster/sets/tenant/default.nix` | Enables/configures apps for tenant clusters |
| **mkCluster** | `cluster/lib/mkCluster.nix` | Evaluates a set → packages, manifests, ArgoCD Application CRs |

```
cluster/flake.nix  (single sub-flake — auto-discovers everything)
  │
  ├── Auto-discovers modules: builtins.readDir ./modules
  │     → [ ./modules ./modules/argo-cd ./modules/authelia ... ]
  │
  ├── Auto-discovers sets: builtins.readDir ./sets
  │     → [ "management", "tenant" ]
  │
  └── For each set, calls mkCluster { config, prefix, appModules }:
        │
        ├── lib.evalModules(appModules ++ [ setConfig ])
        ├── Generates per-chart YAML: <prefix>-<name> packages
        ├── Generates ArgoCD Application CRs from cluster.argocd metadata
        └── Builds manifest directory: <prefix>/helm/<name>/manifests.yaml

cluster/lib/
  ├── yaml.nix          YAML primitives (fromHelm, toYAMLStreamFile, charts)
  ├── k8s.nix           K8s resource constructors (mkApp, mkDeployment, etc.)
  ├── istio.nix         VirtualService constructors (mgmtVs, tenantVs)
  └── mkCluster.nix     config → { packages, manifests, evaluated }
```

### Key principle: shared modules, separate configs

App modules are generic.  They declare options (`cluster.apps.<name>.*`) and
produce K8s resources.  They never hardcode cluster-specific values like
domain names or OIDC clients.  All cluster-specific values come from the
application set layer:

- Management config: `cluster/sets/management/default.nix`
- Tenant config: `cluster/sets/tenant/default.nix`

### Zero-maintenance discovery

Both modules and application sets are auto-discovered via `builtins.readDir`.
Adding a new module requires only creating a directory under `cluster/modules/`.
Adding a new cluster type requires only creating a directory under
`cluster/sets/`.  No lists or flake files need updating.

### Dynamic ArgoCD Application CRs

ArgoCD Application CRs are generated automatically by `mkCluster.nix` for
every app that produces resources.  Modules that need special ArgoCD behavior
(server-side apply, namespace override, non-default project) declare it via
`cluster.argocd.<name>` in their config block.  There is no `apps.nix` file.

---

## Directory Layout

```
cluster/
  flake.nix                    # Sub-flake: auto-discovers modules + sets, calls mkCluster
  flake.lock                   # Pinned dependency hashes
  lib/
    yaml.nix                   # YAML primitives (fromHelm, toYAMLStreamFile, charts)
    k8s.nix                    # K8s resource constructors (mkApp, mkDeployment, etc.)
    istio.nix                  # VirtualService constructors (mgmtVs, tenantVs)
    mkCluster.nix              # config → { packages, manifests, evaluated }
  modules/
    default.nix                # Base options: cluster.domain, cluster.resources, cluster.argocd
    <name>/                    # Auto-discovered app modules (one dir per app)
      default.nix              # Module: options + config
      helm.nix                 # Helm chart rendering (optional)
      resources.nix            # Pure Nix K8s resources (alternative to Helm)
      ...                      # Extra files (seed jobs, patches, etc.)
  sets/
    management/
      default.nix              # Management application set (cluster.domain = "cia.net")
      bootstrap.nix            # Bootstrap resources for fresh cluster
    tenant/
      default.nix              # Tenant application set (cluster.domain = "cia.net")
      cilium.nix               # Standalone Cilium render for ClusterResourceSet injection
```

### App modules (auto-discovered from `cluster/modules/`)

```
modules/
  argo-cd/           # ArgoCD GitOps controller
  authelia/          # Authelia SSO/OIDC provider
  cert-manager/      # cert-manager TLS controller
  cilium/            # Cilium CNI
  cilium-policies/   # CiliumNetworkPolicy passthrough
  cloudnative-pg/    # CNPG operator + database instances
  cluster-template/  # CAPI cluster template (k3s + OVN)
  dirigible/         # Eclipse Dirigible IDE
  docuseal/          # DocuSeal document signing
  external-secrets/  # External Secrets operator
  forgejo/           # Forgejo git hosting
  forgejo-runner/    # Forgejo Actions runners
  harbor/            # Harbor container registry
  istio-base/        # Istio base CRDs
  istiod/            # Istiod control plane
  istio-gateway/     # Istio ingress gateway
  istio-routing/     # Gateway + VirtualServices + AuthorizationPolicy
  librechat/         # LibreChat AI chat
  lldap/             # LLDAP lightweight LDAP server
  lldap-operator/    # LLDAP Kubernetes operator CRDs
  nextcloud/         # Nextcloud (disabled, replaced by OpenCloud)
  opencloud/         # OpenCloud file sync & collaboration
  pgweb/             # pgweb PostgreSQL web client
  self-signed-cert/  # Self-signed CA + wildcard certificates
  trust-manager/     # trust-manager CA bundle distribution
  victoriametrics/   # VictoriaMetrics monitoring stack
  windmill/          # Windmill workflow engine
```

---

## Build Pipeline

### 1. Nix evaluation

`cluster/flake.nix` auto-discovers modules and application sets, then calls
`mkCluster` (from `cluster/lib/mkCluster.nix`) for each set.  `mkCluster`
runs `lib.evalModules` with the shared modules plus the set's config module:

```nix
# Inside mkCluster.nix:
evaluated = lib.evalModules {
  specialArgs = { inherit pkgs yaml k8s istio; };
  modules = appModules ++ [ config ];   # config = ./sets/<name>
};
```

### 2. YAML serialization

Each app's resource list is converted to a YAML stream file via
`yaml.toYAMLStreamFile`.  This produces one Nix derivation per app.

Chart names are derived automatically from `builtins.attrNames resources`
— there is no hardcoded chart list.

### 3. ArgoCD Application CRs

`mkCluster.nix` generates ArgoCD Application CRs dynamically for every app
that has entries in `cluster.resources`.  It reads `cluster.argocd.<name>`
metadata (serverSideApply, namespace override, project) to configure each
Application CR.  No `apps.nix` file is needed.

### 4. Manifests package

`mkCluster` produces a `<prefix>-manifests` package that arranges all
derivations into a directory tree:

```
<prefix>/
  helm/<name>/manifests.yaml        # Per-app K8s manifests
  apps/manifests.yaml               # Auto-generated ArgoCD Application CRs
```

### 5. Combined manifests

`cluster/flake.nix` merges all per-set manifest trees into a single
`manifests` package.  It also adds `management-bootstrap` (the only
set-specific extra).

### 6. Git push to manifests branch

The combined `manifests` tree is pushed to the `manifests` branch of the
Forgejo repo.  ArgoCD watches this branch.

### Build commands

```sh
# Build a single management app:
nix build .#management-authelia && cat result

# Build a single tenant app:
nix build .#tenant-authelia && cat result

# Build all manifests (management + tenant):
nix build .#manifests

# List all available packages:
nix eval .#packages.x86_64-linux --apply 'builtins.attrNames' --impure
```

---

## Management vs Tenant Clusters

### Management cluster (`portal.net`)

The management cluster runs the full platform:

- **Infrastructure**: ArgoCD, Forgejo, Harbor, cert-manager, trust-manager,
  Cilium, Istio
- **Auth stack**: LLDAP + Authelia (OIDC provider for all apps)
- **Apps**: OpenCloud (with Collabora), LibreChat, DocuSeal, Windmill,
  Dirigible, Mathesar, pgweb, VictoriaMetrics (with Grafana), and the
  TradePortal staging/production deployments
- **Database**: CloudNativePG operator with 6 databases (windmill, nextcloud,
  dirigible, joget, docuseal, platform)
- **TLS**: Self-signed CA for `*.portal.net` + Let's Encrypt for `tradecrm.ltd`
- **Network policies**: Cilium policies for LLDAP access control

Config: `cluster/sets/management/default.nix`.

### Tenant clusters (`change.me`)

Tenant clusters run a subset of apps.  They are provisioned by the
management cluster via Cluster API and deployed to via management ArgoCD
(remote clusters via ApplicationSets).

- **Infrastructure**: cert-manager, Cilium, Istio (full mesh)
- **Auth stack**: per-tenant LLDAP + Authelia
- **Apps**: OpenCloud (with Collabora), LibreChat, DocuSeal, Mathesar
- **Database**: CloudNativePG operator with 3 databases (nextcloud, docuseal,
  mathesar)
- **TLS**: Self-signed CA for `*.change.me`

Config: `cluster/sets/tenant/default.nix`.

**Domain model**: Every tenant cluster uses `change.me` as its internal
domain.  Platform-dns in the management cluster resolves tenant domains
dynamically from the platform database.  The actual external domain
(assigned per-tenant) is handled by the management platform's DNS and Istio
routing.

---

## HOW-TO: Add a New App to the Management Cluster

This section covers the full lifecycle.  For detailed module authoring
patterns, see [nix-module-apps.md](./nix-module-apps.md).

### 1. Create the app module

```sh
mkdir -p cluster/modules/my-app
```

Create `cluster/modules/my-app/default.nix`:

```nix
{ config, lib, yaml, k8s, ... }:
let
  cfg = config.cluster.apps.my-app;
in
{
  options.cluster.apps.my-app = {
    enable = lib.mkEnableOption "My App";
    namespace = lib.mkOption {
      type = lib.types.str;
      default = "my-app";
    };
    # Add app-specific options here
  };

  config = lib.mkIf cfg.enable {
    cluster.resources.my-app = import ./helm.nix {
      inherit yaml cfg;
    };
  };
}
```

Create `cluster/modules/my-app/helm.nix`:

```nix
{ yaml, cfg }:
yaml.fromHelm {
  name = "my-app";
  chart = yaml.charts.<repo>.<chart>;
  namespace = cfg.namespace;
  values = {
    # Helm values, parameterized via cfg.*
  };
}
```

### 2. Auto-discovery (no registration needed)

Modules are auto-discovered from `cluster/modules/`.  Creating the directory
and staging it with `git add` is all that's needed — no list to update.

### 3. Add management config

In `cluster/sets/management/default.nix`:

```nix
cluster.apps.my-app = {
  enable = true;
  # set required options
};
```

### 4. (Optional) Add ArgoCD metadata

ArgoCD Application CRs are generated automatically.  If the app needs
special ArgoCD behavior (server-side apply for CRDs, namespace override),
add `cluster.argocd.<name>` in the module's config block:

```nix
config = lib.mkIf cfg.enable {
  cluster.argocd.my-app.serverSideApply = true;
  cluster.resources.my-app = import ./helm.nix { inherit yaml cfg; };
};
```

### 5. If the app needs Istio routing

Add a VirtualService to the `cluster.apps.istio-routing.virtualServices`
list in `cluster/sets/management/default.nix`.  Use the `mgmtVs` helper for
standard services or hand-craft the attrset for custom routing (e.g. Harbor
X-Forwarded-Proto, staging/production websocket split).  Do NOT emit
VirtualService resources from the app module itself.

### 6. If the app needs a database

Add a database entry to `cluster.apps.cloudnative-pg.databases` in
`cluster/sets/management/default.nix`.  Do NOT emit CNPG Cluster resources from
the app module.

### 7. Test

```sh
git add cluster/modules/my-app/
nix build .#management-my-app && cat result     # check YAML output
nix build .#manifests                            # full build, no regressions
```

---

## HOW-TO: Add a New App to the Tenant Cluster

Same process as management, with these differences:

### 1. Create the app module (same as management)

Module goes in `cluster/modules/my-app/`.  The module is shared — it should
not contain any management-specific or tenant-specific hardcoded values.

**Important**: If the module references `config.cluster.domain` or passes it
to `helm.nix`, it will automatically use the correct domain (`portal.net`
for management, `change.me` for tenant).

### 2. Auto-discovery (no registration needed)

If the module is new, create the directory under `cluster/modules/` and
stage it with `git add`.  If the module already exists, skip this step.

### 3. Add tenant config

In `cluster/sets/tenant/default.nix`:

```nix
cluster.apps.my-app = {
  enable = true;
  # set tenant-specific values
};
```

### 4. ArgoCD Application CRs (automatic)

ArgoCD Application CRs are generated automatically for every enabled app.
No `apps.nix` entry is needed.  If the app requires server-side apply,
add `cluster.argocd.<name>.serverSideApply = true` in the module's config
block (same as management — see step 4 above).

### 5. If the app needs Istio routing

Add a VirtualService to `cluster.apps.istio-routing.virtualServices` in
`cluster/sets/tenant/default.nix`, using the `tenantVs` helper and `change.me`
as the domain.

### 6. If the app needs a database

Add a database to `cluster.apps.cloudnative-pg.databases` in
`cluster/sets/tenant/default.nix`.

### 7. Test

```sh
git add cluster/modules/my-app/
nix build .#tenant-my-app && cat result
nix build .#manifests
```

---

## HOW-TO: Add an Existing Management App to Tenants

If an app module already exists in `cluster/modules/` and is used by the
management cluster, adding it to tenants requires only config changes — no
new module code.

### Steps

1. **Check module parameterization**.  Verify the module doesn't hardcode
   domain-specific values in `helm.nix`.  If it does, refactor them into
   options or pass `config.cluster.domain` through (see how `librechat` and
   `authelia` were refactored).

2. **Add config** in `cluster/sets/tenant/default.nix`.

3. **ArgoCD Application CRs are automatic** — no `apps.nix` entry needed.

4. **Add Istio routing** in the tenant `istio-routing` config if the app
   needs ingress.

5. **Add database** in the tenant `cloudnative-pg` config if needed.

6. **Test**: `nix build .#tenant-<name> && cat result`

### Common refactoring patterns

When adapting a management-only module for shared use:

| Problem | Solution |
|---|---|
| Hardcoded `portal.net` in `helm.nix` | Pass `clusterDomain = config.cluster.domain` from `default.nix` to `helm.nix` and interpolate with `${clusterDomain}` |
| Hardcoded access control rules | Add an `accessControlRules` option (list of attrs), move rules to the config block |
| Hardcoded OIDC clients | Already parameterized via `oidcClients` option in most modules |
| Hardcoded session cookies | Add a `sessionCookies` option, move cookie list to the config block |

---

## Deployment Flow

### Management cluster

```
 nix build .#manifests
       │
       ▼
 management/helm/<name>/manifests.yaml  ──push──▶  manifests branch
 management/apps/manifests.yaml                     (Forgejo git repo)
       │
       ▼
 ArgoCD root Application                            watches management/apps/
       │
       ▼
 Per-app Application CRs                            watches management/helm/<name>/
       │
       ▼
 Auto-sync (prune + selfHeal)                       to local cluster
       │                                             (kubernetes.default.svc)
       ▼
 Resources applied to management cluster
```

### Tenant clusters

```
 nix build .#manifests
       │
       ▼
 tenant/helm/<name>/manifests.yaml      ──push──▶  manifests branch
 tenant/apps/manifests.yaml                         (same Forgejo repo)
       │
       ▼
 Tenant ApplicationSets                             cluster generator:
 (deployed by management ArgoCD)                    cluster-type=tenant
       │
       ▼
 Per-cluster Applications created                   watches tenant/helm/<name>/
       │
       ▼
 Auto-sync to REMOTE tenant clusters                (registered via argocd-secret)
```

The management ArgoCD has tenant clusters registered as remote destinations
via Secrets.  Tenant ArgoCD Application CRs are auto-generated by
`mkCluster.nix` and live in `tenant/apps/manifests.yaml`.

---

## Tenant Bootstrap

Tenant clusters are provisioned via Cluster API using the cluster-template
module (`cluster/modules/cluster-template/`) (k3s + OVN/LXC).  The bootstrap
sequence:

1. **Provision the cluster**: The cluster-template module generates CAPI
   resources (Cluster, LXCCluster, KThreesControlPlane, LXCMachineTemplate,
   ClusterResourceSet).  Apply via `kubectl apply`.

2. **Register with ArgoCD**: Apply the ArgoCD cluster secret with TLS
   client cert auth and the `cluster-type: tenant` label.

3. **Cilium bootstrap**: A `ClusterResourceSet` in the cluster-template
   module auto-applies Cilium to any cluster labeled `cni=cilium`.  The
   Cilium config is rendered from `cluster/sets/tenant/cilium.nix`.

4. **ArgoCD Applications take over**: Once the cluster is registered and
   labeled, the auto-generated tenant ArgoCD Applications sync manifests
   from `tenant/helm/*/manifests.yaml`.

5. **Self-signed cert**: The tenant self-signed-cert module creates a
   self-signed CA in-cluster via cert-manager.

---

## Checklist Reference

### Adding a management app

- [ ] Module created: `cluster/modules/<name>/default.nix` + `helm.nix` (or `resources.nix`)
- [ ] Config added in `cluster/sets/management/default.nix`
- [ ] (If needed) `cluster.argocd.<name>` set for serverSideApply/namespace override
- [ ] VirtualService added to `istio-routing` config (if app needs ingress)
- [ ] Database added to `cloudnative-pg` config (if app needs PostgreSQL)
- [ ] Files staged: `git add cluster/modules/<name>/`
- [ ] `nix build .#management-<name> && cat result` produces correct YAML
- [ ] `nix build .#manifests` succeeds

### Adding a tenant app

- [ ] Module exists in `cluster/modules/<name>/` (create if new; reuse if existing)
- [ ] Module has no hardcoded domain values (uses `config.cluster.domain` or options)
- [ ] Config added in `cluster/sets/tenant/default.nix`
- [ ] (If needed) `cluster.argocd.<name>` set for serverSideApply/namespace override
- [ ] VirtualService added to tenant `istio-routing` config (if needed)
- [ ] Database added to tenant `cloudnative-pg` config (if needed)
- [ ] `nix build .#tenant-<name> && cat result` produces correct YAML
- [ ] `nix build .#manifests` succeeds
