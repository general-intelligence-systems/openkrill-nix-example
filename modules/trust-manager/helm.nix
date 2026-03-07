# trust-manager Helm chart + Bundle resource
{ lib, yaml, cfg }:
let
  chart = yaml.downloadHelmChart {
    repo = "https://charts.jetstack.io/";
    chart = "trust-manager";
    version = "v0.16.0";
    chartHash = "sha256-fbvGdEiLj0Y4iDDU2XF9+mXMwEY23BtwLZxB13WWwus=";
  };

  defaults = {
    crds.enabled = true;
  };

  helmResources = yaml.fromHelm {
    name = "trust-manager";
    inherit chart;
    namespace = cfg.namespace;
    values = lib.recursiveUpdate defaults cfg.values;
  };

  # Bundle: merge public CAs + internal cluster CA, sync to labelled namespaces
  bundle = {
    apiVersion = "trust.cert-manager.io/v1alpha1";
    kind = "Bundle";
    metadata.name = cfg.bundleConfigMapName;
    spec = {
      sources = [
        { useDefaultCAs = true; }
        {
          secret = {
            name = cfg.caSecretName;
            key = cfg.caSecretKey;
          };
        }
      ];
      target = {
        configMap.key = cfg.bundleKey;
        namespaceSelector.matchLabels."trust-bundle" = "true";
      };
    };
  };

in
helmResources ++ [ bundle ]
