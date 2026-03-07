# OpenCloud K8s resources — pure nix, no helm
# Returns a flat list of K8s resource attrsets.
{ lib, k8s, cfg }:
let
  ns = cfg.namespace;

  # ── Naming ────────────────────────────────────────────────────────────
  # Matches the helm chart's {{ include "oc.*.fullname" . }} pattern
  # with release name "opencloud" and chart name "opencloud-custom".
  opencloudName     = "opencloud";
  collaboraName     = "opencloud-collabora";
  collaborationName = "opencloud-collaboration";
  tikaName          = "opencloud-tika";

  # ── Image helper ──────────────────────────────────────────────────────
  mkImage = img:
    if img.registry != ""
    then "${img.registry}/${img.repository}:${img.tag}"
    else "${img.repository}:${img.tag}";

  mkExtImage = tag: let img = cfg.webExtensions.image; in
    if img.registry != ""
    then "${img.registry}/${img.repository}:${tag}"
    else "${img.repository}:${tag}";

  # ── Labels ────────────────────────────────────────────────────────────
  commonLabels = component: {
    "app.kubernetes.io/name" = "opencloud-custom";
    "app.kubernetes.io/instance" = "opencloud";
    "app.kubernetes.io/version" = cfg.image.tag;
    "app.kubernetes.io/managed-by" = "nix";
    "app.kubernetes.io/component" = component;
  };

  selectorLabels = component: {
    "app.kubernetes.io/name" = "opencloud-custom";
    "app.kubernetes.io/instance" = "opencloud";
    "app.kubernetes.io/component" = component;
  };

  # ── Inline file contents ──────────────────────────────────────────────

  appRegistryYaml = ''
    app_registry:
      mimetypes:
      - mime_type: application/pdf
        extension: pdf
        name: PDF
        description: PDF document
        icon: ""
        default_app: ""
        allow_creation: false
      - mime_type: application/vnd.oasis.opendocument.text
        extension: odt
        name: OpenDocument
        description: OpenDocument text document
        icon: ""
        default_app: Collabora
        allow_creation: true
      - mime_type: application/vnd.oasis.opendocument.spreadsheet
        extension: ods
        name: OpenSpreadsheet
        description: OpenDocument spreadsheet document
        icon: ""
        default_app: Collabora
        allow_creation: true
      - mime_type: application/vnd.oasis.opendocument.presentation
        extension: odp
        name: OpenPresentation
        description: OpenDocument presentation document
        icon: ""
        default_app: Collabora
        allow_creation: true
      - mime_type: application/vnd.openxmlformats-officedocument.wordprocessingml.document
        extension: docx
        name: Microsoft Word
        description: Microsoft Word document
        icon: ""
        default_app: Collabora
        allow_creation: true
      - mime_type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
        extension: xlsx
        name: Microsoft Excel
        description: Microsoft Excel document
        icon: ""
        default_app: Collabora
        allow_creation: true
      - mime_type: application/vnd.openxmlformats-officedocument.presentationml.presentation
        extension: pptx
        name: Microsoft PowerPoint
        description: Microsoft PowerPoint document
        icon: ""
        default_app: Collabora
        allow_creation: true
      - mime_type: application/vnd.jupyter
        extension: ipynb
        name: Jupyter Notebook
        description: Jupyter Notebook
        icon: ""
        default_app: ""
        allow_creation: true
  '';

  # CSP directives — generated from domain/collabora/OIDC config
  oidcIssuerHost = lib.removePrefix "https://" (lib.removePrefix "http://" cfg.oidc.issuer);

  cspYaml = ''
    directives:
      child-src:
        - "'self'"
      connect-src:
        - "'self'"
        - "blob:"
        - "https://raw.githubusercontent.com/opencloud-eu/awesome-apps/"
        - "https://${oidcIssuerHost}/"
      default-src:
        - "'none'"
      font-src:
        - "'self'"
      frame-ancestors:
        - "'self'"
      frame-src:
        - "'self'"
        - "blob:"
        - "https://embed.diagrams.net/"
        - "https://${cfg.collabora.domain}/"
        - "https://docs.opencloud.eu"
      img-src:
        - "'self'"
        - "data:"
        - "blob:"
        - "https://raw.githubusercontent.com/opencloud-eu/awesome-apps/"
        - "https://${cfg.collabora.domain}/"
      manifest-src:
        - "'self'"
      media-src:
        - "'self'"
      object-src:
        - "'self'"
        - "blob:"
      script-src:
        - "'self'"
        - "'unsafe-inline'"
      style-src:
        - "'self'"
        - "'unsafe-inline'"
      worker-src:
        - "'self'"
  '';

  searchYaml = builtins.toJSON {
    mapping.file.properties = {
      name    = { type = "text"; analyzer = "standard"; };
      content = { type = "text"; analyzer = "standard"; };
      mime_type = { type = "keyword"; };
      owner   = { type = "keyword"; };
      path    = { type = "text"; analyzer = "standard"; };
    };
  };

  webExtensionsInitScript = ''
    #!/bin/sh
    set -e
    mkdir -p /var/lib/opencloud/web/assets/apps
    echo "Initializing Draw.io extension..."
    cp -R /extensions/draw-io/ /var/lib/opencloud/web/assets/apps/
    echo "Initializing External Sites extension..."
    cp -R /extensions/external-sites/ /var/lib/opencloud/web/assets/apps/
    echo "Initializing Importer extension..."
    cp -R /extensions/importer/ /var/lib/opencloud/web/assets/apps/
    echo "Initializing JSON Viewer extension..."
    cp -R /extensions/json-viewer/ /var/lib/opencloud/web/assets/apps/
    echo "Initializing Progress Bars extension..."
    cp -R /extensions/progress-bars/ /var/lib/opencloud/web/assets/apps/
    echo "Initializing Unzip extension..."
    cp -R /extensions/unzip/ /var/lib/opencloud/web/assets/apps/
    echo "Web extensions initialization completed."
  '';

  # ── Helper: env var shorthand ─────────────────────────────────────────
  env = name: value: { inherit name; value = toString value; };
  envSecret = name: secretName: key: {
    inherit name;
    valueFrom.secretKeyRef = { name = secretName; inherit key; };
  };

  boolStr = b: if b then "true" else "false";

  busyboxImage = mkImage cfg.busybox.image;

  # ── Web extension init containers ─────────────────────────────────────
  extInitContainer = { name, extName, tag }: {
    inherit name;
    image = mkExtImage tag;
    command = [ "sh" "-c" "mkdir -p /extensions/${extName} && cp -R /usr/share/nginx/html/${extName}/ /extensions/" ];
    volumeMounts = [{ name = "extensions"; mountPath = "/extensions"; }];
  };

  webExtInitContainers = lib.optionals cfg.webExtensions.enable [
    (extInitContainer { name = "init-drawio";        extName = "draw-io";        tag = cfg.webExtensions.extensions.drawio.tag; })
    (extInitContainer { name = "init-externalsites"; extName = "external-sites"; tag = cfg.webExtensions.extensions.externalsites.tag; })
    (extInitContainer { name = "init-importer";      extName = "importer";       tag = cfg.webExtensions.extensions.importer.tag; })
    (extInitContainer { name = "init-jsonviewer";    extName = "json-viewer";    tag = cfg.webExtensions.extensions.jsonviewer.tag; })
    (extInitContainer { name = "init-progressbars";  extName = "progress-bars";  tag = cfg.webExtensions.extensions.progressbars.tag; })
    (extInitContainer { name = "init-unzip";         extName = "unzip";          tag = cfg.webExtensions.extensions.unzip.tag; })
    {
      name = "init-web-extensions";
      image = busyboxImage;
      imagePullPolicy = "IfNotPresent";
      command = [ "sh" "/scripts/init-web-extensions.sh" ];
      volumeMounts = [
        { name = "extensions"; mountPath = "/extensions"; }
        { name = "data";       mountPath = "/var/lib/opencloud"; }
        { name = "web-extensions-init-script"; mountPath = "/scripts"; }
      ];
    }
  ];

in
[
  # ════════════════════════════════════════════════════════════════════════
  # ConfigMap: config.json (web UI config)
  # ════════════════════════════════════════════════════════════════════════
  {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = "${opencloudName}-config-json";
      namespace = ns;
      labels = commonLabels "opencloud";
    };
    data."config.json" = builtins.toJSON {
      server = "https://${cfg.domain}";
      theme = "owncloud";
      version = "0.1.0";
    };
  }

  # ════════════════════════════════════════════════════════════════════════
  # ConfigMap: config files (app-registry, CSP, banned-passwords, search)
  # ════════════════════════════════════════════════════════════════════════
  {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = "${opencloudName}-config";
      namespace = ns;
      labels = commonLabels "opencloud";
    };
    data = {
      "app-registry.yaml" = appRegistryYaml;
      "csp.yaml" = cspYaml;
      "banned-password-list.txt" = "";
      "search.yaml" = searchYaml;
    };
  }

  # ════════════════════════════════════════════════════════════════════════
  # PVC: config volume
  # ════════════════════════════════════════════════════════════════════════
  {
    apiVersion = "v1";
    kind = "PersistentVolumeClaim";
    metadata = {
      name = "${opencloudName}-config";
      namespace = ns;
      labels = commonLabels "opencloud";
      annotations."helm.sh/resource-policy" = "keep";
    };
    spec = {
      accessModes = [ "ReadWriteOnce" ];
      resources.requests.storage = cfg.persistence.config.size;
    };
  }

  # ════════════════════════════════════════════════════════════════════════
  # PVC: data volume
  # ════════════════════════════════════════════════════════════════════════
  {
    apiVersion = "v1";
    kind = "PersistentVolumeClaim";
    metadata = {
      name = "${opencloudName}-data";
      namespace = ns;
      labels = commonLabels "opencloud";
      annotations."helm.sh/resource-policy" = "keep";
    };
    spec = {
      accessModes = [ "ReadWriteOnce" ];
      resources.requests.storage = cfg.persistence.data.size;
    };
  }

  # ════════════════════════════════════════════════════════════════════════
  # Deployment: OpenCloud (main server)
  # ════════════════════════════════════════════════════════════════════════
  {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = {
      name = opencloudName;
      namespace = ns;
      labels = commonLabels "opencloud";
      annotations."reloader.stakater.com/auto" = "true";
    };
    spec = {
      replicas = 1;
      strategy.type = "Recreate";
      selector.matchLabels = selectorLabels "opencloud";
      template = {
        metadata.labels = selectorLabels "opencloud";
        spec = {
          securityContext = {
            fsGroup = 1000;
            fsGroupChangePolicy = "OnRootMismatch";
          };
          initContainers = [
            {
              name = "init-dirs";
              image = busyboxImage;
              imagePullPolicy = "IfNotPresent";
              command = [ "sh" "-c" "mkdir -p /etc/opencloud /var/lib/opencloud" ];
              volumeMounts = [
                { name = "config"; mountPath = "/etc/opencloud"; }
                { name = "data";   mountPath = "/var/lib/opencloud"; }
              ];
            }
          ] ++ webExtInitContainers;
          containers = [
            ({
              name = "opencloud";
              image = mkImage cfg.image;
              imagePullPolicy = "IfNotPresent";
              securityContext = {
                allowPrivilegeEscalation = false;
                capabilities.drop = [ "ALL" ];
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
              };
              command = [ "/bin/sh" ];
              args = [ "-c" "opencloud init || true; opencloud server" ];
              env = [
                # -- Core
                (env "OC_URL"        "https://${cfg.domain}")
                (env "OC_LOG_LEVEL"  cfg.logLevel)
                (env "OC_LOG_COLOR"  "false")
                (env "OC_LOG_PRETTY" "false")
                (env "OC_INSECURE"   (boolStr cfg.insecure))
                (env "PROXY_TLS"     "false")
                (env "GATEWAY_GRPC_ADDR" "0.0.0.0:9142")
                (env "GRAPH_AVAILABLE_ROLES" "b1e2218d-eef8-4d4c-b82d-0f1a1b48f3b5,a8d5fe5e-96e3-418d-825b-534dbdf22b99,fb6c3e19-e378-47e5-b277-9732f9de6e21,58c63c02-1d89-4572-916a-870abc5a1b7d,2d00ce52-1fc2-4dbc-8b95-a73b73395f5a,1c996275-f1c9-4e71-abdf-a42f6495e960,312c0871-5ef7-4b3a-85b6-0e4074c64049,aa97fe03-7980-45ac-9e50-b325749fd7e6")
                (env "OC_GRPC_MAX_RECEIVED_MESSAGE_SIZE" "102400000")

                # -- Exclude built-in IDP (using Authelia)
                (env "OC_EXCLUDE_RUN_SERVICES" "idp")

                # -- OIDC (Authelia)
                (env "PROXY_AUTOPROVISION_ACCOUNTS"           "true")
                (env "PROXY_ENABLE_BASIC_AUTH"                 "false")
                (env "PROXY_ROLE_ASSIGNMENT_DRIVER"            "oidc")
                (env "PROXY_ROLE_ASSIGNMENT_OIDC_CLAIM"        cfg.oidc.roleClaim)
                (env "PROXY_USER_OIDC_CLAIM"                   cfg.oidc.userClaim)
                (env "PROXY_USER_CS3_CLAIM"                    "username")
                (env "PROXY_OIDC_REWRITE_WELLKNOWN"            "true")
                (env "PROXY_OIDC_ACCESS_TOKEN_VERIFY_METHOD"   "jwt")
                (env "OC_OIDC_ISSUER"                          cfg.oidc.issuer)
                (env "WEB_OIDC_CLIENT_ID"                      cfg.oidc.clientId)
                (env "WEB_OIDC_SCOPE"                          cfg.oidc.scope)
                (env "WEB_OIDC_METADATA_URL"                   "${cfg.oidc.issuer}/.well-known/openid-configuration")
                (env "FRONTEND_READONLY_USER_ATTRIBUTES"       "user.onPremisesSamAccountName,user.displayName,user.mail,user.passwordProfile,user.accountEnabled,user.appRoleAssignments")
                (env "OC_ADMIN_USER_ID"                        "")
                (env "GRAPH_ASSIGN_DEFAULT_USER_ROLE"          "false")
                (env "GRAPH_USERNAME_MATCH"                     "none")

                # -- Admin password
                (envSecret "IDM_ADMIN_PASSWORD" cfg.existingSecret "adminPassword")
                (env "IDM_CREATE_DEMO_USERS" (boolStr cfg.createDemoUsers))

                # -- NATS (in-process)
                (env "MICRO_REGISTRY_ADDRESS" "127.0.0.1:9233")
                (env "NATS_NATS_HOST"         "0.0.0.0")
                (env "NATS_NATS_PORT"         "9233")

                # -- S3 storage
                (env "STORAGE_USERS_DRIVER"                      "decomposeds3")
                (env "STORAGE_SYSTEM_DRIVER"                     "decomposed")
                (env "STORAGE_USERS_DECOMPOSEDS3_ENDPOINT"       cfg.s3.endpoint)
                (env "STORAGE_USERS_DECOMPOSEDS3_REGION"         cfg.s3.region)
                (env "STORAGE_USERS_DECOMPOSEDS3_BUCKET"         cfg.s3.bucket)
                (env "STORAGE_USERS_DECOMPOSEDS3_CREATE_BUCKET"  (boolStr cfg.s3.createBucket))
                (envSecret "STORAGE_USERS_DECOMPOSEDS3_ACCESS_KEY" cfg.s3.existingSecret "accessKey")
                (envSecret "STORAGE_USERS_DECOMPOSEDS3_SECRET_KEY" cfg.s3.existingSecret "secretKey")

                # -- Search / Tika
                (env "SEARCH_EXTRACTOR_TYPE"          "tika")
                (env "SEARCH_EXTRACTOR_TIKA_TIKA_URL" "http://${tikaName}:9998")

                # -- Sharing
                (env "OC_SHARING_PUBLIC_SHARE_MUST_HAVE_PASSWORD" "false")
                (env "OC_PASSWORD_POLICY_BANNED_PASSWORDS_LIST"  "banned-password-list.txt")

                # -- CSP
                (env "PROXY_CSP_CONFIG_FILE_LOCATION" "/etc/opencloud/csp.yaml")

                # -- Collabora domain
                (env "COLLABORA_DOMAIN" cfg.collabora.domain)
              ]
              ++ lib.optionals (cfg.oidc.accountUrl != "") [
                (env "WEB_OPTION_ACCOUNT_EDIT_LINK_HREF" cfg.oidc.accountUrl)
              ]
              ++ lib.optionals cfg.smtp.enable [
                (env "NOTIFICATIONS_SMTP_HOST"           cfg.smtp.host)
                (env "NOTIFICATIONS_SMTP_PORT"           cfg.smtp.port)
                (env "NOTIFICATIONS_SMTP_SENDER"         (if cfg.smtp.sender != "" then cfg.smtp.sender else "OpenCloud <notifications@${cfg.domain}>"))
                (envSecret "NOTIFICATIONS_SMTP_USERNAME"  cfg.smtp.existingSecret "smtpUser")
                (envSecret "NOTIFICATIONS_SMTP_PASSWORD"  cfg.smtp.existingSecret "smtpPassword")
                (env "NOTIFICATIONS_SMTP_INSECURE"       (boolStr cfg.smtp.insecure))
                (env "NOTIFICATIONS_SMTP_AUTHENTICATION" cfg.smtp.authentication)
                (env "NOTIFICATIONS_SMTP_ENCRYPTION"     cfg.smtp.encryption)
              ]
              ++ cfg.env;
              ports = [
                { name = "http"; containerPort = 9200; }
                { name = "nats"; containerPort = 9233; }
              ];
              startupProbe = {
                httpGet = { path = "/health"; port = 9200; };
                periodSeconds = 2;
                timeoutSeconds = 5;
                failureThreshold = 60;
              };
              livenessProbe = {
                httpGet = { path = "/health"; port = 9200; };
                periodSeconds = 10;
                timeoutSeconds = 5;
                failureThreshold = 3;
              };
              readinessProbe = {
                httpGet = { path = "/health"; port = 9200; };
                periodSeconds = 5;
                timeoutSeconds = 5;
                failureThreshold = 3;
              };
              volumeMounts = [
                { name = "config";       mountPath = "/etc/opencloud"; }
                { name = "data";         mountPath = "/var/lib/opencloud"; }
                { name = "config-json";  mountPath = "/var/lib/opencloud/config.json"; subPath = "config.json"; }
                { name = "config-files"; mountPath = "/etc/opencloud/search.yaml";              subPath = "search.yaml"; }
                { name = "config-files"; mountPath = "/etc/opencloud/csp.yaml";                 subPath = "csp.yaml"; }
                { name = "config-files"; mountPath = "/etc/opencloud/banned-password-list.txt";  subPath = "banned-password-list.txt"; }
              ];
              resources = cfg.resources;
            } // lib.optionalAttrs (cfg.envFrom != []) {
              envFrom = cfg.envFrom;
            })
          ];
          volumes = [
            { name = "config";       persistentVolumeClaim.claimName = "${opencloudName}-config"; }
            { name = "data";         persistentVolumeClaim.claimName = "${opencloudName}-data"; }
            { name = "config-json";  configMap.name = "${opencloudName}-config-json"; }
            { name = "config-files"; configMap.name = "${opencloudName}-config"; }
          ]
          ++ lib.optionals cfg.webExtensions.enable [
            { name = "extensions"; emptyDir = {}; }
            { name = "web-extensions-init-script"; configMap.name = "${opencloudName}-web-extensions-init"; }
          ];
        };
      };
    };
  }

  # ════════════════════════════════════════════════════════════════════════
  # Service: OpenCloud (HTTP 9200 + NATS 9233)
  # ════════════════════════════════════════════════════════════════════════
  {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      name = opencloudName;
      namespace = ns;
      labels = commonLabels "opencloud";
    };
    spec = {
      type = "ClusterIP";
      selector = selectorLabels "opencloud";
      ports = [
        { port = 9200; targetPort = "http"; protocol = "TCP"; name = "http"; }
        { port = 9233; targetPort = 9233;   protocol = "TCP"; name = "nats"; }
      ];
    };
  }

  # ════════════════════════════════════════════════════════════════════════
  # Deployment: Collabora CODE
  # ════════════════════════════════════════════════════════════════════════
  {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = {
      name = collaboraName;
      namespace = ns;
      labels = commonLabels "collabora";
    };
    spec = {
      replicas = 1;
      selector.matchLabels = selectorLabels "collabora";
      template = {
        metadata.labels = selectorLabels "collabora";
        spec.containers = [
          {
            name = "collabora";
            image = mkImage cfg.collabora.image;
            imagePullPolicy = "IfNotPresent";
            command = [ "/bin/bash" "-c" ];
            args = [ "coolconfig generate-proof-key && /start-collabora-online.sh" ];
            env = [
              (env "aliasgroup1"      "http://${collaborationName}:9300,https://${cfg.collabora.domain}")
              (env "DONT_GEN_SSL_CERT" "YES")
              (env "extra_params"      "--o:ssl.enable=${boolStr cfg.collabora.ssl.enabled} --o:ssl.ssl_verification=${boolStr cfg.collabora.ssl.verification} --o:ssl.termination=true --o:welcome.enable=false --o:net.frame_ancestors=${cfg.domain}")
              (envSecret "username" cfg.collabora.admin.existingSecret "username")
              (envSecret "password" cfg.collabora.admin.existingSecret "password")
            ];
            ports = [
              { containerPort = 9980; name = "http"; protocol = "TCP"; }
            ];
            livenessProbe = {
              httpGet = { path = "/hosting/discovery"; port = "http"; };
              initialDelaySeconds = 60;
              periodSeconds = 10;
            };
            readinessProbe = {
              httpGet = { path = "/hosting/discovery"; port = "http"; };
              initialDelaySeconds = 30;
              periodSeconds = 10;
            };
            securityContext.capabilities.add = [ "MKNOD" ];
            resources = cfg.collabora.resources;
          }
        ];
      };
    };
  }

  # ════════════════════════════════════════════════════════════════════════
  # Service: Collabora (port 9980)
  # ════════════════════════════════════════════════════════════════════════
  {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      name = collaboraName;
      namespace = ns;
      labels = commonLabels "collabora";
    };
    spec = {
      type = "ClusterIP";
      selector = selectorLabels "collabora";
      ports = [
        { port = 9980; targetPort = "http"; protocol = "TCP"; name = "http"; }
      ];
    };
  }

  # ════════════════════════════════════════════════════════════════════════
  # Deployment: Collaboration sidecar (WOPI bridge)
  # ════════════════════════════════════════════════════════════════════════
  {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = {
      name = collaborationName;
      namespace = ns;
      labels = commonLabels "collaboration";
    };
    spec = {
      replicas = 1;
      selector.matchLabels = selectorLabels "collaboration";
      template = {
        metadata.labels = selectorLabels "collaboration";
        spec = {
          securityContext.fsGroup = 1000;
          initContainers = [
            {
              name = "wait-for-opencloud";
              image = busyboxImage;
              imagePullPolicy = "IfNotPresent";
              command = [ "sh" "-c" "until wget -q -O- http://${opencloudName}:9200/health; do echo waiting for opencloud; sleep 5; done;" ];
            }
            {
              name = "wait-for-collabora";
              image = busyboxImage;
              imagePullPolicy = "IfNotPresent";
              command = [ "sh" "-c" "until wget -q -O- http://${collaboraName}:9980/hosting/discovery; do echo waiting for collabora; sleep 2; done;" ];
            }
          ];
          containers = [
            {
              name = "collaboration";
              image = mkImage cfg.image;
              imagePullPolicy = "IfNotPresent";
              command = [ "/bin/sh" ];
              args = [ "-c" "opencloud collaboration server" ];
              env = [
                (env "COLLABORATION_GRPC_ADDR" "0.0.0.0:9301")
                (env "COLLABORATION_HTTP_ADDR" "0.0.0.0:9300")
                (env "MICRO_REGISTRY"          "nats-js-kv")
                (env "MICRO_REGISTRY_ADDRESS"  "${opencloudName}.${ns}.svc.cluster.local:9233")
                # -- Collabora WOPI config
                (env "COLLABORATION_WOPI_SRC"                    "http://${collaborationName}:9300")
                (env "COLLABORATION_APP_NAME"                     "CollaboraOnline")
                (env "COLLABORATION_APP_PRODUCT"                  "Collabora")
                (env "COLLABORATION_APP_ADDR"                     "https://${cfg.collabora.domain}")
                (env "COLLABORATION_APP_ICON"                     "https://${cfg.collabora.domain}/favicon.ico")
                (env "COLLABORATION_APP_PROOF_DISABLE"            "true")
                (env "COLLABORATION_APP_INSECURE"                 (boolStr cfg.insecure))
                (env "COLLABORATION_CS3API_DATAGATEWAY_INSECURE"  (boolStr cfg.insecure))
                (env "COLLABORATION_LOG_LEVEL"                    cfg.logLevel)
                (env "OC_URL"                                     "https://${cfg.domain}")
              ];
              ports = [
                { name = "http"; containerPort = 9300; protocol = "TCP"; }
                { name = "grpc"; containerPort = 9301; protocol = "TCP"; }
              ];
              volumeMounts = [
                { name = "etc-opencloud"; mountPath = "/etc/opencloud"; }
              ];
              livenessProbe = {
                exec.command = [
                  "/bin/sh" "-c"
                  "curl --silent --fail http://${opencloudName}:9200/app/list | grep '\"product_name\":\"Collabora\"'"
                ];
                timeoutSeconds = 10;
                initialDelaySeconds = 200;
                periodSeconds = 5;
                failureThreshold = 1;
              };
              resources = cfg.collabora.collaboration.resources;
            }
          ];
          volumes = [
            {
              name = "etc-opencloud";
              persistentVolumeClaim = {
                claimName = "${opencloudName}-config";
                readOnly = true;
              };
            }
          ];
        };
      };
    };
  }

  # ════════════════════════════════════════════════════════════════════════
  # Service: Collaboration (HTTP 9300 + gRPC 9301)
  # ════════════════════════════════════════════════════════════════════════
  {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      name = collaborationName;
      namespace = ns;
      labels = commonLabels "collaboration";
    };
    spec = {
      type = "ClusterIP";
      selector = selectorLabels "collaboration";
      ports = [
        { port = 9300; targetPort = "http"; protocol = "TCP"; name = "http"; }
        { port = 9301; targetPort = "grpc"; protocol = "TCP"; name = "grpc"; }
      ];
    };
  }

  # ════════════════════════════════════════════════════════════════════════
  # Deployment: Tika (full-text search extraction)
  # ════════════════════════════════════════════════════════════════════════
  {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = {
      name = tikaName;
      namespace = ns;
      labels = commonLabels "tika";
    };
    spec = {
      replicas = 1;
      selector.matchLabels = selectorLabels "tika";
      template = {
        metadata.labels = selectorLabels "tika";
        spec.containers = [
          {
            name = "tika";
            image = mkImage cfg.tika.image;
            imagePullPolicy = "IfNotPresent";
            ports = [
              { name = "http"; containerPort = 9998; protocol = "TCP"; }
            ];
            env = [
              (env "JAVA_OPTS" "-Xmx3g")
            ];
            resources = cfg.tika.resources;
          }
        ];
      };
    };
  }

  # ════════════════════════════════════════════════════════════════════════
  # Service: Tika (port 9998)
  # ════════════════════════════════════════════════════════════════════════
  {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      name = tikaName;
      namespace = ns;
      labels = commonLabels "tika";
    };
    spec = {
      type = "ClusterIP";
      selector = selectorLabels "tika";
      ports = [
        { port = 9998; targetPort = "http"; protocol = "TCP"; name = "http"; }
      ];
    };
  }
]
# ── Conditional: web extensions init script ConfigMap ──────────────────
++ lib.optionals cfg.webExtensions.enable [
  {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = "${opencloudName}-web-extensions-init";
      namespace = ns;
      labels = commonLabels "opencloud";
    };
    data."init-web-extensions.sh" = webExtensionsInitScript;
  }
]
