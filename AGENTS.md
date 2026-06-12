# AGENTS.md

Guidance for AI agents (and humans) working in this repository.

## What this is

`juicefs-nix` is a Nix flake that ships a **NixOS module** for
[JuiceFS](https://juicefs.com). The module (`services.juicefs`) formats & mounts JuiceFS
volumes and runs the S3 gateway / WebDAV server as systemd services. It does **not** package
JuiceFS (it re-uses `pkgs.juicefs`) and does **not** manage the metadata engine or object
storage backends — those are the user's responsibility.

## Layout

| Path | Purpose |
| --- | --- |
| `flake.nix` | Flake outputs: `nixosModules.{juicefs,default}` and `packages.<system>.{juicefs,default}`. Minimal — no checks/devShell/formatter. |
| `modules/juicefs.nix` | The whole module. All options live under `services.juicefs`. |
| `README.md` | User-facing docs: install, examples, secrets, option reference. |
| `AGENTS.md` | This file. `CLAUDE.md` is a symlink to it. |

## Module design (read before editing `modules/juicefs.nix`)

- Options: `services.juicefs.{package, mounts.<name>, gateway, webdav}`.
- Each enabled mount → a `juicefs-<name>.service` (`Type=simple`) running
  `juicefs mount --no-syslog` in the foreground. An `ExecStartPost` blocks on `mountpoint -q`
  so dependents see a live FUSE mount.
- `autoFormat` adds an idempotent `ExecStartPre`: it runs `juicefs format` **only** when
  `juicefs status` reports the volume is not yet initialized.
- `gateway` / `webdav` → `juicefs-gateway.service` / `juicefs-webdav.service`.
- Command lines are assembled by the `formatArgs` / `mountArgs` helpers, then escaped with
  `lib.escapeShellArgs`. Add new first-class options there; reserve `extraOptions` /
  `mountOptions` for the long tail.
- Mount services set `path = [ "/run/wrappers" ]` so juicefs can find the SUID
  `fusermount3` wrapper (the default unit PATH omits `/run/wrappers/bin`). FUSE-less services
  (gateway/webdav) don't need it.

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
- `environmentFile` → systemd `EnvironmentFile` (object storage keys, MinIO root creds, …).

When adding a secret, route it through `secretPrelude`/`EnvironmentFile`. Do **not**
interpolate secret *contents* into Nix strings or pass them as CLI args (they'd show in `ps`).

## Conventions

- Format Nix with `nixfmt-rfc-style` (`nix fmt` is not wired up; run
  `nix run nixpkgs#nixfmt-rfc-style -- modules/juicefs.nix flake.nix`).
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

For a real runtime smoke test, build a VM with such a config and confirm
`mountpoint -q /mnt/demo` after boot.
