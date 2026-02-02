# preservation-disko

Sane defaults for [disko](https://github.com/nix-community/disko) + [preservation](https://github.com/nix-community/preservation) integration.

## Quick Start

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko";
    preservation-disko.url = "github:visualphoenix/preservation-disko";
  };
}
```

Start with disko's [hybrid-tmpfs-on-root](https://github.com/nix-community/disko/blob/master/example/hybrid-tmpfs-on-root.nix) example, then add a persist partition:

```nix
# disko-config.nix
{ config, ... }:
{
  disko.devices = {
    disk.main = {
      # ... ESP and nix partitions from hybrid-tmpfs-on-root.nix ...

      content.partitions.persist = {
        size = "100%";
        content = {
          type = "filesystem";
          format = "ext4";
          mountpoint = "/persist";
          # This connects preservation to disko:
          postMountHook = config.preservation.diskoSetupCommands;
        };
      };
    };

    # tmpfs root from hybrid-tmpfs-on-root.nix
    nodev."/" = {
      fsType = "tmpfs";
      mountOptions = [ "defaults" "size=2G" "mode=755" ];
    };
  };

  fileSystems."/persist".neededForBoot = true;
}
```

```nix
# configuration.nix
{ inputs, ... }:
{
  imports = [
    inputs.disko.nixosModules.disko
    inputs.preservation-disko.nixosModules.default
    ./disko-config.nix
  ];
}
```

That's it. Run `disko` and `nixos-install` as normal.

## What You Get

Out of the box, the module:

| Feature | Details |
|---------|---------|
| **Persisted directories** | `/var/lib/nixos`, `/var/lib/systemd`, `/var/log` |
| **Persisted files** | `/etc/machine-id` (with proper initrd handling) |
| **Disko integration** | Auto-generated `postMountHook` commands |
| **Initrd support** | Enables `boot.initrd.systemd` automatically |
| **Clan auto-detection** | If using clan, automatically preserves secrets (not required) |

## Extending

Add more directories or files using standard NixOS module merging:

```nix
{ config, ... }:
let
  persistPath = config.preservation.persistentStoragePath;  # "/persist" by default
in
{
  preservation.preserveAt.${persistPath} = {
    directories = [
      "/var/lib/postgresql"
      "/var/lib/private/myapp"
    ];
    files = [
      { file = "/etc/ssh/ssh_host_ed25519_key"; }
      { file = "/etc/ssh/ssh_host_ed25519_key.pub"; }
    ];
  };
}
```

For directories needed before systemd starts (secrets, early-boot state):

```nix
{
  preservation.extraBindMounts."/var/lib/myapp-secrets".neededForBoot = true;
}
```

Note: `/var/lib/sops-nix` is handled automatically for clan users.

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `preservation.persistentStoragePath` | `"/persist"` | Where persistent storage is mounted |
| `preservation.installMountPoint` | `"/mnt"` | Root mount point during installation |
| `preservation.machineIdMode` | `"symlink"` | How to persist `/etc/machine-id`: `"symlink"` or `"bindmount"` |
| `preservation.extraBindMounts` | `{}` | Additional bind mounts with `neededForBoot` support |
| `preservation.diskoSetupCommands` | (generated) | Shell commands for disko's `postMountHook` |

## How It Works

When you run `disko`, the `postMountHook` executes after mounting your persist partition. The generated commands:

1. Create directories on persistent storage (`/mnt/persist/var/lib/nixos`, etc.)
2. Create mount points on the root filesystem (`/mnt/var/lib/nixos`, etc.)
3. Set up bind mounts so `nixos-install` writes to the persistent locations

At runtime, preservation handles the bind mounts via initrd systemd.

## Clan Integration

Clan is **not required**. This module works standalone with any NixOS + disko setup.

If you are using [clan-core](https://git.clan.lol/clan/clan-core), the module automatically detects it and:

- Preserves `clan.core.facts` `secretUploadDirectory`
- Preserves `/var/lib/sops-nix` when `clan.core.vars` generators are defined

No configuration needed - it just works.

## Troubleshooting

**"Directory doesn't exist" during nixos-install**

Make sure `postMountHook = config.preservation.diskoSetupCommands;` is on your persist partition content.

**Machine-ID regenerates every boot**

The module handles this by default. If you're overriding `/etc/machine-id` preservation, ensure `inInitrd = true`.

**Secrets not available at boot (non-clan sops-nix users)**

Clan users get `/var/lib/sops-nix` automatically. For standalone sops-nix:

```nix
preservation.extraBindMounts."/var/lib/sops-nix".neededForBoot = true;
```

## References

- [nix-community/preservation](https://github.com/nix-community/preservation)
- [nix-community/disko](https://github.com/nix-community/disko)
- [NixOS PR #351151](https://github.com/NixOS/nixpkgs/pull/351151) - machine-id changes
- [preservation#22](https://github.com/nix-community/preservation/issues/22) - machine-id discussion
