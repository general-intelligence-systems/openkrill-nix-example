# cluster/modules/opencloud -- OpenCloud file sync & collaboration
# Deploys OpenCloud with Authelia OIDC, Collabora, Tika, and web extensions.
# All secrets are referenced via existingSecret (no plaintext in nix).
{ config, lib, yaml, k8s, ... }:
let
  cfg = config.cluster.apps.opencloud;

  mkImageOption = { registry ? "docker.io", repository, tag }: {
    registry = lib.mkOption {
      type = lib.types.str;
      default = registry;
    };
    repository = lib.mkOption {
      type = lib.types.str;
      default = repository;
    };
    tag = lib.mkOption {
      type = lib.types.str;
      default = tag;
    };
  };
in
{
  options.cluster.apps.opencloud = {
    enable = lib.mkEnableOption "OpenCloud file sync & collaboration";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "opencloud";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      description = "FQDN for OpenCloud (e.g. cloud.portal.net).";
    };

    image = mkImageOption {
      repository = "opencloudeu/opencloud-rolling";
      tag = "2.1.0";
    };

    # ── OIDC (Authelia) ────────────────────────────────────────────────
    oidc = {
      issuer = lib.mkOption {
        type = lib.types.str;
        description = "OIDC issuer URL (e.g. https://auth.portal.net).";
      };

      clientId = lib.mkOption {
        type = lib.types.str;
        default = "opencloud";
      };

      accountUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Account management URL shown in the web UI.";
      };

      scope = lib.mkOption {
        type = lib.types.str;
        default = "openid profile email groups";
      };

      userClaim = lib.mkOption {
        type = lib.types.str;
        default = "preferred_username";
      };

      roleClaim = lib.mkOption {
        type = lib.types.str;
        default = "groups";
      };
    };

    # ── Admin secret ───────────────────────────────────────────────────
    existingSecret = lib.mkOption {
      type = lib.types.str;
      default = "opencloud-admin";
      description = "K8s Secret with key 'adminPassword'.";
    };

    # ── Core settings ──────────────────────────────────────────────────
    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
    };

    insecure = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Set true if using self-signed certs.";
    };

    createDemoUsers = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    env = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [];
      description = "Additional env vars for the OpenCloud container.";
    };

    envFrom = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [];
      description = "Additional envFrom for the OpenCloud container.";
    };

    resources = lib.mkOption {
      type = lib.types.attrs;
      default = {
        requests = { cpu = "128m"; memory = "128Mi"; };
        limits = { memory = "20Gi"; };
      };
    };

    # ── Persistence ────────────────────────────────────────────────────
    persistence = {
      config.size = lib.mkOption {
        type = lib.types.str;
        default = "5Gi";
      };
      data.size = lib.mkOption {
        type = lib.types.str;
        default = "30Gi";
      };
    };

    # ── S3 Storage (Cloudflare R2) ─────────────────────────────────────
    s3 = {
      endpoint = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "S3 endpoint URL.";
      };

      region = lib.mkOption {
        type = lib.types.str;
        default = "auto";
      };

      bucket = lib.mkOption {
        type = lib.types.str;
        default = "opencloud";
      };

      createBucket = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      existingSecret = lib.mkOption {
        type = lib.types.str;
        default = "opencloud-s3";
        description = "K8s Secret with keys 'accessKey' and 'secretKey'.";
      };
    };

    # ── SMTP ───────────────────────────────────────────────────────────
    smtp = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "";
      };

      port = lib.mkOption {
        type = lib.types.str;
        default = "587";
      };

      sender = lib.mkOption {
        type = lib.types.str;
        default = "";
      };

      existingSecret = lib.mkOption {
        type = lib.types.str;
        default = "opencloud-smtp";
        description = "K8s Secret with keys 'smtpUser' and 'smtpPassword'.";
      };

      insecure = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      authentication = lib.mkOption {
        type = lib.types.str;
        default = "plain";
      };

      encryption = lib.mkOption {
        type = lib.types.str;
        default = "starttls";
      };
    };

    # ── Collabora CODE ─────────────────────────────────────────────────
    collabora = {
      domain = lib.mkOption {
        type = lib.types.str;
        description = "FQDN for Collabora (e.g. office.portal.net).";
      };

      image = mkImageOption {
        repository = "collabora/code";
        tag = "24.04.13.2.1";
      };

      ssl = {
        enabled = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        verification = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
      };

      admin.existingSecret = lib.mkOption {
        type = lib.types.str;
        default = "opencloud-collabora";
        description = "K8s Secret with keys 'username' and 'password'.";
      };

      resources = lib.mkOption {
        type = lib.types.attrs;
        default = {
          requests = { cpu = "100m"; memory = "256Mi"; };
          limits = { cpu = "1"; memory = "1Gi"; };
        };
      };

      collaboration.resources = lib.mkOption {
        type = lib.types.attrs;
        default = {
          requests = { cpu = "100m"; memory = "256Mi"; };
          limits = { cpu = "1"; memory = "1Gi"; };
        };
      };
    };

    # ── Tika (full-text search) ────────────────────────────────────────
    tika = {
      image = mkImageOption {
        repository = "apache/tika";
        tag = "2.9.2.1-full";
      };

      resources = lib.mkOption {
        type = lib.types.attrs;
        default = {
          requests = { cpu = "100m"; memory = "1Gi"; };
          limits = { cpu = "1000m"; memory = "3Gi"; };
        };
      };
    };

    # ── Web Extensions ─────────────────────────────────────────────────
    webExtensions = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };

      image = {
        registry = lib.mkOption {
          type = lib.types.str;
          default = "docker.io";
        };
        repository = lib.mkOption {
          type = lib.types.str;
          default = "opencloudeu/web-extensions";
        };
      };

      extensions = {
        drawio.tag = lib.mkOption { type = lib.types.str; default = "draw-io-1.0.0"; };
        externalsites.tag = lib.mkOption { type = lib.types.str; default = "external-sites-1.0.0"; };
        importer.tag = lib.mkOption { type = lib.types.str; default = "importer-1.0.0"; };
        jsonviewer.tag = lib.mkOption { type = lib.types.str; default = "json-viewer-1.0.0"; };
        progressbars.tag = lib.mkOption { type = lib.types.str; default = "progress-bars-1.0.0"; };
        unzip.tag = lib.mkOption { type = lib.types.str; default = "unzip-1.0.0"; };
      };
    };

    # ── Busybox (init containers) ──────────────────────────────────────
    busybox.image = mkImageOption {
      repository = "library/busybox";
      tag = "1.36";
    };
  };

  config = lib.mkIf cfg.enable {
    cluster.resources.opencloud = import ./resources.nix {
      inherit lib k8s cfg;
    };
  };
}
