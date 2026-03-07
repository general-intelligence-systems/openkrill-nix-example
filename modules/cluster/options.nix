# Shared option declarations for cluster app modules.
#
# These options are written to by individual app modules (argocd, authelia,
# cert-manager, etc.) and read by the manifest output pipeline.
{ config, lib, pkgs, yaml, ... }:
let
  cfg = config.cluster;

  manifestsPkg = pkgs.linkFarm "cluster-manifests" (
    lib.mapAttrsToList (name: res: {
      name = "${name}.yaml";
      path = yaml.toYAMLStreamFile res;
    }) cfg.resources
  );
in
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

    manifestsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Directory to write manifest YAML files as symlinks into the Nix
        store. Set to "/var/lib/rancher/k3s/server/manifests" for k3s
        auto-deploy. When null, no files are written.
      '';
    };

    manifestsPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = manifestsPkg;
      description = ''
        Derivation containing all manifest YAML files. Each enabled app
        produces a <name>.yaml multi-document YAML file.
      '';
    };
  };

  config = lib.mkIf (cfg.manifestsDir != null) {
    system.activationScripts.cluster-manifests.text =
      let
        managedFiles = lib.mapAttrsToList
          (name: _: "${cfg.manifestsDir}/${name}.yaml")
          cfg.resources;
        manifestLinks = lib.concatStringsSep "\n" (lib.mapAttrsToList
          (name: res: ''
            ln -sf "${yaml.toYAMLStreamFile res}" "${cfg.manifestsDir}/${name}.yaml"
          '')
          cfg.resources);
      in
      ''
        mkdir -p "${cfg.manifestsDir}"

        # Remove manifests from previous activation that are no longer needed
        if [ -f "${cfg.manifestsDir}/.nix-managed" ]; then
          while IFS= read -r f; do
            [ -L "$f" ] && rm -f "$f"
          done < "${cfg.manifestsDir}/.nix-managed"
        fi

        # Symlink current manifests into the target directory
        ${manifestLinks}

        # Record managed files for cleanup on next activation
        cat > "${cfg.manifestsDir}/.nix-managed" <<'EOF'
        ${lib.concatStringsSep "\n" managedFiles}
        EOF
      '';
  };
}
