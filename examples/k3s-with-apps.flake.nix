# k3s server with cert-manager and ArgoCD — GitOps-ready deployment.
#
# Builds a NixOS k3s node that auto-deploys cert-manager and ArgoCD
# on boot via manifest symlinks to the k3s auto-deploy directory.
#
# Build: nix build .#qcow2
# VM:    nix run .#vm
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    openkrill.url = "github:nathankidd/openkrill-nix-k3s-example";
  };

  outputs = { self, nixpkgs, openkrill, ... }:
    let
      system = "x86_64-linux";

      # Shared NixOS configuration
      clusterConfig = { lib, ... }: {
        imports = [
          openkrill.nixosModules.openkrill
          openkrill.nixosModules.cluster
        ];

        services.openkrill.enable = true;
        networking.hostName = "k3s-gitops";

        # ── Cluster config ──────────────────────────────────────────
        cluster.domain = "example.com";
        cluster.manifestsDir = "/var/lib/rancher/k3s/server/manifests";

        # ── Apps ────────────────────────────────────────────────────
        cluster.apps.cert-manager.enable = true;
        cluster.apps.argocd = {
          enable = true;
          domain = "argocd.example.com";
          caCertFile = ./ca.pem;
          oidc.issuer = "https://auth.example.com";
        };

        # Fallback root filesystem — image modules override this.
        fileSystems."/" = lib.mkOverride 1500 {
          device = "/dev/vda1";
          fsType = "ext4";
        };

        system.stateVersion = "25.11";
      };

      baseSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ clusterConfig ];
      };

      images = openkrill.lib.buildImages {
        inherit nixpkgs;
        system = baseSystem;
      };
    in
    {
      nixosConfigurations.default = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          clusterConfig
          {
            fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
            boot.loader.grub.device = "/dev/sda";
          }
        ];
      };

      packages.${system} = {
        qcow2   = images.qcow2.image;
        vm      = images.vm.image;
        default = images.qcow2.image;
      };
    };
}
