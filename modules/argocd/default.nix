# cluster/modules/argocd — ArgoCD GitOps controller
# OIDC: uses Authelia as the identity provider.
{ config, lib, yaml, k8s, ... }:
let
  cfg = config.cluster.apps.argocd;
in
{
  options.cluster.apps.argocd = {
    enable = lib.mkEnableOption "ArgoCD GitOps controller";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "argocd";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      description = "FQDN for ArgoCD (e.g. argocd.cia.net).";
    };

    caCertFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to the CA cert file for internal TLS trust.";
    };

    trustedDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Domains whose TLS should be trusted via the CA cert.";
    };

    oidc.issuer = lib.mkOption {
      type = lib.types.str;
      description = "OIDC issuer URL (e.g. https://auth.cia.net).";
    };

    values = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Helm chart value overrides, deep-merged with module defaults.";
    };
  };

  config = lib.mkIf cfg.enable {
    cluster.argocd.argocd.serverSideApply = true;

    cluster.resources.argocd = import ./helm.nix {
      inherit lib yaml cfg;
    };
  };
}
