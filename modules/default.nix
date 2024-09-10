{
  pkgs,
  lib,
  config,
  ...
}: let
  inherit (lib) mkOption types unique;
  inherit (lib.lists) elem;
  inherit (lib.strings) concatStrings concatStringsSep escape stringAsChars;
  inherit (lib.attrsets) filterAttrs mapAttrs' mapAttrsToList nameValuePair optionalAttrs;

  cfg = config.services.nix-mc;

  # Server config rendering
  serverPropertiesFile = serverConfig:
    pkgs.writeText "server.properties"
    (mkOptionText serverConfig);

  startFile = script:
    pkgs.writeShellScript "start.sh" ''
      cd "$(dirname "$0")"
      ${script}
    '';

  encodeOptionValue = value: let
    encodeBool = value:
      if value
      then "true"
      else "false";
    encodeString = value: escape [":" "=" "'"] value;
    typeMap = {
      "bool" = encodeBool;
      "string" = encodeString;
    };
  in
    (typeMap.${builtins.typeOf value} or toString) value;

  mkOptionLine = name: value: let
    dotNames = ["query-port" "rcon-password" "rcon-port"];
    fixName = name:
      if elem name dotNames
      then
        stringAsChars
        (x:
          if x == "-"
          then "."
          else x)
        name
      else name;
  in "${fixName name}=${encodeOptionValue value}";

  mkOptionText = serverConfig: let
    # Merge declared options with extraConfig
    c =
      (builtins.removeAttrs serverConfig ["extra-options"])
      // serverConfig.extra-options;
  in
    concatStringsSep "\n"
    (mapAttrsToList mkOptionLine c);

  # Render EULA file
  eulaFile = builtins.toFile "eula.txt" ''
    # eula.txt managed by NixOS Configuration
    eula=true
  '';
in {
  options = {
    services.nix-mc = {
      eula = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether or not you accept the Minecraft EULA.
        '';
      };

      user = mkOption {
        default = "minecraft";
        type = types.str;
        description = ''
          The name of the user who is going to be running
          the servers. Defaults to "minecraft".
        '';
      };

      group = mkOption {
        default = "minecraft";
        type = types.str;
        description = ''
          The name of the group of the user who is going to
          be running the servers. Defaults to "minecraft".
        '';
      };

      instances = mkOption {
        type =
          types.attrsOf
          (types.submodule (import ./minecraft-instance-options.nix pkgs));
        default = {};
        description = ''
          Define instances of Minecraft servers to run.
        '';
      };
    };
  };

  config = let
    enabledInstances = filterAttrs (_: x: x.enable) cfg.instances;

    # Attrset options
    perEnabledInstance = func:
      mapAttrs' (i: c: nameValuePair "mc-${i}" (func i c)) enabledInstances;

    serverPorts =
      mapAttrsToList
      (_: v: v.serverConfig.server-port)
      enabledInstances;

    rconPorts =
      mapAttrsToList
      (_: v: v.serverConfig.rcon-port)
      (filterAttrs (_: x: x.serverConfig.enable-rcon) enabledInstances);

    openRconPorts =
      mapAttrsToList
      (_: v: v.serverConfig.rcon-port)
      (filterAttrs (_: x: x.serverConfig.enable-rcon && x.openRcon) enabledInstances);

    queryPorts =
      mapAttrsToList
      (_: v: v.serverConfig.query-port)
      (filterAttrs (_: x: x.serverConfig.enable-query) enabledInstances);
  in {
    assertions = [
      {
        assertion = cfg.eula;
        message = ''
          You must accept the Mojang EULA in order to run any servers.
        '';
      }
      {
        assertion = (unique serverPorts) == serverPorts;
        message = ''
          Your Minecraft instances have overlapping server ports.
          They must be unique.
        '';
      }
      {
        assertion = (unique rconPorts) == rconPorts;
        message = ''
          Your Minecraft instances have overlapping RCON ports.
          They must be unique.
        '';
      }
      {
        assertion = (unique queryPorts) == queryPorts;
        message = ''
          Your Minecraft instances have overlapping query ports.
          They must be unique.
        '';
      }
      (
        let
          allPorts = serverPorts ++ rconPorts ++ queryPorts;
        in {
          assertion = (unique allPorts) == allPorts;
          message = ''
            Your Minecraft instances have some overlapping ports
            among server, rcon and query ports. They must all be
            unique.
          '';
        }
      )
    ];

    systemd.services =
      perEnabledInstance (name: icfg: {
        description = "Minecraft Server ${name}";
        wantedBy = ["multi-user.target"];
        after = [ "network.target" ];

        path = [icfg.jvmPackage pkgs.bash] ++ icfg.serviceExtraPackages;

        environment = {
          JVMOPTS = icfg.jvmOptString;
          MCRCON_PORT = toString icfg.serverConfig.rcon-port;
          MCRCON_PASS = "whatisloveohbabydonthurtmedonthurtmenomore";
        };

        serviceConfig = let
          WorkingDirectory = "/var/lib/minecraft/${name}";
        in {
          ExecStart = ''
            ${WorkingDirectory}/start.sh
          '';
          Restart = "always";
          User = cfg.user;
          Group = cfg.group;
          StateDirectory = "minecraft/${name}";
          inherit WorkingDirectory;
        };

        preStart = ''
          # Ensure EULA is accepted
          ln -sf ${eulaFile} eula.txt

          # Ensure server.properties is present
          # This file must be writeable, because Mojang.
          cp -f ${serverPropertiesFile icfg.serverConfig} server.properties
          chmod 644 server.properties

          # Generate start.sh
          ${if icfg.generateScript then ''cp -f ${startFile icfg.startScript} start.sh'' else ""}
        '';
      });

    users.users = optionalAttrs (cfg.user == "minecraft") {
      minecraft = {
        createHome = true;
        group = cfg.group;
        home = "/var/lib/minecraft";
        isSystemUser = true;
      };
    };

    users.groups = optionalAttrs (cfg.group == "minecraft") {
      minecraft = {};
    };

    networking.firewall.allowedUDPPorts = queryPorts;
    networking.firewall.allowedTCPPorts = serverPorts ++ queryPorts ++ openRconPorts;
  };
}
