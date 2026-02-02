# Disko integration for nix-community/preservation
#
# This module provides:
# 1. Auto-generated disko postMountHook commands from preservation config
# 2. Required initrd systemd configuration
# 3. Auto-detection of clan vars/facts for secret persistence
#
# Usage in disko-config.nix:
#   postMountHook = config.preservation.diskoSetupCommands;
#
# The persistent storage path defaults to "/persist" but can be customized:
#   preservation.persistentStoragePath = "/nix/persist";
#
# Machine-ID Handling:
# --------------------
# This module initializes /persist/etc/machine-id with "uninitialized" via
# initrd tmpfiles. By default, /etc/machine-id is a symlink to the persistent
# copy. Use machineIdMode = "bindmount" for bind mount mode instead.
#
# Clan Integration (Auto-Detected):
# ---------------------------------
# If clan-core modules are present, this module automatically:
# - Detects clan.core.facts and preserves secretUploadDirectory
# - Detects clan.core.vars generators and preserves /var/lib/sops-nix
# No explicit configuration needed - works for both clan and non-clan users.
#
# Extending:
# ----------
# Add directories using the standard module system (it merges lists):
#   preservation.preserveAt."/persist".directories = [ "/var/lib/myapp" ];
#
# For boot-critical bind mounts with neededForBoot:
#   preservation.extraBindMounts."/var/lib/myapp".neededForBoot = true;
#
# References:
# - https://github.com/NixOS/nixpkgs/pull/351151
# - https://github.com/nix-community/preservation
# - https://github.com/nix-community/preservation/issues/22
{ preservation }:

{ lib, config, options, ... }:

let
  cfg = config.preservation;
  persistPath = cfg.persistentStoragePath;
  mountPoint = cfg.installMountPoint;

  # === Clan Auto-Detection ===
  # Check if clan modules exist WITHOUT importing them (avoids circular deps)
  hasClanFacts = options ? clan && options.clan ? core && options.clan.core
    ? facts;
  hasClanVars = options ? clan && options.clan ? core && options.clan.core
    ? vars;

  # Clan facts: check if enabled and get secretUploadDirectory
  clanFactsEnabled = hasClanFacts && (config.clan.core.facts.enable or false);
  clanFactsSecretDir = if clanFactsEnabled then
    config.clan.core.facts.secretUploadDirectory or null
  else
    null;

  # Clan vars: check if any generators are defined
  clanVarsEnabled = hasClanVars
    && ((config.clan.core.vars.generators or { }) != { });

  # === Directory Extraction ===
  # Extract bind-mounted directories from fileSystems configuration
  # These are directories that have bind mounts to the persistent storage path
  bindMountDirs = lib.optionals cfg.enable (builtins.filter (x: x != null)
    (lib.mapAttrsToList (name: fsConfig:
      if fsConfig.fsType or "" == "none"
      && lib.hasPrefix persistPath (fsConfig.device or "")
      && builtins.elem "bind" (fsConfig.options or [ ]) then
        name
      else
        null) config.fileSystems));

  # Extract parent directories of symlinked files from preservation config
  symlinkParentDirs =
    lib.optionals (cfg.enable && builtins.hasAttr persistPath cfg.preserveAt)
    (map (f: builtins.dirOf f.file)
      (lib.filter (f: f.how or "symlink" == "symlink")
        (builtins.getAttr persistPath cfg.preserveAt).files or [ ]));

  # Combine all directories that need to be created during disko install
  # Note: preservation.preserveAt.directories are NOT included - they're created at boot by preservation
  persistDirectories = bindMountDirs ++ symlinkParentDirs;

  # Generate unique, sorted list of directories
  uniquePersistDirs = lib.unique (lib.sort (a: b: a < b) persistDirectories);

in {
  imports = [ preservation.nixosModules.preservation ];

  options.preservation = {
    persistentStoragePath = lib.mkOption {
      type = lib.types.str;
      default = "/persist";
      example = "/nix/persist";
      description = ''
        Path where persistent storage is mounted at runtime.

        Defaults to "/persist" but can be customized for different partition layouts.
        This should match the mountpoint of your persistent partition in disko.
      '';
    };

    installMountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/mnt";
      example = "/mnt";
      description = ''
        Root mount point used during installation (where the new system root is mounted).

        Defaults to "/mnt" which is the standard for most installers including disko.
        Only change this if your installation process uses a different mount point.
      '';
    };

    machineIdMode = lib.mkOption {
      type = lib.types.enum [ "symlink" "bindmount" ];
      default = "symlink";
      description = ''
        How to persist /etc/machine-id.

        - "symlink": Uses symlink with createLinkTarget (default)
        - "bindmount": Uses bind mount (requires ConditionFirstBoot workaround)

        Both modes initialize the file with "uninitialized" via tmpfiles.
        Reference: https://github.com/nix-community/preservation/pull/23
      '';
    };

    diskoSetupCommands = lib.mkOption {
      type = lib.types.lines;
      readOnly = true;
      description = ''
        Shell commands for disko's postMountHook to create necessary
        directories and bind mounts for preservation. This is automatically
        generated from the preservation configuration.

        Include this in your disko configuration:
          postMountHook = config.preservation.diskoSetupCommands;
      '';
    };

    extraBindMounts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          neededForBoot = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Whether this bind mount is needed during early boot.

              Set to true for directories containing secrets or state
              required before systemd services start.
            '';
          };
        };
      });
      default = { };
      example = { "/var/lib/sops-nix" = { neededForBoot = true; }; };
      description = ''
        Boot-critical bind mounts from persistent storage.

        Creates fileSystems entries with neededForBoot. Use this for
        directories that must be available before systemd services start.

        For regular directories, just add to preservation.preserveAt directly:
          preservation.preserveAt."/persist".directories = [ "/var/lib/myapp" ];
      '';
    };
  };

  config = {
    # === Boot-Critical Bind Mounts ===
    # These must be bind-mounted during disko install so nixos-install writes persist
    # /var/lib/nixos: uid/gid maps - without this, user mappings are lost on first boot
    # /var/lib/sops-nix: clan vars encryption keys (when clan detected)
    preservation.extraBindMounts = {
      "/var/lib/nixos" = { neededForBoot = false; };
    } // lib.optionalAttrs (clanVarsEnabled && !clanFactsEnabled) {
      "/var/lib/sops-nix" = { neededForBoot = true; };
    };

    # === Disko Setup Commands ===
    # Auto-generate from preservation configuration
    preservation.diskoSetupCommands = lib.mkIf cfg.enable ''
      # === Preservation Setup Commands ===
      # Auto-generated from preservation-disko module
      # These commands ensure all preservation targets exist during installation
      # Persistent storage path: ${persistPath}

      ${lib.optionalString (uniquePersistDirs != [ ]) ''
        # Create persistent directories
        ${lib.concatMapStringsSep "\n"
        (dir: "mkdir -p ${mountPoint}${persistPath}${dir}") uniquePersistDirs}

        # Create ephemeral mount points (on tmpfs root)
        ${lib.concatMapStringsSep "\n" (dir: "mkdir -p ${mountPoint}${dir}")
        uniquePersistDirs}
      ''}

      ${lib.optionalString (bindMountDirs != [ ]) ''
        # Create bind mounts for boot-critical directories
        ${lib.concatMapStringsSep "\n" (dir:
          "mount --bind ${mountPoint}${persistPath}${dir} ${mountPoint}${dir}")
        bindMountDirs}
      ''}

      echo "preservation-disko: setup complete (${persistPath})"
    '';

    preservation.enable = true;

    # Required for preservation to work in initrd
    boot.initrd.systemd.enable = true;

    # For symlink mode with createLinkTarget=true, preservation handles file creation
    # For bindmount mode, we need tmpfiles to initialize the file
    # Reference: https://github.com/nix-community/preservation/issues/22
    boot.initrd.systemd.tmpfiles.settings.preservation =
      lib.mkIf (cfg.machineIdMode == "bindmount") {
        "/sysroot${persistPath}/etc".d = { mode = "0755"; };
        "/sysroot${persistPath}/etc/machine-id".f = {
          mode = "0644";
          argument = "uninitialized";
        };
      };

    # === Preservation Config ===
    # Base directories - users add more via module system merging
    # Reference: https://github.com/nix-community/preservation/pull/23
    preservation.preserveAt.${persistPath} = {
      directories = [
        "/var/lib/nixos" # NixOS state (uid/gid maps, etc)
        "/var/lib/systemd" # systemd state (needed for ConditionFirstBoot)
        "/var/log" # System logs
      ]
      # Clan facts: preserve the secret upload directory
        ++ lib.optional (clanFactsSecretDir != null) clanFactsSecretDir
        # Clan vars (without facts): preserve sops-nix keys
        ++ lib.optional (clanVarsEnabled && !clanFactsEnabled)
        "/var/lib/sops-nix";

      files = [
        ({
          file = "/etc/machine-id";
          inInitrd = true;
          how = cfg.machineIdMode;
        } // lib.optionalAttrs (cfg.machineIdMode == "symlink") {
          createLinkTarget = true;
        })
      ];
    };

    # === Extra Bind Mounts ===
    # Create fileSystems entries for extraBindMounts
    fileSystems = lib.mapAttrs (path: opts: {
      device = "${persistPath}${path}";
      fsType = "none";
      options = [ "bind" "X-fstrim.notrim" ];
      neededForBoot = opts.neededForBoot;
    }) cfg.extraBindMounts;

    # === Machine-ID Commit Service ===
    # For bind mount: add ConditionFirstBoot=true to prevent committing on every boot
    # (bind mount makes ConditionPathIsMountPoint true every time)
    # Reference: https://github.com/nix-community/preservation/pull/23
    systemd.services.systemd-machine-id-commit.unitConfig.ConditionFirstBoot =
      lib.mkIf (cfg.machineIdMode == "bindmount") true;
  };
}
