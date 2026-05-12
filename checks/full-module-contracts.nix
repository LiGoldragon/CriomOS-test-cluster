{
  inputs,
  pkgs,
  self,
  system,
  ...
}:

let
  inherit (inputs.nixpkgs) lib;

  constants = inputs.criomos-lib.lib.constants;
  bool = value: if value then "true" else "false";

  readHorizon = node: builtins.fromJSON (builtins.readFile "${self}/fixtures/horizon/${node}.json");

  configurationFor =
    horizon:
    (lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit constants horizon inputs;
        deployment = {
          includeHome = false;
        };
      };
      modules = [
        inputs.criomos.nixosModules.criomos
      ];
    }).config;

  beacon = readHorizon "beacon";
  cedar = readHorizon "cedar";

  beaconSystem = configurationFor beacon;
  cedarSystem = configurationFor cedar;

  cedarWifiScript = cedarSystem.systemd.services.wifi-eap-connection.script;
in
pkgs.runCommand "full-module-contracts" { } ''
  set -eu

  test ${lib.escapeShellArg cedarSystem.networking.hostName} = cedar
  test ${lib.escapeShellArg (bool cedarSystem.networking.networkmanager.enable)} = true
  test ${lib.escapeShellArg (bool cedarSystem.services.openssh.enable)} = true
  test ${lib.escapeShellArg (bool cedarSystem.services.openssh.settings.PasswordAuthentication)} = false
  test ${lib.escapeShellArg (bool cedarSystem.services.tailscale.enable)} = true
  test ${lib.escapeShellArg (bool (cedarSystem.services.headscale.enable or false))} = false
  test ${lib.escapeShellArg (bool (cedarSystem.programs.dconf.enable or false))} = true
  test ${lib.escapeShellArg (bool (cedarSystem.systemd.services ? "cedar-llama-router"))} = false
  test ${lib.escapeShellArg (toString (builtins.length cedarSystem.users.users.root.openssh.authorizedKeys.keys))} -gt 0
  printf '%s' ${lib.escapeShellArg cedarWifiScript} | grep -F 'key-mgmt=wpa-eap'
  printf '%s' ${lib.escapeShellArg cedarWifiScript} | grep -F 'identity=cedar'

  test ${lib.escapeShellArg beaconSystem.networking.hostName} = beacon
  test ${lib.escapeShellArg (bool beaconSystem.nix.sshServe.enable)} = true
  test ${lib.escapeShellArg (bool beaconSystem.nix.distributedBuilds)} = true
  test ${lib.escapeShellArg (bool beaconSystem.services.tailscale.enable)} = true
  test ${lib.escapeShellArg (bool (beaconSystem.services.headscale.enable or false))} = false
  test ${lib.escapeShellArg (bool (beaconSystem.systemd.services ? "beacon-llama-router"))} = false

  touch "$out"
''
