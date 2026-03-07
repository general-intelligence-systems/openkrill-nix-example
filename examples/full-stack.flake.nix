# Full-stack k3s deployment — all apps with auto-deploy.
#
# A production-ready starting point with k3s, TLS, GitOps, databases,
# SSO, file storage, and a web IDE. Uncomment and configure each
# section for your environment.
#
# Build: nix build .#qcow2
# ISO:   nix build .#iso
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    openkrill.url = "github:nathankidd/openkrill-nix-k3s-example";
  };

  outputs = { self, nixpkgs, openkrill, ... }:
    let
      system = "x86_64-linux";

      clusterConfig = {
        imports = [
          openkrill.nixosModules.openkrill
          openkrill.nixosModules.cluster
        ];

        services.openkrill.enable = true;
        networking.hostName = "openkrill-prod";

        # ── Cluster ─────────────────────────────────────────────────
        cluster.domain = "example.com";
        cluster.manifestsDir = "/var/lib/rancher/k3s/server/manifests";

        # ── TLS: cert-manager + trust-manager ───────────────────────
        # cert-manager handles certificate issuance (Let's Encrypt, etc.)
        # trust-manager distributes CA bundles across the cluster
        cluster.apps.cert-manager.enable = true;
        cluster.apps.trust-manager = {
          enable = true;
          caSecretName = "cluster-ca";  # K8s Secret containing your CA cert
        };

        # ── GitOps: ArgoCD ──────────────────────────────────────────
        # Watches a git repo and deploys manifests automatically.
        cluster.apps.argocd = {
          enable = true;
          domain = "argocd.example.com";
          caCertFile = ./ca.pem;        # path to your CA certificate
          oidc.issuer = "https://auth.example.com";
          # trustedDomains = [ "git.example.com" ];
          # values = {};  # Helm value overrides
        };

        # ── Database: CloudNativePG ─────────────────────────────────
        # PostgreSQL operator — define databases declaratively.
        cluster.apps.cloudnative-pg.enable = true;
        # cluster.apps.cloudnative-pg.databases.myapp = {
        #   namespace = "myapp";
        #   instances = 2;
        #   storageSize = "10Gi";
        # };

        # ── Web IDE: Theia ──────────────────────────────────────────
        cluster.apps.theia-ide.enable = true;

        # ── SSO: Authelia ───────────────────────────────────────────
        # Single sign-on portal + OIDC provider for all services.
        # Requires LLDAP as the user directory backend.
        #
        # cluster.apps.authelia = {
        #   enable = true;
        #   ldapBaseDn = "dc=example,dc=com";
        #   sessionCookies = [
        #     { domain = "example.com"; authelia_url = "https://auth.example.com"; }
        #   ];
        #   oidcClients = [
        #     { name = "Argo CD"; redirect_uris = [ "https://argocd.example.com/auth/callback" ]; }
        #     { name = "OpenCloud"; redirect_uris = [ "https://cloud.example.com/oidc-callback.html" ]; }
        #   ];
        # };

        # ── File Storage: OpenCloud ─────────────────────────────────
        # File sync & collaboration with Collabora, Tika search, and
        # S3 storage backend.
        #
        # cluster.apps.opencloud = {
        #   enable = true;
        #   domain = "cloud.example.com";
        #   oidc.issuer = "https://auth.example.com";
        #   collabora.domain = "office.example.com";
        #   s3 = {
        #     endpoint = "https://s3.example.com";
        #     bucket = "opencloud";
        #   };
        # };

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

      packages.${system} = {
        # QCOW2 disk image — for libvirt, Proxmox, plain QEMU
        qcow2 = (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            clusterConfig
            "${nixpkgs}/nixos/modules/virtualisation/disk-image.nix"
            {
              image.baseName = "openkrill-prod";
              image.format = "qcow2";
              virtualisation.diskSize = 20480;
            }
          ];
        }).config.system.build.image;

        # Bootable ISO — flash to USB with: dd if=result/openkrill.iso of=/dev/sdX
        iso = (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            clusterConfig
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            { image.baseName = nixpkgs.lib.mkForce "openkrill"; }
          ];
        }).config.system.build.image;

        default = self.packages.${system}.qcow2;
      };
    };
}
