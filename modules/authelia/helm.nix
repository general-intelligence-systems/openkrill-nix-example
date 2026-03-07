# Authelia Helm chart values
{ lib, yaml, cfg }:
let
  defaults = {
    pod = {
      kind = "Deployment";
      replicas = 1;
    };

    secret = {
      existingSecret = "authelia";
      additionalSecrets = {
        authelia = {
          items = [
            {
              key = "identity_providers.oidc.jwks.0.key";
              path = "identity_providers.oidc.jwks.0.key";
            }
          ];
        };
      };
    };

    configMap = {
      authentication_backend = {
        ldap = {
          enabled = true;
          implementation = "lldap";
          address = cfg.ldapAddress;
          base_dn = cfg.ldapBaseDn;
          user = "uid=admin,ou=people,${cfg.ldapBaseDn}";
          password = {
            disabled = false;
          };
        };
      };

      session = {
        cookies = cfg.sessionCookies;
      };

      storage = {
        local = {
          enabled = true;
          path = "/config/db.sqlite3";
        };
      };

      notifier = {
        filesystem = {
          enabled = true;
          filename = "/config/notification.txt";
        };
      };

      access_control = {
        default_policy = "one_factor";
      } // (if cfg.accessControlRules != [] then {
        rules = cfg.accessControlRules;
      } else {});

      identity_providers = {
        oidc = {
          enabled = true;

          hmac_secret = {
            path = "identity_providers.oidc.hmac_secret";
          };

          jwks = [
            {
              key = {
                path = "/secrets/authelia/identity_providers.oidc.jwks.0.key";
              };
            }
          ];

          cors = {
            endpoints = [
              "authorization"
              "token"
              "revocation"
              "introspection"
              "userinfo"
            ];
            allowed_origins_from_client_redirect_uris = true;
          };

          clients = map (c:
            lib.filterAttrs (_: v: v != null) {
              client_id = c.client_id;
              client_name = c.name;
              client_secret = c.client_secret;
              inherit (c) public authorization_policy redirect_uris
                scopes response_types grant_types
                access_token_signed_response_alg
                userinfo_signed_response_alg
                token_endpoint_auth_method
                claims_policy require_pkce;
            } // c.extraConfig
          ) cfg.oidcClients;
        } // (if cfg.claimsPolicies != {} then {
          claims_policies = cfg.claimsPolicies;
        } else {});
      };
    };
  };
in
yaml.fromHelm {
  name = "authelia";
  chart = yaml.charts.authelia.authelia;
  namespace = cfg.namespace;
  extraOpts = [ "--skip-schema-validation" ];
  values = lib.recursiveUpdate defaults cfg.values;
}
