# deploy-flake — the hermetic, OFFLINE deploy flake the lojix daemon evals +
# builds inside the C6 smoke test (design reports 50/4 §3.2, 50/1; live e2e
# reports 48/49). Companion to mkDeployTest.nix.
#
# THE PROBLEM IT SOLVES (Spirit [dqg3] — unblock the blocker IN the test):
#   The production deploy path is `nix eval <flake>#<attr>.drvPath` ->
#   `nix build <drv>^*` -> copy -> activate. Inside a HERMETIC runNixOSTest the
#   deployer has NO network, so the daemon's eval+build must resolve entirely
#   from the deployer node's own /nix/store. Two facts make the naive path fail
#   offline, and this module fixes both WITHOUT touching the daemon (the eval
#   command stays production-identical):
#
#   1. A real CriomOS toplevel eval reaches `inputs.clavifaber.packages.*` whose
#      crane/fenix build fetches `nota-derive` over git AT EVAL TIME — an
#      unavoidable network fetch (report 48 fix #1 hit exactly this and stubbed
#      clavifaber). So this deploy flake threads a tiny OFFLINE clavifaber STUB
#      through specialArgs.inputs; the rest of the node is mercury's real
#      projected CriomOS system. The deployed closure is the target's
#      cluster-data-generated config with one package stubbed — faithful to the
#      live e2e, real `nixos-system-<node>`, not a hand-written stub.
#
#   2. A flake eval is PURE: it cannot `import` a prebuilt .drv or use
#      `builtins.storePath`. So the toplevel is RE-DERIVED here from
#      remote-pinned inputs whose source trees are also retained in the
#      deployer node's store. Nix resolves every locked input from STORE
#      RESIDENCE by narHash (verified: empty eval cache + empty flake-registry
#      + --offline still resolves), so as long as the deployer node's store
#      holds the input source trees (mkDeployTest pins them as a node store
#      dependency) the eval is fully offline. The re-derived drv is
#      byte-identical to the one this very build realises, so
#      `nix build <drv>^*` is an instant offline store hit.
#
# WHAT IT RETURNS:
#   { source;       # the locked deploy-flake SOURCE dir in the store — the
#                   #   flake reference the daemon evals
#     buildAttribute;# "systemToplevel" — the build_attribute the Deploy carries
#     toplevel;     # the realised deployed system (a real nixos-system-<node>),
#                   #   so mkDeployTest can pin its build closure into the node
#                   #   store and assert the activated path equals it
#     evalSources;  # the set of input source store paths the offline eval reads,
#                   #   gathered generically (nixpkgs + criomos + every
#                   #   criomos.inputs.*), so the node can depend on them
#   }
#
# THE LOCK IS PRE-GENERATED, NOT HAND-WRITTEN. The deploy flake carries exact
# remote GitHub revisions while the same source trees are threaded in as
# explicit build dependencies. Its lock is cut from this repo's already-pinned
# flake.lock, keeping the remote nodes and narHashes without running
# `nix flake lock` inside the offline builder.

{
  inputs,
  pkgs,
  self,
  system,
}:

let
  inherit (inputs.nixpkgs) lib;
  criomos = inputs.criomos;
  nixpkgsSource = inputs.nixpkgs.outPath;
  criomosSource = criomos.outPath;

  parentLock = builtins.fromJSON (builtins.readFile "${self}/flake.lock");
  rootInputNode = name: parentLock.nodes.root.inputs.${name};

  # A FIXED nixos label, pinned identically in toplevelFor and the deploy-flake
  # text. Without it the label is derived from nixpkgs's flake revision — which
  # differs between this build (nixpkgs has a rev) and any deploy flake eval
  # whose nixpkgs input has no revision metadata (a `.dirty` label), making
  # the two drvs diverge. Pinning it makes the re-derived deployed system
  # byte-identical to the closure this build realises, so the daemon's
  # `nix build <drv>^*` is an instant offline store hit on the pinned closure.
  deployedLabel = "26.05-c6smoke";

  # The router-wifi sops secret as its OWN content-addressed store path,
  # referenced IDENTICALLY by toplevelFor (in-process) and the deploy-flake text
  # (via `self`, which copies the same file into the locked flake at this
  # basename). sops-nix records this path in the system closure, so both
  # evaluations must see the SAME store path or the drv diverges (mercury is not
  # a router and never reads the secret, but sops-nix still threads the path).
  secretName = "routerWifiSaePasswords";
  secretPath = builtins.path {
    name = secretName;
    path = "${self}/fixtures/secrets/routerWifiSaePasswords";
  };

  # Every input SOURCE the offline eval may touch — gathered generically by
  # walking criomos's transitive inputs (each carries `.outPath`), plus the two
  # roots + criomos-lib. The deployer node depends on this set (mkDeployTest),
  # so the VM store holds every source tree the daemon's `nix eval` resolves.
  # The daemon's eval is offline by node nix config (`tarball-ttl` very large +
  # `use-registries=false`): `--refresh` then re-uses the store-resident input
  # copies by narHash instead of re-unpacking from github (which would need the
  # network). So the plain github-pinned lock resolves fully from store —
  # verified cold-cache — with NO lock rewriting, and the deployed drv is
  # identical to the in-process `toplevelFor` (both github-pinned).
  evalSources =
    let
      walk =
        flake:
        let
          ins = flake.inputs or { };
          names = builtins.attrNames ins;
          here = builtins.foldl' (
            acc: name: if ins.${name} ? outPath then acc ++ [ ins.${name}.outPath ] else acc
          ) [ ] names;
          deeper = builtins.foldl' (acc: name: acc ++ walk ins.${name}) [ ] names;
        in
        here ++ deeper;
    in
    [
      nixpkgsSource
      criomosSource
      inputs.criomos-lib.outPath
    ]
    ++ walk criomos;

  criomosLibSource = inputs.criomos-lib.outPath;

  originalGithubUrl =
    nodeName:
    let
      original =
        parentLock.nodes.${nodeName}.original
          or (throw "CriomOS-test-cluster deploy flake requires ${nodeName} to have an original input");
      referenceSuffix = lib.optionalString (original ? ref) "?ref=${original.ref}";
    in
    if (original.type or null) == "github" then
      "github:${original.owner}/${original.repo}${referenceSuffix}"
    else
      throw "CriomOS-test-cluster deploy flake requires ${nodeName} to be an original GitHub input";

  nixpkgsNode = rootInputNode "nixpkgs";
  nixpkgsUrl = originalGithubUrl nixpkgsNode;
  criomosLibUrl = originalGithubUrl "criomos-lib";
  criomosUrl = originalGithubUrl "criomos";

  evalSourcesClosure = pkgs.linkFarm "lojix-deploy-flake-eval-sources" (
    lib.imap0 (index: source: {
      name = "source-${toString index}";
      path = source;
    }) evalSources
  );

  deployLock = builtins.toFile "lojix-deploy-flake-lock" (
    builtins.toJSON (
      parentLock
      // {
        nodes = parentLock.nodes // {
          root = (parentLock.nodes.root or { }) // {
            inputs = {
              criomos = "criomos";
              criomos-lib = "criomos-lib";
              nixpkgs = nixpkgsNode;
            };
          };
        };
      }
    )
  );

  # The deploy flake's text. Inputs stay remote refs; the source closure above
  # keeps their source trees present in the builder/deployer stores so offline
  # lock/eval resolves by narHash. criomos-lib is top-level and criomos FOLLOWS
  # it, so both roots use the same locked remote revision.
  deployFlakeText = vmNode: ''
    {
      inputs.nixpkgs.url = "${nixpkgsUrl}";
      inputs.criomos-lib.url = "${criomosLibUrl}";
      inputs.criomos.url = "${criomosUrl}";
      inputs.criomos.inputs.criomos-lib.follows = "criomos-lib";
      inputs.criomos.inputs.nixpkgs.follows = "nixpkgs";
      outputs =
        { self, nixpkgs, criomos, criomos-lib }:
        let
          system = "${system}";
          pkgs = nixpkgs.legacyPackages.''${system};
          clavifaberStub.packages.''${system}.default =
            pkgs.writeShellScriptBin "clavifaber" "exit 0";
        in
        {
          # The deployed system — the target's real projected CriomOS config
          # (clavifaber stubbed for offline eval). The daemon evals
          # systemToplevel.drvPath then builds <drv>^*; the <drv>^* fix means it
          # realises THIS nixos-system, never the bare .drv.
          systemToplevel =
            (nixpkgs.lib.nixosSystem {
              inherit system;
              specialArgs = {
                constants = criomos-lib.lib.constants;
                horizon = builtins.fromJSON (builtins.readFile (self + "/${vmNode}.json"));
                deployment = {
                  includeHome = false;
                  includeComplex = false;
                };
                inputs = criomos.inputs // {
                  inherit criomos;
                  sops-nix = criomos.inputs.sops-nix;
                  microvm = criomos.inputs.microvm;
                  clavifaber = clavifaberStub;
                  # Content-addressed so this path is IDENTICAL to toplevelFor's
                  # secretPath (same name + same content -> same store path),
                  # keeping the re-derived drv byte-identical.
                  secrets.sopsFiles.routerWifiSaePasswords = builtins.path {
                    name = "${secretName}";
                    path = self + "/${secretName}";
                  };
                };
              };
              modules = [
                criomos.nixosModules.criomos
                {
                  system.nixos.label = "${deployedLabel}";
                  system.nixos.version = "${deployedLabel}";
                  system.nixos.revision = "${deployedLabel}";
                  # GENERATION-ACTIVATION SCOPE (psyche decision, report 50/1):
                  # C6 asserts the system PROFILE generation becomes the deployed
                  # closure (nix-env --set), NOT the full BootOnce/bootloader
                  # path (deferred q35 work). The daemon's Switch runs
                  # `nix-env --set <closure> && switch-to-configuration switch`;
                  # the runNixOSTest guest direct-boots, so the real systemd-boot
                  # INSTALL has no firmware target and fails (report 48 finding).
                  # A no-op installBootLoader lets switch-to-configuration
                  # COMPLETE after the generation is set — the deployed system
                  # activates to gen-2 without a bootloader write. This is a
                  # SUBSTRATE property of the throwaway test target (like
                  # require-sigs=false), scoping to generation-activation; it does
                  # NOT change the daemon or the deploy command.
                  system.build.installBootLoader = nixpkgs.lib.mkForce (
                    pkgs.writeShellScript "c6-noop-install-bootloader" "exit 0"
                  );
                }
              ];
            }).config.system.build.toplevel;
        };
    }
  '';

  # Build the LOCKED deploy-flake source dir. The root inputs are exact remote
  # refs and their source trees are store-resident; the generated lock carries
  # the narHashes from this flake's lock, so the builder performs no networked
  # lock update.
  sourceFor =
    vmNode:
    pkgs.runCommand "lojix-deploy-flake-${vmNode}"
      {
        passAsFile = [ "flakeText" ];
        flakeText = deployFlakeText vmNode;
        flakeLock = deployLock;
        inherit nixpkgsSource criomosSource evalSourcesClosure;
        projection = "${self}/fixtures/horizon/${vmNode}.json";
        secret = "${self}/fixtures/secrets/routerWifiSaePasswords";
        NIX_CONFIG = ''
          experimental-features = nix-command flakes
          flake-registry =
          substituters =
        '';
      }
      ''
        export HOME="$TMPDIR"
        mkdir -p "$out"
        cp "$flakeTextPath" "$out/flake.nix"
        cp "$flakeLock" "$out/flake.lock"
        cp "$projection" "$out/${vmNode}.json"
        cp "$secret" "$out/routerWifiSaePasswords"
        test -f "$out/flake.lock"
      '';

  # The deployed system, RE-DERIVED in-process exactly as the deploy-flake text
  # builds it (same constants, threaded inputs, stub, pinned label/version/
  # revision, no-op bootloader). Evaluated on the HOST with substituters ON, so
  # its full closure realises from the cache — this is what mkDeployTest pins
  # into the deployer node store so the daemon's offline `nix build <drv>^*`
  # finds all its deps. The daemon's own eval (from the generated lock)
  # produces a drv that shares this closure (only label-metadata-level
  # derivations differ, and those build locally offline in seconds, as the live
  # runs confirm reaching Copy+Activate). The test discovers the daemon's exact
  # activated path from the durable Query state and asserts it is a real
  # nixos-system — the deployedSystem closure guarantees the offline build
  # succeeds.
  toplevelFor =
    vmNode:
    let
      horizon = builtins.fromJSON (builtins.readFile "${self}/fixtures/horizon/${vmNode}.json");
      clavifaberStub.packages.${system}.default = pkgs.writeShellScriptBin "clavifaber" "exit 0";
    in
    (lib.nixosSystem {
      inherit system;
      specialArgs = {
        constants = inputs.criomos-lib.lib.constants;
        inherit horizon;
        deployment = {
          includeHome = false;
          includeComplex = false;
        };
        inputs = criomos.inputs // {
          inherit criomos;
          sops-nix = criomos.inputs.sops-nix;
          microvm = criomos.inputs.microvm;
          clavifaber = clavifaberStub;
          secrets.sopsFiles.routerWifiSaePasswords = secretPath;
        };
      };
      modules = [
        criomos.nixosModules.criomos
        {
          system.nixos.label = deployedLabel;
          system.nixos.version = deployedLabel;
          system.nixos.revision = deployedLabel;
          system.build.installBootLoader = lib.mkForce (
            pkgs.writeShellScript "c6-noop-install-bootloader" "exit 0"
          );
        }
      ];
    }).config.system.build.toplevel;
in
{
  sourceFor = vmNode: sourceFor vmNode;
  # The deployed nixos-system toplevel derivation (its closure is pinned into
  # the deployer node so the daemon's offline build resolves; the test
  # discovers the daemon's exact activated path from durable state).
  toplevelFor = toplevelFor;
  inherit evalSources;
  buildAttribute = "systemToplevel";
}
