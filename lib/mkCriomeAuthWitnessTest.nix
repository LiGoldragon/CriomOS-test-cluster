# mkCriomeAuthWitnessTest — the two-VM criome-attestation witness.
#
# PATTERN (one concept): a criome attestation minted by node-a's criome
# propagates THROUGH the persona router to node-b, where node-b's criome verifies
# it and the mirror DURABLY LANDS the carried head — AND two distinct forwards
# are refused fail-closed, never reaching the mirror: one whose signer node-b's
# criome has NOT registered (UnknownSigner) and one for a REGISTERED identity
# bearing a FOREIGN signature (InvalidSignature). The ONLY difference between the
# refusals and the accepted forward is a correctly-registered, matching key on
# criome B: cross-instance trust by registered key is the load-bearing gate (the
# psyche's distinct-identities choice).
#
# THE CHAIN, AS REAL CODE (see CriomosImplementer evidence): spirit ships head
# DIRECTLY to a mirror and the router only fans out a typed reference, so the
# recorded "spirit -> criome -> router -> mirror" is composed here from the REAL
# mechanisms: (1) a real Spirit record is seeded on a guardian-compiled,
# no-agent (fail-closed) spirit daemon via owner-only meta Import, and its REAL
# versioned-log head is read back via the owner-only meta op ObserveHead; (2) the
# router-forward-witness sender attests the forward of a signal-mirror Append
# (carrying that real head) through a REAL criome daemon, stamping Host(node-a);
# (3) it sends one signal-router ForwardMessage over TCP to node-b's REAL
# persona-router daemon, which verifies the attestation through node-b's REAL
# criome and, on Valid, returns ForwardAccepted (vs ForwardRefused for the two
# negatives); (4) node-b's router relays the carried Append to the co-resident
# mirror's ComponentSocket (bootstrap endpoint + operator->mirror grant) and the
# mirror DURABLY APPENDS it, so the mirror's head equals the real forwarded head.
# The witnessed, load-bearing claims: the criome auth gate (refuse vs accept by
# registered matching key) AND the durable mirror landing read from the mirror's
# own ObserveHeads.
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
  # the mirror actor home with a ComponentSocket endpoint (4th ActorHome field)
  # so a verified inbound forward's RoutedContractObject octets are relayed to
  # the mirror's working socket, AND `grantsNota` — the 5th BootstrapWriteRequest
  # list — an `(operator mirror)` direct-message channel grant, without which the
  # verified forward parks for adjudication and never reaches the mirror. Both
  # surfaces require router `criome-auth-witness` @ 221b5fb0; the 5-list
  # BootstrapWriteRequest is the only authoring path for the grant (the daemon's
  # meta grant vocabulary names only fixed components, not the witness actors).
  routerService =
    {
      identity,
      actorHomesNota ? "",
      grantsNota ? "",
    }:
    let
      hasBootstrap = actorHomesNota != "";
      bootstrapField = if hasBootstrap then "(Some ${routerBootstrap})" else "None";
      writeBootstrap =
        if hasBootstrap then
          ''
            ${routerPackage}/bin/router-write-bootstrap \
              '(BootstrapWriteRequest ${routerBootstrap} [ ] [ ${actorHomesNota} ] [ ${grantsNota} ])'
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

  # The record seeded into spirit. The head forwarded through the router is the
  # store's REAL versioned-log head, read back from the seeded daemon via the
  # owner-only meta op `ObserveHead` (spirit `criome-auth-witness`) — NOT a
  # synthetic hash of the identifier/description. So the head criome attests and
  # the mirror durably lands is the spirit store's own content-addressed head.
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
          # so a verified inbound forward's Append octets reach the mirror, AND an
          # (operator mirror) channel grant so the verified forward is delivered
          # rather than parked for adjudication.
          actorHomesNota = "(mirror 0 None (Some (ComponentSocket ${mirrorWorking})))";
          grantsNota = "(operator mirror)";
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

    # L3 — the forwarded head is the spirit store's REAL versioned-log head, read
    # back from the seeded daemon over the owner-only meta op `ObserveHead`
    # (spirit criome-auth-witness). It is `EntryDigest::to_string()` of the
    # store's current head — spirit's own content-addressing, NOT a synthetic
    # hash of the identifier/description. Before the Import the head is None; after
    # it the head is `(Some <64-hex>)`, the value criome attests and mirror lands.
    head_reply = node_a.succeed(
        "SPIRIT_META_SOCKET=${spiritMeta} ${spiritPackage}/bin/meta-spirit '(ObserveHead)'"
    ).strip()
    head_match = re.search(r"\(Some ([0-9a-f]{64})\)", head_reply)
    assert head_match, f"ObserveHead must report the real seeded head: {head_reply!r}"
    head = head_match.group(1)
    print("L3 OK: real spirit versioned-log head (ObserveHead) =", head)

    # ===================================================================
    # L5-prep — register the mirror store BEFORE any forward. An Append to an
    # unregistered store is refused UnknownStore (the head row must exist), so the
    # receiver must register the store the verified forwards target. A virgin
    # registration starts with no head: ObserveHeads reads `(spirit None)`, the
    # non-degenerate baseline the landing assertion advances past.
    # ===================================================================
    node_b.wait_until_succeeds("test -S ${mirrorMeta}")
    store_registered = node_b.succeed(
        "MIRROR_META_SOCKET=${mirrorMeta} ${mirrorPackage}/bin/meta-mirror '(RegisterStore spirit)'"
    ).strip()
    assert "StoreRegistered" in store_registered, f"mirror store must register: {store_registered!r}"
    baseline = node_b.succeed(
        "MIRROR_SOCKET=${mirrorWorking} ${mirrorPackage}/bin/mirror '(ObserveHeads (Some spirit))'"
    ).strip()
    assert "(spirit None)" in baseline, f"registered virgin store must have no head: {baseline!r}"
    assert head not in baseline, f"the real head must be ABSENT before any landing: {baseline!r}"
    print("L5-prep OK: mirror store 'spirit' registered, head empty =", baseline)

    # The router daemon starts its networked runtime LAZILY — on the first
    # working-socket request — and that runtime's on_start is what binds the
    # tailnet TCP ingress AND applies the bootstrap actor-home table (the mirror
    # endpoint + the operator->mirror channel grant). A receiver that only ever
    # gets inbound TCP would therefore never bind :${toString routerTcpPort} nor
    # register the mirror home/grant. Poke node-b's router working socket once to
    # start its runtime: this binds the ingress and applies the bootstrap so a
    # verified forward can be delivered. (Real receiver-side limitation flagged
    # for the auditor: the daemon should eagerly start its runtime when a
    # tailnet_listen_address is configured.)
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

    def mirror_heads():
        return node_b.succeed(
            "MIRROR_SOCKET=${mirrorWorking} ${mirrorPackage}/bin/mirror '(ObserveHeads (Some spirit))'"
        ).strip()

    # ===================================================================
    # L6a (negative 1 — UNREGISTERED signer) — node-a is NOT yet registered on
    # criome B, so node-b's criome resolves the signer to no key (UnknownSigner)
    # and the forward is refused fail-closed with reason AttestationInvalid. The
    # forward never reaches the mirror.
    # ===================================================================
    # criome B genuinely holds no node-a identity yet: this is what makes the
    # refusal an UnknownSigner decision and not some other failure.
    lookup_before = node_b.succeed(
        "CRIOME_SOCKET=${criomeSocket} ${criomePackage}/bin/criome '(LookupIdentity (Host node-a))'"
    ).strip()
    assert "UnknownIdentity" in lookup_before, f"criome B must NOT yet know node-a (UnknownSigner case): {lookup_before!r}"

    negative_one = node_a.succeed(
        "CRIOME_SOCKET=${criomeSocket} ROUTER_PEER_ADDRESS=node-b:${toString routerTcpPort} "
        "NODE_IDENTITY=node-a MIRROR_STORE=spirit HEAD_DIGEST_HEX=" + head + " "
        "FORWARD_NONCE=witness-negative-1 ${routerPackage}/bin/router-forward-witness"
    ).strip()
    print("L6a negative-1 (unregistered) forward outcome:", negative_one)
    assert "ForwardRefused" in negative_one, f"unregistered signer must be refused: {negative_one!r}"
    assert "AttestationInvalid" in negative_one, f"the refusal reason must be AttestationInvalid: {negative_one!r}"

    match = re.search(r"WITNESS_PUBLIC_KEY=([0-9a-fA-F]+)", negative_one)
    assert match, f"witness must surface node-a's public key: {negative_one!r}"
    node_a_public_key = match.group(1)

    heads_after_neg1 = mirror_heads()
    print("L6a mirror heads after negative-1:", heads_after_neg1)
    assert "(Some" not in heads_after_neg1, f"refused forward must NOT land in the mirror: {heads_after_neg1!r}"
    assert head not in heads_after_neg1, f"the real head must remain absent after the refusal: {heads_after_neg1!r}"
    print("L6a OK: unregistered signer refused (ForwardRefused AttestationInvalid); mirror head still empty")

    # ===================================================================
    # Trust handshake — register node-a's REAL criome public key on criome B
    # (the psyche's distinct-identities cross-trust). This is the ONLY change
    # between the refused-unregistered and the accepted forward.
    # ===================================================================
    registered = node_b.succeed(
        "CRIOME_SOCKET=${criomeSocket} ${criomePackage}/bin/criome "
        "'(RegisterIdentity ((Host node-a) " + node_a_public_key + " node-a-witness-fp CriomeRoot None))'"
    ).strip()
    print("trust handshake (criome B registers node-a's REAL key):", registered)
    assert "Active" in registered or "IdentityReceipt" in registered, f"registration must succeed: {registered!r}"

    lookup_after = node_b.succeed(
        "CRIOME_SOCKET=${criomeSocket} ${criomePackage}/bin/criome '(LookupIdentity (Host node-a))'"
    ).strip()
    assert "Active" in lookup_after, f"criome B must now hold node-a Active: {lookup_after!r}"

    # ===================================================================
    # L6b (negative 2 — REGISTERED identity, FOREIGN signature) — node-a is now
    # registered on criome B with its REAL key, but this forward is attested
    # through node-b's criome (claiming Host(node-a) via NODE_IDENTITY=node-a, a
    # registered active identity on criome B). criome signs with its OWN master
    # key, so the presented public key is node-b's (foreign to node-a's
    # registered key). criome B resolves node-a -> registered key, sees the
    # presented key differs, and returns InvalidSignature -> refused fail-closed
    # with reason AttestationInvalid. The forward never reaches the mirror.
    # ===================================================================
    negative_two = node_b.succeed(
        "CRIOME_SOCKET=${criomeSocket} ROUTER_PEER_ADDRESS=127.0.0.1:${toString routerTcpPort} "
        "NODE_IDENTITY=node-a MIRROR_STORE=spirit HEAD_DIGEST_HEX=" + head + " "
        "FORWARD_NONCE=witness-negative-2 ${routerPackage}/bin/router-forward-witness"
    ).strip()
    print("L6b negative-2 (registered, foreign key) forward outcome:", negative_two)
    assert "ForwardRefused" in negative_two, f"foreign signature must be refused: {negative_two!r}"
    assert "AttestationInvalid" in negative_two, f"the refusal reason must be AttestationInvalid: {negative_two!r}"

    foreign_match = re.search(r"WITNESS_PUBLIC_KEY=([0-9a-fA-F]+)", negative_two)
    assert foreign_match, f"witness must surface the foreign signing key: {negative_two!r}"
    foreign_public_key = foreign_match.group(1)
    # the presented (foreign) key genuinely differs from node-a's registered key:
    # this is precisely the InvalidSignature condition (registered key != presented).
    assert foreign_public_key != node_a_public_key, (
        f"negative-2 must present a FOREIGN key (registered {node_a_public_key}, "
        f"presented {foreign_public_key}) — else it is not the InvalidSignature case"
    )

    heads_after_neg2 = mirror_heads()
    print("L6b mirror heads after negative-2:", heads_after_neg2)
    assert "(Some" not in heads_after_neg2, f"refused foreign-key forward must NOT land: {heads_after_neg2!r}"
    assert head not in heads_after_neg2, f"the real head must remain absent after negative-2: {heads_after_neg2!r}"
    print("L6b OK: registered identity + foreign signature refused (ForwardRefused AttestationInvalid); mirror head still empty")

    # ===================================================================
    # L4 (positive) — node-a is registered on criome B with its REAL key and this
    # forward is attested through node-a's OWN criome (the matching key). criome B
    # resolves node-a -> registered key == presented key, verifies the BLS
    # signature, and returns Valid -> ForwardAccepted. The ONLY difference from
    # the two refusals is a correctly-registered, matching key: the
    # distinct-identity cross-trust gate the witness exists to prove.
    # ===================================================================
    positive = node_a.succeed(
        "CRIOME_SOCKET=${criomeSocket} ROUTER_PEER_ADDRESS=node-b:${toString routerTcpPort} "
        "NODE_IDENTITY=node-a MIRROR_STORE=spirit HEAD_DIGEST_HEX=" + head + " "
        "FORWARD_NONCE=witness-positive-1 ${routerPackage}/bin/router-forward-witness"
    ).strip()
    print("L4 positive forward outcome:", positive)
    assert "ForwardAccepted" in positive, f"registered matching-key signer must be accepted: {positive!r}"

    # ===================================================================
    # L5 (durable mirror landing) — the verified forward's carried
    # signal-mirror::Append is relayed by node-b's router to the mirror's
    # ComponentSocket (the bootstrap endpoint + operator->mirror grant), and the
    # mirror durably appends it. The mirror's head now equals the REAL forwarded
    # spirit head. This is the un-fakeable durable witness: read from the mirror's
    # own ObserveHeads, not the router reply.
    # ===================================================================
    landed = mirror_heads()
    print("L5 mirror heads after accept:", landed)
    landed_match = re.search(r"\(spirit \(Some \(\d+ ([0-9a-f]{64})\)\)\)", landed)
    assert landed_match, f"L5: the verified forward must durably land a head in the mirror: {landed!r}"
    landed_head = landed_match.group(1)
    assert landed_head == head, (
        f"L5: the landed mirror head {landed_head} must equal the REAL forwarded "
        f"spirit head {head} — not a different digest"
    )
    print("L5 OK: real spirit head durably landed in the mirror; mirror head ==", landed_head)

    print("WITNESS GREEN (full chain): a real Spirit record was seeded on a fail-closed "
          "guardian daemon (meta Import; ordinary Record refused HarnessUnavailable); its REAL "
          "versioned-log head (ObserveHead) was attested by criome A and forwarded through the "
          "persona router to node-b. node-b's criome REFUSED the unregistered signer (negative-1, "
          "UnknownSigner -> AttestationInvalid) and a registered identity bearing a FOREIGN "
          "signature (negative-2, InvalidSignature -> AttestationInvalid), leaving the mirror "
          "empty; after registering node-a's REAL key it ACCEPTED the matching-key forward "
          "(ForwardAccepted) and the carried Append durably LANDED in the mirror with head == the "
          "real spirit head — the registered matching key is the sole gate.")
  '';
}
