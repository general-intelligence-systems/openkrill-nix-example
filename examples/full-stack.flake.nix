# Full-stack k3s deployment — all apps with auto-deploy.
#
# A production-ready starting point with k3s, TLS, GitOps, databases,
# SSO, file storage, and a web IDE. Uncomment and configure each
# section for your environment.
#
# Build: nix build .#qcow2
# ISO:   nix build .#iso
# VM:    nix run .#vm
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    openkrill.url = "github:nathankidd/openkrill-nix-k3s-example";
  };

  outputs = { self, nixpkgs, openkrill, ... }:
    let
      system = "x86_64-linux";

      clusterConfig = { lib, ... }: {
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
        cluster.apps.cert-manager.enable = true;
        cluster.apps.trust-manager = {
          enable = true;
          caSecretName = "cluster-ca";
        };

        # ── GitOps: ArgoCD ──────────────────────────────────────────
        cluster.apps.argocd = {
          enable = true;
          domain = "argocd.example.com";
          caCertFile = ./ca.pem;
          oidc.issuer = "https://auth.example.com";
        };

        # ── Database: CloudNativePG ─────────────────────────────────
        cluster.apps.cloudnative-pg.enable = true;

        # ── Web IDE: Theia ──────────────────────────────────────────
        cluster.apps.theia-ide.enable = true;

        # ── SSO: Authelia ───────────────────────────────────────────
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
        iso      = images.iso.image;
        vm       = images.vm.image;
        default  = images.qcow2.image;
      };
    };
}
