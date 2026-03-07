# Theia IDE Helm chart values
{ lib, yaml, cfg }:
let
  chart = yaml.downloadHelmChart {
    repo = "https://bjw-s-labs.github.io/helm-charts/";
    chart = "app-template";
    version = "4.6.2";
    chartHash = "sha256-+ClIestqvDytE459npFyVU4ET2Rsy1CC3XgKY/vnRrs=";
  };

  defaults = {
    controllers.main = {
      containers.main = {
        image = {
          repository = "ghcr.io/eclipse-theia/theia-ide/theia-ide";
          tag = "latest";
        };
      };
    };

    service.main = {
      controller = "main";
      ports.http = {
        port = 3000;
      };
    };

    persistence.data = {
      enabled = true;
      type = "persistentVolumeClaim";
      accessMode = "ReadWriteOnce";
      size = "10Gi";
      globalMounts = [
        { path = "/home/theia"; }
      ];
    };
  };
in
yaml.fromHelm {
  name = "theia-ide";
  inherit chart;
  namespace = cfg.namespace;
  values = lib.recursiveUpdate defaults cfg.values;
}
