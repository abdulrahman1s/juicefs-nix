# nix-darwin module for JuiceFS (https://juicefs.com).
#
# Provides `services.juicefs` — the same option tree as the NixOS module — to
# declaratively format & mount JuiceFS volumes and run the S3 gateway / WebDAV
# server, backed by launchd instead of systemd.
#
# macOS prerequisite: FUSE mounts require macFUSE (https://macfuse.io), a
# user-installed kernel extension that cannot come from the Nix store. Install it
# out of band, approve the kext in System Settings, and reboot before enabling a
# mount. The gateway / WebDAV servers do not use FUSE and need no macFUSE.
#
# launchd vs systemd notes:
#   - launchd runs exactly one program per daemon, so the idempotent `juicefs
#     format` step and the mount-point/cache mkdir are folded into the mount
#     wrapper (mkMountWrapper) — there is no ExecStartPre.
#   - There is no ExecStop. launchd stops a daemon with SIGTERM, and a foreground
#     `juicefs mount` unmounts cleanly on SIGTERM, so no explicit umount is needed.
#   - There is no ExecStartPost mount-wait; launchd has no ordering target that
#     needed it.
#   - `openFirewall` is a no-op (macOS has no `networking.firewall`).
#
# The `services.juicefs` option tree lives in ./options.nix and the command-line /
# wrapper-script helpers in ./builders.nix, both shared with the NixOS module
# (./juicefs.nix).
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
    mkMountWrapper
    serverSecrets
    gatewayArgs
    webdavArgs
    mkAssertions
    mkWarnings
    ;

  enabledMounts = b.enabledMounts cfg;

  # launchd creates the log file itself; /var/log always exists, so a flat path
  # avoids needing an activation script to pre-create a directory.
  logPath = name: "/var/log/juicefs-${name}.log";

  # ~ systemd Restart=on-failure / RestartSec=5s.
  commonDaemon = {
    RunAtLoad = true;
    KeepAlive = {
      SuccessfulExit = false;
    };
    ThrottleInterval = 5;
  };

  serverDaemon = name: svc: args: {
    serviceConfig = commonDaemon // {
      ProgramArguments = [
        "${mkExec {
          inherit name args;
          secrets = serverSecrets svc;
          envFile = svc.environmentFile;
        }}"
      ];
      StandardOutPath = logPath name;
      StandardErrorPath = logPath name;
    };
  };

  firewallWarnings = lib.filter (w: w != "") [
    (lib.optionalString (cfg.gateway.enable && cfg.gateway.openFirewall)
      "services.juicefs.gateway.openFirewall has no effect on macOS; open port ${toString cfg.gateway.address} via the macOS firewall / pf manually."
    )
    (lib.optionalString (cfg.webdav.enable && cfg.webdav.openFirewall)
      "services.juicefs.webdav.openFirewall has no effect on macOS; open port ${toString cfg.webdav.address} via the macOS firewall / pf manually."
    )
  ];
in
{
  imports = [ ./options.nix ];

  config = lib.mkIf (enabledMounts != { } || cfg.gateway.enable || cfg.webdav.enable) {
    environment.systemPackages = [ cfg.package ];

    assertions = mkAssertions cfg;
    warnings = mkWarnings cfg ++ firewallWarnings;

    launchd.daemons = lib.mkMerge [
      # One mount daemon per enabled volume.
      (lib.mapAttrs' (
        name: m:
        lib.nameValuePair "juicefs-${name}" {
          serviceConfig =
            commonDaemon
            // {
              ProgramArguments = [ "${mkMountWrapper name m}" ];
              StandardOutPath = logPath name;
              StandardErrorPath = logPath name;
            }
            # macOS gid 0 is named "wheel", not "root"; only set User/GroupName
            # when non-root so a root daemon (the default) just runs as root.
            // lib.optionalAttrs (m.user != "root") { UserName = m.user; }
            // lib.optionalAttrs (m.group != "root") { GroupName = m.group; };
        }
      ) enabledMounts)

      # S3 gateway.
      (lib.mkIf cfg.gateway.enable {
        "juicefs-gateway" = serverDaemon "gateway" cfg.gateway (gatewayArgs cfg.gateway);
      })

      # WebDAV server.
      (lib.mkIf cfg.webdav.enable {
        "juicefs-webdav" = serverDaemon "webdav" cfg.webdav (webdavArgs cfg.webdav);
      })
    ];
  };

  meta.maintainers = [ ];
}
