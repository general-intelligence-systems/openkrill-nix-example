# lib/yaml.nix — YAML serialization/parsing primitives
# Thin re-export of nix-kube-generators under the spec's yaml.* namespace,
# plus the nixhelm chart catalog on yaml.charts.
{
  pkgs,
  kubelib,
  charts,
}:
{
  inherit (kubelib)
    toYAMLStreamFile # [attrset] → derivation (multi-doc YAML)
    toYAMLFile # attrset → derivation (single-doc YAML)
    fromYAML # string → [attrset]
    fromHelm # { name, chart, namespace?, values?, ... } → [attrset] (IFD)
    downloadHelmChart # { repo, chart, version, chartHash } → derivation (chart dir)
    buildHelmChart
    ; # { name, chart, ... } → derivation (raw YAML)
  inherit charts; # nixhelm catalog: yaml.charts.argoproj.argo-cd etc.
}
