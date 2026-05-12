{
  inputs,
  pkgs,
  ...
}:

let
  inherit (inputs.nixpkgs) lib;

  moduleRoot = inputs.criomos + "/modules/nixos";
  files = lib.filter (path: lib.hasSuffix ".nix" (builtins.toString path)) (
    lib.filesystem.listFilesRecursive moduleRoot
  );

  forbiddenHostFacts = [
    "ouranos"
    "prometheus"
    "zeus"
    "balboa"
    "klio"
    "tiger"
    "maisiliym"
    "goldragon"
  ];

  forbiddenPredicateFragments = [
    "node.name =="
    "node.name !="
    "builtins.elem node.name"
    "lib.elem node.name"
  ];

  forbiddenClusterDomainFragments = [
    "tailnet.\${cluster.name}.criome"
    ".\${cluster.name}.criome"
  ];

  forbiddenFragments =
    forbiddenHostFacts ++ forbiddenPredicateFragments ++ forbiddenClusterDomainFragments;

  scanFile =
    path:
    let
      text = builtins.readFile path;
      matches = lib.filter (fragment: lib.hasInfix fragment text) forbiddenFragments;
    in
    lib.optionals (matches != [ ]) [
      {
        file = lib.removePrefix ((builtins.toString inputs.criomos) + "/") (builtins.toString path);
        inherit matches;
      }
    ];

  offenders = lib.concatLists (map scanFile files);
  offenderText = lib.concatMapStringsSep "\n" (
    offender: "${offender.file}: ${lib.concatStringsSep ", " offender.matches}"
  ) offenders;

  offenderReport = pkgs.writeText "criomos-source-constraint-offenders.txt" offenderText;
in
pkgs.runCommand "source-constraints" { } ''
  set -eu
  if [ -s ${offenderReport} ]; then
    echo "CriomOS module source contains forbidden host facts, node-name predicates, or fixed cluster domains:" >&2
    cat ${offenderReport} >&2
    exit 1
  fi

  touch "$out"
''
