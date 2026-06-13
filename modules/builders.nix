# Shared, platform-agnostic helpers for the JuiceFS modules.
#
# Imported by both `modules/juicefs.nix` (systemd) and `modules/darwin.nix`
# (launchd). Everything here is pure command-line / wrapper-script construction;
# no systemd- or launchd-specific knowledge lives in this file.
#
# Secrets rule (see AGENTS.md): secret *contents* never enter the Nix store or a
# command line. `*File` options carry runtime paths only — the wrapper scripts
# `cat`/source them at start. `environmentFile` is handled differently per
# platform: NixOS uses systemd `EnvironmentFile`; darwin passes `envFile` to
# `mkExec`, which sources it in the wrapper (the path is in the store, never the
# contents).
{
  lib,
  pkgs,
  juicefs,
}:
rec {
  # Shell prelude that loads `*File` secrets into environment variables at
  # runtime. Each entry is `{ var; file; }`; null files are skipped.
  secretPrelude =
    entries:
    lib.concatMapStringsSep "\n" (
      e: ''export ${e.var}="$(cat ${lib.escapeShellArg (toString e.file)})"''
    ) (lib.filter (e: e.file != null) entries);

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

  # Build an ExecStart wrapper script for a juicefs subcommand.
  #
  # `envFile`     : optional path sourced before running (darwin's stand-in for
  #                 systemd EnvironmentFile). NixOS omits it and uses EnvironmentFile.
  # `prelude`     : optional extra shell run after the secret/env setup, before
  #                 `exec` (used by darwin to mkdir/format inline; launchd has no
  #                 ExecStartPre). Defaults keep the script byte-identical to the
  #                 original NixOS wrapper.
  mkExec =
    {
      name,
      secrets ? [ ],
      envFile ? null,
      prelude ? "",
      args,
    }:
    let
      middle = lib.concatStringsSep "\n" (
        lib.filter (s: s != "") [
          (lib.optionalString (envFile != null) ''
            set -a
            . ${lib.escapeShellArg (toString envFile)}
            set +a'')
          (secretPrelude secrets)
          prelude
        ]
      );
    in
    pkgs.writeShellScript "juicefs-${name}" ''
      set -eu
      ${middle}
      exec ${juicefs} ${lib.escapeShellArgs args}
    '';

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

  gatewayArgs =
    s:
    [
      "gateway"
      "--no-syslog"
    ]
    ++ s.extraOptions
    ++ [
      s.metaUrl
      s.address
    ];

  webdavArgs =
    s:
    [
      "webdav"
      "--no-syslog"
    ]
    ++ s.extraOptions
    ++ [
      s.metaUrl
      s.address
    ];

  # Idempotent format step: only formats when the volume is not yet initialized.
  # Shared by NixOS's ExecStartPre wrapper and darwin's inline mount wrapper.
  formatSnippet = m: ''
    if ${juicefs} status ${lib.escapeShellArg m.metaUrl} >/dev/null 2>&1; then
      echo "juicefs: volume '${m.format.name}' already initialized, skipping format"
    else
      echo "juicefs: formatting volume '${m.format.name}'"
      ${juicefs} format ${lib.escapeShellArgs (formatArgs m)}
    fi'';

  # NixOS ExecStartPre wrapper for the idempotent format step.
  mkFormatExec =
    name: m:
    pkgs.writeShellScript "juicefs-format-${name}" ''
      set -eu
      ${secretPrelude (mountSecrets m)}
      ${formatSnippet m}
    '';

  # darwin mount wrapper: launchd runs a single program, so fold directory
  # creation and the optional format step into one script before `exec mount`.
  mkMountWrapper =
    name: m:
    mkExec {
      name = "mount-${name}";
      secrets = mountSecrets m;
      envFile = m.environmentFile;
      args = mountArgs m;
      prelude = ''
        export PATH="/sbin:/usr/sbin:$PATH"
        mkdir -p ${lib.escapeShellArg m.mountPoint}
        chmod 0755 ${lib.escapeShellArg m.mountPoint}
        mkdir -p ${lib.escapeShellArg m.cacheDir}
        chmod 0700 ${lib.escapeShellArg m.cacheDir}''
      + lib.optionalString (m.user != "root") ''

        chown ${
          lib.escapeShellArg (m.user + lib.optionalString (m.group != "root") ":${m.group}")
        } ${lib.escapeShellArg m.mountPoint} ${lib.escapeShellArg m.cacheDir}''
      + lib.optionalString m.autoFormat ''

        ${formatSnippet m}'';
    };

  portOf = address: lib.toInt (lib.last (lib.splitString ":" address));

  enabledMounts = cfg: lib.filterAttrs (_: m: m.enable) cfg.mounts;

  # Platform-agnostic assertions/warnings, spliced into each module's config.
  mkAssertions =
    cfg:
    let
      mounts = enabledMounts cfg;
    in
    (lib.mapAttrsToList (name: m: {
      assertion = !m.autoFormat || m.format.bucket != "";
      message = "services.juicefs.mounts.${name}: format.bucket must be set when autoFormat is enabled.";
    }) mounts)
    ++ (lib.mapAttrsToList (name: m: {
      assertion = !(m.autoFormat && m.encryption.enable) || m.encryption.rsaKeyFile != null;
      message = "services.juicefs.mounts.${name}: encryption.rsaKeyFile must be set to format an encrypted volume.";
    }) mounts)
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

  mkWarnings =
    cfg:
    lib.filter (w: w != "") (
      lib.mapAttrsToList (
        name: m:
        lib.optionalString (m.encryption.enable && m.encryption.passphraseFile == null)
          "services.juicefs.mounts.${name}: encryption is enabled but encryption.passphraseFile is null; mounting will fail unless the RSA key has no passphrase."
      ) (enabledMounts cfg)
    );
}
