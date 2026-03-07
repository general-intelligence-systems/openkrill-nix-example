# Development VM + image builder — local k3s cluster with image outputs.
#
# Run a local dev VM:   nix run .#vm
# Build a QCOW2 image:  nix build .#qcow2
# Build a DO image:     nix build .#digitalocean
# Build an ISO:         nix build .#iso
# Flash to USB:         sudo dd if=result/iso/openkrill.iso of=/dev/sdX bs=4M status=progress conv=fsync
#
# Override pattern (extend a specific image):
#   (images.digitalocean.extendModules {
#     modules = [{ virtualisation.diskSize = 8192; }];
#   }).config.system.build.image
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    openkrill.url = "github:nathankidd/openkrill-nix-k3s-example";
  };

  outputs = { self, nixpkgs, openkrill, ... }:
    let
      system = "x86_64-linux";

      # Shared base configuration for all image variants.
      # Boot loader is NOT set here — each image module sets its own
      # to avoid grub/systemd-boot/direct-boot conflicts.
      baseConfig = { lib, ... }: {
        imports = [
          openkrill.nixosModules.openkrill
          openkrill.nixosModules.cluster
        ];

        services.openkrill.enable = true;
        networking.hostName = "openkrill";

        cluster.domain = "example.com";
        cluster.manifestsDir = "/var/lib/rancher/k3s/server/manifests";
        cluster.apps.cert-manager.enable = true;

        # Fallback root filesystem — image modules override this at
        # higher priority with their own disk layout.
        fileSystems."/" = lib.mkOverride 1500 {
          device = "/dev/vda1";
          fsType = "ext4";
        };

        system.stateVersion = "25.11";
      };

      # Build a base NixOS system, then derive all image variants from it.
      baseSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ baseConfig ];
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
          baseConfig
          {
            fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
            boot.loader.grub.device = "/dev/sda";
          }
        ];
      };

      packages.${system} = {
        qcow2         = images.qcow2.image;
        digitalocean   = images.digitalocean.image;
        google-compute = images.google-compute.image;
        incus-vm       = images.incus-vm.image;
        iso            = images.iso.image;
        vm             = images.vm.image;
        default        = images.qcow2.image;
      };
    };
}
