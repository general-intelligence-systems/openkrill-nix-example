# cert-manager Helm chart values
{ lib, yaml, cfg }:
let
  defaults = {
    crds.enabled = true;
  };
in
yaml.fromHelm {
  name = "cert-manager";
  chart = yaml.charts.jetstack.cert-manager;
  namespace = cfg.namespace;
  values = lib.recursiveUpdate defaults cfg.values;
}
