# HOW-TO: Creating a Cluster App Module

This guide explains how to add a new application to the cluster by creating a
NixOS-style module under `cluster/modules/`.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Module Patterns](#module-patterns)
3. [Step-by-Step: Creating a New Module](#step-by-step-creating-a-new-module)
4. [Option Design Guidelines](#option-design-guidelines)
5. [Common Nix Patterns Reference](#common-nix-patterns-reference)
6. [Available specialArgs](#available-specialargs)
7. [Checklist](#checklist)

---

## Architecture Overview

The cluster configuration is built in three layers:

### Layer 1: Base Options (`cluster/modules/default.nix`)

Declares the top-level options that every module uses:

```nix
options.cluster = {
  domain    = lib.mkOption { type = lib.types.str; };
  resources = lib.mkOption {
    type    = lib.types.attrsOf (lib.types.listOf lib.types.attrs);
    default = {};
  };
  argocd    = lib.mkOption {
    type    = lib.types.attrsOf (lib.types.submodule { ... });
    default = {};
  };
};
```

- **`cluster.domain`** — The primary domain for the cluster (e.g. `cia.net`).
- **`cluster.resources`** — A keyed attrset where each module contributes its
  K8s resources: `cluster.resources.<app-name> = [ ...k8s-attrsets... ];`
- **`cluster.argocd`** — Per-app ArgoCD metadata (namespace override,
  serverSideApply, project).  Modules that need special ArgoCD behavior set
  `cluster.argocd.<name>` in their config block.

### Layer 2: App Modules (`cluster/modules/<name>/default.nix`)

Each module declares its own options under `cluster.apps.<name>` and, when
enabled, populates `cluster.resources.<name>` with a list of K8s resource
attrsets (Deployments, Services, ConfigMaps, CRDs, etc.).

Modules are **auto-discovered** — any directory under `cluster/modules/` is
automatically imported.  There is no manual module list to maintain.

### Layer 3: Application Sets (`cluster/sets/<name>/default.nix`)

Each cluster type has an application set module:

- **Management**: `cluster/sets/management/default.nix` — enables and configures
  apps for the management cluster (`cia.net`).
- **Tenant**: `cluster/sets/tenant/default.nix` — enables and configures apps
  for tenant clusters (`cia.net`).

Application sets are also **auto-discovered** — any directory under
`cluster/sets/` is automatically picked up by `cluster/flake.nix`.

### How It All Fits Together

```
cluster/flake.nix  (single sub-flake — auto-discovers everything)
  │
  ├── Auto-discovers modules: builtins.readDir ./modules
  │     → [ ./modules ./modules/argo-cd ./modules/authelia ... ]
  │
  ├── Auto-discovers sets: builtins.readDir ./sets
  │     → [ "management", "tenant" ]
  │
  └── For each set, calls mkCluster:
        │
        ├── lib.evalModules
        │     specialArgs = { pkgs, yaml, k8s, istio }
        │     modules = appModules ++ [ ./sets/<name> ]
        │
        ├── evaluated.config.cluster.resources → { argo-cd = [...]; authelia = [...]; ... }
        │
        ├── evaluated.config.cluster.argocd   → ArgoCD metadata per app
        │
        ├── Generates ArgoCD Application CRs dynamically from resources + argocd metadata
        │
        └── yaml.toYAMLStreamFile per app     → <prefix>-<name> packages
```

The final output is an attrset of YAML stream derivations — one per app —
plus auto-generated ArgoCD Application CRs, written to
`<prefix>/helm/<name>/manifests.yaml` by the manifests package.

Chart names are derived automatically from `builtins.attrNames resources`
— there is no hardcoded chart list.  Modules that aren't enabled simply
produce no resources and are omitted from the output.

ArgoCD Application CRs are generated dynamically by `cluster/lib/mkCluster.nix`
from the `cluster.argocd` metadata.  There is no `apps.nix` file to maintain.

---

## Module Patterns

There are five patterns used across the codebase. Pick the one that fits.

### Pattern 1: Helm-Only (simplest)

Use when: the app is a straightforward Helm chart with no post-processing.

**Examples:** cert-manager, cilium, docuseal, forgejo, mathesar, pgweb,
victoriametrics

**Structure:**
```
cluster/modules/my-app/
  default.nix    # module: options + config
  helm.nix       # Helm chart values → list of K8s attrsets
```

**`default.nix`:**
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

    values = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Helm chart value overrides, deep-merged with module defaults.";
    };
  };

  config = lib.mkIf cfg.enable {
    cluster.resources.my-app = import ./helm.nix {
      inherit lib yaml cfg;
    };
  };
}
```

**`helm.nix`:**
```nix
{ lib, yaml, cfg }:
let
  defaults = {
    ingress.enabled = false;
    # ... chart values ...
  };
in
yaml.fromHelm {
  name = "my-app";
  chart = yaml.charts.<repo>.<chart>;
  namespace = cfg.namespace;
  values = lib.recursiveUpdate defaults cfg.values;
}
```

`yaml.fromHelm` returns a list of K8s resource attrsets. That list is
assigned directly to `cluster.resources.my-app`.

The `values` option allows the application set to override or extend any
nested helm value without modifying the module itself. Module defaults are
defined in the `defaults` let-binding inside `helm.nix`, and
`lib.recursiveUpdate` deep-merges `cfg.values` on top of those defaults.
This means the caller only needs to specify the keys they want to change.

### Pattern 2: Helm + Post-Processing

Use when: the Helm chart output needs patching (e.g. injecting env vars,
fixing missing namespaces, mounting CA certs).

**Examples:** windmill, dirigible, librechat, lldap, nextcloud

**`helm.nix` with post-processing:**
```nix
{ lib, yaml, cfg }:
let
  defaults = { ... };

  rawHelm = yaml.fromHelm {
    name = "my-app";
    chart = yaml.charts.<repo>.<chart>;
    namespace = cfg.namespace;
    values = lib.recursiveUpdate defaults cfg.values;
  };

  # Ensure every resource has a namespace (some charts omit it)
  setNamespace = r: r // {
    metadata = (r.metadata or {}) // { namespace = cfg.namespace; };
  };

  # Inject an env var into all Deployments
  patchDeployment = r:
    if (r.kind or "") == "Deployment" then
      r // {
        spec = r.spec // {
          template = r.spec.template // {
            spec = r.spec.template.spec // {
              containers = map (c: c // {
                env = (c.env or []) ++ [
                  { name = "MY_VAR"; value = "my-value"; }
                ];
              }) r.spec.template.spec.containers;
            };
          };
        };
      }
    else r;

in
map (r: patchDeployment (setNamespace r)) rawHelm
```

**Common post-processing operations:**

| Operation | Pattern |
|-----------|---------|
| Set namespace on all resources | `map setNamespace resources` |
| Inject env vars into Deployments | `map patchDeployment resources` where patchDeployment drills into `spec.template.spec.containers` |
| Add volumes/volumeMounts | Same drill-down pattern, appending to `volumes` and `volumeMounts` lists |
| Fix null lists from Helm | `orEmpty = v: if v == null then [] else v;` then use `(orEmpty (c.env or null)) ++ newVars` |
| Prepend extra resources | `[ myConfigMap ] ++ helmResources` |
| Chain multiple transforms | `map (r: transform2 (transform1 r)) rawHelm` or compose named functions |

### Pattern 3: Raw Resources (no Helm)

Use when: the resources are simple enough to declare as Nix attrsets directly,
or you're passing through raw attrsets from the config.

**Examples:** cilium-policies, istio-routing, opencloud, forgejo-runner,
production, staging

The `opencloud` module is a notable example — it generates all K8s resources
(Deployments, Services, ConfigMaps, PVCs) as pure Nix attrsets in
`resources.nix` with no Helm chart involved.

**`default.nix` (passthrough pattern):**
```nix
{ config, lib, yaml, k8s, ... }:
let
  cfg = config.cluster.apps.my-policies;
in
{
  options.cluster.apps.my-policies = {
    enable = lib.mkEnableOption "My policies";

    policies = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [];
      description = "List of raw K8s policy resource attrsets.";
    };
  };

  config = lib.mkIf cfg.enable {
    cluster.resources.my-policies = cfg.policies;
  };
}
```

The config then passes the actual resource attrsets:

```nix
cluster.apps.my-policies = {
  enable = true;
  policies = [
    {
      apiVersion = "cilium.io/v2";
      kind = "CiliumNetworkPolicy";
      metadata = { name = "my-policy"; namespace = "my-ns"; };
      spec = { ... };
    }
  ];
};
```

**`default.nix` (pure resources pattern, like opencloud):**
```nix
{ config, lib, yaml, k8s, ... }:
let
  cfg = config.cluster.apps.my-app;
in
{
  options.cluster.apps.my-app = {
    enable = lib.mkEnableOption "My App";
    namespace = lib.mkOption { type = lib.types.str; default = "my-app"; };
    domain = lib.mkOption { type = lib.types.str; };
    # ... more options ...
  };

  config = lib.mkIf cfg.enable {
    cluster.resources.my-app = import ./resources.nix { inherit cfg; };
  };
}
```

Where `resources.nix` returns a list of hand-crafted K8s resource attrsets.

### Pattern 4: Helm + Conditional Extras

Use when: the module has optional features that add extra K8s resources
(e.g. a setup Job, a seed script).

**Examples:** harbor (OIDC setup Job), lldap (group seed Job)

**`default.nix`:**
```nix
config = lib.mkIf cfg.enable {
  cluster.resources.my-app =
    (import ./helm.nix { inherit lib yaml cfg; })
    ++ (lib.optionals cfg.oidc.enable (import ./oidc-setup.nix { inherit cfg; }));
};
```

The extra file (e.g. `oidc-setup.nix`) takes `{ cfg }` and returns a list
of K8s resource attrsets (typically a Job, ConfigMap, etc.).

### Pattern 5: Submodule (attrsOf submodule)

Use when: the module manages a dynamic collection of similar things
(databases, runner instances, ExApps, etc.).

**Examples:** cloudnative-pg (databases), harp (exapps)

**`default.nix` with submodule:**
```nix
{ config, lib, yaml, k8s, ... }:
let
  cfg = config.cluster.apps.my-app;

  mkResource = name: sub: {
    apiVersion = "example.io/v1";
    kind = "MyResource";
    metadata = { inherit name; namespace = sub.namespace; };
    spec = { size = sub.size; };
  };
in
{
  options.cluster.apps.my-app = {
    enable = lib.mkEnableOption "My App";

    things = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          namespace = lib.mkOption { type = lib.types.str; };
          size = lib.mkOption {
            type = lib.types.str;
            default = "5Gi";
          };
        };
      }));
      default = {};
    };
  };

  config = lib.mkIf cfg.enable {
    cluster.resources.my-app =
      (import ./helm.nix { inherit lib yaml cfg; })
      ++ (lib.mapAttrsToList mkResource cfg.things);
  };
}
```

Use `lib.mapAttrsToList` to turn the submodule attrset into a list of
resources. Use `lib.concatLists (lib.mapAttrsToList ...)` if each entry
produces multiple resources.

Useful submodule patterns:

| Pattern | Use |
|---------|-----|
| `lib.types.nullOr lib.types.str` | Optional string (e.g. credentialSecretName that defaults to null) |
| `lib.optionalAttrs (x != null) { ... }` | Conditionally include an attrset field |
| `lib.filterAttrs (_: v: v.enable) cfg.things` | Filter to only enabled sub-items |
| Default derived from key: `default = "${name}-pg"` | The `name` arg in the submodule function is the attrset key |

---

## Step-by-Step: Creating a New Module

### 1. Create the directory

```sh
mkdir -p cluster/modules/my-app
```

### 2. Write `default.nix`

Start from the Helm-only skeleton (Pattern 1) and adjust:

```nix
# cluster/modules/my-app — Short description
{ config, lib, yaml, k8s, ... }:
let
  cfg = config.cluster.apps.my-app;
in
{
  options.cluster.apps.my-app = {
    enable = lib.mkEnableOption "My App description";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "my-app";
    };

    values = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Helm chart value overrides, deep-merged with module defaults.";
    };

    # Add app-specific options here
  };

  config = lib.mkIf cfg.enable {
    cluster.resources.my-app = import ./helm.nix {
      inherit lib yaml cfg;
    };
  };
}
```

If you need `pkgs` (for `pkgs.fetchurl`, `pkgs.runCommand`, `pkgs.lib`,
etc.), add it to the module function args:

```nix
{ config, lib, pkgs, yaml, k8s, ... }:
```

If you need `config.cluster.domain`, access it in the config block and pass
it to helm.nix:

```nix
config = lib.mkIf cfg.enable {
  cluster.resources.my-app = import ./helm.nix {
    inherit yaml cfg;
    clusterDomain = config.cluster.domain;
  };
};
```

### 3. Write `helm.nix`

```nix
{ lib, yaml, cfg }:
let
  defaults = {
    # Helm chart values, parameterized by cfg.*
    ingress.enabled = false;
  };
in
yaml.fromHelm {
  name = "my-app";
  chart = yaml.charts.<repo>.<chart>;
  namespace = cfg.namespace;
  values = lib.recursiveUpdate defaults cfg.values;
}
```

For charts not in nixhelm, you can fetch manually:

```nix
{ lib, yaml, cfg, pkgs }:
let
  chart = pkgs.runCommand "my-chart" {} ''
    mkdir -p $out
    tar xzf ${pkgs.fetchurl {
      url = "https://example.com/charts/my-chart-1.0.0.tgz";
      hash = "sha256-AAAA...";
    }} -C $out --strip-components=1
  '';
in
yaml.fromHelm {
  name = "my-app";
  inherit chart;
  namespace = cfg.namespace;
  values = { ... };
}
```

Or use `yaml.downloadHelmChart`:

```nix
chart = yaml.downloadHelmChart {
  repo = "https://example.com/charts/";
  chart = "my-chart";
  version = "1.0.0";
  chartHash = "sha256-AAAA...";
};
```

### 4. Auto-discovery (no registration needed)

Modules are auto-discovered from `cluster/modules/` by `cluster/flake.nix`.
Any directory under `cluster/modules/` that contains a `default.nix` is
automatically imported into every cluster evaluation.

There is no module list to update.  Simply creating the directory is enough.

Since the module is guarded by `lib.mkIf cfg.enable`, it produces no
resources unless explicitly enabled in an application set's config.

### 5. Add config in the application set

For the management cluster, edit `cluster/sets/management/default.nix`:

```nix
# ── My App ───────────────────────────────────────────────────────
cluster.apps.my-app = {
  enable = true;
  # set any required options
};
```

For the tenant cluster, edit `cluster/sets/tenant/default.nix` instead.

### 6. (Optional) Add ArgoCD metadata

ArgoCD Application CRs are generated **automatically** by
`cluster/lib/mkCluster.nix` for every app that has entries in
`cluster.resources`.  No `apps.nix` file exists.

By default, the generated Application uses the app's `namespace` option
and standard client-side apply.  If the app needs special ArgoCD behavior
(e.g. server-side apply for CRDs), declare it in the module's `config` block:

```nix
config = lib.mkIf cfg.enable {
  cluster.argocd.my-app = {
    serverSideApply = true;       # needed if chart installs CRDs
    # namespace = "custom-ns";    # override destination namespace
    # project = "infra";          # non-default ArgoCD project
  };

  cluster.resources.my-app = import ./helm.nix { inherit lib yaml cfg; };
};
```

### 7. Stage files for flake visibility

Nix flakes only see files tracked by git. Stage your new files:

```sh
git add cluster/modules/my-app/
```

### 8. Test

```sh
# Quick evaluation check (no build):
nix build .#management-my-app --dry-run

# Full build (produces the YAML stream):
nix build .#management-my-app && cat result

# Full manifests build (all charts):
nix build .#manifests
```

For tenant apps, replace `management-` with `tenant-`.

---

## Option Design Guidelines

### What to parameterize

- **Always parameterize:** `enable`, `namespace`, `values`
- **Parameterize if it varies per-cluster:** domain names, CA cert paths,
  database connection details, OIDC endpoints, persistence sizes
- **Parameterize if it's a meaningful behavioral switch:** feature flags
  (e.g. `collabora.enable`, `oidc.enable`), enum modes
  (e.g. `policyEnforcementMode`)

### What to hardcode

- **Helm chart references** (`yaml.charts.<repo>.<chart>`) — these change
  via nixhelm flake input, not per-cluster
- **Container images** from the chart (the chart controls these)
- **Internal wiring** (service names like
  `my-app.my-app.svc.cluster.local`) — these are determined by the Helm
  chart and namespace
- **Scrape intervals, retention periods, replica counts** — unless you have
  a concrete reason to vary them across clusters

### Option types reference

| Type | Use for |
|------|---------|
| `lib.types.str` | Domain names, namespace names, secret names |
| `lib.types.int` | Replica counts, port numbers |
| `lib.types.bool` | Feature flags (prefer `mkEnableOption` for `enable`) |
| `lib.types.path` | File paths (CA certs, config files) — evaluated at nix eval time |
| `lib.types.enum [...]` | Fixed set of choices |
| `lib.types.listOf lib.types.str` | Lists of domains, SQL statements |
| `lib.types.listOf lib.types.attrs` | Lists of raw K8s resource attrsets |
| `lib.types.attrs` | Single raw K8s resource attrset |
| `lib.types.attrsOf (lib.types.submodule ...)` | Dynamic collections |
| `lib.types.nullOr lib.types.str` | Optional values that default to null |

---

## Common Nix Patterns Reference

### Guard the config block

Every module wraps its config in `lib.mkIf`:

```nix
config = lib.mkIf cfg.enable {
  cluster.resources.my-app = [ ... ];
};
```

### Conditional resources

Append extra resources only when a feature is enabled:

```nix
cluster.resources.my-app =
  (import ./helm.nix { inherit lib yaml cfg; })
  ++ (lib.optionals cfg.feature.enable (import ./feature.nix { inherit cfg; }));
```

### Conditional attrset fields

Include a field only when a value is non-null or non-empty:

```nix
spec = {
  instances = 1;
}
// lib.optionalAttrs (secretName != null) {
  secret.name = secretName;
}
// lib.optionalAttrs (initSQL != []) {
  postInitSQL = initSQL;
};
```

### Read files at eval time

```nix
caCert = builtins.readFile cfg.caCertFile;
```

This embeds the file contents into the Nix expression. Use `lib.types.path`
for the option type.

### Null coercion for Helm output

Helm renders missing YAML lists as `null`. Coerce to empty list:

```nix
orEmpty = v: if v == null then [] else v;

# Usage:
env = (orEmpty (c.env or null)) ++ newEnvVars;
```

### Generate resources from a submodule

```nix
lib.mapAttrsToList (name: sub: {
  apiVersion = "...";
  kind = "...";
  metadata = { inherit name; namespace = sub.namespace; };
  spec = { ... };
}) cfg.things
```

If each entry produces multiple resources, flatten with:

```nix
lib.concatLists (lib.mapAttrsToList (name: sub:
  import ./thing.nix { inherit cfg name sub; }
) cfg.things)
```

### Filter enabled items in a submodule

```nix
enabledThings = lib.filterAttrs (_: v: v.enable) cfg.things;
```

### Indexed iteration

```nix
lib.imap0 (i: item: "${toString i}: ${item}") myList
```

---

## Available specialArgs

These are passed to every module via `lib.evalModules { specialArgs = ... }`:

### `yaml`

Produced by `cluster/lib/yaml.nix`. Key functions:

| Function | Returns | Use |
|----------|---------|-----|
| `yaml.fromHelm { name, chart, namespace, values, ... }` | `listOf attrs` | Render a Helm chart to a list of K8s resource attrsets |
| `yaml.toYAMLStreamFile resources` | `derivation` | Convert a list of K8s attrsets to a `---`-separated YAML file |
| `yaml.charts` | `attrs` | Attrset of all Helm charts from nixhelm, keyed by `<repo>.<chart>` |
| `yaml.downloadHelmChart { repo, chart, version, chartHash }` | `path` | Fetch a chart tarball not in nixhelm |

`yaml.fromHelm` accepts an optional `extraOpts` parameter (list of strings)
for additional Helm flags, e.g. `extraOpts = ["--skip-schema-validation"]`.

### `k8s`

Produced by `cluster/lib/k8s.nix`. Key functions:

| Function | Returns | Use |
|----------|---------|-----|
| `k8s.mkApp { name, path, ... }` | `attrs` | Create an ArgoCD Application resource |
| `k8s.mkNamespace name` | `attrs` | Create a Namespace resource |
| `k8s.mkConfigMap { name, namespace, data }` | `attrs` | Create a ConfigMap |
| `k8s.mkSecret { name, namespace, ... }` | `attrs` | Create a Secret |
| `k8s.mkDeployment { name, namespace, ... }` | `attrs` | Create a Deployment |
| `k8s.mkService { name, namespace, ... }` | `attrs` | Create a Service |
| `k8s.mkPVC { name, namespace, ... }` | `attrs` | Create a PersistentVolumeClaim |
| `k8s.mkCNPGCluster { name, namespace, ... }` | `attrs` | Create a CNPG Cluster resource |

### `pkgs`

The full nixpkgs package set. Available as a module arg:

```nix
{ config, lib, pkgs, yaml, k8s, ... }:
```

Commonly used for:
- `pkgs.lib` (when you need `lib` inside `helm.nix` which doesn't get it as an arg)
- `pkgs.fetchurl` (fetching chart tarballs)
- `pkgs.runCommand` (unpacking/patching charts)

### `config`

The evaluated module config. Access other modules' options:

```nix
clusterDomain = config.cluster.domain;       # "portal.net" or "change.me"
otherAppEnabled = config.cluster.apps.other.enable;
```

---

## Checklist

Before submitting a new module:

- [ ] Directory created: `cluster/modules/<name>/`
- [ ] `default.nix` has `options` and `config` sections
- [ ] Every option has a type; required options have no default
- [ ] `values` option declared (type `lib.types.attrs`, default `{}`) for helm-based modules
- [ ] `config` block is guarded with `lib.mkIf cfg.enable`
- [ ] `helm.nix` uses `lib.recursiveUpdate defaults cfg.values` for the `values` arg
- [ ] `helm.nix` (or `resources.nix`) returns a list of K8s resource attrsets
- [ ] (If needed) `cluster.argocd.<name>` set for serverSideApply/namespace override
- [ ] Config block added in `cluster/sets/management/default.nix` (and/or `cluster/sets/tenant/default.nix`)
- [ ] Files staged: `git add cluster/modules/<name>/`
- [ ] `nix build .#management-<name> --dry-run` succeeds
- [ ] `nix build .#management-<name> && cat result` produces correct YAML
- [ ] `nix build .#manifests` succeeds (no regressions)
- [ ] No CNPG Cluster resources emitted by the app module (use cloudnative-pg module instead)
- [ ] No VirtualService resources emitted by the app module (use istio-routing module instead)
