# Image registry — standard image variants built via extendModules.
#
# Usage (from a consumer flake):
#
#   let
#     baseSystem = nixpkgs.lib.nixosSystem { ... };
#     images = openkrill.lib.buildImages { inherit nixpkgs; system = baseSystem; };
#   in {
#     packages.x86_64-linux.qcow2 = images.qcow2.image;
#     packages.x86_64-linux.vm    = images.vm.image;
#   }
#
# Override pattern (consumer extends a specific image):
#
#   (images.digitalocean.extendModules {
#     modules = [{ virtualisation.diskSize = 8192; }];
#   }).config.system.build.image
#
{ nixpkgs, system }:
let
  mkImage = { modules, output ? (config: config.system.build.image) }:
    let sys = system.extendModules { inherit modules; };
    in sys // { image = output sys.config; };
in
{
  qcow2 = mkImage {
    modules = [
      "${nixpkgs}/nixos/modules/virtualisation/disk-image.nix"
      {
        image.baseName = "openkrill";
        image.format = "qcow2";
        image.efiSupport = false;
        virtualisation.diskSize = 20480;
      }
    ];
  };

  digitalocean = mkImage {
    modules = [
      "${nixpkgs}/nixos/modules/virtualisation/digital-ocean-image.nix"
      {
        image.baseName = "openkrill-digitalocean";
        virtualisation.diskSize = 4096;
      }
    ];
  };

  google-compute = mkImage {
    modules = [
      "${nixpkgs}/nixos/modules/virtualisation/google-compute-image.nix"
      {
        image.baseName = "openkrill-google-compute";
        virtualisation.diskSize = 4096;
      }
    ];
  };

  incus-vm = mkImage {
    modules = [
      "${nixpkgs}/nixos/modules/virtualisation/incus-virtual-machine.nix"
    ];
    output = config: config.system.build.qemuImage;
  };

  iso = mkImage {
    modules = [
      "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
      { image.baseName = nixpkgs.lib.mkForce "openkrill"; }
    ];
  };

  vm = mkImage {
    modules = [
      ({ modulesPath, lib, ... }: {
        imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];
        boot.loader.grub.enable = lib.mkForce false;
        virtualisation = {
          memorySize = 4096;
          cores = 2;
          diskSize = 20480;
          forwardPorts = [
            { from = "host"; host.port = 6443; guest.port = 6443; }
          ];
          graphics = false;
        };
      })
    ];
    output = config: config.system.build.vm;
  };
}
