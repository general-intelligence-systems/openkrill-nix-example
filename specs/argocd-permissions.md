# ArgoCD Permissions

## Overview

ArgoCD uses an RBAC policy to control what authenticated users can do. Users authenticate via Authelia (OIDC) and are identified by their email address. The RBAC policy maps emails and LDAP group names to ArgoCD roles, which in turn define what actions are permitted.

## Architecture

The permission chain has three links:

```
LLDAP (user directory)
  -> Authelia (OIDC provider, issues tokens with email/groups claims)
    -> ArgoCD (matches claims against RBAC policy)
```

### Key files

| File | What it controls |
|------|-----------------|
| `cluster/modules/argo-cd/helm.nix` | RBAC policy and OIDC config (module-based, active) |
| `cluster/modules/argo-cd/default.nix` | Module options including `oidc.adminEmail` |
| `cluster/modules/authelia/helm.nix` | Authelia `claims_policies` (must include `argocd` policy) |
| `cluster/sets/management/default.nix` | ArgoCD OIDC client definition with `claims_policy = "argocd"` (in the `cluster.apps.authelia.oidcClients` list) |

## RBAC Policy

The RBAC policy lives in `cluster/modules/argo-cd/helm.nix` under `configs.rbac."policy.csv"`. It uses [Casbin](https://casbin.org/) syntax.

### Current policy

```
g, <cfg.oidc.adminEmail>, role:admin       # nathankidd@hey.com by default
g, nathankidd@hey.com, role:admin

p, role:admin, applications, *, */*, allow
p, role:admin, clusters, *, *, allow
p, role:admin, repositories, *, *, allow
p, role:admin, projects, *, *, allow

p, deploy-bot, applications, sync, */*, allow
p, deploy-bot, applications, get, */*, allow
```

The default policy for any authenticated user not matched by a `g` line:

```
policy.default = "role:readonly"
```

### Policy syntax

There are two statement types:

**`p` (permission)** — grants an action on a resource:

```
p, <subject>, <resource>, <action>, <object>, <effect>
```

| Field | Values |
|-------|--------|
| subject | A role name (e.g. `role:admin`) or a user/group identifier |
| resource | `applications`, `clusters`, `repositories`, `projects`, `logs`, `exec`, `extensions` |
| action | `get`, `create`, `update`, `delete`, `sync`, `action`, `override`, `invoke`, or `*` (all) |
| object | `<project>/<app-or-name>` for applications; `*` for all. Glob patterns are supported (`policy.matchMode: glob` is set). |
| effect | `allow` or `deny` |

**`g` (group)** — assigns a user or group to a role:

```
g, <user-or-group>, <role>
```

The `<user-or-group>` value is matched against the OIDC claims specified by `scopes`. In this cluster, `scopes = "[email, groups]"`, so ArgoCD matches against both the user's email address and their LLDAP group names.

## How to Grant a User Admin Access

### 1. Add a `g` line to the RBAC policy

Edit `cluster/modules/argo-cd/helm.nix` and add a line inside `configs.rbac."policy.csv"`:

```nix
rbac = {
  "policy.csv" = ''
    g, ${cfg.oidc.adminEmail}, role:admin
    g, nathankidd@hey.com, role:admin
    g, newuser@example.com, role:admin            # <-- add this
    ...
  '';
};
```

### 2. Ensure the user exists in LLDAP

The user must have an account in LLDAP with the `mail` attribute set to exactly the email used in the `g` line. Case matters.

LLDAP is managed at `https://lldap.portal.net` (or via its in-cluster address).

### 3. Commit, push, and wait for sync

```bash
git add cluster/modules/argo-cd/helm.nix
git commit -m "feat(argocd): grant admin to newuser@example.com"
git push
```

The Forgejo Actions workflow `render-manifests.yaml` will run `nix build .#manifests` and force-push the rendered YAML to the `manifests` branch. ArgoCD auto-syncs from there.

### 4. User must re-login

RBAC changes take effect immediately on the ArgoCD server, but the user must **log out and log back in** to get a fresh OIDC token if their identity claims changed.

## How to Grant Access via LDAP Groups

Instead of mapping individual emails, you can map an LLDAP group:

### 1. Create the group in LLDAP

Either add it to the `defaultGroups` list in `cluster/sets/management/default.nix` (auto-seeded on deploy):

```nix
cluster.apps.lldap = {
  defaultGroups = [
    "nextcloud-admins"
    "nextcloud-users"
    "argocd-admins"     # <-- add this
  ];
};
```

Or create it manually in the LLDAP web UI and assign users to it.

### 2. Add a `g` line mapping the group to a role

In `cluster/modules/argo-cd/helm.nix`:

```nix
"policy.csv" = ''
  g, argocd-admins, role:admin
  ...
'';
```

Any user in the `argocd-admins` LLDAP group will now get `role:admin` in ArgoCD.

## How to Create a Custom Role

Define permissions with `p` lines and assign users/groups with `g` lines:

```nix
"policy.csv" = ''
  # Custom role: can sync and view apps in the "myproject" project only
  p, role:deployer, applications, get, myproject/*, allow
  p, role:deployer, applications, sync, myproject/*, allow

  # Assign a group to the role
  g, deployers, role:deployer

  # Or assign an individual user
  g, someone@example.com, role:deployer
  ...
'';
```

### Available resources and actions

| Resource | Common actions | Notes |
|----------|---------------|-------|
| `applications` | `get`, `create`, `update`, `delete`, `sync`, `action`, `override` | `action` covers resource actions like pod restart; `delete` covers deleting individual resources within an app |
| `clusters` | `get`, `create`, `update`, `delete` | |
| `repositories` | `get`, `create`, `update`, `delete` | |
| `projects` | `get`, `create`, `update`, `delete` | |
| `logs` | `get` | Pod log streaming |
| `exec` | `create` | Pod exec (requires `exec.enabled: "true"` in argocd-cm) |

## Authelia Claims Policy (Critical Dependency)

ArgoCD identifies users by the `email` claim in the OIDC **ID token**. By default, Authelia only includes `email` and `groups` in the userinfo endpoint response, not in the ID token itself. Without the claims policy, ArgoCD falls back to using the `sub` claim (a UUID), which won't match any RBAC `g` lines, and all users silently get `role:readonly`.

The fix is the `argocd` claims policy defined in Authelia's config:

```nix
# In cluster/modules/authelia/helm.nix
claims_policies = {
  argocd = {
    id_token = [ "email" "groups" "preferred_username" ];
  };
};
```

And the ArgoCD OIDC client must reference it:

```nix
# In cluster/sets/management/default.nix (cluster.apps.authelia.oidcClients list)
{
  client_id = "argocd";
  claims_policy = "argocd";
  ...
}
```

**Do not remove this claims policy.** If it is removed, all OIDC users will lose their roles and fall back to readonly.

## Debugging Permissions

### Check what identity ArgoCD sees

Look at the ArgoCD server logs for the JWT claims:

```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=200 \
  | grep "grpc.request.claims"
```

The `sub` field is the OIDC subject. If you see a UUID instead of an email in permission-denied errors, the Authelia claims policy is not working (see section above).

### Check the live RBAC configmap

```bash
kubectl get configmap argocd-rbac-cm -n argocd -o yaml
```

### Test a user's permissions

From inside the ArgoCD server pod:

```bash
PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)

kubectl -n argocd exec deploy/argocd-server -- \
  argocd login localhost:8080 --plaintext --username admin --password "$PASS"

kubectl -n argocd exec deploy/argocd-server -- \
  argocd account can-i get applications '*/*' --server localhost:8080 --plaintext
```

### Common failure modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| User gets readonly despite `g` line existing | Email in RBAC doesn't match email in OIDC token (case or value mismatch) | Check LLDAP `mail` attribute; check ArgoCD logs for actual `sub`/email |
| All OIDC users are readonly | Authelia `claims_policy` missing or not assigned to ArgoCD client | Restore the `argocd` claims policy (see section above) |
| "permission denied: sub: \<uuid\>" | `email` claim missing from ID token | Same as above -- claims policy issue |
| CRD sync fails with "annotations too long" | `ServerSideApply` not enabled for argo-cd Application | Set `cluster.argocd.<name>.serverSideApply = true` in the module's config block |
| User can view but not delete/sync | User's role lacks the required `p` line for that action | Add the missing `p` line to `policy.csv` |
