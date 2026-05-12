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

  rewriteDomainSuffix =
    from: to: node:
    node
    // {
      criomeDomainName = lib.replaceStrings [ from ] [ to ] node.criomeDomainName;
      nixCacheDomain =
        if node.nixCacheDomain == null then
          null
        else
          lib.replaceStrings [ from ] [ to ] node.nixCacheDomain;
    };

  withDomainSuffix =
    horizon: from: to:
    let
      rewriteNode = rewriteDomainSuffix from to;
    in
    horizon
    // {
      node = rewriteNode horizon.node;
      exNodes = lib.mapAttrs (_: rewriteNode) horizon.exNodes;
    };

  configurationFor =
    horizon: modules:
    (lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit constants horizon inputs;
      };
      modules = modules ++ [
        { system.stateVersion = "26.05"; }
      ];
    }).config;

  criomosModule = path: inputs.criomos + "/modules/nixos/${path}";

  atlas = readHorizon "atlas";
  beacon = readHorizon "beacon";
  cedar = readHorizon "cedar";

  atlasNetwork = configurationFor atlas [
    (criomosModule "network/default.nix")
    (criomosModule "router/default.nix")
  ];
  atlasAlternateDomainNetwork =
    configurationFor (withDomainSuffix atlas ".fieldlab.criome" ".fieldlab.test")
      [
        (criomosModule "network/default.nix")
        (criomosModule "router/default.nix")
      ];
  cedarNetwork = configurationFor cedar [
    (criomosModule "network/default.nix")
  ];

  atlasNix = configurationFor atlas [
    (criomosModule "nix/default.nix")
  ];
  beaconNix = configurationFor beacon [
    (criomosModule "nix/default.nix")
  ];
  cedarNix = configurationFor cedar [
    (criomosModule "nix/default.nix")
  ];

  cedarWifiScript = cedarNetwork.systemd.services.wifi-eap-connection.script;
in
pkgs.runCommand "cluster-contracts" { } ''
  set -eu

  test ${lib.escapeShellArg atlas.node.name} = atlas
  test ${lib.escapeShellArg atlas.cluster.name} = fieldlab
  test ${lib.escapeShellArg atlas.node.services.tailnet} = Client
  test ${lib.escapeShellArg atlas.node.services.tailnetController} = Server
  test ${lib.escapeShellArg cedar.node.services.tailnet} = Client
  test ${lib.escapeShellArg (bool cedar.node.hasWifiCertPubKey)} = true

  test ${lib.escapeShellArg (bool atlasNetwork.services.headscale.enable)} = true
  test ${lib.escapeShellArg (bool atlasNetwork.services.tailscale.enable)} = true
  test ${lib.escapeShellArg (bool atlasNetwork.services.dnsmasq.enable)} = true
  echo ${lib.escapeShellArg (builtins.toJSON atlasNetwork.services.dnsmasq.settings.server)} \
    | grep -F '/tailnet.fieldlab.criome/100.100.100.100'
  test ${lib.escapeShellArg atlasAlternateDomainNetwork.services.headscale.settings.dns.base_domain} = tailnet.fieldlab.test
  echo ${lib.escapeShellArg (builtins.toJSON atlasAlternateDomainNetwork.services.dnsmasq.settings.server)} \
    | grep -F '/tailnet.fieldlab.test/100.100.100.100'

  test ${lib.escapeShellArg (bool cedarNetwork.services.tailscale.enable)} = true
  test ${lib.escapeShellArg (bool (cedarNetwork.services.headscale.enable or false))} = false
  printf '%s' ${lib.escapeShellArg cedarWifiScript} | grep -F 'key-mgmt=wpa-eap'
  printf '%s' ${lib.escapeShellArg cedarWifiScript} | grep -F 'identity=cedar'
  printf '%s' ${lib.escapeShellArg cedarWifiScript} | grep -F 'client-cert='

  test ${lib.escapeShellArg (bool atlasNix.services.nix-serve.enable)} = true
  test ${lib.escapeShellArg (bool beaconNix.nix.sshServe.enable)} = true
  test ${lib.escapeShellArg (bool cedarNix.nix.distributedBuilds)} = true
  test ${lib.escapeShellArg (toString (builtins.length cedarNix.nix.buildMachines))} = 2
  test ${lib.escapeShellArg (bool (builtins.hasAttr "atlas.fieldlab.criome" cedarNix.programs.ssh.knownHosts))} = true
  test ${lib.escapeShellArg (bool (builtins.hasAttr "beacon.fieldlab.criome" cedarNix.programs.ssh.knownHosts))} = true
  echo ${lib.escapeShellArg (builtins.toJSON cedarNix.nix.settings.substituters)} \
    | grep -F 'http://nix.atlas.fieldlab.criome'

  touch "$out"
''
