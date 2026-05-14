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

          cluster-contracts = pkgs.callPackage ./checks/cluster-contracts.nix {
            inherit inputs self system;
          };

          full-module-contracts = pkgs.callPackage ./checks/full-module-contracts.nix {
            inherit inputs self system;
          };

          source-constraints = pkgs.callPackage ./checks/source-constraints.nix {
            inherit inputs;
          };
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
        in
        {
          dune-toplevel = fixtureSystem "dune" [ ];
          dune-nspawn-toplevel = fixtureSystem "dune" [
            (
              { lib, ... }:
              {
                boot.isNspawnContainer = true;
                networking.useHostResolvConf = lib.mkForce false;
              }
            )
          ];

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

        run-on-prometheus = {
          type = "app";
          program = "${self.packages.${system}.run-on-prometheus}/bin/run-on-prometheus";
        };
      });

      formatter = forSystems (system: inputs.nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
