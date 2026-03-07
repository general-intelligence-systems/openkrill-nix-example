# lib/k8s.nix — helper constructors (mkApp, mkIngress, mkNamespace, mkSecret)
{ pkgs, yaml }:
let
  repoURL = "ssh://git@basic-git.basic-git.svc.cluster.local/srv/git/manifests.git";
in
rec {
  # ── mkApp ──────────────────────────────────────────────────────────────
  # ArgoCD Application with sensible defaults.
  # CreateNamespace=true and automated.enabled are always included.
  mkApp =
    {
      name,
      path,
      namespace ? name,
      project ? "default",
      targetRevision ? "manifests",
      serverSideApply ? false,
    }:
    {
      apiVersion = "argoproj.io/v1alpha1";
      kind = "Application";
      metadata = {
        inherit name;
        namespace = "argocd";
      };
      spec = {
        inherit project;
        source = { inherit repoURL path targetRevision; };
        destination = {
          server = "https://kubernetes.default.svc";
        }
        // (if namespace != null then { inherit namespace; } else { });
        syncPolicy = {
          automated = {
            prune = true;
            selfHeal = true;
            enabled = true;
          };
          syncOptions = [
            "CreateNamespace=true"
          ]
          ++ pkgs.lib.optional serverSideApply "ServerSideApply=true";
        };
      };
    };

  # ── mkNamespace ────────────────────────────────────────────────────────
  mkNamespace = name: {
    apiVersion = "v1";
    kind = "Namespace";
    metadata = { inherit name; };
  };

  # ── mkSecret ───────────────────────────────────────────────────────────
  mkSecret =
    {
      name,
      namespace,
      stringData,
    }:
    {
      apiVersion = "v1";
      kind = "Secret";
      metadata = { inherit name namespace; };
      type = "Opaque";
      inherit stringData;
    };

  # ── mkIngress ──────────────────────────────────────────────────────────
  # Ingress with optional TLS via cert-manager.
  mkIngress =
    {
      name,
      namespace,
      host,
      serviceName,
      servicePort,
      tlsSecretName ? null,
      ingressClass ? "istio",
    }:
    {
      apiVersion = "networking.k8s.io/v1";
      kind = "Ingress";
      metadata = {
        inherit name namespace;
      }
      // pkgs.lib.optionalAttrs (tlsSecretName != null) {
        annotations."cert-manager.io/cluster-issuer" = "letsencrypt";
      };
      spec = {
        ingressClassName = ingressClass;
        rules = [
          {
            inherit host;
            http.paths = [
              {
                path = "/";
                pathType = "Prefix";
                backend.service = {
                  name = serviceName;
                  port.number = servicePort;
                };
              }
            ];
          }
        ];
      }
      // pkgs.lib.optionalAttrs (tlsSecretName != null) {
        tls = [
          {
            hosts = [ host ];
            secretName = tlsSecretName;
          }
        ];
      };
    };
}
