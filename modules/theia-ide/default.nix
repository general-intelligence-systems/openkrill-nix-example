# cluster/modules/theia-ide — Theia IDE
# Deploys Eclipse Theia IDE from GHCR via bjw-s app-template.
{ config, lib, yaml, k8s, ... }:
let
  cfg = config.cluster.apps.theia-ide;
in
{
  options.cluster.apps.theia-ide = {
    enable = lib.mkEnableOption "Theia IDE";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "theia-ide";
    };

    values = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Helm chart value overrides, deep-merged with module defaults.";
    };
  };

  config = lib.mkIf cfg.enable {
    cluster.resources.theia-ide = import ./helm.nix {
      inherit lib yaml cfg;
    };
  };
}
