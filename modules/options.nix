# Shared option tree for the JuiceFS modules.
#
# Imported by both the NixOS module (`modules/juicefs.nix`) and the nix-darwin
# module (`modules/darwin.nix`) so the `services.juicefs` interface is identical
# on both platforms. This file only declares options — the platform-specific
# service wiring (systemd vs launchd) lives in the consuming modules.
{
  lib,
  pkgs,
  ...
}:
let
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
        Path to an environment file with additional secrets, e.g.
        `ACCESS_KEY=…` / `SECRET_KEY=…` for object storage,
        `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` for the gateway, or
        `JFS_RSA_PASSPHRASE` for an encrypted volume.

        On NixOS this is a systemd `EnvironmentFile`. On nix-darwin (launchd has
        no equivalent) the file is sourced by the service's wrapper script, so
        values containing shell metacharacters must be quoted.
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
        description = ''
          Whether to open the listen port in the firewall. No effect on
          nix-darwin (macOS has no `networking.firewall`).
        '';
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
}
