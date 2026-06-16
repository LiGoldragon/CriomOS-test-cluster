{
  description = "Independent CriomOS fixture cluster and sandboxed Nix regression tests.";

  inputs = {
    nixpkgs.url = "github:LiGoldragon/nixpkgs?ref=main";

    criomos.url = "github:LiGoldragon/CriomOS/horizon-test-vm";
    criomos.inputs.nixpkgs.follows = "nixpkgs";
    criomos.inputs.criomos-lib.follows = "criomos-lib";

    criomos-lib.url = "github:LiGoldragon/CriomOS-lib";

    brightness-ctl.follows = "criomos/brightness-ctl";
    clavifaber.follows = "criomos/clavifaber";
    criomos-home.follows = "criomos/criomos-home";
    home-manager.follows = "criomos/home-manager";

    horizon.url = "github:LiGoldragon/horizon-rs/horizon-test-vm";
    horizon.inputs.nixpkgs.follows = "nixpkgs";

    # The lojix deploy orchestrator — pinned to main (carrying the <drv>^*
    # output-selector fix, commit efbc5ea, that the live e2e caught: build
    # must realise the system, never copy/activate the bare .drv). The C6
    # smoke test builds the FIXED daemon + the meta-lojix / lojix / write-
    # configuration CLIs into the deployer node from this input. lojix pins
    # its own nixpkgs (its crane/fenix toolchain); we do NOT follow ours onto
    # it — the daemon is a self-contained release artifact.
    lojix.url = "github:LiGoldragon/lojix/main";

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
          inherit (inputs.nixpkgs) lib;
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          horizonCli = inputs.horizon.packages.${system}.default;

          # ================================================================
          # AUTO-PICKUP: declaring a test-VM node IS getting a test (§1).
          #
          # The flake STOPS hand-listing per-node checks. Instead it iterates
          # the Pod-on-a-VmHost set the projection already names
          # (`hostedPodNamesOf` in lib/mkVmTest.nix) and generates ONE check
          # per declared node. Add a guest to the cluster -> it gets a check,
          # with no flake edit. `mkVmTest` itself is UNCHANGED.
          #
          # Each node gets the role-derived STANDARD fallback testScript
          # (lib/standardTest.nix) UNLESS it appears in the `customTests`
          # registry below, which overrides with a bespoke single-concept
          # script (the desktop + home anchors). Capacity / subnet safety
          # comes free — mkVmTest's `assertModel` already fails at eval if the
          # hosted set over-subscribes the host's VmHost ceiling or subnet.
          # ================================================================

          mkVmTest = import ./lib/mkVmTest.nix { inherit inputs pkgs self system; };
          standardTestFor = import ./lib/standardTest.nix { inherit lib; };

          # Read a committed horizon projection — the same fromJSON(readFile)
          # artifact mkVmTest reads, kept honest by projections-match-fieldlab.
          readHorizon =
            node: builtins.fromJSON (builtins.readFile "${self}/fixtures/horizon/${node}.json");

          # The python runNixOSTest driver mangles a node name's dashes to
          # underscores for its machine binding: edge-desktop -> edge_desktop.
          machineNameOf = node: builtins.replaceStrings [ "-" ] [ "_" ] node;

          # The host whose hosted guests are auto-picked-up into checks. atlas
          # is the only declared VmHost today; a second host (prometheus) is a
          # data-only addition that this same iteration would pick up.
          vmHostNode = "atlas";

          hostHorizon = readHorizon vmHostNode;

          # The hosted Pod set the host runs — the exact pickup predicate the
          # generator already encodes. For atlas this is, by declaration alone:
          #   [ base-home dune edge-desktop mercury ]
          hostedNodes = lib.sort lib.lessThan (
            lib.attrNames (
              lib.filterAttrs (
                _: exNode:
                (exNode.machine.superNode or null) == vmHostNode
                && (exNode.machine.species or null) == "Pod"
              ) (hostHorizon.exNodes or { })
            )
          );

          # includeHome resolved the SAME way mkVmTest derives it (a lean
          # TestVm drops home; every other role keeps the production home
          # profile), so the standard test's home layer agrees with the home
          # profile the generator actually builds. A customTests entry may
          # override this knob explicitly.
          includeHomeFor = node: !(readHorizon node).node.behavesAs.testVm or false;

          # ---- the CUSTOM OVERRIDE REGISTRY (§1.3) ------------------------
          # A per-node map of bespoke specs. A node present here uses its
          # custom script (and any extra mkVmTest knob — includeHome,
          # substrate, extraGuestModules); a node absent falls through to the
          # role-derived standard fallback. The two original hand-authored
          # anchors MOVE here verbatim, keeping their rich single-concept
          # assertions (Spirit [xxgp]). This is the single coexistence seam.
          customTests = {
            # The headline COMPLEX-OS anchor. edge-desktop is an Edge Pod; its
            # projection derives behavesAs.edge, so edge/default.nix emits the
            # greetd (regreet) display manager, polkit, dbus, gnome-keyring —
            # the complex desktop OS. The author names none of it. This is a
            # RICHER version of the standard edge fragment (it additionally
            # narrates the keyring PAM + the niri session), kept hand-authored.
            edge-desktop.testScript = ''
              # the desktop support bus comes up
              edge_desktop.wait_for_unit("dbus.service")
              # the display manager is greetd (regreet greeter) — the KEY design
              # point of an Edge profile: a node you log into graphically. greetd
              # reaches its active greeter at boot, and its PAM starts the keyring
              # ("gkr-pam: gnome-keyring-daemon started properly" in the boot log).
              edge_desktop.wait_for_unit("greetd.service")
              # the desktop keyring + the niri graphical session are installed —
              # the Secret portal binds gnome-keyring, the display manager runs
              # niri. Both daemons on PATH prove the desktop stack is composed.
              edge_desktop.succeed("test -x /run/current-system/sw/bin/gnome-keyring-daemon")
              edge_desktop.succeed("test -x /run/current-system/sw/bin/niri")
              # polkit is dbus/socket-activated (not active until first call), so
              # assert it is the system's installed authorization daemon.
              edge_desktop.succeed("systemctl cat polkit.service | grep -q polkitd")
            '';

            # The headline HOME-PROFILE anchor. base-home is a lean TestVm Pod;
            # includeHome = true (the one cluster-decided home flag) ISOLATES
            # the home profile on a minimal system, so the test proves the
            # home-manager activation in isolation, not entangled with a desktop.
            base-home = {
              includeHome = true;
              testScript = ''
                # the per-user home-manager activation generation runs at boot
                base_home.wait_for_unit("home-manager-aria.service")
                base_home.succeed("systemctl is-active home-manager-aria.service")
                # a home PROGRAM landed in the user's config — programs.git from the
                # base (min) home profile writes ~/.config/git/config with the
                # project's pull.rebase + beads.role + the projected user email.
                # Asserting the generated file proves the home profile applied, not
                # just that the activation unit ran. (String values render quoted;
                # booleans bare — git's own ini format.)
                base_home.succeed("test -e /home/aria/.config/git/config")
                base_home.succeed("grep -q 'rebase = true' /home/aria/.config/git/config")
                base_home.succeed("grep -q 'role = \"maintainer\"' /home/aria/.config/git/config")
                base_home.succeed("grep -q 'email = \"aria@fieldlab.criome.net\"' /home/aria/.config/git/config")
              '';
            };
          };

          # Every auto-picked node belongs to the same fieldlab cluster, hosted
          # on the same VmHost host (atlas). cluster/hostNode are fixed; only
          # vmNode + the resolved script/knobs vary per node.
          cluster = "fieldlab";

          # Resolve one node into a complete mkVmTest spec: the custom entry if
          # present, else the standard role-derived fallback. The standard path
          # passes BOTH the derived includeHome and the matching standard
          # testScript, so the home layer never disagrees with the built profile.
          # A customTests entry contributes only its bespoke knobs (testScript,
          # includeHome, substrate, extraGuestModules) on top of the pairing.
          specFor =
            node:
            let
              guestHorizon = readHorizon node;
              homeKept = includeHomeFor node;
              standardSpec = {
                includeHome = homeKept;
                testScript = standardTestFor {
                  machineName = machineNameOf node;
                  nodeName = guestHorizon.node.name;
                  behavesAs = guestHorizon.node.behavesAs;
                  users = guestHorizon.users or { };
                  includeHome = homeKept;
                };
              };
            in
            {
              inherit cluster;
              hostNode = vmHostNode;
              vmNode = node;
            }
            // (customTests.${node} or standardSpec);

          # The auto-generated per-node checks, keyed `vm-<node>`. Declaring a
          # node in the cluster's hosted Pod set yields exactly one of these.
          autoVmChecks = lib.genAttrs (map (n: "vm-${n}") hostedNodes) (
            checkName: mkVmTest (specFor (lib.removePrefix "vm-" checkName))
          );
        in
        {
          projections-match-fieldlab = pkgs.runCommand "projections-match-fieldlab" { } ''
            set -eu
            for node in atlas beacon cedar dune mercury edge-desktop base-home; do
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
        // lib.optionalAttrs (system == "x86_64-linux") (
          # ==================================================================
          # The AUTO-PICKUP suite (§1). One `vm-<node>` check per declared
          # Pod-on-atlas guest, generated above with zero per-node authoring:
          #   vm-base-home    (custom: home-profile anchor)
          #   vm-dune         (standard: Edge fallback — boot+sshd+desktop)
          #   vm-edge-desktop (custom: complex-OS desktop anchor)
          #   vm-mercury      (standard: lean TestVm fallback — boot+sshd)
          # dune is the proof: it had NO check before; declaring it a Pod on
          # atlas now yields a real Edge standard check by declaration alone.
          # ==================================================================
          autoVmChecks
          // {
            # ================================================================
            # C6 — the lojix-deploy SMOKE TEST stays one EXPLICIT call, OUTSIDE
            # the per-node iteration: it is deploy-MACHINERY (the FIXED lojix
            # daemon, <drv>^* fix) under a HERMETIC, REPEATABLE 2-node
            # runNixOSTest — a deployer node deploys the TARGET's projected
            # config into the target node; the target's system profile
            # generation becomes the lojix-deployed closure (a real
            # nixos-system, never the bare .drv). Psyche-scoped to
            # generation-activation (NOT the full BootOnce reboot). See
            # lib/mkDeployTest.nix + lib/deploy-flake.nix. ONE concept,
            # PATTERN comment there (Spirit [xxgp]); the integration risks
            # (offline eval+build, address resolution, ssh-ng/store-copy, silent
            # daemon) are unblocked IN the test (Spirit [dqg3]). It proves a
            # representative node (mercury), not every node, so it is NOT
            # auto-generated.
            # ================================================================
            lojix-deploy-smoke = (import ./lib/mkDeployTest.nix {
              inherit inputs pkgs self system;
            }) {
              cluster = "fieldlab";
              hostNode = "atlas";
              vmNode = "mercury";
            };
          }
        )
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
                inherit constants;
                inputs = inputs // {
                  sops-nix = inputs.criomos.inputs.sops-nix;
                  # Thread CriomOS's own microvm.nix input through so the
                  # microvm host module is imported and the TestVm host
                  # emission (test-vm-host.nix) can declare its KVM guest.
                  # The test cluster does not pin microvm itself; it reuses
                  # CriomOS's locked revision.
                  microvm = inputs.criomos.inputs.microvm;
                  secrets.sopsFiles.routerWifiSaePasswords = ./fixtures/secrets/routerWifiSaePasswords;
                };
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

          # The TestVm guest (mercury) — its own lean, deployable CriomOS
          # toplevel. behavesAs.testVm suppresses the home/doc weight; sshd +
          # operator key + a real /dev/vda Ext4 root remain (it is a real
          # node). Design report 47, surface 4.
          mercury-toplevel = fixtureSystem "mercury" [ ];

          # The host (atlas) that hosts mercury — its toplevel now carries the
          # mercury KVM microVM guest + the additive tap + the guest-IP
          # networking.hosts entry + the non-autostart unit. Design report 47,
          # surface 5.
          atlas-toplevel = fixtureSystem "atlas" [ ];

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
