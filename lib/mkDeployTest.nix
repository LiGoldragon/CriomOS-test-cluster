# mkDeployTest — the C6 lojix-deploy SMOKE TEST generator: the REAL production
# deploy path under a HERMETIC, REPEATABLE 2-node runNixOSTest (design reports
# 50/4 §3.2 "one thin lojix-deploy smoke test", 50/1 decision "scope C6 to the
# proven microvm build->copy->generation-activation path"; live e2e reports
# 48/49). Psyche-scoped to GENERATION-ACTIVATION, NOT the full BootOnce reboot
# (the deferred q35 part).
#
# PATTERN: ONE concept (Spirit [xxgp]) — "lojix builds, copies, and
# generation-activates a full OS into a target node, and the target's system
# profile generation becomes the lojix-deployed closure (a real nixos-system,
# the <drv>^* fix held — never the bare .drv)". This is the SINGLE place the
# real production deploy machinery is exercised under repeatable test; role/
# profile CONTENT is proven by the hermetic mkVmTest suite (C5), the deploy
# MACHINERY here.
#
# THE TWO NODES, BOTH GENERATED FROM CLUSTER DATA:
#   - deployer: runs the FIXED real lojix daemon (lojix main, the <drv>^* fix)
#       as a service with both sockets (ordinary 0660 + owner 0600), configured
#       by the real lojix-write-configuration -> rkyv -> lojix-daemon path
#       (daemons take only a pre-generated rkyv; never source text). meta-lojix + lojix
#       CLIs present. The deploy key authorises root@target; the target's
#       <node>.<cluster>.criome address resolves (networking.hosts) to the
#       target's test-network IP; ssh-ng host-key trust is pre-seeded. The whole
#       immutable CriomOS root flake and its locked input closure are pinned
#       into its store, so the daemon evaluates the same revision through its
#       production GitHub reference entirely offline.
#   - target: the vmNode (mercury) as a REAL CriomOS nixosSystem built from its
#       horizon PROJECTION (the same projections-match-fieldlab pins), plus the
#       test-substrate UEFI guestModule: writable store, require-sigs=false,
#       NSS/nscd/root-shell prebakes, sshd keys-only + the deploy key, EFI so
#       `bootctl`/`switch-to-configuration switch` complete, the horizon-derived
#       address. The target BOOTS a base system; lojix DEPLOYS the target's own
#       projected config INTO it (build_attribute from the projection) — exactly
#       the live e2e shape (report 49: a node boots a base, lojix reconfigures
#       it to its role).
#
# THE DEPLOY + ASSERTION:
#   The deployer submits a BaseHost `SetBootProfile` Deploy of the target's
#   config (build_attribute = the CriomOS root's normal `target` toplevel,
#   which IS the target's materialized projected system — cluster-data-generated,
#   not hand-written). The
#   daemon runs `nix-env --set <closure> && switch-to-configuration boot` on the
#   target: this SETS the system profile generation (the C6 ground truth) and
#   stages the config for the next boot WITHOUT tearing down the running
#   userspace (a `switch` would restart CriomOS's network services, which block
#   on the unreachable network in the hermetic runner). The test then ASSERTS,
#   on the target, that `/nix/var/nix/profiles/system` resolves to the
#   lojix-deployed closure (`nixos-system-<node>-...`) AND that it is a REAL
#   nixos-system directory (has /bin/switch-to-configuration + /init + /activate)
#   — the <drv>^* fix held: a .drv would have no such tree. It also reads the
#   daemon's durable terminal deploy-job record via the ORDINARY `lojix Query
#   (ByNode ...)` CLI (report 46/48 approach: observe the silent daemon's
#   durable state).
#
# THE INTEGRATION RISKS, HEAD-ON (Spirit [dqg3] — unblock the blocker IN the
# test, do not just report "blocked"):
#   1. OFFLINE eval+build: the immutable CriomOS root flake, its locked input
#      closure, and selected mercury closure are present in the deployer store. The
#      daemon's eval/build run with the node's offline Nix config; no network or
#      substituters.
#   2. ADDRESS resolution: networking.hosts maps <node>.<cluster>.criome to the
#      target's test IP on BOTH nodes; the deployer reaches the target by that
#      exact name lojix targets.
#   3. ssh-ng / store copy: the deployer holds the deploy private key (via
#      NIX_SSHOPTS for nix-copy AND programs.ssh.extraConfig for the activation
#      ssh); the target authorises its public half for root; the target's
#      first-boot ssh host key is learned into a writable known_hosts
#      (StrictHostKeyChecking=accept-new). nix copy --to ssh-ng://root@target
#      then works node-to-node, require-sigs off.
#   4. SILENT daemon: the daemon emits no progress, so the test observes the
#      deploy's durable effect — it polls the TARGET's own
#      /nix/var/nix/profiles/system link until it becomes the deployed closure,
#      then reads the daemon's terminal deploy-job record via the ordinary CLI.

{
  inputs,
  pkgs,
  self,
  system,
}:

let
  inherit (inputs.nixpkgs) lib;

  constants = inputs.criomos-lib.lib.constants;

  readHorizon = node: builtins.fromJSON (builtins.readFile "${self}/fixtures/horizon/${node}.json");

  lojixPackages = inputs.lojix.packages.${system};
  # The real fixed daemon (lojix main, <drv>^* fix) and the CLIs
  # (meta-lojix / lojix / lojix-write-configuration, built with their text CLI
  # feature so the test can submit/query typed requests).
  lojixDaemon = lojixPackages.daemon-binary;
  lojixClis = lojixPackages.default;
  horizonCompose = inputs.horizon.packages.${system}.horizon-compose;
  horizonDefinition = inputs.horizon-config.lib.composeHorizonDefinition {
    inherit system horizonCompose;
    configuration = ./../clusters/fieldlab-horizon-configuration.datom;
    cluster = ./../clusters/fieldlab-definition.datom;
  };
  horizonDefinitionPath = inputs.horizon-config.lib.horizonDefinitionPath horizonDefinition;

  # The normal CriomOS root owns all four materialized input names: `horizon`,
  # `system`, `deployment`, and `secrets`. The smoke driver remains a separate
  # test-cluster checkout; it cannot stand in for the RequireImmutable source.
  deployFlakeReference = "github:LiGoldragon/CriomOS?rev=add8a445052e9517a10eff7877ed7608aca871b2";
  deployFlakeSource = inputs.criomos.outPath;
  # This closure came from a real Lojix BuildOnly materialization of the exact
  # definition below, `(fieldlab, mercury)`, BaseHost, NoSecrets, and the same
  # immutable CriomOS source/selector. The VM request regenerates the four
  # inputs and must reach this content-addressed target again.
  deployedToplevel = "/nix/store/rdlmvd1bhax248fzkgxwb5lq04bbivcd-nixos-system-mercury-26.11.20260813.0e251e2";
  deployedToplevelDrv = "/nix/store/mkqzyi7vsicjkxiv40wy4rd1n2dnd2gj-nixos-system-mercury-26.11.20260813.0e251e2.drv";

  # The immutable root flake and every direct input are present in the
  # deployer store before the daemon evaluates the exact GitHub revision.
  # CriomOS itself has nested inputs, so retain its complete input closure too.
  directInputSources = inputs.nixpkgs.lib.concatMap (
    input: inputs.nixpkgs.lib.optional (input ? outPath) input.outPath
  ) (builtins.attrValues (builtins.removeAttrs inputs [ "self" ]));
  inputSources =
    flake:
    let
      nested = flake.inputs or { };
    in
    inputs.nixpkgs.lib.concatMap (
      input:
      inputs.nixpkgs.lib.optional (input ? outPath) input.outPath
      ++ inputs.nixpkgs.lib.optionals (input ? inputs) (inputSources input)
    ) (builtins.attrValues nested);
  criomosInputSources = inputSources inputs.criomos;
  deployFlakeInputSources = inputs.nixpkgs.lib.unique (
    [ deployFlakeSource ] ++ directInputSources ++ criomosInputSources
  );

  # Direct immutable github: roots bypass registries and Nix has no supported
  # cache-import interface. C6 replays only the exact GitHub archive endpoint
  # in a third test VM. The submitted Lojix reference remains github:, and the
  # deployer verifies Nix's resolved source path and narHash before it starts.
  sourceReplayAddress = "192.168.1.3";
  sourceReplayRoute = "/LiGoldragon/CriomOS/archive/add8a445052e9517a10eff7877ed7608aca871b2.tar.gz";
  sourceReplayTls =
    pkgs.runCommand "c6-source-replay-tls"
      {
        nativeBuildInputs = [ pkgs.openssl ];
      }
      ''
          mkdir -p "$out"
          openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$out/key.pem" \
            -out "$out/cert.pem" \
            -days 3650 \
        -subj /CN=github.com \
        -addext subjectAltName=DNS:github.com
      '';
  sourceReplayArchive =
    pkgs.runCommand "c6-source-replay-archive"
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.gzip
        ];
      }
      ''
        mkdir -p "$out/source"
        cp -a ${deployFlakeSource}/. "$out/source/"
        tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
          -C "$out" -cf - source | gzip -n > "$out/archive.tar.gz"
      '';
  sourceReplayServer = pkgs.writeText "c6-source-replay.py" ''
    import http.server
    import os
    import ssl

    ARCHIVE = "${sourceReplayArchive}/archive.tar.gz"
    ROUTE = "${sourceReplayRoute}"

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != ROUTE:
                self.send_error(404, "C6 source replay permits only the pinned archive route")
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/x-gzip")
            self.send_header("Content-Length", str(os.path.getsize(ARCHIVE)))
            self.end_headers()
            with open(ARCHIVE, "rb") as archive:
                self.wfile.write(archive.read())

        def log_message(self, format, *args):
            print("C6 source replay: " + format % args, flush=True)

    server = http.server.ThreadingHTTPServer(("0.0.0.0", 443), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain("/etc/c6-source-replay/cert.pem", "/etc/c6-source-replay/key.pem")
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print("C6 source replay listening on 0.0.0.0:443", flush=True)
    server.serve_forever()
  '';

  # A throwaway deploy keypair, generated reproducibly at build time. Private
  # half lives only on the deployer; public half authorises root on the target.
  # A test-substrate credential (like require-sigs=false), never a real key.
  deployKeyPair = pkgs.runCommand "lojix-deploy-keypair" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir -p "$out"
    ssh-keygen -t ed25519 -N "" -C lojix-c6-deploy -f "$out/deploy_key"
  '';
in
{
  cluster,
  hostNode,
  vmNode,
}:

let
  guestHorizon = readHorizon vmNode;
  guestName = guestHorizon.node.name;
  machine = guestHorizon.node.machine;

  # The host's projection — read for the SAME model assertion mkVmTest makes, so
  # the smoke FAILS if the deploy target stops being a Pod on the declared
  # VmHost (finding 2: hostNode was accepted but never used). The host endpoint
  # is not actually wired in this hermetic deploy (the runner owns the network),
  # but the host->guest cluster relation is the model claim C6 rests on, so it
  # is asserted from data here, not hand-waved.
  hostHorizon = readHorizon hostNode;

  # The host's cluster-authored VmHost service (C1) — services is a list of
  # single-key attrsets, one per NodeService variant.
  hostVmHostService = lib.findFirst (capability: capability.kind == "vmHost") null (
    hostHorizon.node.capabilities or [ ]
  );
  hostDeclaresVmHost = hostVmHostService != null;

  # The target must be a Pod-substrate node whose machine.host names the
  # declared host (the exact "vmNode is a Pod on this VmHost" claim).
  vmNodeIsPod = (machine.kind or null) == "VirtualMachine";
  vmNodeHostedByHost = (machine.host or null) == hostNode;

  clusterName = guestHorizon.cluster or cluster;
  criomeDomainName = guestHorizon.node.criomeDomainName or "${guestName}.${clusterName}.criome";

  # The target's test-network IP. runNixOSTest assigns 192.168.1.<N> per node on
  # vlan 1 (deployer = .1, the vmNode = .2); we ALSO map the criome domain ->
  # this target IP on the deployer so lojix's root@<node>.<cluster>.criome
  # resolves to the target machine. (The projected nodeIp is the cluster's
  # production address; inside the hermetic runner the test network owns the
  # addressing, so the domain is bound to the runner-assigned IP here.)
  targetTestIp = "192.168.1.2";

  deployPublicKey = builtins.readFile "${deployKeyPair}/deploy_key.pub";

  sourceReplayModule =
    { pkgs, ... }:
    {
      environment.etc."c6-source-replay/cert.pem".source = "${sourceReplayTls}/cert.pem";
      environment.etc."c6-source-replay/key.pem" = {
        source = "${sourceReplayTls}/key.pem";
        mode = "0400";
      };
      networking.firewall.allowedTCPPorts = [ 443 ];
      systemd.services.c6-source-replay = {
        description = "C6 exact immutable GitHub archive replay";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        path = [ pkgs.python3 ];
        serviceConfig = {
          Type = "simple";
          Restart = "no";
        };
        script = ''
          exec ${pkgs.python3}/bin/python ${sourceReplayServer}
        '';
      };
      system.stateVersion = lib.mkDefault "26.05";
    };

  # The UEFI test-substrate (C3) — writable store, require-sigs off, NSS / root
  # shell prebakes, sshd keys-only + the deploy key, EFI label alignment. The
  # daemon's Boot activation runs `nix-env --set` (sets the generation — the C6
  # ground truth) then `switch-to-configuration boot` (no-op bootloader install
  # on this throwaway target) + a no-op `bootctl` EFI reconcile, all GREEN.
  substrateProfile = import "${inputs.criomos}/modules/nixos/test-substrate.nix" {
    substrate = "uefi";
    deployKey = deployPublicKey;
  };

  # The target guest: a real CriomOS nixosSystem from the projection + the UEFI
  # substrate. This is the BASE the target boots; lojix deploys the (identical-
  # base, freshly-built) projected system into it and flips the generation.
  targetModule =
    { lib, ... }:
    {
      imports = [
        inputs.criomos.nixosModules.criomos
        inputs.criomos.inputs.sops-nix.nixosModules.sops
        substrateProfile.guestModule
      ];

      # size from the projected machine facts.
      virtualisation = {
        cores = machine.hardware.cores;
        memorySize = machine.hardware.ramGib * 1024;
        diskSize = machine.diskGib * 1024;
        # A real writable disk + EFI so the deployed generation activates and
        # bootctl can run. runNixOSTest gives a writable store for free; the
        # UEFI vars make `bootctl` operate (report 49 substrate, inside the
        # hermetic runner where the lean guest boots clean — C4 finding).
        useEFIBoot = true;
      };

      # The target answers to its own criome domain (lojix targets
      # root@<node>.<cluster>.criome). networking.hosts maps it locally; the
      # deployer maps it to this node's test IP.
      networking.hosts = lib.mkForce {
        "127.0.0.1" = [ "localhost" ];
        "${targetTestIp}" = [
          criomeDomainName
          guestName
        ];
      };

      # GENERATION-ACTIVATION SCOPE: the daemon's `Switch` reconciles EFI after
      # switch-to-configuration (`bootctl set-default`/`set-oneshot ''`). On a
      # runNixOSTest direct-boot guest there are no systemd-boot loader entries,
      # so real `bootctl set-default <entry>` fails. C6 asserts the generation
      # is SET (nix-env --set), not the bootloader default, so a no-op `bootctl`
      # shim (winning root's PATH via /etc/profiles wrappers) lets the EFI
      # reconcile complete without a real loader write — a throwaway-target
      # substrate property, like the no-op installBootLoader on the deployed
      # system. Does not touch the daemon or the deploy command.
      environment.systemPackages = lib.mkAfter [
        (pkgs.writeShellScriptBin "bootctl" ''
          # no-op shim: the test target direct-boots and has no systemd-boot
          # entries; report success for set-default/set-oneshot/status so the
          # daemon's EFI reconcile completes (generation-activation scope).
          case "''${1:-}" in
            status) echo "Current Entry: nixos-c6-test.conf" ;;
            *) : ;;
          esac
          exit 0
        '')
      ];

      system.stateVersion = lib.mkDefault "26.05";
    };

  # The deployer node: the real fixed lojix daemon + CLIs, the deploy key, the
  # target address, ssh-ng trust, and the OFFLINE deploy closure pinned in.
  deployerModule =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      # The whole offline deploy closure pinned into the deployer's store so the
      # daemon's `nix eval`/`nix build` resolve with NO network: the exact
      # immutable root flake source, the realised mercury system (so `nix build
      # <drv>^*` is a store hit), and every locked input source are present.
      system.extraDependencies = [
        deployedToplevel
        horizonDefinitionPath
      ]
      ++ deployFlakeInputSources;

      # The real CLIs (meta-lojix / lojix / lojix-write-configuration) +
      # nix/openssh for the daemon's effects.
      environment.systemPackages = [
        lojixClis
        pkgs.openssh
        pkgs.nix
      ];

      # Nix remains offline from the outside world and trusts unsigned local
      # closures. The fixture maps only github.com to the source-replay VM
      # and pins that synthetic endpoint with its test CA. Lojix still receives
      # the immutable production github: URI; neither registry nor path
      # substitution is involved.
      nix.settings = {
        substituters = lib.mkForce [ ];
        require-sigs = lib.mkForce false;
        builders = lib.mkForce "";
        tarball-ttl = 999999999;
        use-registries = false;
        flake-registry = "";
        ssl-cert-file = "${sourceReplayTls}/cert.pem";
        experimental-features = [
          "nix-command"
          "flakes"
        ];
      };

      # The deploy private key on disk for the daemon's ssh / nix-copy.
      environment.etc."lojix-c6/deploy_key" = {
        source = "${deployKeyPair}/deploy_key";
        mode = "0600";
      };

      # The daemon's ACTIVATION step is a plain `ssh -o BatchMode=yes
      # root@<target> …` (lojix-cli SystemActivation), NOT a nix-copy — so it
      # does not read NIX_SSHOPTS. programs.ssh.extraConfig prepends a Host block
      # to the system /etc/ssh/ssh_config (which NixOS does NOT auto-include
      # ssh_config.d into, so extraConfig is the right knob) giving that bare ssh
      # the deploy key + a writable known_hosts + accept-new, so the activation
      # ssh authenticates and trusts the target's first-boot host key exactly
      # like the copy path.
      programs.ssh.extraConfig = ''
        Host ${criomeDomainName} ${guestName} ${targetTestIp}
          User root
          IdentityFile /etc/lojix-c6/deploy_key
          UserKnownHostsFile /root/.ssh/known_hosts
          StrictHostKeyChecking accept-new
          BatchMode yes
      '';

      # Resolve the target's criome domain to its test IP (lojix targets it by
      # this exact name) and pin the target's ssh host key so BatchMode ssh /
      # ssh-ng do not prompt.
      networking.hosts = lib.mkForce {
        "127.0.0.1" = [ "localhost" ];
        "${targetTestIp}" = [
          criomeDomainName
          guestName
        ];
        "${sourceReplayAddress}" = [ "github.com" ];
      };

      # The lojix daemon as a service, configured the REAL way:
      # lojix-write-configuration encodes a typed text config into the rkyv
      # startup the daemon consumes (daemons take only rkyv, never source text). Both
      # sockets at the production modes (ordinary 0660, owner 0600).
      systemd.services.lojix-daemon = {
        description = "lojix deploy daemon (C6 smoke)";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        path = [
          pkgs.nix
          pkgs.openssh
          pkgs.coreutils
          pkgs.curl
        ];
        environment = {
          # ssh-ng / nix-copy uses the deploy key + learns the target host key
          # on first contact (accept-new) into a WRITABLE known_hosts under the
          # daemon's runtime dir. Fully offline.
          NIX_SSHOPTS = "-i /etc/lojix-c6/deploy_key -o UserKnownHostsFile=/run/lojix/known_hosts -o StrictHostKeyChecking=accept-new -o BatchMode=yes";
          GIT_SSH_COMMAND = "ssh -i /etc/lojix-c6/deploy_key -o UserKnownHostsFile=/run/lojix/known_hosts -o StrictHostKeyChecking=accept-new -o BatchMode=yes";
        };
        serviceConfig = {
          Type = "simple";
          Restart = "no";
          TimeoutStartSec = "120s";
          StateDirectory = "lojix";
          RuntimeDirectory = "lojix";
        };
        script = ''
          set -eu
          touch /run/lojix/known_hosts
          # /root/.ssh for the activation ssh's learned host key (the ssh_config
          # points UserKnownHostsFile here).
          install -d -m 700 /root/.ssh
          touch /root/.ssh/known_hosts
          # Fetch the direct-GitHub root through the fixture-only TLS replay
          # before starting the daemon. A top-level github: URI carries no
          # narHash, so require Nix's resolved metadata to match the exact
          # lock-derived path, hash, and revision. Lojix then evaluates the
          # unchanged URI under the same Nix configuration.
          export XDG_CACHE_HOME=/var/lib/lojix/.cache
          mkdir -p "$XDG_CACHE_HOME"
          for _ in $(seq 1 30); do
            if ${pkgs.curl}/bin/curl --fail --silent --show-error \
              --cacert "${sourceReplayTls}/cert.pem" \
              "https://github.com${sourceReplayRoute}" \
              --output /run/lojix/root-flake-archive.tar.gz; then
              break
            fi
            sleep 1
          done
          test -s /run/lojix/root-flake-archive.tar.gz
          if ${pkgs.curl}/bin/curl --fail --silent --show-error \
            --cacert "${sourceReplayTls}/cert.pem" \
            https://github.com/c6-source-replay-unmatched \
            --output /run/lojix/unmatched-response; then
            echo "C6 source replay served an unmatched route" >&2
            exit 1
          fi
          metadata=/run/lojix/root-flake-metadata.json
          for _ in $(seq 1 30); do
            if nix flake metadata --refresh --json "${deployFlakeReference}" > "$metadata"; then
              break
            fi
            sleep 1
          done
          test -s "$metadata"
          ${pkgs.jq}/bin/jq -e \
            --arg source "${deployFlakeSource}" \
            --arg nar_hash "sha256-TOnQ7iBNIdVHDodwhybwyCDhSPoZwdOd8s5pLxtbh0E=" \
            --arg revision "add8a445052e9517a10eff7877ed7608aca871b2" \
            '.path == $source and .locked.narHash == $nar_hash and .revision == $revision' \
            "$metadata" >/dev/null
          ${lojixClis}/bin/lojix-write-configuration \
            "ConfigurationWriteRequest.{ /run/lojix/ordinary.sock 432 /run/lojix/owner.sock 384 /var/lib/lojix /var/lib/lojix/lojix-store.db deployer NoTestDefaults /run/lojix/startup.rkyv }"
          exec ${lojixDaemon}/bin/lojix-daemon /run/lojix/startup.rkyv
        '';
      };

      system.stateVersion = lib.mkDefault "26.05";
    };

  # The C6 model invariant, asserted from cluster data (finding 2): the deploy
  # target is a Pod on the DECLARED VmHost host. A violation is a cluster-
  # authoring error — surfaced loudly at eval, not as a confusing mid-deploy
  # failure. This mirrors mkVmTest's assertModel and makes hostNode load-bearing
  # rather than an ignored argument: the smoke fails if the target stops being a
  # Pod on this VmHost.
  assertModel =
    value:
    assert lib.assertMsg hostDeclaresVmHost
      "mkDeployTest: hostNode ${hostNode} declares no VmHost service in its projection; it cannot host the deploy target ${vmNode}.";
    assert lib.assertMsg vmNodeIsPod
      "mkDeployTest: vmNode ${vmNode} is not a Pod-substrate node (machine.kind != VirtualMachine in its projection); only a Pod node runs as a VM on a host.";
    assert lib.assertMsg vmNodeHostedByHost
      "mkDeployTest: vmNode ${vmNode} machine.host is ${
        toString (machine.host or null)
      }, not the declared hostNode ${hostNode}; the target is not hosted on this VmHost.";
    value;
in

assertModel (
  inputs.nixpkgs.legacyPackages.${system}.testers.runNixOSTest {
    name = "lojix-deploy-smoke-${cluster}-${vmNode}";

    # Both nodes carry the projected horizon as a specialArg exactly as production
    # nixosSystem receives it; the target IS a real CriomOS node from its
    # projection (never a hand-stub).
    node.specialArgs = {
      inherit constants;
      horizon = guestHorizon;
      inputs = inputs // {
        sops-nix = inputs.criomos.inputs.sops-nix;
        microvm = inputs.criomos.inputs.microvm;
        secrets.sopsFiles.routerWifiSaePasswords = "${self}/fixtures/secrets/routerWifiSaePasswords";
      };
      deployment = {
        includeHome = false;
        includeComplex = false;
      };
    };

    nodes.deployer = deployerModule;
    nodes.source-replay = sourceReplayModule;
    nodes.${vmNode} = targetModule;

    # The test reads like prose: ONE concept — lojix deploys a full OS and the
    # target's generation becomes the deployed closure.
    testScript = ''
      start_all()

      # --- the deployer's fixed daemon comes up with both sockets ---------------
      # `Type=simple` becomes active while its pre-daemon setup still runs.
      # Surface that setup's journal early if configuration writing or the
      # hermetic flake cache preparation fails; the actual socket assertions
      # below remain the service-readiness boundary.
      for _ in range(120):
          if deployer.execute("test -S /run/lojix/ordinary.sock && test -S /run/lojix/owner.sock")[0] == 0:
              break
          if deployer.execute("systemctl --quiet is-failed lojix-daemon.service")[0] == 0:
              break
          deployer.sleep(1)
      else:
          journal = deployer.execute("journalctl -u lojix-daemon.service --no-pager")[1]
          print("=== lojix daemon startup journal ===")
          print(journal)
          raise AssertionError("lojix daemon did not create both sockets within 120 seconds")
      if deployer.execute("systemctl --quiet is-failed lojix-daemon.service")[0] == 0:
          journal = deployer.execute("journalctl -u lojix-daemon.service --no-pager")[1]
          print("=== failed lojix daemon startup journal ===")
          print(journal)
          raise AssertionError("lojix daemon service failed before its sockets were ready")
      deployer.succeed("systemctl is-active --quiet lojix-daemon.service")
      deployer.wait_for_file("/run/lojix/ordinary.sock", timeout=30)
      deployer.wait_for_file("/run/lojix/owner.sock", timeout=30)
      # both sockets at the production modes (ordinary 0660, owner 0600) — the
      # real lojix-write-configuration -> rkyv -> daemon path set them.
      deployer.succeed("test \"$(stat -c %a /run/lojix/ordinary.sock)\" = 660")
      deployer.succeed("test \"$(stat -c %a /run/lojix/owner.sock)\" = 600")

      # --- the target boots as a real CriomOS node, sshd up --------------------
      ${vmNode}.wait_for_unit("sshd.service")
      # the deployer can reach root@<node>.<cluster>.criome by that exact name
      # (networking.hosts) with the deploy key (ssh-ng host-key trust pre-seeded).
      deployer.succeed(
          "timeout 30s ssh -n -i /etc/lojix-c6/deploy_key "
          "-o UserKnownHostsFile=/run/lojix/known_hosts "
          "-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 "
          "root@${criomeDomainName} true"
      )

      # baseline generation the target booted (the deploy must ADVANCE it).
      base_system = ${vmNode}.succeed("readlink -f /run/current-system").strip()

      # --- submit the REAL production deploy over the OWNER socket -------------
      # BaseHost SetBootProfile of the TARGET's own materialized config; the
      # normal CriomOS root's `target` output is selected directly. The daemon
      # mints the deployment id and runs the pipeline autonomously (build ->
      # copy -> activate); the client returns immediately.
      # `SetBootProfile` runs `nix-env --set <closure> &&
      # switch-to-configuration BOOT`. `boot` sets the system profile generation
      # (the C6 ground truth) and stages the new config for the NEXT boot WITHOUT
      # restarting the running system's services — so it does not disrupt the
      # live network/sshd of the running target mid-activation (which a `switch`
      # would, on a network-service-heavy CriomOS node in a hermetic VM where
      # tailscale/yggdrasil block on the unreachable network). Generation-
      # activation scope: the profile becomes the deployed closure; the running
      # userspace is not torn down.
      deploy_reply = deployer.succeed(
          "LOJIX_OWNER_SOCKET=/run/lojix/owner.sock "
          "${lojixClis}/bin/meta-lojix "
          "'Deploy.Host.{ ${clusterName} ${vmNode} BaseHost ${horizonDefinitionPath} "
          "NoSecrets ${deployFlakeReference} { ssh-ng://root@${criomeDomainName} root@${criomeDomainName} } "
          "Horizon { nixosConfigurations.target.config.system.build.toplevel } NixosSystemdBootV1 SetBootProfile RequireImmutable None [] }'"
      )
      print("deploy reply:", deploy_reply)
      assert "DeployAccepted" in deploy_reply, f"deploy not accepted: {deploy_reply}"

      # read the daemon's durable deploy state via the ORDINARY CLI (Query ByNode)
      # — used for observability of the silent deploy (the generation-activation
      # ground truth is asserted on the target itself).
      def query_node():
          return deployer.succeed(
              "LOJIX_ORDINARY_SOCKET=/run/lojix/ordinary.sock "
              "${lojixClis}/bin/lojix "
              "'Query.ByNode.{ ${clusterName} ${vmNode} None }'"
          )

      # The exact closure the daemon evaluates/builds from the normal immutable
      # CriomOS root under the real four Lojix-generated input directories.
      # This is the activated-generation ground truth.
      expected_closure = "${deployedToplevel}"
      expected_derivation = "${deployedToplevelDrv}"
      print("expected deployed closure:", expected_closure)
      # the <drv>^* fix: the expected artifact is a realised nixos-system dir,
      # NEVER a bare .drv.
      assert not expected_closure.endswith(".drv"), expected_closure
      assert "nixos-system-${vmNode}" in expected_closure, expected_closure
      assert expected_derivation.endswith(".drv"), expected_derivation

      # The daemon is SILENT during the deploy (no logs); it owns the
      # build->copy->activate pipeline after AcceptedDeploy. The ground truth of
      # the microvm-scoped GENERATION-ACTIVATION is the TARGET's own system profile
      # link — poll it directly until it becomes the deployed closure (the daemon's
      # `nix-env --set` on the target). This is the report-46/48 approach: observe
      # the deploy's durable effect rather than the silent daemon.
      ${vmNode}.wait_until_succeeds(
          f"test \"$(readlink -f /nix/var/nix/profiles/system)\" = {expected_closure}",
          timeout=600,
      )

      # --- ASSERT: the target's system profile generation IS the lojix-deployed
      # closure (the microvm-scoped generation-activation: /nix/var/nix/profiles/
      # system -> the deployed nixos-system) ------------------------------------
      profile_target = ${vmNode}.succeed("readlink -f /nix/var/nix/profiles/system").strip()
      assert profile_target == expected_closure, (
          f"system profile {profile_target} is not the deployed closure {expected_closure}"
      )
      # it ADVANCED past the booted base (a real deploy, not a no-op).
      assert profile_target != base_system, "generation did not advance past the base"

      # --- ASSERT: the daemon's DURABLE deploy-job record corroborates (Spirit
      # [vcin]: a print is not proof — assert the real durable record) -----------
      # The ordinary `(Query (ByNode ...))` reply renders the schema-owned
      # GenerationListing:
      #   (Queried ([ (Generation <genId> <depId> <cluster> <node>
      #                <kind> <activationKind> <slot> <closurePath>) ... ]
      #             (DatabaseMarker <seq> <digest>)))
      # The daemon is silent and the live-set write commits after the target's
      # profile flip, so poll the durable Query until the node's record carries the
      # deployed closure, then assert the three load-bearing facts: the node name,
      # the generated artifact, the activation effect, and the deployed ClosurePath
      # (the SAME closure the profile assertion checked). The durable generation for
      # this deploy is `(<gen> <dep> ${cluster} ${vmNode} BaseHost BootProfile Current
      # <closure>)` —
      # the live generation lands in the `Current` slot (the terminal deployed
      # state the query exposes), so `Current` is the durable state this proves.
      expected_slot = "Current"
      deployer.wait_until_succeeds(
          "LOJIX_ORDINARY_SOCKET=/run/lojix/ordinary.sock "
          "${lojixClis}/bin/lojix 'Query.ByNode.{{ ${clusterName} ${vmNode} None }}' "
          f"| grep -F {expected_closure}",
          timeout=600,
      )
      deployer.wait_until_succeeds(
          "LOJIX_ORDINARY_SOCKET=/run/lojix/ordinary.sock "
          "${lojixClis}/bin/lojix 'Query.ByNode.{{ ${clusterName} ${vmNode} None }}' "
          "| grep -F Completed",
          timeout=600,
      )
      deployer.wait_until_succeeds(
          "LOJIX_ORDINARY_SOCKET=/run/lojix/ordinary.sock "
          "${lojixClis}/bin/lojix 'Query.ByNode.{{ ${clusterName} ${vmNode} None }}' "
          "| grep -F Succeeded",
          timeout=600,
      )
      final_query = query_node()
      print("durable deploy state:", final_query)
      assert "Queried" in final_query, f"ordinary query was not accepted: {final_query}"
      # Assert the schema-owned positional Generation fragment — node + kind +
      # activationKind + terminal slot together (`${vmNode} BaseHost BootProfile Current`),
      # not a loose lone-`Current` substring that could match elsewhere. This ties
      # the deployed node to its terminal generation slot in one schema shape.
      node_generation = "${vmNode} BaseHost BootProfile " + expected_slot
      assert node_generation in final_query, (
          f"durable Query reply does not record {node_generation!r}: {final_query}"
      )
      # and the deployed ClosurePath in that same record equals the SAME closure
      # the profile assertion verified — durable record and on-target generation
      # agree.
      assert expected_closure in final_query, (
          f"durable Query reply does not record the deployed closure {expected_closure}: {final_query}"
      )
      assert "Completed" in final_query, (
          f"durable Query reply does not record a completed deployment: {final_query}"
      )
      assert "Succeeded" in final_query, (
          f"durable Query reply does not record a terminal Succeeded deployment: {final_query}"
      )

      # --- ASSERT: the activated artifact is a REAL nixos-system (the <drv>^* fix
      # held) — a .drv would have NONE of this tree -----------------------------
      ${vmNode}.succeed(f"test -d {expected_closure}")
      ${vmNode}.succeed(f"test -x {expected_closure}/bin/switch-to-configuration")
      ${vmNode}.succeed(f"test -e {expected_closure}/init")
      ${vmNode}.succeed(f"test -e {expected_closure}/activate")
      # it is genuinely the deployed closure in the target's store (the daemon's
      # nix copy --to ssh-ng landed it there node-to-node).
      ${vmNode}.succeed(f"test \"$(nix-store --query --deriver {expected_closure})\" = {expected_derivation}")

      print("C6 GREEN: lojix build->copy->generation-activated a real nixos-system into ${vmNode}; "
            "the target's system profile generation is the deployed closure.")
    '';
  }
)
