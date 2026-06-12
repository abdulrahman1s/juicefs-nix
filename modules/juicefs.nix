# NixOS module for JuiceFS (https://juicefs.com).
#
# Provides `services.juicefs` to declaratively format & mount JuiceFS volumes and
# run the S3 gateway / WebDAV server. A JuiceFS volume needs a *metadata engine*
# (sqlite/redis/postgres/mysql/tikv) and *object storage* (s3/minio/oss/file/…);
# managing those backends is out of scope and left to the user.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.juicefs;

  juicefs = lib.getExe' cfg.package "juicefs";

  # Shell prelude that loads secrets into environment variables at runtime, so they
  # are read from runtime paths (sops/agenix) and never enter the Nix store. Each
  # entry is `{ var; file; }`; null files are skipped.
  secretPrelude =
    entries:
    lib.concatMapStringsSep "\n" (
      e: ''export ${e.var}="$(cat ${lib.escapeShellArg (toString e.file)})"''
    ) (lib.filter (e: e.file != null) entries);

  # Build an ExecStart wrapper script for a juicefs subcommand.
  mkExec =
    {
      name,
      secrets ? [ ],
      args,
    }:
    pkgs.writeShellScript "juicefs-${name}" ''
      set -eu
      ${secretPrelude secrets}
      exec ${juicefs} ${lib.escapeShellArgs args}
    '';

  # Secrets that may be needed to talk to a volume's metadata engine / encryption.
  mountSecrets = m: [
    {
      var = "META_PASSWORD";
      file = m.metaPasswordFile;
    }
    {
      var = "JFS_RSA_PASSPHRASE";
      file = m.encryption.passphraseFile;
    }
  ];

  serverSecrets = s: [
    {
      var = "META_PASSWORD";
      file = s.metaPasswordFile;
    }
  ];

  formatArgs =
    m:
    [
      "--storage"
      m.format.storage
      "--bucket"
      m.format.bucket
    ]
    ++ lib.optionals (m.format.compression != null) [
      "--compress"
      m.format.compression
    ]
    ++ lib.optionals (m.format.blockSize != null) [
      "--block-size"
      m.format.blockSize
    ]
    ++ lib.optionals (m.format.capacity != null) [
      "--capacity"
      (toString m.format.capacity)
    ]
    ++ lib.optionals (m.format.inodes != null) [
      "--inodes"
      (toString m.format.inodes)
    ]
    ++ lib.optionals (m.format.trashDays != null) [
      "--trash-days"
      (toString m.format.trashDays)
    ]
    ++ lib.optionals m.encryption.enable [
      "--encrypt-rsa-key"
      (toString m.encryption.rsaKeyFile)
      "--encrypt-algo"
      m.encryption.algorithm
    ]
    ++ m.format.extraOptions
    ++ [
      m.metaUrl
      m.format.name
    ];

  mountArgs =
    m:
    [
      "mount"
      "--no-syslog"
      "--cache-dir"
      m.cacheDir
    ]
    ++ lib.optionals (m.backupMeta != null) [
      "--backup-meta"
      m.backupMeta
    ]
    ++ lib.optionals (m.cacheSize != null) [
      "--cache-size"
      (toString m.cacheSize)
    ]
    ++ lib.optional m.readOnly "--read-only"
    ++ lib.optional m.writeback "--writeback"
    ++ m.mountOptions
    ++ [
      m.metaUrl
      m.mountPoint
    ];

  # Idempotent format pre-step: only formats when the volume is not yet initialized.
  mkFormatExec =
    name: m:
    pkgs.writeShellScript "juicefs-format-${name}" ''
      set -eu
      ${secretPrelude (mountSecrets m)}
      if ${juicefs} status ${lib.escapeShellArg m.metaUrl} >/dev/null 2>&1; then
        echo "juicefs: volume '${m.format.name}' already initialized, skipping format"
      else
        echo "juicefs: formatting volume '${m.format.name}'"
        ${juicefs} format ${lib.escapeShellArgs (formatArgs m)}
      fi
    '';

  portOf = address: lib.toInt (lib.last (lib.splitString ":" address));

  enabledMounts = lib.filterAttrs (_: m: m.enable) cfg.mounts;

  commonServiceConfig = svc: {
    Restart = "on-failure";
    RestartSec = "5s";
    EnvironmentFile = lib.mkIf (svc.environmentFile != null) svc.environmentFile;
  };

  # ---- option fragments -------------------------------------------------------

  secretOptions = {
    metaPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/juicefs-meta-password";
      description = ''
        Path to a file containing the metadata engine password. Loaded into the
        `META_PASSWORD` environment variable at service start. Use a runtime path
        managed by sops-nix/agenix so the secret never enters the Nix store.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/juicefs-env";
      description = ''
        Path to a systemd `EnvironmentFile` with additional secrets, e.g.
        `ACCESS_KEY=…` / `SECRET_KEY=…` for object storage,
        `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` for the gateway, or
        `JFS_RSA_PASSPHRASE` for an encrypted volume.
      '';
    };
  };

  mountModule =
    { name, ... }:
    {
      options = {
        enable = lib.mkEnableOption "this JuiceFS mount" // {
          default = true;
        };

        metaUrl = lib.mkOption {
          type = lib.types.str;
          example = "redis://localhost:6379/1";
          description = ''
            Metadata engine URL, e.g. `redis://host:6379/1`,
            `sqlite3:///var/lib/juicefs/${name}.db`, or
            `postgres://user@host:5432/juicefs`. Passwords should be supplied via
            {option}`metaPasswordFile` rather than embedded here.
          '';
        };

        mountPoint = lib.mkOption {
          type = lib.types.str;
          example = "/mnt/jfs";
          description = "Directory where the volume is mounted.";
        };

        mountOptions = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [
            "-o"
            "allow_other"
          ];
          description = "Extra arguments appended to `juicefs mount` (for flags not covered by a dedicated option).";
        };

        cacheDir = lib.mkOption {
          type = lib.types.str;
          default = "/var/cache/juicefs/${name}";
          defaultText = lib.literalExpression ''"/var/cache/juicefs/<name>"'';
          description = "Local cache directory for this mount.";
        };

        cacheSize = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = null;
          example = 102400;
          description = "Size of cached objects for read, in MiB (`--cache-size`). Null uses the JuiceFS default.";
        };

        backupMeta = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "1h";
          description = ''
            Interval to automatically back up metadata into the object storage
            (`--backup-meta`), e.g. `"1h"`. Set to `"0"` to disable. Null uses the
            JuiceFS default (1h).

            Must be `"0"` on object stores whose `ListObjects` is not fully
            S3-compatible (notably Cloudflare R2), where the periodic backup fails.
          '';
        };

        readOnly = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Mount read-only (`--read-only`).";
        };

        writeback = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Upload blocks to object storage asynchronously (`--writeback`).";
        };

        user = lib.mkOption {
          type = lib.types.str;
          default = "root";
          description = "User the mount service runs as (FUSE `allow_other` typically needs root).";
        };

        group = lib.mkOption {
          type = lib.types.str;
          default = "root";
          description = "Group the mount service runs as.";
        };

        autoFormat = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Whether to run `juicefs format` before mounting when the volume is not
            yet initialized. The check is idempotent (`juicefs status`), so an
            already-formatted volume is left untouched.
          '';
        };

        encryption = {
          enable = lib.mkEnableOption "data-at-rest encryption for this volume";

          algorithm = lib.mkOption {
            type = lib.types.enum [
              "aes256gcm-rsa"
              "chacha20-rsa"
            ];
            default = "aes256gcm-rsa";
            description = "Encryption algorithm (`--encrypt-algo`), set at format time.";
          };

          rsaKeyFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            example = "/run/secrets/juicefs-rsa-key.pem";
            description = ''
              Path to the RSA private key (PEM) used to encrypt the volume
              (`--encrypt-rsa-key`). Only read at format time; the encrypted key is
              then stored in the metadata engine. Required when both
              {option}`autoFormat` and {option}`encryption.enable` are set.
            '';
          };

          passphraseFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            example = "/run/secrets/juicefs-rsa-passphrase";
            description = ''
              Path to a file with the passphrase of the RSA private key. Loaded into
              `JFS_RSA_PASSPHRASE`, required at every mount (and format) of an
              encrypted volume. Leave null only if the key has no passphrase.
            '';
          };
        };

        format = {
          name = lib.mkOption {
            type = lib.types.str;
            default = name;
            defaultText = lib.literalExpression "<attribute name>";
            description = "Volume name used by `juicefs format`.";
          };

          storage = lib.mkOption {
            type = lib.types.str;
            default = "file";
            example = "s3";
            description = "Object storage backend (e.g. `file`, `s3`, `minio`, `oss`).";
          };

          bucket = lib.mkOption {
            type = lib.types.str;
            default = "";
            example = "https://myjfs.s3.us-west-1.amazonaws.com";
            description = ''
              Object storage bucket/endpoint. For `storage = "file"` this is a local
              directory path. Required when {option}`autoFormat` is enabled.
            '';
          };

          compression = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.enum [
                "none"
                "lz4"
                "zstd"
              ]
            );
            default = null;
            description = "Compression algorithm (`--compress`). Null uses the JuiceFS default (none).";
          };

          blockSize = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "4M";
            description = "Block size (`--block-size`). Null uses the JuiceFS default.";
          };

          capacity = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            example = 1024;
            description = "Hard space quota of the volume in GiB (`--capacity`).";
          };

          inodes = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            description = "Hard inode quota of the volume (`--inodes`).";
          };

          trashDays = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            example = 7;
            description = "Days to keep deleted files in trash (`--trash-days`). 0 disables the trash.";
          };

          extraOptions = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [
              "--shards"
              "4"
            ];
            description = "Extra arguments appended to `juicefs format` (for flags not covered by a dedicated option).";
          };
        };
      }
      // secretOptions;
    };

  serverModule = defaultAddress: {
    options = {
      enable = lib.mkEnableOption "the JuiceFS server";

      metaUrl = lib.mkOption {
        type = lib.types.str;
        example = "redis://localhost:6379/1";
        description = "Metadata engine URL of the volume to serve.";
      };

      address = lib.mkOption {
        type = lib.types.str;
        default = defaultAddress;
        description = "Listen address in `host:port` form.";
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to open the listen port in the firewall.";
      };

      extraOptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra arguments appended to the server command.";
      };
    }
    // secretOptions;
  };
in
{
  options.services.juicefs = {
    package = lib.mkPackageOption pkgs "juicefs" { };

    mounts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule mountModule);
      default = { };
      description = "JuiceFS volumes to mount, keyed by volume name.";
      example = lib.literalExpression ''
        {
          data = {
            metaUrl = "redis://localhost:6379/1";
            mountPoint = "/mnt/data";
            autoFormat = true;
            format = {
              storage = "s3";
              bucket = "https://my-bucket.s3.us-west-1.amazonaws.com";
              compression = "zstd";
              trashDays = 7;
            };
            backupMeta = "1h";
            environmentFile = "/run/secrets/juicefs-data";
          };
        }
      '';
    };

    gateway = lib.mkOption {
      type = lib.types.submodule (serverModule "localhost:9005");
      default = { };
      description = "S3-compatible gateway (`juicefs gateway`).";
    };

    webdav = lib.mkOption {
      type = lib.types.submodule (serverModule "localhost:9007");
      default = { };
      description = "WebDAV server (`juicefs webdav`).";
    };
  };

  config = lib.mkIf (enabledMounts != { } || cfg.gateway.enable || cfg.webdav.enable) {
    environment.systemPackages = [ cfg.package ];

    assertions =
      (lib.mapAttrsToList (name: m: {
        assertion = !m.autoFormat || m.format.bucket != "";
        message = "services.juicefs.mounts.${name}: format.bucket must be set when autoFormat is enabled.";
      }) enabledMounts)
      ++ (lib.mapAttrsToList (name: m: {
        assertion = !(m.autoFormat && m.encryption.enable) || m.encryption.rsaKeyFile != null;
        message = "services.juicefs.mounts.${name}: encryption.rsaKeyFile must be set to format an encrypted volume.";
      }) enabledMounts)
      ++ [
        {
          assertion = !cfg.gateway.enable || cfg.gateway.metaUrl != "";
          message = "services.juicefs.gateway.metaUrl must be set when the gateway is enabled.";
        }
        {
          assertion = !cfg.webdav.enable || cfg.webdav.metaUrl != "";
          message = "services.juicefs.webdav.metaUrl must be set when WebDAV is enabled.";
        }
      ];

    warnings = lib.filter (w: w != "") (
      lib.mapAttrsToList (
        name: m:
        lib.optionalString (m.encryption.enable && m.encryption.passphraseFile == null)
          "services.juicefs.mounts.${name}: encryption is enabled but encryption.passphraseFile is null; mounting will fail unless the RSA key has no passphrase."
      ) enabledMounts
    );

    systemd.tmpfiles.rules = lib.flatten (
      lib.mapAttrsToList (_: m: [
        "d ${m.mountPoint} 0755 ${m.user} ${m.group} - -"
        "d ${m.cacheDir} 0700 ${m.user} ${m.group} - -"
      ]) enabledMounts
    );

    networking.firewall.allowedTCPPorts =
      (lib.optional (cfg.gateway.enable && cfg.gateway.openFirewall) (portOf cfg.gateway.address))
      ++ (lib.optional (cfg.webdav.enable && cfg.webdav.openFirewall) (portOf cfg.webdav.address));

    systemd.services = lib.mkMerge [
      # One mount service per enabled volume.
      (lib.mapAttrs' (
        name: m:
        lib.nameValuePair "juicefs-${name}" {
          description = "JuiceFS mount ${name} (${m.mountPoint})";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];

          # juicefs execs `fusermount3` by name to (un)mount; on NixOS that's the
          # root-SUID wrapper in /run/wrappers/bin, which the default unit PATH omits.
          # `path` runs entries through makeBinPath, so "/run/wrappers" -> /run/wrappers/bin.
          path = [ "/run/wrappers" ];

          serviceConfig = commonServiceConfig m // {
            Type = "simple";
            User = m.user;
            Group = m.group;
            ExecStartPre = lib.mkIf m.autoFormat (mkFormatExec name m);
            ExecStart = mkExec {
              name = "mount-${name}";
              secrets = mountSecrets m;
              args = mountArgs m;
            };
            # `simple` reports "started" once the process spawns, before the FUSE
            # mount is live; block until it is so dependents see a real mount.
            ExecStartPost = pkgs.writeShellScript "juicefs-wait-${name}" ''
              until ${lib.getExe' pkgs.util-linux "mountpoint"} -q ${lib.escapeShellArg m.mountPoint}; do
                sleep 0.2
              done
            '';
            ExecStop = "${juicefs} umount ${lib.escapeShellArg m.mountPoint}";
          };
        }
      ) enabledMounts)

      # S3 gateway.
      (lib.mkIf cfg.gateway.enable {
        juicefs-gateway = {
          description = "JuiceFS S3 gateway";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          serviceConfig = commonServiceConfig cfg.gateway // {
            Type = "simple";
            ExecStart = mkExec {
              name = "gateway";
              secrets = serverSecrets cfg.gateway;
              args = [
                "gateway"
                "--no-syslog"
              ]
              ++ cfg.gateway.extraOptions
              ++ [
                cfg.gateway.metaUrl
                cfg.gateway.address
              ];
            };
          };
        };
      })

      # WebDAV server.
      (lib.mkIf cfg.webdav.enable {
        juicefs-webdav = {
          description = "JuiceFS WebDAV server";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          serviceConfig = commonServiceConfig cfg.webdav // {
            Type = "simple";
            ExecStart = mkExec {
              name = "webdav";
              secrets = serverSecrets cfg.webdav;
              args = [
                "webdav"
                "--no-syslog"
              ]
              ++ cfg.webdav.extraOptions
              ++ [
                cfg.webdav.metaUrl
                cfg.webdav.address
              ];
            };
          };
        };
      })
    ];
  };

  meta.maintainers = [ ];
}
