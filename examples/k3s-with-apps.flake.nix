# k3s server with cert-manager and ArgoCD — GitOps-ready deployment.
#
# Builds a NixOS k3s node that auto-deploys cert-manager and ArgoCD
# on boot via manifest symlinks to the k3s auto-deploy directory.
#
# Build: nix build .#qcow2
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    openkrill.url = "github:nathankidd/openkrill-nix-k3s-example";
  };

  outputs = { self, nixpkgs, openkrill, ... }:
    let
      system = "x86_64-linux";

      # Shared NixOS configuration
      clusterConfig = {
        imports = [
          openkrill.nixosModules.openkrill
          openkrill.nixosModules.cluster
        ];

        services.openkrill.enable = true;
        networking.hostName = "k3s-gitops";

        # ── Cluster config ──────────────────────────────────────────
        cluster.domain = "example.com";

        # Write manifests to k3s auto-deploy directory — k3s applies
        # them automatically on boot and watches for changes.
        cluster.manifestsDir = "/var/lib/rancher/k3s/server/manifests";

        # ── Apps ────────────────────────────────────────────────────
        # cert-manager: zero required config
        cluster.apps.cert-manager.enable = true;

        # ArgoCD: requires domain, CA cert, and OIDC issuer
        cluster.apps.argocd = {
          enable = true;
          domain = "argocd.example.com";
          caCertFile = ./ca.pem;  # your CA certificate
          oidc.issuer = "https://auth.example.com";
        };

        system.stateVersion = "25.11";
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

      # QCOW2 disk image
      packages.${system}.qcow2 = (nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          clusterConfig
          "${nixpkgs}/nixos/modules/virtualisation/disk-image.nix"
          {
            image.baseName = "k3s-gitops";
            image.format = "qcow2";
            virtualisation.diskSize = 20480;
          }
        ];
      }).config.system.build.image;

      packages.${system}.default = self.packages.${system}.qcow2;
    };
}
