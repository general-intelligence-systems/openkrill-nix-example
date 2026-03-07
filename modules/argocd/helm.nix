# ArgoCD Helm chart values
{ lib, yaml, cfg }:
let
  caCert = builtins.readFile cfg.caCertFile;
  indentedCaCert = builtins.replaceStrings [ "\n" ] [ "\n  " ] caCert;

  # Build TLS certificates attrset from trustedDomains
  tlsCerts = builtins.listToAttrs (map (d: {
    name = d;
    value = caCert;
  }) cfg.trustedDomains);

  defaults = {
    fullnameOverride = "argocd";
    configs = {
      params = {
        "server.insecure" = "true";
      };
      tls = {
        certificates = tlsCerts;
      };
      cm = {
        url = "https://${cfg.domain}";
        "oidc.config" = ''
          name: Authelia
          issuer: ${cfg.oidc.issuer}
          clientID: argocd
          clientSecret: $argocd-oidc-secret:oidc.authelia.clientSecret
          clientAuthMethod: client_secret_basic
          rootCA: |
            ${indentedCaCert}
          requestedScopes:
            - openid
            - email
            - groups
            - profile
          enableUserInfoGroups: true
          userInfoPath: /api/oidc/userinfo
          userIDKey: email
        '';
      };
      rbac = {
        "policy.csv" = ''
          g, nathankidd@hey.com, role:admin
          p, role:admin, applications, *, */*, allow
          p, role:admin, clusters, *, *, allow
          p, role:admin, repositories, *, *, allow
          p, role:admin, projects, *, *, allow
          p, deploy-bot, applications, sync, */*, allow
          p, deploy-bot, applications, get, */*, allow
        '';
        "policy.default" = "role:readonly";
        scopes = "[email, groups]";
      };
    };
  };
in
yaml.fromHelm {
  name = "argo-cd";
  chart = yaml.charts.argoproj.argo-cd;
  namespace = cfg.namespace;
  values = lib.recursiveUpdate defaults cfg.values;
}
