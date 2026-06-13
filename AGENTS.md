# AGENTS.md

Guidance for AI agents (and humans) working in this repository.

## What this is

`juicefs-nix` is a Nix flake that ships a **NixOS module** and a **nix-darwin module** for
[JuiceFS](https://juicefs.com). The module (`services.juicefs`) formats & mounts JuiceFS
volumes and runs the S3 gateway / WebDAV server — as systemd services on NixOS, as launchd
daemons on macOS. It does **not** package JuiceFS (it re-uses `pkgs.juicefs`) and does **not**
manage the metadata engine or object storage backends — those are the user's responsibility.

## Layout

| Path | Purpose |
| --- | --- |
| `flake.nix` | Flake outputs: `nixosModules.{juicefs,default}`, `darwinModules.{juicefs,default}`, `packages.<system>.{juicefs,default}`. Minimal — no checks/devShell/formatter. |
| `modules/options.nix` | **Shared** option tree (`services.juicefs.*`); identical on both platforms. Single source of truth — edit options here. |
| `modules/builders.nix` | **Shared** command-line / wrapper-script helpers (`formatArgs`, `mountArgs`, `mkExec`, `secretPrelude`, `mkMountWrapper`, `mkAssertions`, …). Platform-agnostic; no systemd/launchd knowledge. |
| `modules/juicefs.nix` | NixOS module (thin): imports the two shared files, emits `systemd.services` + tmpfiles + firewall. |
| `modules/darwin.nix` | nix-darwin module (thin): imports the two shared files, emits `launchd.daemons`. |
| `README.md` | User-facing docs: install, examples, secrets, option reference, macOS notes. |
| `AGENTS.md` | This file. `CLAUDE.md` is a symlink to it. |

## Module design (read before editing the modules)

- **Options live once** in `modules/options.nix` and the **arg/wrapper builders once** in
  `modules/builders.nix`; both `juicefs.nix` and `darwin.nix` `import` them. Keep the two
  platform modules thin — add options/builders to the shared files, not per platform, so the
  `services.juicefs` interface never drifts.
- Options: `services.juicefs.{package, mounts.<name>, gateway, webdav}`.
- Command lines are assembled by the `formatArgs` / `mountArgs` / `gatewayArgs` / `webdavArgs`
  helpers in `builders.nix`, then escaped with `lib.escapeShellArgs`. Add new first-class
  options there; reserve `extraOptions` / `mountOptions` for the long tail.

### NixOS (`modules/juicefs.nix`)

- Each enabled mount → a `juicefs-<name>.service` (`Type=simple`) running
  `juicefs mount --no-syslog` in the foreground. An `ExecStartPost` blocks on `mountpoint -q`
  so dependents see a live FUSE mount.
- `autoFormat` adds an idempotent `ExecStartPre` (`mkFormatExec`): runs `juicefs format`
  **only** when `juicefs status` reports the volume is not yet initialized.
- `gateway` / `webdav` → `juicefs-gateway.service` / `juicefs-webdav.service`.
- Mount services set `path = [ "/run/wrappers" ]` so juicefs can find the SUID
  `fusermount3` wrapper (the default unit PATH omits `/run/wrappers/bin`). FUSE-less services
  (gateway/webdav) don't need it.

### macOS (`modules/darwin.nix`)

- Each mount/server → a `launchd.daemons."juicefs-<name>"` (label `org.nixos.juicefs-<name>`)
  with `RunAtLoad = true` and `KeepAlive.SuccessfulExit = false` / `ThrottleInterval = 5`
  (≈ systemd `Restart=on-failure` / `RestartSec=5s`).
- launchd runs **one** program per daemon, so there are no ExecStartPre/Post/Stop hooks. The
  mount wrapper (`mkMountWrapper`) folds directory creation (`mkdir`/`chmod`, plus `chown` when
  `user != "root"`) and the idempotent format step into a single script before `exec juicefs
  mount`. No mount-readiness wait. No explicit umount — `juicefs mount` unmounts on the SIGTERM
  launchd sends to stop the daemon.
- Requires user-installed **macFUSE** (kernel extension, not from the store). Logs go to
  `/var/log/juicefs-<name>.log`. `openFirewall` is a no-op (no `networking.firewall`) and emits
  a warning. `user`/`group` only set `UserName`/`GroupName` when non-root (macOS gid 0 is
  `wheel`, not `root`).

### Deliberate non-features (don't "fix" these)

- The module does **not** parse `metaUrl` connection strings, and does **not** create the
  directory for embedded-file metadata engines (e.g. the SQLite `.db`'s parent dir). That is
  the user's responsibility via their own `systemd.tmpfiles.rules` — see README "Metadata
  directory". Inferring filesystem paths from a DSN is brittle and out of the module's scope.

## Secrets — the one hard rule

Secrets must **never** enter the Nix store or a command line. Options that carry secrets are
`*File` paths resolved **at runtime**:

- `metaPasswordFile` → `META_PASSWORD`, `encryption.passphraseFile` → `JFS_RSA_PASSPHRASE`:
  exported by a `writeShellScript` wrapper (`secretPrelude`) that `cat`s the file at start.
- `environmentFile`: systemd `EnvironmentFile` on NixOS; on macOS (launchd has no equivalent)
  `mkExec`'s `envFile` sources it inside the wrapper (`set -a; . "$file"; set +a`). Either way
  only the runtime *path* is in the store — never the contents.

When adding a secret, route it through `secretPrelude` / `EnvironmentFile` / `mkExec`'s
`envFile`. Do **not** interpolate secret *contents* into Nix strings or pass them as CLI args
(they'd show in `ps`).

## Conventions

- Format Nix with `nixfmt-rfc-style` (`nix fmt` is not wired up; run
  `nix run nixpkgs#nixfmt-rfc-style -- modules/*.nix flake.nix`).
- Every option needs a `description`; mirror JuiceFS CLI flag names in the description
  (e.g. "(`--backup-meta`)").
- Keep `README.md`'s option-reference tables and examples in sync with the option set.

## Validating changes

```sh
# Evaluate the flake outputs.
nix flake show
nix flake check

# Typecheck the module against a real config (renders the systemd units).
nix eval --impure --expr '
  let
    flake = builtins.getFlake (toString ./.);
    nixpkgs = flake.inputs.nixpkgs;
  in (nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      flake.nixosModules.default
      { boot.loader.grub.enable = false; fileSystems."/" = { device = "x"; }; system.stateVersion = "24.11";
        services.juicefs.mounts.demo = {
          metaUrl = "sqlite3:///var/lib/juicefs/demo.db";
          mountPoint = "/mnt/demo";
          autoFormat = true;
          format.bucket = "/var/lib/juicefs/demo-data";
        };
      }
    ];
  }).config.systemd.services."juicefs-demo".serviceConfig.ExecStart
'
```

After any refactor of the shared files, confirm the **NixOS units are unchanged**: the rendered
`ExecStart` (and `ExecStartPre`/`ExecStartPost`) store paths should be byte-for-byte identical
before and after (they are content-addressed, so an unchanged path proves an unchanged wrapper).

Render the **darwin** launchd units (nix-darwin is not a flake input — fetch it ad-hoc):

```sh
nix eval --impure --expr '
  let
    flake  = builtins.getFlake (toString ./.);
    darwin = builtins.getFlake "github:nix-darwin/nix-darwin";
  in (darwin.lib.darwinSystem {
    system = "aarch64-darwin";
    modules = [
      flake.darwinModules.default
      { system.stateVersion = 5; nixpkgs.hostPlatform = "aarch64-darwin";
        services.juicefs.mounts.demo = {
          metaUrl = "sqlite3:///var/lib/juicefs/demo.db";
          mountPoint = "/Users/Shared/jfs-demo";
          autoFormat = true;
          format.bucket = "/var/lib/juicefs/demo-data";
        };
      }
    ];
  }).config.launchd.daemons."juicefs-demo".serviceConfig.ProgramArguments
'
```

For a real runtime smoke test, on NixOS build a VM and confirm `mountpoint -q /mnt/demo` after
boot; on macOS install macFUSE, `darwin-rebuild switch`, and confirm the mount appears (then
`launchctl bootout` the daemon and confirm it unmounts cleanly).
