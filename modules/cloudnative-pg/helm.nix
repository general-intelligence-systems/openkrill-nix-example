# CloudNativePG operator Helm chart
{ lib, yaml, cfg }:
let
  defaults = { };
in
yaml.fromHelm {
  name = "cloudnative-pg";
  chart = yaml.charts.cloudnative-pg.cloudnative-pg;
  namespace = cfg.namespace;
  values = lib.recursiveUpdate defaults cfg.values;
}
