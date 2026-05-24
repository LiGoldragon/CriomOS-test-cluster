{
  description = "Independent CriomOS fixture cluster and sandboxed Nix regression tests.";

  inputs = {
    nixpkgs.url = "github:LiGoldragon/nixpkgs?ref=main";

    criomos.url = "github:LiGoldragon/CriomOS";
    criomos.inputs.nixpkgs.follows = "nixpkgs";
    criomos.inputs.criomos-lib.follows = "criomos-lib";

    criomos-lib.url = "github:LiGoldragon/CriomOS-lib";

    brightness-ctl.follows = "criomos/brightness-ctl";
    clavifaber.follows = "criomos/clavifaber";
    criomos-home.follows = "criomos/criomos-home";
    home-manager.follows = "criomos/home-manager";

    horizon.url = "github:LiGoldragon/horizon-rs";
    horizon.inputs.nixpkgs.follows = "nixpkgs";

    persona-spirit.url = "github:LiGoldragon/persona-spirit";
    persona-spirit-v010.url = "github:LiGoldragon/persona-spirit?ref=v0.1.0";

    upgrade.url = "github:LiGoldragon/upgrade";
  };

  outputs =
    inputs@{ self, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forSystems = inputs.nixpkgs.lib.genAttrs systems;
    in
    {
      checks = forSystems (
        system:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          horizonCli = inputs.horizon.packages.${system}.default;
        in
        {
          projections-match-fieldlab = pkgs.runCommand "projections-match-fieldlab" { } ''
            set -eu
            for node in atlas beacon cedar dune; do
              ${horizonCli}/bin/horizon-cli \
                --cluster fieldlab \
                --node "$node" \
                < ${./clusters/fieldlab.nota} \
                > "$node.json"
              cmp "$node.json" ${./fixtures/horizon}/"$node.json"
            done
            touch "$out"
          '';

          multiple-tailnet-controllers-rejected =
            pkgs.runCommand "multiple-tailnet-controllers-rejected" { }
              ''
                set -eu
                if ${horizonCli}/bin/horizon-cli \
                  --cluster fieldlab \
                  --node atlas \
                  < ${./clusters/fieldlab-two-controllers.nota} \
                  > "$out.unexpected" 2>"$out.err"; then
                  cat "$out.unexpected" >&2
                  exit 1
                fi
                grep -F 'multiple tailnet controller servers' "$out.err"
                touch "$out"
              '';

          pod-missing-super-node-rejected = pkgs.runCommand "pod-missing-super-node-rejected" { } ''
            set -eu
            if ${horizonCli}/bin/horizon-cli \
              --cluster fieldlab \
              --node atlas \
              < ${./clusters/fieldlab-pod-missing-super-node.nota} \
              > "$out.unexpected" 2>"$out.err"; then
              cat "$out.unexpected" >&2
              exit 1
            fi
            grep -F 'references missing super-node' "$out.err"
            touch "$out"
          '';

          cluster-contracts = pkgs.callPackage ./checks/cluster-contracts.nix {
            inherit inputs self system;
          };

          full-module-contracts = pkgs.callPackage ./checks/full-module-contracts.nix {
            inherit inputs self system;
          };

          source-constraints = pkgs.callPackage ./checks/source-constraints.nix {
            inherit inputs;
          };

          spirit-nspawn-can-build = pkgs.runCommand "spirit-nspawn-can-build" { } ''
            test -x ${self.packages.${system}.spirit-nspawn-toplevel}/init
            test -e ${self.packages.${system}.spirit-nspawn-toplevel}/etc/os-release
            touch "$out"
          '';
        }
      );

      packages = forSystems (
        system:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          constants = inputs.criomos-lib.lib.constants;
          fixtureHorizon =
            node: builtins.fromJSON (builtins.readFile "${self}/fixtures/horizon/${node}.json");
          fixtureSystem =
            node: extraModules:
            (inputs.nixpkgs.lib.nixosSystem {
              inherit system;
              specialArgs = {
                inherit constants inputs;
                horizon = fixtureHorizon node;
                deployment = {
                  includeHome = false;
                };
              };
              modules = [
                inputs.criomos.nixosModules.criomos
              ]
              ++ extraModules;
            }).config.system.build.toplevel;

          spirit010 = inputs.persona-spirit-v010.packages.${system};
          spirit011 = inputs.persona-spirit.packages.${system};
          upgradePackage = inputs.upgrade.packages.${system}.default;

          spiritV010Wrappers = [
            (pkgs.writeShellScriptBin "spirit-v010" ''
              exec ${spirit010.spirit}/bin/spirit "$@"
            '')
            (pkgs.writeShellScriptBin "persona-spirit-daemon-v010" ''
              exec ${spirit010.persona-spirit-daemon}/bin/persona-spirit-daemon "$@"
            '')
          ];

          spiritUpgradeTestRunner = pkgs.writeShellApplication {
            name = "spirit-upgrade-test-runner";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.findutils
              pkgs.gnugrep
              spirit011.spirit
              spirit011.persona-spirit-daemon
              upgradePackage
            ]
            ++ spiritV010Wrappers;
            text = builtins.readFile ./scripts/spirit-upgrade-test-runner;
          };

          # Minimal NixOS toplevel for the Spirit nspawn upgrade test. The
          # Spirit pilot only needs systemd plus the Spirit and upgrade
          # binaries; using the full CriomOS module tree would pull in
          # unrelated fixture drift while this test is proving Spirit's
          # database migration path.
          spirit-nspawn-toplevel =
            (inputs.nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                (
                  { lib, ... }:
                  {
                    boot.isContainer = true;

                    networking.hostName = "spirit-upgrade-test";
                    networking.useDHCP = lib.mkForce true;
                    networking.firewall.enable = false;

                    documentation.enable = false;
                    documentation.nixos.enable = false;
                    documentation.man.enable = false;

                    services.openssh.enable = false;

                    system.stateVersion = "25.05";

                    environment.systemPackages = [
                      spirit011.spirit
                      spirit011.persona-spirit-daemon
                      upgradePackage
                      spiritUpgradeTestRunner
                    ]
                    ++ spiritV010Wrappers;
                  }
                )
              ];
            }).config.system.build.toplevel;
        in
        {
          dune-toplevel = fixtureSystem "dune" [ ];
          dune-nspawn-toplevel = fixtureSystem "dune" [
            (
              { lib, ... }:
              {
                boot.isNspawnContainer = true;
                networking.useHostResolvConf = lib.mkForce false;
                programs.regreet.enable = lib.mkForce false;
                services.greetd.enable = lib.mkForce false;
                services.yggdrasil.enable = lib.mkForce false;
                systemd.services.complex-init.enable = lib.mkForce false;
                systemd.services.wpa_supplicant.enable = lib.mkForce false;
              }
            )
          ];

          inherit spirit-nspawn-toplevel;

          spirit-upgrade-test-runner = spiritUpgradeTestRunner;

          build-dune-on-prometheus = pkgs.writeShellApplication {
            name = "build-dune-on-prometheus";
            runtimeInputs = [
              pkgs.jujutsu
              pkgs.openssh
              pkgs.bash
            ];
            text = builtins.readFile ./scripts/build-dune-on-prometheus;
          };

          nspawn-dune-on-prometheus = pkgs.writeShellApplication {
            name = "nspawn-dune-on-prometheus";
            runtimeInputs = [
              pkgs.jujutsu
              pkgs.openssh
              pkgs.bash
            ];
            text = builtins.readFile ./scripts/nspawn-dune-on-prometheus;
          };

          nspawn-spirit-upgrade-on-prometheus = pkgs.writeShellApplication {
            name = "nspawn-spirit-upgrade-on-prometheus";
            runtimeInputs = [
              pkgs.jujutsu
              pkgs.openssh
              pkgs.bash
            ];
            text = builtins.readFile ./scripts/nspawn-spirit-upgrade-on-prometheus;
          };

          run-on-prometheus = pkgs.writeShellApplication {
            name = "run-on-prometheus";
            runtimeInputs = [
              pkgs.jujutsu
              pkgs.openssh
              pkgs.bash
            ];
            text = builtins.readFile ./scripts/run-on-prometheus;
          };
        }
      );

      apps = forSystems (system: {
        build-dune-on-prometheus = {
          type = "app";
          program = "${self.packages.${system}.build-dune-on-prometheus}/bin/build-dune-on-prometheus";
        };

        nspawn-dune-on-prometheus = {
          type = "app";
          program = "${self.packages.${system}.nspawn-dune-on-prometheus}/bin/nspawn-dune-on-prometheus";
        };

        nspawn-spirit-upgrade-on-prometheus = {
          type = "app";
          program = "${
            self.packages.${system}.nspawn-spirit-upgrade-on-prometheus
          }/bin/nspawn-spirit-upgrade-on-prometheus";
        };

        run-on-prometheus = {
          type = "app";
          program = "${self.packages.${system}.run-on-prometheus}/bin/run-on-prometheus";
        };
      });

      formatter = forSystems (system: inputs.nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
