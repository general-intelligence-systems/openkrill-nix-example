<!--
 Copyright (c) 2025 Nathan Kidd <nathankidd@hey.com>. All rights reserved.
 SPDX-License-Identifier: Proprietary
-->

<!--
  HOW TO MAINTAIN THIS FILE

  This is the index of all design specifications for Ralph.rb.
  Each row links a spec document to its implementation code and a short purpose summary.

  When adding a new spec:
  1. Create the markdown file in this directory (specs/)
  2. Add a row to the appropriate table section below
  3. Link the spec file, the code path it describes, and a brief purpose

  Table format:
    | [spec-name.md](./spec-name.md) | [path/to/code](../path/to/code) | Short description |

  Use "—" in the Code column if the spec has no implementation yet.
  Group specs under heading sections by domain area.
-->

# Spec Index

Design documentation for Trade Portal, a comprehensive DevOps platform with GitOps deployment automation and AI development capabilities.

## Kubernetes

| Spec | Code | Purpose |
|------|------|---------|
| [argocd-permissions.md](./argocd-permissions.md) | [cluster/modules/argo-cd/](../cluster/modules/argo-cd/) | How to manage ArgoCD RBAC roles, grant users access, and debug OIDC permission issues |
| [k8s-debug.md](./k8s-debug.md) | — | Systematic toolkit and workflows for debugging Kubernetes clusters, pods, services, and deployments |
| [k8s-manifests.md](./k8s-manifests.md) | [cluster/](../cluster/) | How the Nix module system produces K8s manifests for management and tenant clusters, and how to add apps to each |
| [nix-module-apps.md](./nix-module-apps.md) | [cluster/modules/](../cluster/modules/) | How-to guide for creating NixOS-style cluster app modules under `cluster/modules/` |
| [secrets.md](./secrets.md) | [cluster/bootstrap/secret-generator.nix](../cluster/bootstrap/secret-generator.nix) | How to add and manage secrets: generation, storage, distribution via ESO, and all edge cases |

## Nextcloud

| Spec | Code | Purpose |
|------|------|---------|
| [nextcloud-apps.md](./nextcloud-apps.md) | [cluster/modules/nextcloud/](../cluster/modules/nextcloud/) | How to add a new app (plugin) to the Nextcloud deployment via Nix config |

## Incus

| Spec | Code | Purpose |
|------|------|---------|
| [incus-clusters.md](./incus-clusters.md) | [modules/incus/](../modules/incus/) | How to bootstrap an Incus cluster and add member nodes over WireGuard |
| [incus-images.md](./incus-images.md) | [modules/incus/images/](../modules/incus/images/) | Verification and debugging of VM image builds imported into Incus on boot |

## Operators

| Spec | Code | Purpose |
|------|------|---------|
| [k8s-operators.md](./k8s-operators.md) | [operators/](../operators/) | How to write minimal Kubernetes operators in Go using controller-runtime |
| [lldap-operator.md](./lldap-operator.md) | [operators/lldap-operator/](../operators/lldap-operator/) | How to manage LLDAP servers, groups, and users declaratively via Kubernetes CRDs |
| [metatron-controller.md](./metatron-controller.md) | [operators/agent-controller/](../operators/agent-controller/) | How to write Metacontroller webhook controllers in Ruby using Metatron |

