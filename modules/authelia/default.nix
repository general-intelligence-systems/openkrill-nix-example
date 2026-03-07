# cluster/modules/authelia — Authelia SSO portal + OIDC provider
# Provides ext_authz authentication for all services via Istio.
# Acts as OpenID Connect 1.0 provider for ArgoCD, Windmill, Harbor, etc.
# Uses LLDAP as the user directory backend.
{ config, lib, yaml, k8s, ... }:
let
  cfg = config.cluster.apps.authelia;
  domain = config.cluster.domain;

  # Derive client_id from display name: lowercase and remove spaces.
  #   "Argo CD" → "argocd"
  mkClientId = name:
    lib.replaceStrings [ " " ] [ "" ] (lib.toLower name);

  oidcClientModule = lib.types.submodule ({ config, ... }: {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Display name for this OIDC client (also used to derive client_id).";
      };

      client_id = lib.mkOption {
        type = lib.types.str;
        default = mkClientId config.name;
        description = "OIDC client identifier. Defaults to lowercased name with spaces removed.";
      };

      redirect_uris = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Allowed redirect URIs for this client.";
      };

      client_secret = lib.mkOption {
        type = lib.types.str;
        default = "$plaintext$${config.client_id}-oidc-client-secret-${domain}";
        description = "Client secret. Defaults to a deterministic plaintext secret.";
      };

      public = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether this is a public (no secret) client.";
      };

      authorization_policy = lib.mkOption {
        type = lib.types.str;
        default = "one_factor";
        description = "Authelia authorization policy for this client.";
      };

      scopes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "openid" "profile" "email" "groups" ];
        description = "Allowed OIDC scopes.";
      };

      response_types = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "code" ];
        description = "Allowed response types.";
      };

      grant_types = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "authorization_code" ];
        description = "Allowed grant types.";
      };

      access_token_signed_response_alg = lib.mkOption {
        type = lib.types.str;
        default = "none";
        description = "Algorithm for signing access token responses.";
      };

      userinfo_signed_response_alg = lib.mkOption {
        type = lib.types.str;
        default = "none";
        description = "Algorithm for signing userinfo responses.";
      };

      token_endpoint_auth_method = lib.mkOption {
        type = lib.types.str;
        default = "client_secret_basic";
        description = "Token endpoint authentication method.";
      };

      claims_policy = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Claims policy name. Omitted from config when null.";
      };

      require_pkce = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether to require PKCE. Omitted from config when null.";
      };

      extraConfig = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "Additional attributes merged into the client config.";
      };
    };
  });
in
{
  options.cluster.apps.authelia = {
    enable = lib.mkEnableOption "Authelia SSO portal + OIDC provider";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "authelia";
    };

    ldapAddress = lib.mkOption {
      type = lib.types.str;
      default = "ldap://lldap.lldap.svc.cluster.local:3890";
      description = "LDAP server address.";
    };

    ldapBaseDn = lib.mkOption {
      type = lib.types.str;
      description = "LDAP base DN (e.g. dc=cia,dc=net).";
    };

    sessionCookies = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      description = "Authelia session cookie configurations.";
    };

    accessControlRules = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [];
      description = "Authelia access control rules.";
    };

    claimsPolicies = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Authelia claims policies for OIDC.";
    };

    oidcClients = lib.mkOption {
      type = lib.types.listOf oidcClientModule;
      default = [];
      description = "OIDC client configurations. Only 'name' and 'redirect_uris' are required.";
    };

    values = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Helm chart value overrides, deep-merged with module defaults.";
    };
  };

  config = lib.mkIf cfg.enable {
    cluster.resources.authelia = import ./helm.nix {
      inherit lib yaml cfg;
    };
  };
}
