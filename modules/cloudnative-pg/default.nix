# cluster/modules/cloudnative-pg — CloudNativePG operator + database instances
# Deploys the CNPG operator and all declared PostgreSQL clusters.
# Individual app modules declare their databases here centrally.
{ config, lib, yaml, k8s, ... }:
let
  cfg = config.cluster.apps.cloudnative-pg;

  # Build a CNPG Cluster resource from a database submodule config
  mkPgCluster = _name: db: {
    apiVersion = "postgresql.cnpg.io/v1";
    kind = "Cluster";
    metadata = {
      name = db.name;
      namespace = db.namespace;
    };
    spec = {
      instances = db.instances;
      storage = {
        size = db.storageSize;
      };
      bootstrap = {
        initdb = {
          database = db.database;
          owner = db.owner;
        }
        // lib.optionalAttrs (db.credentialSecretName != null) {
          secret.name = db.credentialSecretName;
        }
        // lib.optionalAttrs (db.postInitSQL != []) {
          postInitSQL = db.postInitSQL;
        }
        // lib.optionalAttrs (db.postInitApplicationSQL != []) {
          postInitApplicationSQL = db.postInitApplicationSQL;
        };
      };
    };
  };

  pgClusters = lib.mapAttrsToList mkPgCluster cfg.databases;
in
{
  options.cluster.apps.cloudnative-pg = {
    enable = lib.mkEnableOption "CloudNativePG operator and database instances";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "cnpg-system";
      description = "Namespace for the CNPG operator.";
    };

    values = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Helm chart value overrides, deep-merged with module defaults.";
    };

    databases = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            default = "${name}-pg";
            description = "CNPG Cluster resource name.";
          };

          namespace = lib.mkOption {
            type = lib.types.str;
            description = "Namespace for this database cluster.";
          };

          database = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Database name to create.";
          };

          owner = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Database owner role.";
          };

          instances = lib.mkOption {
            type = lib.types.int;
            default = 1;
            description = "Number of PostgreSQL instances.";
          };

          storageSize = lib.mkOption {
            type = lib.types.str;
            default = "5Gi";
            description = "PVC storage size for the database.";
          };

          credentialSecretName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "K8s Secret with bootstrap credentials. If null, CNPG auto-generates.";
          };

          postInitSQL = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "SQL statements to run after database creation (as superuser).";
          };

          postInitApplicationSQL = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "SQL statements to run after database creation (as the owner role).";
          };
        };
      }));
      default = {};
      description = "PostgreSQL database instances managed by CNPG.";
    };
  };

  config = lib.mkIf cfg.enable {
    cluster.resources.cloudnative-pg =
      (import ./helm.nix { inherit lib yaml cfg; })
      ++ pgClusters;
  };
}
