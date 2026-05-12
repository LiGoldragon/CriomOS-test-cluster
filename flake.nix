{
  description = "Independent CriomOS fixture cluster and sandboxed Nix regression tests.";

  inputs = {
    nixpkgs.url = "github:LiGoldragon/nixpkgs?ref=main";

    criomos.url = "github:LiGoldragon/CriomOS";
    criomos.inputs.nixpkgs.follows = "nixpkgs";
    criomos.inputs.criomos-lib.follows = "criomos-lib";

    criomos-lib.url = "github:LiGoldragon/CriomOS-lib";

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
            for node in atlas beacon cedar; do
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

          source-constraints = pkgs.callPackage ./checks/source-constraints.nix {
            inherit inputs;
          };
        }
      );

      packages = forSystems (
        system:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
        in
        {
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
        run-on-prometheus = {
          type = "app";
          program = "${self.packages.${system}.run-on-prometheus}/bin/run-on-prometheus";
        };
      });

      formatter = forSystems (system: inputs.nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
