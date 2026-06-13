# juicefs-nix

A NixOS + nix-darwin module + flake to declaratively configure [JuiceFS](https://juicefs.com):
format and mount volumes, run the S3-compatible gateway, and run the WebDAV server.

[JuiceFS](https://juicefs.com) is a POSIX-compatible distributed filesystem. A volume
combines two backends, **both of which you provide and run yourself**:

- a **metadata engine** — SQLite, Redis, PostgreSQL, MySQL, or TiKV;
- **object storage** — S3, MinIO, OSS, a local directory (`file`), etc.

The same `services.juicefs` interface works on both NixOS (systemd) and macOS via
[nix-darwin](https://github.com/nix-darwin/nix-darwin) (launchd). The module does **not**
manage the metadata database or the object store — see [Prerequisites](#prerequisites). On
macOS it also requires **macFUSE** — see [macOS / nix-darwin](#macos--nix-darwin).

## Installation

Add the flake as an input and import the module:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    juicefs-nix = {
      url = "github:abdulrahman1s/juicefs-nix";
      # Follow your own nixpkgs (e.g. nixos-unstable) instead of pulling a second copy.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, juicefs-nix, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        juicefs-nix.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

On macOS, import the nix-darwin module instead:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin";
    juicefs-nix = {
      url = "github:abdulrahman1s/juicefs-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nix-darwin, juicefs-nix, ... }: {
    darwinConfigurations.mymac = nix-darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      modules = [
        juicefs-nix.darwinModules.default
        ./configuration.nix
      ];
    };
  };
}
```

See [macOS / nix-darwin](#macos--nix-darwin) for the macFUSE prerequisite and the behavioral
differences from the NixOS module.

The flake also exposes `packages.<system>.juicefs` (re-exported from nixpkgs) if you just
want the CLI: `nix run github:abdulrahman1s/juicefs-nix`.

## Usage

### Example 1 — SQLite metadata + local `file` storage, auto-formatted

The simplest, fully self-contained setup. The volume is created on first boot.

```nix
# JuiceFS does not create the directory that holds the SQLite metadata DB, so
# create it yourself. Owner/group must match the mount service's user/group
# (root by default). See "Metadata directory" below.
systemd.tmpfiles.rules = [
  "d /var/lib/juicefs 0700 root root - -"
];

services.juicefs.mounts.demo = {
  metaUrl = "sqlite3:///var/lib/juicefs/demo.db";
  mountPoint = "/mnt/demo";
  autoFormat = true;
  format = {
    storage = "file";
    bucket = "/var/lib/juicefs/demo-data"; # juicefs creates this dir itself
  };
};
```

### Example 2 — Redis metadata + S3 storage, with secrets

```nix
services.juicefs.mounts.data = {
  metaUrl = "redis://localhost:6379/1";
  mountPoint = "/mnt/data";
  mountOptions = [ "--writeback" "-o" "allow_other" ];

  autoFormat = true;
  format = {
    storage = "s3";
    bucket = "https://my-bucket.s3.us-west-1.amazonaws.com";
  };

  # Redis password -> META_PASSWORD
  metaPasswordFile = "/run/secrets/juicefs-meta-password";
  # ACCESS_KEY=… / SECRET_KEY=… for S3
  environmentFile = "/run/secrets/juicefs-data-env";
};
```

### Example 3 — S3-compatible gateway

```nix
services.juicefs.gateway = {
  enable = true;
  metaUrl = "redis://localhost:6379/1";
  address = "0.0.0.0:9005";
  openFirewall = true;
  # MINIO_ROOT_USER=… / MINIO_ROOT_PASSWORD=…
  environmentFile = "/run/secrets/juicefs-gateway-env";
};
```

### Example 4 — WebDAV server

```nix
services.juicefs.webdav = {
  enable = true;
  metaUrl = "redis://localhost:6379/1";
  address = "0.0.0.0:9007";
  openFirewall = true;
};
```

### Example 5 — Encrypted volume + compression + tuning

JuiceFS encrypts data at rest with an RSA key pair. The key is supplied at format time
(`encryption.rsaKeyFile`) and its encrypted form is stored in the metadata; every mount then
needs the key's passphrase, loaded into `JFS_RSA_PASSPHRASE` from `encryption.passphraseFile`.

```nix
services.juicefs.mounts.secure = {
  metaUrl = "redis://localhost:6379/1";
  mountPoint = "/mnt/secure";

  autoFormat = true;
  format = {
    storage = "s3";
    bucket = "https://my-bucket.s3.us-west-1.amazonaws.com";
    compression = "zstd";   # --compress
    blockSize = "4M";       # --block-size
    trashDays = 7;          # --trash-days
    capacity = 1024;        # --capacity (GiB)
  };

  encryption = {
    enable = true;
    algorithm = "aes256gcm-rsa";           # or chacha20-rsa
    rsaKeyFile = "/run/secrets/jfs-key.pem";
    passphraseFile = "/run/secrets/jfs-key-passphrase";
  };

  backupMeta = "1h";        # --backup-meta (auto metadata backup interval; "0" disables)
  writeback = true;         # --writeback
  cacheSize = 102400;       # --cache-size (MiB)

  environmentFile = "/run/secrets/juicefs-secure-env"; # ACCESS_KEY / SECRET_KEY
};
```

Generate an RSA key with a passphrase out of band, then store it (and the passphrase) with
your secret manager:

```sh
openssl genrsa -aes256 -out jfs-key.pem 2048
```

Anything not exposed as a dedicated option can still be passed through `format.extraOptions`
(e.g. `[ "--shards" "4" ]`) or `mountOptions` (e.g. `[ "--upload-limit" "200" ]`).

### Example 6 — Cloudflare R2

R2 is used through the S3-compatible backend (`storage = "s3"`) with an R2 endpoint.

> [!WARNING]
> R2's `ListObjects` API is not fully S3-compatible (results are not sorted), so several
> JuiceFS maintenance commands do **not** work against R2: `juicefs gc`, `juicefs fsck`,
> `juicefs sync`, `juicefs destroy`. You must also **disable automatic metadata backup** by
> setting `backupMeta = "0"` (the periodic backup relies on sorted listing and would fail).

```nix
services.juicefs.mounts.r2 = {
  metaUrl = "redis://localhost:6379/1";
  mountPoint = "/mnt/r2";

  backupMeta = "0"; # REQUIRED for R2 → passes --backup-meta 0

  autoFormat = true;
  format = {
    storage = "s3";
    bucket = "https://<accountid>.r2.cloudflarestorage.com/my-bucket";
  };
  environmentFile = "/run/secrets/juicefs-r2-env"; # ACCESS_KEY / SECRET_KEY (R2 token)
};
```

## Secrets

Never put passwords or storage keys directly in your Nix configuration — they would land
in the world-readable Nix store. Instead supply runtime paths produced by
[sops-nix](https://github.com/Mic92/sops-nix) or [agenix](https://github.com/ryantm/agenix):

- **`metaPasswordFile`** — a file containing only the metadata engine password. Loaded into
  `META_PASSWORD` at service start.
- **`environmentFile`** — an environment file. Use it for object storage credentials
  (`ACCESS_KEY`, `SECRET_KEY`) and, for the gateway, `MINIO_ROOT_USER` /
  `MINIO_ROOT_PASSWORD`. On NixOS it is a systemd `EnvironmentFile`; on macOS (launchd has no
  equivalent) it is **sourced** by the wrapper script, so any value containing shell
  metacharacters must be quoted (e.g. `SECRET_KEY='a$b'`).

Make sure the secret files are readable by the service's `user`/`group` and exist before the
unit starts (e.g. order your secret provisioning before `juicefs-*.service`).

## macOS / nix-darwin

Import `juicefs-nix.darwinModules.default` into your `darwinSystem` (see
[Installation](#installation)). The `services.juicefs` options are identical to NixOS, but the
services are launchd daemons rather than systemd units, which changes a few things:

- **macFUSE is required** for any mount. It is a kernel extension that **cannot** come from the
  Nix store, so install it out of band from [macfuse.io](https://macfuse.io) (or
  `brew install --cask macfuse`), approve the system extension in **System Settings → Privacy &
  Security**, and **reboot**. Until macFUSE is approved, a mount daemon will crash-loop (this is
  expected, not a module bug). The gateway / WebDAV servers do not use FUSE and need no macFUSE.
- **No firewall integration.** `openFirewall` is a no-op on macOS (there is no
  `networking.firewall`); a warning is emitted if you set it. Open ports via the macOS
  Application Firewall or `pf` yourself.
- **Logs** go to `/var/log/juicefs-<name>.log` (and `juicefs-gateway.log` / `juicefs-webdav.log`),
  rather than the journal. Use `log show` / `tail -f` on those files.
- **No mount-readiness barrier.** Unlike the systemd unit (which blocks on `mountpoint` before
  dependents start), launchd has no equivalent; the daemon simply runs `juicefs mount` in the
  foreground.
- **Stopping** a daemon (`sudo launchctl bootout system/org.nixos.juicefs-<name>`, or
  `darwin-rebuild switch` replacing it) sends SIGTERM, which `juicefs mount` handles by
  unmounting cleanly. If a mount ever gets stuck, force it with `diskutil unmount force <path>`.
- **Directories** (`mountPoint`, `cacheDir`) are created by the mount daemon itself; there is no
  `systemd.tmpfiles` equivalent to manage. The metadata-directory caveat below still applies —
  create the parent of an embedded SQLite DB yourself.
- **`user`/`group`** default to `root`; the daemon then runs as root and ownership is left alone.
  Set them to a non-root user/group to run unprivileged (mapped to launchd `UserName`/`GroupName`
  and a `chown` of the mount/cache dirs).

```nix
services.juicefs.mounts.demo = {
  metaUrl = "sqlite3:///var/lib/juicefs/demo.db";
  mountPoint = "/Users/Shared/jfs-demo";
  autoFormat = true;
  format.bucket = "/var/lib/juicefs/demo-data";
};
```

## Prerequisites

You must run the metadata engine and object storage yourself. For example, a local Redis as
the metadata engine:

```nix
services.redis.servers.juicefs = {
  enable = true;
  port = 6379;
};
```

Then order the mount after it (the module only orders against `network-online.target`):

```nix
systemd.services.juicefs-data = {
  after = [ "redis-juicefs.service" ];
  requires = [ "redis-juicefs.service" ];
};
```

### Metadata directory (SQLite / embedded engines)

Networked metadata engines (Redis, PostgreSQL, MySQL, TiKV) have no local directory, so
there's nothing extra to create. But **embedded-file engines store a file on local disk**,
and JuiceFS does **not** create the directory for it — `juicefs format`/`mount` fail with
`unable to open database file: no such file or directory` if it's missing.

The module deliberately stays out of the metadata engine's business (it won't parse your
connection string), so create that directory yourself with a tmpfiles rule. The owner/group
**must match the mount's `user`/`group`** (root by default) because SQLite writes `-wal`/`-shm`
files alongside the DB and the `autoFormat` step runs as that user:

```nix
# for metaUrl = "sqlite3:///var/lib/juicefs/data.db";
systemd.tmpfiles.rules = [
  "d /var/lib/juicefs 0700 root root - -"
];
```

The object storage *bucket* directory (for `storage = "file"`) is created by JuiceFS
automatically and does not need a rule.

## Option reference

### `services.juicefs`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `package` | package | `pkgs.juicefs` | JuiceFS package providing the `juicefs` CLI. |
| `mounts.<name>` | attrs | `{}` | Volumes to mount, keyed by volume name. |
| `gateway` | submodule | disabled | S3-compatible gateway (`juicefs gateway`). |
| `webdav` | submodule | disabled | WebDAV server (`juicefs webdav`). |

### `services.juicefs.mounts.<name>`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `enable` | bool | `true` | Whether to mount this volume. |
| `metaUrl` | str | _required_ | Metadata engine URL (`redis://…`, `sqlite3:///…`, `postgres://…`). |
| `mountPoint` | str | _required_ | Where to mount the volume. |
| `mountOptions` | list of str | `[]` | Extra args for `juicefs mount` (long-tail flags). |
| `cacheDir` | str | `/var/cache/juicefs/<name>` | Local cache directory. |
| `cacheSize` | null or int | `null` | Read cache size in MiB (`--cache-size`). |
| `backupMeta` | null or str | `null` | Auto metadata backup interval (`--backup-meta`), e.g. `"1h"`; `"0"` disables. |
| `readOnly` | bool | `false` | Mount read-only (`--read-only`). |
| `writeback` | bool | `false` | Async block upload (`--writeback`). |
| `user` / `group` | str | `root` | User/group the mount service runs as. |
| `autoFormat` | bool | `false` | Format the volume on first start if not yet initialized. |
| `encryption.enable` | bool | `false` | Enable data-at-rest encryption. |
| `encryption.algorithm` | enum | `aes256gcm-rsa` | `aes256gcm-rsa` or `chacha20-rsa` (`--encrypt-algo`). |
| `encryption.rsaKeyFile` | null or path | `null` | RSA private key (PEM) used at format time (`--encrypt-rsa-key`). |
| `encryption.passphraseFile` | null or path | `null` | RSA key passphrase → `JFS_RSA_PASSPHRASE` (needed every mount). |
| `format.name` | str | `<name>` | Volume name for `juicefs format`. |
| `format.storage` | str | `file` | Object storage backend. |
| `format.bucket` | str | `""` | Bucket/endpoint (local path for `file`); required if `autoFormat`. |
| `format.compression` | null or enum | `null` | `none`/`lz4`/`zstd` (`--compress`). |
| `format.blockSize` | null or str | `null` | Block size (`--block-size`), e.g. `"4M"`. |
| `format.capacity` | null or int | `null` | Space quota in GiB (`--capacity`). |
| `format.inodes` | null or int | `null` | Inode quota (`--inodes`). |
| `format.trashDays` | null or int | `null` | Trash retention in days (`--trash-days`). |
| `format.extraOptions` | list of str | `[]` | Extra args for `juicefs format` (long-tail flags). |
| `metaPasswordFile` | null or path | `null` | File with the metadata password → `META_PASSWORD`. |
| `environmentFile` | null or path | `null` | Env file for `ACCESS_KEY`/`SECRET_KEY`/etc. (systemd `EnvironmentFile` on NixOS; sourced by the wrapper on macOS). |

### `services.juicefs.gateway` / `services.juicefs.webdav`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `enable` | bool | `false` | Enable the server. |
| `metaUrl` | str | _required_ | Metadata engine URL of the volume to serve. |
| `address` | str | `localhost:9005` (gateway) / `localhost:9007` (webdav) | Listen `host:port`. |
| `openFirewall` | bool | `false` | Open the listen port in the firewall. No effect on macOS. |
| `extraOptions` | list of str | `[]` | Extra args for the server command. |
| `metaPasswordFile` | null or path | `null` | File with the metadata password → `META_PASSWORD`. |
| `environmentFile` | null or path | `null` | Env file (e.g. `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD`); systemd `EnvironmentFile` on NixOS, sourced by the wrapper on macOS. |

## How it works

On **NixOS** (systemd):

- Each enabled mount becomes a `juicefs-<name>.service` (`Type=simple`) running
  `juicefs mount --no-syslog` in the foreground. An `ExecStartPost` hook blocks until the
  FUSE mount is actually live, so units ordered after it see a real mount.
- With `autoFormat`, an `ExecStartPre` runs `juicefs format` only when `juicefs status` shows
  the volume is not yet initialized (idempotent — existing volumes are untouched).
- The gateway and WebDAV servers become `juicefs-gateway.service` and
  `juicefs-webdav.service`.

On **macOS** (nix-darwin / launchd):

- Each mount/server becomes a launchd daemon (`org.nixos.juicefs-<name>`) with
  `RunAtLoad`/`KeepAlive` (restart on failure). launchd runs a single program, so directory
  creation and the idempotent `autoFormat` step are folded into the mount wrapper, and the
  process unmounts itself on SIGTERM (no separate stop step). See
  [macOS / nix-darwin](#macos--nix-darwin).

On both platforms:

- The command line is assembled by shared helpers (`modules/builders.nix`) from the same
  `services.juicefs` options (`modules/options.nix`).
- Secrets are read from their files at runtime inside a wrapper script, so they never enter
  the Nix store or appear in `ps`.

## License

MIT — see [LICENSE](./LICENSE).
