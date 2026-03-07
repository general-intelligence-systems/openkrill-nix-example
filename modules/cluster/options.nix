# Shared option declarations for cluster app modules.
#
# These options are written to by individual app modules (argocd, authelia,
# cert-manager, etc.) and read by the build pipeline or other modules.
{ lib, ... }:
{
  options.cluster = {
    domain = lib.mkOption {
      type = lib.types.str;
      default = "cluster.local";
      description = "Base domain for cluster services (e.g. mycompany.com).";
    };

    resources = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = ''
        Per-app Kubernetes resource sets. Each key is an app name,
        value is whatever the app module produces (typically a list
        of K8s resource attrsets from yaml.fromHelm).
      '';
    };

    argocd = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "ArgoCD cross-module configuration.";
    };
  };
}
