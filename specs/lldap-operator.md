# LLDAP Operator

## Overview

The lldap-operator manages the full lifecycle of LLDAP instances, users, and groups declaratively via Kubernetes Custom Resources. Instead of deploying LLDAP with Helm and imperatively calling the GraphQL API or using seed Jobs, you declare the desired state as CRs and the operator reconciles them.

The operator defines three resources, each building on the previous:

```
LdapServer  (deploys and manages an LLDAP instance)
  -> LdapGroup  (a single group on that server)
  -> LdapUser   (a single user on that server, with group memberships)
```

An LdapServer must exist, have its Deployment available, and report a healthy connection before LdapGroup or LdapUser resources referencing it will be reconciled.

---

## Table of Contents

1. [Custom Resources](#custom-resources)
   - [LdapServer](#ldapserver)
   - [LdapGroup](#ldapgroup)
   - [LdapUser](#ldapuser)
2. [How to Deploy an LLDAP Server](#how-to-deploy-an-lldap-server)
3. [How to Create a Group](#how-to-create-a-group)
4. [How to Create a User and Assign Groups](#how-to-create-a-user-and-assign-groups)
5. [How to Add a User to Additional Groups](#how-to-add-a-user-to-additional-groups)
6. [Credentials Secret Format](#credentials-secret-format)
7. [Managed Child Resources](#managed-child-resources)
8. [Status Conditions](#status-conditions)

---

## Custom Resources

All resources use API group `lldap.cia.net/v1alpha1`.

### LdapServer

Deploys and manages a complete LLDAP instance. The operator creates a Deployment, Service, PVC, and auto-generated config Secret for the LLDAP server. It periodically authenticates with the LLDAP API and runs a health check to confirm the instance is operational.

Every LdapGroup and LdapUser references an LdapServer by name.

#### Schema

```yaml
apiVersion: lldap.cia.net/v1alpha1
kind: LdapServer
metadata:
  name: <string>           # Name used by LdapGroup/LdapUser serverRef
  namespace: <string>
spec:
  # Required. The LDAP base distinguished name.
  baseDN: <string>          # e.g. "dc=cia,dc=net"

  # Required. Reference to a Secret containing admin credentials.
  # The Secret must have 'username' and 'password' keys.
  adminCredentialsSecretRef:
    name: <string>          # Secret name in the same namespace

  # Optional. LLDAP container image.
  # Default: "lldap/lldap:v0.6.2-alpine-rootless"
  image: <string>

  # Required. PostgreSQL database connection for LLDAP.
  database:
    # Required. Database server hostname.
    host: <string>          # e.g. "lldap-pg-rw.lldap.svc.cluster.local"

    # Optional. Database server port. Default: 5432.
    port: <int>

    # Required. Database name.
    name: <string>          # e.g. "lldap"

    # Required. Reference to a Secret with 'username' and 'password' keys.
    credentialsSecretRef:
      name: <string>

  # Optional. PVC configuration for LLDAP data.
  storage:
    # Optional. Storage request size. Default: "100Mi".
    size: <string>

    # Optional. StorageClass name. Empty or omitted = cluster default.
    storageClassName: <string>

  # Optional. Interval between health checks. Default: "60s".
  checkInterval: <duration> # e.g. "30s", "5m"
status:
  # Whether the LLDAP instance is healthy and reachable.
  connected: <bool>

  # ISO 8601 timestamp of the last successful connection check.
  lastCheckTime: <string>

  # The computed internal service URL for the LLDAP HTTP API.
  url: <string>             # e.g. "http://main.lldap.svc.cluster.local:17170"

  # Human-readable message (error detail on failure, "OK" on success).
  message: <string>

  # Standard Kubernetes conditions.
  conditions:
    - type: Ready            # "True" when connected, "False" otherwise
      status: <string>
      reason: <string>
      message: <string>
      lastTransitionTime: <string>
```

#### Spec field reference

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `baseDN` | string | yes | — | LDAP base DN (e.g. `dc=cia,dc=net`) |
| `adminCredentialsSecretRef.name` | string | yes | — | Secret with `username` and `password` keys for the LLDAP admin account |
| `image` | string | no | `lldap/lldap:v0.6.2-alpine-rootless` | LLDAP container image |
| `database.host` | string | yes | — | PostgreSQL server hostname |
| `database.port` | int | no | `5432` | PostgreSQL server port |
| `database.name` | string | yes | — | PostgreSQL database name |
| `database.credentialsSecretRef.name` | string | yes | — | Secret with `username` and `password` keys for the database |
| `storage.size` | string | no | `100Mi` | PVC storage request size |
| `storage.storageClassName` | string | no | cluster default | StorageClass for the PVC |
| `checkInterval` | duration | no | `60s` | How often to re-verify connectivity |

---

### LdapGroup

Declares a single group in LLDAP. The operator creates the group if it does not exist, and ensures it remains present. Deleting the CR removes the group from LLDAP.

#### Schema

```yaml
apiVersion: lldap.cia.net/v1alpha1
kind: LdapGroup
metadata:
  name: <string>
  namespace: <string>
spec:
  # Required. Reference to an LdapServer in the same namespace.
  serverRef:
    name: <string>

  # Required. The display name of the group in LLDAP.
  # This is the group name users see and that appears in OIDC group claims.
  displayName: <string>     # e.g. "argocd-admins"
status:
  # The numeric group ID assigned by LLDAP.
  groupId: <int>

  # Whether the group has been synced to LLDAP.
  synced: <bool>

  # Human-readable status message.
  message: <string>

  # Standard Kubernetes conditions.
  conditions:
    - type: Ready
      status: <string>
      reason: <string>
      message: <string>
      lastTransitionTime: <string>
```

#### Spec field reference

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `serverRef.name` | string | yes | — | Name of the LdapServer CR to use |
| `displayName` | string | yes | — | Group name in LLDAP |

---

### LdapUser

Declares a single user in LLDAP with optional group memberships. The operator creates the user if they do not exist, updates their attributes if they drift, and manages their group membership list. Deleting the CR removes the user from LLDAP.

Users are created without a password. They must set one through another mechanism (e.g. the LLDAP web UI or a password reset flow).

#### Schema

```yaml
apiVersion: lldap.cia.net/v1alpha1
kind: LdapUser
metadata:
  name: <string>
  namespace: <string>
spec:
  # Required. Reference to an LdapServer in the same namespace.
  serverRef:
    name: <string>

  # Required. The LLDAP username (uid). Must be unique per server.
  username: <string>        # e.g. "jdoe"

  # Required. The user's email address.
  email: <string>           # e.g. "jdoe@cia.net"

  # Optional. Display name shown in LLDAP and OIDC claims.
  displayName: <string>     # e.g. "Jane Doe"

  # Optional. User's first name.
  firstName: <string>

  # Optional. User's last name.
  lastName: <string>

  # Optional. List of group names this user should belong to.
  # Each entry must match the displayName of an LdapGroup on the same server.
  # The operator adds the user to listed groups and removes them from any
  # groups not in this list (except built-in LLDAP groups like "lldap_admin").
  groups:                   # e.g. ["argocd-admins", "nextcloud-users"]
    - <string>
status:
  # Whether the user has been synced to LLDAP.
  synced: <bool>

  # The list of groups the user currently belongs to in LLDAP.
  groups:
    - <string>

  # Human-readable status message.
  message: <string>

  # Standard Kubernetes conditions.
  conditions:
    - type: Ready
      status: <string>
      reason: <string>
      message: <string>
      lastTransitionTime: <string>
```

#### Spec field reference

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `serverRef.name` | string | yes | — | Name of the LdapServer CR to use |
| `username` | string | yes | — | LLDAP uid (unique per server) |
| `email` | string | yes | — | User's email address |
| `displayName` | string | no | — | Display name |
| `firstName` | string | no | — | First name |
| `lastName` | string | no | — | Last name |
| `groups` | list of strings | no | `[]` | Group displayNames the user should belong to |

---

## How to Deploy an LLDAP Server

### 1. Create the admin credentials Secret

The Secret must contain `username` and `password` keys with the LLDAP admin credentials:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: lldap-admin-credentials
  namespace: lldap
type: Opaque
stringData:
  username: admin
  password: my-secret-password
```

### 2. Ensure a PostgreSQL database is available

The operator expects a PostgreSQL database. If using CloudNativePG, create a Cluster and reference the auto-generated app Secret:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: lldap-pg
  namespace: lldap
spec:
  instances: 1
  storage:
    size: 5Gi
  bootstrap:
    initdb:
      database: lldap
      owner: lldap
```

CNPG creates a Secret named `lldap-pg-app` with `username` and `password` keys.

### 3. Create the LdapServer resource

```yaml
apiVersion: lldap.cia.net/v1alpha1
kind: LdapServer
metadata:
  name: main
  namespace: lldap
spec:
  baseDN: "dc=cia,dc=net"
  adminCredentialsSecretRef:
    name: lldap-admin-credentials
  database:
    host: "lldap-pg-rw.lldap.svc.cluster.local"
    name: "lldap"
    credentialsSecretRef:
      name: lldap-pg-app
```

The operator will create a Deployment, Service, PVC, and config Secret automatically.

### 4. Verify the server is running

```bash
kubectl get ldapserver main -n lldap
```

Expected output when healthy:

```
NAME   CONNECTED   MESSAGE   AGE
main   true        OK        60s
```

If `CONNECTED` is `false`, check the `message` field for error details:

```bash
kubectl describe ldapserver main -n lldap
```

Common failures:

| Message | Cause | Fix |
|---------|-------|-----|
| `waiting for deployment to become available` | LLDAP pod is not yet running | Wait for the Deployment to become ready; check pod logs |
| `auth failed: 401` | Admin credentials are incorrect | Check the admin credentials Secret values |
| `Secret "..." not found` | The referenced Secret does not exist | Create the Secret in the same namespace |
| `failed to reconcile deployment` | Database connection issue or image pull error | Check pod events and database connectivity |

---

## How to Create a Group

### 1. Ensure an LdapServer exists and is connected

```bash
kubectl get ldapserver -n lldap
```

### 2. Create the LdapGroup resource

```yaml
apiVersion: lldap.cia.net/v1alpha1
kind: LdapGroup
metadata:
  name: argocd-admins
  namespace: lldap
spec:
  serverRef:
    name: main
  displayName: argocd-admins
```

### 3. Verify the group was created

```bash
kubectl get ldapgroup argocd-admins -n lldap
```

Expected output:

```
NAME             GROUP ID   SYNCED   AGE
argocd-admins    42         true     10s
```

The `groupId` is assigned by LLDAP and recorded in `.status.groupId`.

### Creating multiple groups

Apply multiple LdapGroup manifests at once:

```yaml
apiVersion: lldap.cia.net/v1alpha1
kind: LdapGroup
metadata:
  name: nextcloud-users
  namespace: lldap
spec:
  serverRef:
    name: main
  displayName: nextcloud-users
---
apiVersion: lldap.cia.net/v1alpha1
kind: LdapGroup
metadata:
  name: nextcloud-admins
  namespace: lldap
spec:
  serverRef:
    name: main
  displayName: nextcloud-admins
```

---

## How to Create a User and Assign Groups

### 1. Create the groups first

Groups referenced in `spec.groups` must exist as LdapGroup CRs (and be synced) before the user can be added to them. If a referenced group does not exist in LLDAP, the operator reports the missing groups in the LdapUser status message but still creates the user and adds them to whichever groups do exist.

### 2. Create the LdapUser resource

```yaml
apiVersion: lldap.cia.net/v1alpha1
kind: LdapUser
metadata:
  name: jdoe
  namespace: lldap
spec:
  serverRef:
    name: main
  username: jdoe
  email: jdoe@cia.net
  displayName: Jane Doe
  firstName: Jane
  lastName: Doe
  groups:
    - argocd-admins
    - nextcloud-users
```

The user is created without a password. They must set one through the LLDAP web UI or another mechanism.

### 3. Verify the user was created

```bash
kubectl get ldapuser jdoe -n lldap
```

Expected output:

```
NAME   SYNCED   GROUPS                                  AGE
jdoe   true     ["argocd-admins","nextcloud-users"]     15s
```

Check group membership details:

```bash
kubectl get ldapuser jdoe -n lldap -o jsonpath='{.status.groups}'
```

---

## How to Add a User to Additional Groups

### 1. Ensure the new group exists

Create the LdapGroup CR if it does not exist yet (see [How to Create a Group](#how-to-create-a-group)).

### 2. Edit the LdapUser's groups list

Add the new group name to the `spec.groups` array:

```bash
kubectl edit ldapuser jdoe -n lldap
```

Or patch it directly:

```bash
kubectl patch ldapuser jdoe -n lldap --type=merge \
  -p '{"spec":{"groups":["argocd-admins","nextcloud-users","nextcloud-admins"]}}'
```

Or update the manifest and re-apply:

```yaml
apiVersion: lldap.cia.net/v1alpha1
kind: LdapUser
metadata:
  name: jdoe
  namespace: lldap
spec:
  serverRef:
    name: main
  username: jdoe
  email: jdoe@cia.net
  displayName: Jane Doe
  firstName: Jane
  lastName: Doe
  groups:
    - argocd-admins
    - nextcloud-users
    - nextcloud-admins    # added
```

### 3. Verify

```bash
kubectl get ldapuser jdoe -n lldap -o jsonpath='{.status.groups}'
```

The operator adds the user to `nextcloud-admins` and removes them from any groups not in the list (except built-in LLDAP groups).

### Removing a user from a group

Remove the group name from `spec.groups`. The operator will remove the user from that group in LLDAP on the next reconcile.

---

## Credentials Secret Format

### LdapServer admin credentials

Referenced by `spec.adminCredentialsSecretRef.name`. Must contain:

| Key | Description |
|-----|-------------|
| `username` | LLDAP admin username (e.g. `admin`) |
| `password` | LLDAP admin password |

### Database credentials

Referenced by `spec.database.credentialsSecretRef.name`. Must contain:

| Key | Description |
|-----|-------------|
| `username` | PostgreSQL username |
| `password` | PostgreSQL password |

---

## Managed Child Resources

When an LdapServer CR is created, the operator creates and owns the following Kubernetes resources via `ownerReferences`. Deleting the LdapServer CR deletes all child resources.

| Resource | Name | Purpose |
|----------|------|---------|
| Secret | `<server-name>-config` | Auto-generated `jwt-secret` and `key-seed` for the LLDAP instance. Created once and never overwritten. |
| PVC | `<server-name>-data` | Persistent storage for `/data` in the LLDAP container. |
| Deployment | `<server-name>` | Single-replica LLDAP Deployment with Recreate strategy. Mounts the PVC, injects env vars from admin credentials, config Secret, database credentials, and baseDN. Includes liveness and readiness probes on `/health`. |
| Service | `<server-name>` | ClusterIP Service exposing port 3890 (LDAP) and 17170 (HTTP/GraphQL). |

The operator constructs the `LLDAP_DATABASE_URL` environment variable from the database spec fields and credentials Secret:

```
postgres://$(DB_USER):$(DB_PASS)@<host>:<port>/<name>
```

---

## Status Conditions

All three resources use standard Kubernetes conditions. The primary condition is `Ready`.

| Resource | Condition | True when | False when |
|----------|-----------|-----------|------------|
| LdapServer | `Ready` | Deployment is available, authentication and health check succeed | Deployment not available, auth fails, or Secret is missing |
| LdapGroup | `Ready` | Group exists in LLDAP and matches spec | Server not ready, API error, or group creation failed |
| LdapUser | `Ready` | User exists with correct attributes and group memberships | Server not ready, missing groups, API error, or user creation failed |

### Dependency ordering

The operator respects dependencies between resources:

1. **LdapServer** must have its Deployment available and pass a health check before `Ready=True`.
2. **LdapGroup** waits for its referenced **LdapServer** to have `Ready=True` before attempting to create the group.
3. **LdapUser** waits for its referenced **LdapServer** to have `Ready=True` before attempting to create the user.
4. **LdapUser** reports missing groups in its status message if any entry in `spec.groups` does not match an existing group in LLDAP, but still creates the user and adds them to whichever groups do exist.

### Finalizers

All three resources use the finalizer `lldap.cia.net/cleanup`:

- **LdapServer**: removes the finalizer on deletion (child resources are garbage-collected via `ownerReferences`).
- **LdapGroup**: calls `deleteGroup` on the LLDAP GraphQL API before removing the finalizer.
- **LdapUser**: calls `deleteUser` on the LLDAP GraphQL API before removing the finalizer.
