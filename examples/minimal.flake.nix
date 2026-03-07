# Minimal k3s server — bare-bones single-node Kubernetes.
#
# This is the simplest possible openkrill deployment: a NixOS system
# running k3s with no cluster apps. Good starting point for learning
# or building a custom stack.
#
# Build:  nix build .#qcow2
# Run VM: nix run .#vm
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    openkrill.url = "github:nathankidd/openkrill-nix-k3s-example";
  };

  outputs = { self, nixpkgs, openkrill, ... }:
    let
      system = "x86_64-linux";

      baseSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          openkrill.nixosModules.openkrill
          ({ lib, ... }: {
            services.openkrill.enable = true;
            networking.hostName = "k3s-minimal";
            fileSystems."/" = lib.mkOverride 1500 {
              device = "/dev/vda1";
              fsType = "ext4";
            };
            system.stateVersion = "25.11";
          })
        ];
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
          openkrill.nixosModules.openkrill
          {
            services.openkrill.enable = true;
            networking.hostName = "k3s-minimal";
            fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
            boot.loader.grub.device = "/dev/sda";
            system.stateVersion = "25.11";
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
