# NixOS module for JuiceFS (https://juicefs.com).
#
# Provides `services.juicefs` to declaratively format & mount JuiceFS volumes and
# run the S3 gateway / WebDAV server via systemd. A JuiceFS volume needs a
# *metadata engine* (sqlite/redis/postgres/mysql/tikv) and *object storage*
# (s3/minio/oss/file/…); managing those backends is out of scope and left to the
# user.
#
# The `services.juicefs` option tree lives in ./options.nix and the command-line /
# wrapper-script helpers in ./builders.nix, both shared with the nix-darwin module
# (./darwin.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.juicefs;

  juicefs = lib.getExe' cfg.package "juicefs";

  b = import ./builders.nix { inherit lib pkgs juicefs; };
  inherit (b)
    mkExec
    mkFormatExec
    mountArgs
    mountSecrets
    serverSecrets
    gatewayArgs
    webdavArgs
    portOf
    mkAssertions
    mkWarnings
    ;

  enabledMounts = b.enabledMounts cfg;

  commonServiceConfig = svc: {
    Restart = "on-failure";
    RestartSec = "5s";
    EnvironmentFile = lib.mkIf (svc.environmentFile != null) svc.environmentFile;
  };
in
{
  imports = [ ./options.nix ];

  config = lib.mkIf (enabledMounts != { } || cfg.gateway.enable || cfg.webdav.enable) {
    environment.systemPackages = [ cfg.package ];

    assertions = mkAssertions cfg;
    warnings = mkWarnings cfg;

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
              args = gatewayArgs cfg.gateway;
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
              args = webdavArgs cfg.webdav;
            };
          };
        };
      })
    ];
  };

  meta.maintainers = [ ];
}
