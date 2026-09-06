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
  deployFlakeReference = "github:LiGoldragon/CriomOS?rev=82f6bf5958f999c97c4d81f985d4ac91bdbc2340";
  deployFlakeSource = inputs.criomos.outPath;
  # This closure came from a real Lojix BuildOnly materialization of the exact
  # definition below, `(fieldlab, mercury)`, BaseHost, NoSecrets, and the same
  # immutable CriomOS source/selector. The VM request regenerates the four
  # inputs and must reach this content-addressed target again.
  deployedToplevel = "/nix/store/mmx94nvp9mmrnf6khg12xr49vd8kdnvr-nixos-system-mercury-26.11.20260813.0e251e2";
  deployedToplevelDrv = "/nix/store/izzd90gl2vcaym5lpr1cpqsmgkv8vk3y-nixos-system-mercury-26.11.20260813.0e251e2.drv";

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

  # Direct immutable github: roots bypass registries, and Nix has no supported
  # fetcher-cache import interface. C6 therefore replays only the finite GitHub
  # code-source set observed in a cache-disabled evaluation of the exact
  # materialized Mercury output, plus its realised selected closure. Each entry
  # below has a locked revision/NAR hash/lastModified timestamp and is archived deterministically from
  # that exact fetched source. No secret or data authority is included: this is
  # a NoSecrets fixture and unmatched routes are rejected.
  sourceReplayAddress = "192.168.1.3";
  sourceReplaySpecs = [
    { owner = "LiGoldragon"; repo = "CriomOS"; revision = "82f6bf5958f999c97c4d81f985d4ac91bdbc2340"; narHash = "sha256-5oLG5SeumySnnOC/+cIu1tpoR9OXh/L4csoXZv3aJ9Y="; lastModified = 1788669988; }
    { owner = "LiGoldragon"; repo = "CriomOS-home"; revision = "e71729ec6ebccce9d853227aea549712344a743c"; narHash = "sha256-Kq0V2L6CvXArCTOZdOYf7IvRd6BDxqemkYpAaTGuqSM="; lastModified = 1788669393; }
    { owner = "LiGoldragon"; repo = "CriomOS-lib"; revision = "6e3bcb0808b722c881d9c9b19d684b56b9d65642"; narHash = "sha256-Ye+gpUx/WQXEFufn4Mlnvby+OyFEOEm2uiyRwi39rI0="; lastModified = 1786574672; }
    { owner = "LiGoldragon"; repo = "CriomOS-pkgs"; revision = "c64ea0eddea6974c968431f3cebb49a1fef9e56d"; narHash = "sha256-EeGMjHDQguP9YynaRQUaLzbf9eoFPBffVOFBI6VZM/Q="; lastModified = 1786664856; }
    { owner = "LiGoldragon"; repo = "brightness-ctl"; revision = "5274f9937a8b73bd4b1d5fd9a2a0e7199ad574a3"; narHash = "sha256-isNm6Hl/rDwIUHYPtBFbqdVwO2itK2oTzq//uofKW/I="; lastModified = 1786574687; }
    { owner = "LiGoldragon"; repo = "clavifaber"; revision = "d0488014bf931a4690cc2f64a0b41c1df3435cab"; narHash = "sha256-WH9l+01piMkotUeYSGVkzQ5zmzCpLpwTvHrgTnu2dj4="; lastModified = 1786576199; }
    { owner = "LiGoldragon"; repo = "kameo"; revision = "f491b45d7dcb55e5837eddde3d5d7ca8ceaa9f01"; narHash = "sha256-yEide3elYr0mtRUStsD3AlOwdl/sKWtslj3vBp8VzVE="; lastModified = 1781859599; }
    { owner = "LiGoldragon"; repo = "nixpkgs"; revision = "0e251e24a4f24e036a084b6b4b2d2491af4167f4"; narHash = "sha256-yNJd40f11EzXBjSByCB7IPpeFFAdeoSKKM67dGkfFoU="; lastModified = 1786599213; }
    { owner = "LiGoldragon"; repo = "pi-session-namer"; revision = "76a145939d8fc52bda07117e7c04ad66f84f2114"; narHash = "sha256-kS5nnRQA9hSOH3K7yaDPBK+RGfk/FSWpH0QtgJHgQG0="; lastModified = 1786574795; }
    { owner = "LiGoldragon"; repo = "rust-build"; revision = "1bcdafd4590952f73fada56b0507c64192fd6327"; narHash = "sha256-Xz52U4d6S6Z4QeAqW82HSfnEkOXfd94LIBPSVN0WK/0="; lastModified = 1786574812; }
    { owner = "Mic92"; repo = "sops-nix"; revision = "a8627b21b9107c5711c96b84f32a9a4b3d45295f"; narHash = "sha256-gkig4nPi1CWc4Z50GBsjE4ygSE7hMpl/TwID2an2Cck="; lastModified = 1786629091; }
    { owner = "astro"; repo = "microvm.nix"; revision = "71beea0076cd46dafcee97a5a2e7d00cbba5bd2f"; narHash = "sha256-4UFJOVGpaYtHW5yasSv80MaJxTBYdk2zyf3jhKtt0wA="; lastModified = 1786300091; }
    { owner = "dataforxyz"; repo = "agent-intercom-claude"; revision = "d62b3c85547b8b83fdfe06afb38968646fe813b8"; narHash = "sha256-9vi8GnsEVf34p4NvUE6CBRPvqxic41qaeWWbft/el7o="; lastModified = 1786398522; }
    { owner = "dataforxyz"; repo = "agent-intercom-codex"; revision = "ea1c5b538c95b89af3fd36344396779e2eadbadb"; narHash = "sha256-QguRN26/i5Stua+K6wiYAt6pH+wX6jO684Va5VHRUmA="; lastModified = 1785440157; }
    { owner = "dataforxyz"; repo = "agent-intercom-core"; revision = "8316cbab548f422ad11c78ed887fabeef94817c1"; narHash = "sha256-9418pR0tYDGPbf8GknIxAUyDfIN2RdfE3lBwelamLbA="; lastModified = 1785291110; }
    { owner = "dataforxyz"; repo = "agent-intercom-opencode"; revision = "9d81100ea074f68f6466656c65536504209eb060"; narHash = "sha256-jVVIJqJ5O9IuA8K6eU8oCRfBtV68NV47vTHesSktp0s="; lastModified = 1785441928; }
    { owner = "dataforxyz"; repo = "agent-intercom-orchestrator"; revision = "a7e16bd4386726002ab6880b35ebacdeef00fd0d"; narHash = "sha256-nmaAkcUcZ8RVZn1qJK37kEKVBs2w49s72pMXU7wi0SM="; lastModified = 1786638697; }
    { owner = "dataforxyz"; repo = "agent-intercom-pi"; revision = "b6f8f9d08c8c5ec7141a0258ce61cda59d327a20"; narHash = "sha256-b1pif2LgGmcPJFkNKEu0ppjjdllEHLb6oa+6fLA/y/o="; lastModified = 1786488836; }
    { owner = "earendil-works"; repo = "pi"; revision = "53fa77ccd8a279eb87e92294ef3687b03ff80112"; narHash = "sha256-lg+I4S/aAjazjhGZU567ow+rksoNiqOqjHl//TjAMes="; lastModified = 1786081693; }
    { owner = "googleworkspace"; repo = "cli"; revision = "a3768d0e82ad83cca2da97724e46bea4ff0e6dbd"; narHash = "sha256-YyNIHbyZrLlXYtWxZY8Um19MsnLharmS+nWGWO89fsA="; lastModified = 1774983075; }
    { owner = "ipetkov"; repo = "crane"; revision = "2c71e194474d13de031d729b729c968ddbe3507f"; narHash = "sha256-MPaRdVkf6zZP5fCPxYCi8Dr4pZzgmXzg8T9nVEbp3Mw="; lastModified = 1785782307; }
    { owner = "ipetkov"; repo = "crane"; revision = "59a82a1222dd3b2080b5cc52a1a2e8d5f1b77f37"; narHash = "sha256-D+BsdpxmtUwtqGoY0IXPhHgTlmqgcZKCEo1oMyn7ep0="; lastModified = 1780532242; }
    { owner = "nix-community"; repo = "fenix"; revision = "6914a98b7864cb3ef33cb0a2581f8aed3d354e48"; narHash = "sha256-B3GatmIZGQCnJkYoes3a5OqsMNexf0PO3fpeDJDZND4="; lastModified = 1781901863; }
    { owner = "nix-community"; repo = "home-manager"; revision = "c554d3441f725537854e877519f01cbd60680174"; narHash = "sha256-ybGtuwGKTUCefKYsplzvw4xcCqznto0c7BaiQhgILtA="; lastModified = 1786656209; }
    { owner = "nix-community"; repo = "nix-vscode-extensions"; revision = "5ae7b47dd1d2210a1bc62cd75a7407f0794d7193"; narHash = "sha256-pf5m6/fmbeo8NMcsRcWi+vpeye9xcuuRa/H2+HHJLU8="; lastModified = 1786588309; }
    { owner = "nix-systems"; repo = "default"; revision = "da67096a3b9bf56a91d16901293e51ba5b49a27e"; narHash = "sha256-Vy1rq5AaRuLzOxct8nz4T6wlgyUR7zLU309k9mBC768="; lastModified = 1681028828; }
    { owner = "numtide"; repo = "blueprint"; revision = "56131e8628f173d24a27f6d27c0215eff57e40dd"; narHash = "sha256-Dt9t1TGRmJFc0xVYhttNBD6QsAgHOHCArqGa0AyjrJY="; lastModified = 1776249299; }
    { owner = "numtide"; repo = "flake-utils"; revision = "11707dc2f618dd54ca8739b309ec4fc024de578b"; narHash = "sha256-l0KFg5HjrsfsO/JpG+r7fRrqm12kzFHyUHqHCVpMMbI="; lastModified = 1731533236; }
    { owner = "oxalica"; repo = "rust-overlay"; revision = "892c035d7c2ff75acd5da10424a47ab454e1f3dc"; narHash = "sha256-KJhq0HYg2gIZjpsj47z1kWrjoUUAqSqdD2mMWAsOg4k="; lastModified = 1786638241; }
  ];
  sourceReplayEntries = lib.genList (
    index:
    let
      spec = builtins.elemAt sourceReplaySpecs index;
    in
    spec
    // {
      inherit index;
      route = "/${spec.owner}/${spec.repo}/archive/${spec.revision}.tar.gz";
      source = (builtins.fetchTree {
        type = "github";
        owner = spec.owner;
        repo = spec.repo;
        rev = spec.revision;
        narHash = spec.narHash;
      }).outPath;
    }
  ) (builtins.length sourceReplaySpecs);
  kameoReplayEntry = lib.findFirst (
    entry: entry.owner == "LiGoldragon" && entry.repo == "kameo"
  ) (throw "C6 needs the locked Kameo source replay entry") sourceReplayEntries;
  # Clavifaber's Cargo.lock names this exact Git commit. `fetchTree` proves
  # its source content, while Crane's `builtins.fetchGit` needs the complete
  # reachable Git graph, not a shallow source checkout. This committed bundle
  # contains precisely f491 and its 417 ancestors under one `main` ref. To
  # regenerate, import f491 as `refs/heads/main` into a temporary bare repo,
  # create a bundle from that one ref, then update this hash/count/tree only
  # after repeating the locked-NAR and smart-HTTP probes below.
  kameoGitBundle = ./../fixtures/kameo-f491.bundle;
  kameoGitBundleSha256 = "328b6919e2e62459e08feea4f93c5839e579ae2e405e4058f1edff970b3a0d79";
  sourceReplayGit = pkgs.runCommand "c6-kameo-f491-git-replay"
    {
      nativeBuildInputs = [
        pkgs.coreutils
        pkgs.gitMinimal
      ];
    }
    ''
      repository="$out/LiGoldragon/kameo.git"
      test "$(sha256sum ${kameoGitBundle} | cut -d ' ' -f1)" = ${kameoGitBundleSha256}
      mkdir -p "$out/LiGoldragon"
      export GIT_CONFIG_GLOBAL=/dev/null
      git clone --bare ${kameoGitBundle} "$repository"
      actual_commit="$(git -C "$repository" rev-parse refs/heads/main)"
      test "$actual_commit" = f491b45d7dcb55e5837eddde3d5d7ca8ceaa9f01
      actual_tree="$(git -C "$repository" rev-parse "$actual_commit^{tree}")"
      test "$actual_tree" = 4cacb33f3d5731e0345958802a746e1fde82c943
      test "$(git -C "$repository" rev-list --count "$actual_commit")" = 417
      test "$(git -C "$repository" show-ref | wc -l)" = 1
      test ! -e "$repository/shallow"
      cat > "$out/manifest" <<EOF
      bundleSha256=${kameoGitBundleSha256}
      narHash=${kameoReplayEntry.narHash}
      tree=$actual_tree
      revision=$actual_commit
      ref=refs/heads/main
      EOF
    '';
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
  sourceReplayArchives =
    pkgs.runCommand "c6-source-replay-archives"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.gnutar
          pkgs.gzip
        ];
      }
      ''
        mkdir -p "$out/archives"
        : > "$out/manifest.tsv"
        ${lib.concatMapStringsSep "\n" (
          entry: ''
            work="$TMPDIR/source-${toString entry.index}"
            mkdir -p "$work/source"
            cp -a ${entry.source}/. "$work/source/"
            archive="$out/archives/${toString entry.index}.tar.gz"
            tar --sort=name --mtime='@${toString entry.lastModified}' --owner=0 --group=0 --numeric-owner \
              -C "$work" -cf - source | gzip -n > "$archive"
            archive_hash="$(sha256sum "$archive" | cut -d ' ' -f1)"
            printf '%s\t%s\t%s\t%s\t%s\n' \
              '${entry.route}' '${entry.narHash}' '${toString entry.lastModified}' "$archive_hash" \
              'archives/${toString entry.index}.tar.gz' >> "$out/manifest.tsv"
          ''
        ) sourceReplayEntries}
      '';
  sourceReplayServer = pkgs.writeText "c6-source-replay.py" ''
    import http.server
    import os
    import ssl
    import subprocess
    import urllib.parse

    ARCHIVES = {
      ${lib.concatMapStringsSep "\n" (
        entry:
        "${builtins.toJSON entry.route}: ${builtins.toJSON "${sourceReplayArchives}/archives/${toString entry.index}.tar.gz"},"
      ) sourceReplayEntries}
    }
    GIT_PROJECT_ROOT = "/etc/c6-source-replay/git"
    KAMEO_PREFIX = "/LiGoldragon/kameo.git"

    def git_response(handler):
        parsed = urllib.parse.urlsplit(handler.path)
        allowed = (
            (handler.command == "GET" and
             parsed.path == KAMEO_PREFIX + "/info/refs" and
             parsed.query == "service=git-upload-pack") or
            (handler.command == "POST" and
             parsed.path == KAMEO_PREFIX + "/git-upload-pack" and
             parsed.query == "")
        )
        if not allowed:
            handler.send_error(404, "C6 source replay permits only the locked Kameo upload-pack endpoints")
            return
        content_length = int(handler.headers.get("Content-Length", "0"))
        body = handler.rfile.read(content_length) if content_length else b""
        environment = os.environ.copy()
        environment.update({
            "GIT_PROJECT_ROOT": GIT_PROJECT_ROOT,
            "GIT_HTTP_EXPORT_ALL": "1",
            "REQUEST_METHOD": handler.command,
            "PATH_INFO": parsed.path,
            "QUERY_STRING": parsed.query,
            "CONTENT_TYPE": handler.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(content_length),
            "HTTP_GIT_PROTOCOL": handler.headers.get("Git-Protocol", ""),
            "REMOTE_ADDR": handler.client_address[0],
            "SERVER_PROTOCOL": handler.protocol_version,
        })
        result = subprocess.run(
            ["${pkgs.gitMinimal}/bin/git", "http-backend"],
            input=body,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            env=environment,
        )
        if result.returncode != 0 or b"\r\n\r\n" not in result.stdout:
            handler.send_error(500, "C6 Kameo upload-pack backend failed")
            return
        raw_headers, response_body = result.stdout.split(b"\r\n\r\n", 1)
        status = 200
        headers = []
        for raw_header in raw_headers.decode("ascii").split("\r\n"):
            name, value = raw_header.split(":", 1)
            if name.lower() == "status":
                status = int(value.strip().split(" ", 1)[0])
            else:
                headers.append((name, value.strip()))
        handler.send_response(status)
        has_content_length = False
        for name, value in headers:
            if name.lower() == "content-length":
                has_content_length = True
            handler.send_header(name, value)
        if not has_content_length:
            handler.send_header("Content-Length", str(len(response_body)))
        handler.end_headers()
        handler.wfile.write(response_body)

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            if self.path.startswith(KAMEO_PREFIX + "/"):
                git_response(self)
                return
            archive = ARCHIVES.get(self.path)
            if archive is None:
                self.send_error(404, "C6 source replay permits only locked archive routes")
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/x-gzip")
            self.send_header("Content-Length", str(os.path.getsize(archive)))
            self.end_headers()
            with open(archive, "rb") as source_archive:
                self.wfile.write(source_archive.read())

        def do_POST(self):
            git_response(self)

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
      environment.etc."c6-source-replay/git".source = sourceReplayGit;
      networking.firewall.allowedTCPPorts = [ 443 ];
      systemd.services.c6-source-replay = {
        description = "C6 exact immutable GitHub archive replay";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        path = [ pkgs.python3 pkgs.gitMinimal ];
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
      # The real immutable four-input evaluation reads the selected Nix source
      # graph. runNixOSTest defaults to 1 GiB, which OOM-kills that evaluation
      # after admission; this is test-runner capacity only, not a Lojix option.
      virtualisation.memorySize = 4096;

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
          pkgs.gitMinimal
          pkgs.gnutar
        ];
        environment = {
          # ssh-ng / nix-copy uses the deploy key + learns the target host key
          # on first contact (accept-new) into a WRITABLE known_hosts under the
          # daemon's runtime dir. Fully offline.
          NIX_SSHOPTS = "-i /etc/lojix-c6/deploy_key -o UserKnownHostsFile=/run/lojix/known_hosts -o StrictHostKeyChecking=accept-new -o BatchMode=yes";
          GIT_SSH_COMMAND = "ssh -i /etc/lojix-c6/deploy_key -o UserKnownHostsFile=/run/lojix/known_hosts -o StrictHostKeyChecking=accept-new -o BatchMode=yes";
          GIT_SSL_CAINFO = "${sourceReplayTls}/cert.pem";
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
          # Verify every finite replay entry through the VM's actual TLS path
          # before starting the daemon. The manifest binds its exact GitHub
          # route to the lock-derived NAR hash and deterministic archive hash;
          # the server has no fallback route. A top-level github: URI itself
          # carries no NAR hash, so separately require Nix's resolved root
          # metadata to match the original source, locked hash, and revision.
          # Lojix then evaluates that unchanged URI under this same Nix setup.
          export XDG_CACHE_HOME=/var/lib/lojix/.cache
          mkdir -p "$XDG_CACHE_HOME" /run/lojix/source-replay
          replayed_count=0
          while IFS="$(printf '\t')" read -r route nar_hash last_modified archive_hash archive_rel; do
            replayed_count=$((replayed_count + 1))
            archive="/run/lojix/source-replay/$replayed_count.tar.gz"
            for _ in $(seq 1 30); do
              if ${pkgs.curl}/bin/curl --fail --silent --show-error \
                --cacert "${sourceReplayTls}/cert.pem" \
                "https://github.com$route" --output "$archive"; then
                break
              fi
              sleep 1
            done
            test -s "$archive"
            actual_archive_hash="$(sha256sum "$archive" | cut -d ' ' -f1)"
            test "$actual_archive_hash" = "$archive_hash"
            # Every source archive is built with one lock-derived mtime for all
            # members. Read its first source/ header through tar instead of
            # expanding Nixpkgs under /run: the latter is needlessly large and
            # can prevent the daemon from starting before Lojix is involved.
            expected_archive_timestamp="$(${pkgs.coreutils}/bin/date --utc --date "@$last_modified" '+%Y-%m-%d %H:%M:%S')"
            archive_header="$(
              TZ=UTC ${pkgs.gnutar}/bin/tar \
                --use-compress-program=${pkgs.gzip}/bin/gzip \
                --full-time -tvf "$archive" | ${pkgs.coreutils}/bin/head -n 1
            )"
            case "$archive_header" in
              *"$expected_archive_timestamp source/") ;;
              *)
                echo "C6 source replay timestamp mismatch for $route: expected $expected_archive_timestamp source/, got $archive_header" >&2
                exit 1
                ;;
            esac
            echo "C6 source replay verified $route narHash=$nar_hash lastModified=$last_modified archiveSha256=$archive_hash"
          done < "${sourceReplayArchives}/manifest.tsv"
          test "$replayed_count" = "${toString (builtins.length sourceReplayEntries)}"
          # Cargo's locked Kameo dependency is a Git source.  Prove the exact
          # finite smart-HTTP route can fetch the complete locked graph, and that its
          # source tree is the lock-verified NAR before the daemon starts.
          git clone https://github.com/LiGoldragon/kameo.git /run/lojix/kameo-probe
          test "$(git -C /run/lojix/kameo-probe rev-parse HEAD)" = f491b45d7dcb55e5837eddde3d5d7ca8ceaa9f01
          test "$(git -C /run/lojix/kameo-probe rev-list --count HEAD)" = 417
          mkdir -p /run/lojix/kameo-tree
          git -C /run/lojix/kameo-probe archive f491b45d7dcb55e5837eddde3d5d7ca8ceaa9f01 | \
            ${pkgs.gnutar}/bin/tar -C /run/lojix/kameo-tree -xf -
          test "$(nix hash path --type sha256 --sri /run/lojix/kameo-tree)" = "${kameoReplayEntry.narHash}"
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
            --arg nar_hash "sha256-5oLG5SeumySnnOC/+cIu1tpoR9OXh/L4csoXZv3aJ9Y=" \
            --arg revision "82f6bf5958f999c97c4d81f985d4ac91bdbc2340" \
            --argjson last_modified 1788669988 \
            '.path == $source and .locked.narHash == $nar_hash and .revision == $revision and .locked.lastModified == $last_modified' \
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
      # Poll the schema-owned durable deployment record before waiting for the
      # target profile. A failed/rejected pipeline must surface its current
      # `DeploymentLifecycle.[ Failed Rejected ... ]` and
      # `DeploymentTerminal.[ Failed.DeploymentFailure
      # Rejected.DeploymentTerminalReason Succeeded ]` state promptly, rather
      # than making a known failure consume the whole profile timeout.
      for _ in range(600):
          observed_query = query_node()
          if "Failed" in observed_query or "Rejected" in observed_query:
              daemon_journal = deployer.execute(
                  "journalctl -u lojix-daemon.service --no-pager"
              )[1]
              # `EffectStage::Eval` maps every subprocess failure to the public
              # FlakeReferenceMalformed terminal reason. Reconstruct the exact
              # daemon-side eval after materialization so the test reports the
              # Nix stdout/stderr that distinguishes a locator defect from a
              # replayed input, import, or selector failure.
              materialized_root = (
                  "/var/lib/lojix/generated-inputs/"
                  "${clusterName}/${vmNode}/base-host"
              )
              # Preserve the daemon-produced terminal before the independent
              # reproduction so it remains clear which result belongs to the
              # production effect pipeline.
              print("durable failed/rejected deployment state:", observed_query)
              diagnostic_status, diagnostic_output = deployer.execute(
                  "set -u; "
                  "printf 'C6 eval uid='; id -u; printf 'C6 eval working-directory='; pwd; "
                  "printf '%s\n' '=== C6 relevant Nix environment ==='; "
                  "env | grep -E '^(NIX_CONFIG|NIX_PATH|NIX_REMOTE|XDG_CACHE_HOME)=' || true; "
                  "printf '%s\n' '=== C6 relevant Nix configuration ==='; "
                  "nix show-config | grep -E '^(flake-registry|use-registries|experimental-features|extra-experimental-features) =' || true; "
                  "escape_nar() { printf '%s' $1 | sed -e 's/%/%25/g' -e 's/+/%2B/g' -e 's#/#%2F#g' -e 's/=/%3D/g'; }; "
                  "set -- nix eval --raw; "
                  f"for input in horizon system deployment secrets; do nar=$(nix hash path --type sha256 --sri {materialized_root}/$input); "
                  "encoded=$(escape_nar $nar); printf 'C6 eval override %s path:%s narHash=%s\n' $input "
                  f"{materialized_root}/$input $encoded; set -- $@ --override-input $input "
                  f"path:{materialized_root}/$input?narHash=$encoded; done; "
                  "set -- $@ '${deployFlakeReference}#nixosConfigurations.target.config.system.build.toplevel.drvPath'; "
                  "printf '%s\n' '=== C6 reconstructed daemon nix eval ==='; $@"
              )
              print("=== reconstructed daemon nix eval status ===", diagnostic_status)
              print("=== reconstructed daemon nix eval output ===")
              print(diagnostic_output)
              print("=== lojix daemon deployment journal ===")
              print(daemon_journal)
              raise AssertionError(
                  "lojix deployment reached a durable Failed or Rejected terminal state"
              )
          profile_target = ${vmNode}.execute(
              "readlink -f /nix/var/nix/profiles/system"
          )[1].strip()
          if profile_target == expected_closure:
              break
          deployer.sleep(1)
      else:
          final_wait_query = query_node()
          daemon_journal = deployer.execute(
              "journalctl -u lojix-daemon.service --no-pager"
          )[1]
          print("durable deployment state after profile timeout:", final_wait_query)
          print("=== lojix daemon deployment journal ===")
          print(daemon_journal)
          raise AssertionError(
              "lojix deployment did not activate the expected profile within 600 seconds"
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
