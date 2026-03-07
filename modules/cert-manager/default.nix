# cluster/modules/cert-manager — cert-manager controller + CRDs
# Deploys the cert-manager controller, webhook, and CRDs.
# Required by self-signed-cert for ClusterIssuers and Certificates.
{ config, lib, yaml, k8s, ... }:
let
  cfg = config.cluster.apps.cert-manager;
in
{
  options.cluster.apps.cert-manager = {
    enable = lib.mkEnableOption "cert-manager TLS certificate controller";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "cert-manager";
    };

    values = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Helm chart value overrides, deep-merged with module defaults.";
    };
  };

  config = lib.mkIf cfg.enable {
    cluster.resources.cert-manager = import ./helm.nix {
      inherit lib yaml cfg;
    };
  };
}
