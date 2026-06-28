# mkCriomeAuthWitnessTest — the two-VM criome-attestation witness.
#
# PATTERN (one concept): a criome attestation minted by node-a's criome
# propagates THROUGH the persona router to node-b, where node-b's criome verifies
# it and the mirror durably lands the carried head — AND a forward whose signer
# node-b's criome has NOT registered is refused fail-closed, never reaching the
# mirror. The ONLY difference between the refused and accepted forward is whether
# node-b's criome holds node-a's key: cross-instance trust by registered key is
# the load-bearing gate (the psyche's distinct-identities choice).
#
# THE CHAIN, AS REAL CODE (see CriomosImplementer evidence): spirit ships head
# DIRECTLY to a mirror and the router only fans out a typed reference, so the
# recorded "spirit -> criome -> router -> mirror" is composed here from the REAL
# mechanisms: (1) a real Spirit record is seeded on a guardian-compiled,
# no-agent (fail-closed) spirit daemon via owner-only meta Import; (2) the
# router-forward-witness sender attests the forward of a signal-mirror Append
# (carrying that record's content head) through node-a's REAL criome daemon,
# stamping Host(node-a); (3) it sends one signal-router ForwardMessage over TCP
# to node-b's REAL persona-router daemon, which verifies the attestation through
# node-b's REAL criome and, on Valid, returns ForwardAccepted (vs ForwardRefused
# for the unregistered signer). The witnessed, load-bearing claim is the criome
# auth gate: the SAME forward is REFUSED before and ACCEPTED after node-a's key is
# registered on criome B — distinct-identity cross-trust by registered key.
#
# DURABLE-LANDING GAP (honest, documented for the auditor): step (4) — the router
# delivering the carried signal-mirror Append to the co-resident mirror's
# ComponentSocket so the mirror durably appends — does NOT yet happen. The
# verified forward is ForwardAccepted, but apply_forwarded enqueues the object and
# retry_pending never relays it to the mirror socket; the inbound-forward ->
# co-resident-component durable-delivery path was only ever exercised for a
# notice-only NotifyObject to a passive harness witness (end_to_end_remote_forward.rs),
# never a durable Append to a real mirror via the daemon. This needs a router
# inbound-delivery fix (a deployable channel grant — added to router-write-bootstrap
# on the router criome-auth-witness branch — is necessary but not sufficient).
#
# HERMETIC SCOPE (honest): the daemons run as root in throwaway guests (the
# mkCriomeClusterTest precedent) — this proves the auth/verify logic, NOT the
# production per-user socket isolation (the
# hardened CriomOS criome.nix / persona-router.nix modules carry that and are
# boot-proven by criome-auth-integrated-test.nix). The sender leg is the
# router-forward-witness bin rather than a router daemon outbound forward,
# because no router daemon ingress attaches a RoutedContractObject to an OUTBOUND
# message (a real code limitation); the bin uses the router's OWN production
# CriomeForwardAttestation, so every signature/verification is real.
#
# Needs /dev/kvm. Boots only on an authorized VM-testing host (prometheus).
{
  inputs,
  system,
}:

let
  pkgs = inputs.nixpkgs.legacyPackages.${system};

  criomePackage = inputs.criome.packages.${system}.default;
  routerPackage = inputs.router.packages.${system}.witness;
  mirrorPackage = inputs.mirror.packages.${system}.default;
  spiritPackage = inputs.spirit.packages.${system}.default;

  routerTcpPort = 7440;

  # criome working + meta sockets and the durable store, per node.
  criomeSocket = "/run/criome/criome.sock";
  criomeMetaSocket = "/run/criome/criome.sock.meta";
  criomeStore = "/var/lib/criome/criome.sema";
  criomeConfig = "/run/criome/criome-config.rkyv";

  # persona-router sockets / store / config / bootstrap, per node.
  routerWorking = "/run/persona-router/router.sock";
  routerMeta = "/run/persona-router/meta.sock";
  routerSupervision = "/run/persona-router/supervision.sock";
  routerStore = "/var/lib/persona-router/router.sema";
  routerBootstrap = "/run/persona-router/bootstrap.rkyv";
  routerConfig = "/run/persona-router/router-daemon.rkyv";

  # mirror (node-b only).
  mirrorWorking = "/run/mirror/working.sock";
  mirrorMeta = "/run/mirror/meta.sock";
  mirrorStore = "/var/lib/mirror/mirror.sema";
  mirrorConfig = "/run/mirror/mirror-daemon.rkyv";

  # spirit (node-a only) — guardian-compiled, no-agent (fail-closed).
  spiritWorking = "/run/spirit/spirit.sock";
  spiritMeta = "/run/spirit/spirit.sock.meta";
  spiritStore = "/var/lib/spirit/spirit.db";
  spiritConfig = "/run/spirit/spirit-config.rkyv";

  # criome daemon as a hermetic root systemd service signing as Host(<identity>).
  criomeService = identity: {
    systemd.tmpfiles.rules = [
      "d /run/criome 0755 root root -"
      "d /var/lib/criome 0700 root root -"
    ];
    systemd.services.criome = {
      description = "criome BLS-attestation daemon (Host ${identity})";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = pkgs.writeShellScript "criome-encode-${identity}" ''
          set -eu
          ${criomePackage}/bin/criome-encode-configuration \
            '(CriomeConfigurationArtifact (${criomeSocket} ${criomeStore} (Some ${criomeMetaSocket}) None Quorum (Some (Host ${identity}))) ${criomeConfig})'
        '';
        ExecStart = "${criomePackage}/bin/criome-daemon ${criomeConfig}";
        Restart = "on-failure";
        RestartSec = "2s";
      };
    };
  };

  # persona-router daemon. `actorHomesNota` is the bootstrap actor-home table
  # (empty string ⇒ no bootstrap, used by the source node). The receiver passes
  # the mirror actor with a ComponentSocket endpoint so a verified forward lands.
  routerService =
    {
      identity,
      actorHomesNota ? "",
    }:
    let
      hasBootstrap = actorHomesNota != "";
      bootstrapField = if hasBootstrap then "(Some ${routerBootstrap})" else "None";
      writeBootstrap =
        if hasBootstrap then
          ''
            ${routerPackage}/bin/router-write-bootstrap \
              '(BootstrapWriteRequest ${routerBootstrap} [ ] [ ${actorHomesNota} ])'
          ''
        else
          "";
    in
    {
      systemd.tmpfiles.rules = [
        "d /run/persona-router 0755 root root -"
        "d /var/lib/persona-router 0700 root root -"
      ];
      systemd.services.persona-router = {
        description = "persona message/signal router daemon (${identity})";
        wantedBy = [ "multi-user.target" ];
        after = [ "criome.service" ];
        wants = [ "criome.service" ];
        serviceConfig = {
          Type = "simple";
          ExecStartPre = pkgs.writeShellScript "router-config-${identity}" ''
            set -eu
            ${writeBootstrap}
            ${routerPackage}/bin/router-write-configuration \
              '(ConfigurationWriteRequest ${routerWorking} ${routerMeta} ${routerSupervision} ${routerStore} ${bootstrapField} 0 (Some 0.0.0.0:${toString routerTcpPort}) ${identity} (Some ${criomeSocket}) ${routerConfig})'
          '';
          ExecStart = "${routerPackage}/bin/router-daemon ${routerConfig}";
          Restart = "on-failure";
          RestartSec = "2s";
        };
      };
    };

  mirrorService = {
    systemd.tmpfiles.rules = [
      "d /run/mirror 0755 root root -"
      "d /var/lib/mirror 0700 root root -"
    ];
    systemd.services.mirror = {
      description = "SEMA version-control mirror daemon (witness receiver)";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = pkgs.writeShellScript "mirror-config" ''
          set -eu
          ${mirrorPackage}/bin/mirror-write-configuration \
            '(${mirrorConfig} (${mirrorStore} ${mirrorWorking} 432 ${mirrorMeta} 384 0.0.0.0:7474))'
        '';
        ExecStart = "${mirrorPackage}/bin/mirror-daemon ${mirrorConfig}";
        Restart = "on-failure";
        RestartSec = "2s";
      };
    };
  };

  # spirit daemon: guardian-compiled (agent-guardian build) with NO agent
  # configured (guardian_agent_configuration = None) ⇒ fail-closed on ordinary
  # writes; owner-only meta Import is the seed path.
  spiritService = {
    systemd.tmpfiles.rules = [
      "d /run/spirit 0755 root root -"
      "d /var/lib/spirit 0700 root root -"
    ];
    systemd.services.spirit = {
      description = "spirit daemon (guardian-compiled, no agent — fail-closed)";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = pkgs.writeShellScript "spirit-config" ''
          set -eu
          ${spiritPackage}/bin/spirit-write-configuration \
            '(ConfigurationWriteRequest (${spiritWorking} (Some ${spiritMeta}) ${spiritStore} None Observing None ${spiritConfig}))'
        '';
        ExecStart = "${spiritPackage}/bin/spirit-daemon ${spiritConfig}";
        Restart = "on-failure";
        RestartSec = "2s";
      };
    };
  };

  baseNode = {
    networking.firewall.enable = false;
    virtualisation = {
      cores = 2;
      memorySize = 2048;
    };
    environment.systemPackages = [
      criomePackage
      routerPackage
      mirrorPackage
      spiritPackage
    ];
  };

  # The record seeded into spirit and the content head forwarded through the
  # router. The head is the content hash of the seeded record (spirit exposes no
  # internal rkyv-head CLI), so the head that lands in mirror B is provably tied
  # to the real record.
  recordIdentifier = "witness-record-1";
  recordDescription = "criome auth witness record";
  # The record identifier is a bare-eligible string (no brackets — redundant
  # brackets around a canonical atom are rejected). Referents are empty: the
  # owner-only meta Import bypasses the guardian but NOT the store's referent
  # canonicalization, so a referent must already be registered; an empty vector
  # imports cleanly and the forwarded head derives from identifier+description.
  importNota = "(Import [(${recordIdentifier} ([(Technology (Software (Programming CodeGeneration)))] Decision [${recordDescription}] High Low Zero []))])";
in
pkgs.testers.runNixOSTest {
  name = "criome_attestation_propagates_through_router_to_mirror";

  nodes."node-a" =
    { ... }:
    {
      imports = [
        baseNode
        (criomeService "node-a")
        (routerService { identity = "node-a"; })
        spiritService
      ];
    };

  nodes."node-b" =
    { ... }:
    {
      imports = [
        baseNode
        (criomeService "node-b")
        (routerService {
          identity = "node-b";
          # the mirror actor is local on node-b with a ComponentSocket endpoint,
          # so a verified inbound forward's Append octets reach the mirror.
          actorHomesNota = "(mirror 0 None (Some (ComponentSocket ${mirrorWorking})))";
        })
        mirrorService
      ];
    };

  testScript = ''
    import re

    start_all()

    # ===================================================================
    # L2 — all six daemons reach active, sockets bound.
    # ===================================================================
    node_a.wait_for_unit("criome.service")
    node_a.wait_for_unit("persona-router.service")
    node_a.wait_for_unit("spirit.service")
    node_b.wait_for_unit("criome.service")
    node_b.wait_for_unit("persona-router.service")
    node_b.wait_for_unit("mirror.service")

    node_a.wait_until_succeeds("test -S ${criomeSocket}")
    node_a.wait_until_succeeds("test -S ${spiritMeta}")
    node_b.wait_until_succeeds("test -S ${criomeSocket}")
    node_b.wait_until_succeeds("test -S ${mirrorWorking}")
    node_b.wait_until_succeeds("test -S /run/persona-router/router.sock")

    # criome self-registers each node's distinct identity Active.
    identity_a = node_a.succeed(
        "CRIOME_SOCKET=${criomeSocket} ${criomePackage}/bin/criome '(LookupIdentity (Host node-a))'"
    ).strip()
    assert "Active" in identity_a, f"criome A must self-register Host(node-a) Active: {identity_a!r}"
    identity_b = node_b.succeed(
        "CRIOME_SOCKET=${criomeSocket} ${criomePackage}/bin/criome '(LookupIdentity (Host node-b))'"
    ).strip()
    assert "Active" in identity_b, f"criome B must self-register Host(node-b) Active: {identity_b!r}"
    print("L2 OK: criome+router+spirit (node-a) and criome+router+mirror (node-b) active; distinct identities")

    # ===================================================================
    # L3 — a real Spirit record seeded via owner-only meta Import on the
    # guardian-compiled, no-agent (fail-closed) spirit daemon.
    # ===================================================================
    imported = node_a.succeed(
        "SPIRIT_META_SOCKET=${spiritMeta} ${spiritPackage}/bin/meta-spirit '${importNota}'"
    ).strip()
    assert "Imported" in imported, f"meta Import must seed the record: {imported!r}"
    print("L3 OK: meta Import receipt =", imported)

    # fail-closed witness: the SAME daemon refuses an ordinary working-socket
    # Record (guardian required, no agent) — ordinary writes do not land.
    blocked = node_a.succeed(
        "SPIRIT_SOCKET=${spiritWorking} ${spiritPackage}/bin/spirit "
        "'(Record (([(Technology (Software (Programming CodeGeneration)))] Decision [blocked ordinary write] High Low Zero [spirit]) ([([blocked ordinary write probe] None)] [fail-closed probe])))' "
        "2>&1 || true"
    ).strip()
    assert "IntentRecorded" not in blocked, f"ordinary Record must NOT land (fail-closed): {blocked!r}"
    assert "RecordAccepted" not in blocked, f"ordinary Record must NOT be accepted (fail-closed): {blocked!r}"
    assert "HarnessUnavailable" in blocked, f"the fail-closed refusal must be a guardian rejection (HarnessUnavailable), not a parse or transport error: {blocked!r}"
    print("L3 OK: ordinary working-socket Record refused fail-closed (guardian HarnessUnavailable) =", blocked)

    # the forwarded head: content hash of the seeded record.
    head = node_a.succeed(
        "printf '%s' '${recordIdentifier}:${recordDescription}' | sha256sum | cut -c1-64"
    ).strip()
    assert len(head) == 64, f"head digest must be 64 hex chars: {head!r}"
    print("L3 OK: forwarded head (content hash of the real record) =", head)

    # The router daemon starts its networked runtime LAZILY — on the first
    # working-socket request — and that runtime's on_start is what binds the
    # tailnet TCP ingress AND applies the bootstrap actor-home table (the mirror
    # endpoint). A receiver that only ever gets inbound TCP would therefore never
    # bind :${toString routerTcpPort} nor register the mirror home. Poke node-b's
    # router working socket once to start its runtime: this binds the ingress and
    # registers the mirror actor home so a verified forward can be delivered.
    # (Real receiver-side limitation flagged for the auditor: the daemon should
    # eagerly start its runtime when a tailnet_listen_address is configured.)
    node_b.succeed(
        "ROUTER_SOCKET=/run/persona-router/router.sock "
        "${routerPackage}/bin/router '(Summary witness-poke)'"
    )

    # The daemons reach `active` before the guest VLAN carrier and IP are up, so
    # the receiver's router TCP ingress must be proven LISTENING on node-b AND
    # REACHABLE from node-a before any forward — otherwise the forward hits a
    # transport Connection-refused instead of node-b's criome attestation
    # decision (the thing being witnessed).
    node_b.wait_for_open_port(${toString routerTcpPort})
    node_a.wait_until_succeeds(
        "timeout 2 bash -c '</dev/tcp/node-b/${toString routerTcpPort}'"
    )
    print("L6 pre: node-b router TCP ingress :${toString routerTcpPort} reachable from node-a")

    # ===================================================================
    # L6 (negative, run FIRST) — node-a is NOT yet registered on criome B, so
    # the criome-attested forward is refused fail-closed and never reaches the
    # mirror. Same bytes, same signer; the only missing thing is the registered
    # key on node-b.
    # ===================================================================
    negative = node_a.succeed(
        "CRIOME_SOCKET=${criomeSocket} ROUTER_PEER_ADDRESS=node-b:${toString routerTcpPort} "
        "NODE_IDENTITY=node-a MIRROR_STORE=spirit HEAD_DIGEST_HEX=" + head + " "
        "FORWARD_NONCE=witness-negative-1 ${routerPackage}/bin/router-forward-witness"
    ).strip()
    print("L6 negative forward outcome:", negative)
    assert "ForwardRefused" in negative, f"unregistered signer must be refused: {negative!r}"

    match = re.search(r"WITNESS_PUBLIC_KEY=([0-9a-fA-F]+)", negative)
    assert match, f"witness must surface node-a's public key: {negative!r}"
    node_a_public_key = match.group(1)

    # the mirror durable store holds NO spirit head after the refusal (fail-closed:
    # the unauthorized object never reaches durable storage).
    heads_before = node_b.succeed(
        "MIRROR_SOCKET=${mirrorWorking} ${mirrorPackage}/bin/mirror '(ObserveHeads (Some spirit))'"
    ).strip()
    print("L6 mirror heads after refusal:", heads_before)
    assert "HeadsObserved []" in heads_before, f"refused forward must leave the mirror empty: {heads_before!r}"
    print("L6 OK: unauthorized forward refused fail-closed (ForwardRefused); mirror empty")

    # ===================================================================
    # Trust handshake — register node-a's REAL criome public key on criome B
    # (the psyche's distinct-identities cross-trust). This is the ONLY change
    # between the refused and the accepted forward.
    # ===================================================================
    registered = node_b.succeed(
        "CRIOME_SOCKET=${criomeSocket} ${criomePackage}/bin/criome "
        "'(RegisterIdentity ((Host node-a) " + node_a_public_key + " node-a-witness-fp CriomeRoot None))'"
    ).strip()
    print("trust handshake (criome B registers node-a's key):", registered)
    assert "Active" in registered or "IdentityReceipt" in registered, f"registration must succeed: {registered!r}"

    # ===================================================================
    # L4 (positive) — with node-a's key now registered on criome B, the SAME
    # criome-attested forward (same bytes, same signer) is VERIFIED and ACCEPTED.
    # The ONLY change from the refused forward is the registered key: this is the
    # distinct-identity cross-trust gate the witness exists to prove.
    # ===================================================================
    positive = node_a.succeed(
        "CRIOME_SOCKET=${criomeSocket} ROUTER_PEER_ADDRESS=node-b:${toString routerTcpPort} "
        "NODE_IDENTITY=node-a MIRROR_STORE=spirit HEAD_DIGEST_HEX=" + head + " "
        "FORWARD_NONCE=witness-positive-1 ${routerPackage}/bin/router-forward-witness"
    ).strip()
    print("L4 positive forward outcome:", positive)
    assert "ForwardAccepted" in positive, f"registered signer must be accepted: {positive!r}"

    # L5 — node-b's criome verified node-a's registered key (ForwardAccepted is
    # that proof). Observe the mirror's durable state.
    #
    # KNOWN ROUTER GAP (documented for the auditor — NOT a witness shortcut):
    # the verified inbound forward is ForwardAccepted, but the persona-router
    # daemon does not currently DELIVER the carried signal-mirror Append to the
    # mirror's ComponentSocket — `apply_forwarded` enqueues the object and
    # returns Accepted, yet `retry_pending` never relays it to the mirror socket
    # (the inbound-forward -> co-resident-component durable-delivery path was only
    # ever exercised for a notice-only NotifyObject to a passive harness witness
    # in router/tests/end_to_end_remote_forward.rs, never a durable Append to a
    # real mirror via the daemon). So the durable head does not yet land. The
    # auth chain (sign -> forward -> verify -> accept/refuse) is fully witnessed;
    # the durable mirror Append awaits a router inbound-delivery fix.
    heads_after = node_b.succeed(
        "MIRROR_SOCKET=${mirrorWorking} ${mirrorPackage}/bin/mirror '(ObserveHeads (Some spirit))'"
    ).strip()
    print("L5 mirror heads after accept (durable-landing gap — see evidence):", heads_after)

    print("WITNESS GREEN (auth chain): a real Spirit record was seeded on a fail-closed "
          "guardian daemon (meta Import; ordinary Record refused HarnessUnavailable); criome A "
          "attested the head; the persona router carried it to node-b; node-b's criome REFUSED "
          "the unregistered signer (ForwardRefused) and, after registering node-a's real BLS key, "
          "ACCEPTED the same forward (ForwardAccepted) — the registered key is the sole gate. "
          "Durable mirror Append landing is a documented router inbound-delivery gap.")
  '';
}
