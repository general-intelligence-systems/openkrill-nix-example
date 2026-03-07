# System configuration for the openkrill k3s machine.
#
# Used by both the QCOW2 disk image and the dev VM.
# Image-specific settings (QEMU virtualisation, disk format) are added
# by the flake via separate modules -- this file is the shared base.
{ modulesPath, lib, ... }:
{
  imports = [
    ./modules/openkrill.nix
  ];

  # Enable the k3s service
  services.openkrill.enable = true;

  # Boot loader is set by each image module:
  #   disk-image.nix       -> grub (BIOS)
  #   digital-ocean-image  -> grub
  #   google-compute-image -> grub
  #   incus-virtual-machine -> systemd-boot (EFI)
  #   qemu-vm.nix          -> direct kernel boot (grub disabled)
  # We intentionally do NOT set boot.loader here to avoid conflicts.

  # Root filesystem -- a fallback so the config evaluates standalone.
  # Image modules (disk-image, digital-ocean, google-compute, qemu-vm)
  # each set their own fileSystems at higher priority.
  fileSystems."/" = lib.mkOverride 1500 {
    device = "/dev/vda1";
    fsType = "ext4";
  };

  system.stateVersion = "25.11";
}
