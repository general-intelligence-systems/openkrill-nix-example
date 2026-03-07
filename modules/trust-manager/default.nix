# cluster/modules/trust-manager — cert-manager trust-manager
# Deploys trust-manager + a Bundle that distributes the cluster's internal
# CA (plus public CAs) into every namespace labelled trust-bundle=true.
# Apps mount the resulting `cluster-trust-bundle` ConfigMap instead of
# managing per-app CA ConfigMaps.
{ config, lib, yaml, k8s, ... }:
let
  cfg = config.cluster.apps.trust-manager;
in
{
  options.cluster.apps.trust-manager = {
    enable = lib.mkEnableOption "trust-manager CA bundle distribution";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "cert-manager";
    };

    caSecretName = lib.mkOption {
      type = lib.types.str;
      description = "Name of the cert-manager CA Secret (in the cert-manager namespace) to include in the bundle.";
    };

    caSecretKey = lib.mkOption {
      type = lib.types.str;
      default = "ca.crt";
      description = "Key within the CA secret containing the PEM certificate.";
    };

    bundleConfigMapName = lib.mkOption {
      type = lib.types.str;
      default = "cluster-trust-bundle";
      description = "Name of the ConfigMap trust-manager syncs into target namespaces.";
    };

    bundleKey = lib.mkOption {
      type = lib.types.str;
      default = "bundle.pem";
      description = "Key within the synced ConfigMap containing the PEM bundle.";
    };

    values = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Helm chart value overrides, deep-merged with module defaults.";
    };
  };

  config = lib.mkIf cfg.enable {
    cluster.resources.trust-manager = import ./helm.nix {
      inherit lib yaml cfg;
    };
  };
}
