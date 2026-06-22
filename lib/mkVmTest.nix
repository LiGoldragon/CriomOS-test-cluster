# mkVmTest — the cluster-data-generated VM-test generator (C4; refined for the
# complex-OS + home-profile suite, C5; design reports 50/4-design-proposal §2+§4,
# 50/1-psyche-decisions).
#
# A test is a function of the CLUSTER MODEL, never cluster-specific: the author
# writes ONLY (cluster, hostNode, vmNode, testScript). Everything the guest is —
# its OS, its size, its address, its substrate fixes — flows from the projected
# horizon data plus the named test-substrate profile (C3). The generator
# hand-stubs NOTHING (Spirit [dqg3]/[aipc]): the guest is a real CriomOS
# nixosSystem built FROM its horizon projection, the VM is sized FROM the guest's
# projected machine facts, and the host endpoint is sliced FROM the host's
# cluster-authored VmHost.guest_subnet (C1).
#
#   mkVmTest {
#     cluster    = "fieldlab";       # the cluster these nodes belong to
#     hostNode   = "atlas";          # the physical VM host — carries VmHost data
#     vmNode     = "edge-desktop";   # ANY Pod node hosted on the VmHost host
#     testScript = ''<runNixOSTest python, reads like prose>'';
#     substrate  = "microvm";        # baked constraint set (default), NOT authored
#   } -> a runnable flake check (a runNixOSTest derivation)
#
# THE C5 MODEL REFINEMENT (the crux for testing COMPLEX profiles):
#   C4 required vmNode to be a LEAN TestVm (behavesAs.testVm). That is too narrow
#   for "complex OS testing", which means booting HEAVY role profiles — a desktop
#   (Edge), a router. So the model invariant is RELAXED from
#       "vmNode is behavesAs.testVm"
#   to
#       "vmNode is a Pod-substrate node hosted on a VmHost host" (ANY role).
#   The lean TestVm is now just the deploy-target SPECIAL CASE; an Edge Pod is a
#   complex-OS case, a TestVm Pod with home kept is a home-profile case. The
#   profile under test comes ENTIRELY from the node's PROJECTION (its species ->
#   behavesAs facets -> which CriomOS module trees light up) — never hand-stubbed
#   (Spirit [aipc]). 100% cluster-data-generation is preserved.
#
# WHAT FLOWS FROM CLUSTER DATA (never authored per-test):
#   - the guest OS:     a real CriomOS nixosSystem with specialArgs.horizon =
#                       <vmNode projection>; the role (species -> behavesAs.*)
#                       and every module gate come from that projection — an Edge
#                       node lights the desktop tree, a Router node the router
#                       tree, a lean TestVm neither;
#   - the home profile: includeHome is DERIVED from the role — a lean TestVm
#                       suppresses home (its whole point), every other role keeps
#                       the production home profile. A base-home test is a node
#                       that keeps home; the toggle is cluster-decided, not
#                       hand-set (proposal decision 4 — reuse includeHome);
#   - the VM size:      virtualisation.{cores,memorySize,diskSize} read from the
#                       guest's projected machine.{cores,ramGb,diskGb};
#   - the accel:        the host's VmHost.kvm decides the QEMU substrate — kvm
#                       Available -> KVM acceleration, kvm Absent -> a TCG
#                       (software) substrate (read off cluster data, not the
#                       builder's luck);
#   - the capacity:     the host's VmHost.maximum_guests is asserted not exceeded
#                       by its hosted Pod-substrate guest set (over-subscription
#                       is a cluster-authoring error, surfaced at eval);
#   - the network:      the guest's host-side endpoint is sliced from the host's
#                       VmHost.guest_subnet (the same CIDR test-vm-host.nix slices
#                       on the real host) — never the 169.254.100+i.1 invented in
#                       Nix that the model replaced;
#   - the substrate:    test-substrate.nix (C3) composes the writable-store /
#                       require-sigs / NSS / shell / serial / label prebakes onto
#                       the guest. The author never re-types these.
#
# THE runNixOSTest <-> MACHINE-TYPE REALITY (the crux, handled head-on; Spirit
# [dqg3]):
#   The runNixOSTest python driver hard-codes its control plane on the QEMU PCI
#   bus — `-device virtio-serial` + `-device virtconsole,chardev=shell` (the
#   /dev/hvc0 backdoor the driver connects to), `-device virtio-rng-pci`, plus
#   qemu-vm.nix's 9p `-virtfs` store/xchg shares and the virtio-blk-pci root
#   drive. The QEMU `microvm` machine type (`-M microvm`) has NO PCI bus by
#   default (it is virtio-mmio + no-ACPI by design), so a bare `-M microvm`
#   override makes QEMU reject the driver's own backdoor device and the VM can
#   never connect. runNixOSTest + bare `-M microvm` therefore CANNOT compose.
#
#   The resolution is to recognise WHICH substrate each "microvm" fact belongs
#   to. The report-48/49 "userspace only comes up on `-M microvm`, q35 hangs"
#   finding was about the STANDALONE microvm.nix-VM / OVMF-bootloader deploy
#   path, where the guest booted as an actual microvm.nix VM (virtio-mmio mounts,
#   its own bootloader). Under runNixOSTest the guest is a qemu-vm.nix node: a
#   real virtio-blk-pci root, a 9p host store, ordinary NixOS stage-1, and
#   DIRECT KERNEL BOOT (virtualisation.useBootLoader = false) — which is exactly
#   the property that made `-M microvm` attractive in the first place. So the
#   hermetic generator keeps the qemu-vm.nix substrate (PCI, direct kernel boot)
#   and applies ONLY the test-substrate guestModule OS prebakes; it does NOT push
#   the microvm machine-type override onto the driver node. The `substrate`
#   argument still selects the guestModule prebake set (microvm vs uefi labels);
#   the runner's machine type is the driver's own, which is what boots.

{
  # The locked flake inputs (nixpkgs + criomos), threaded from flake.nix.
  inputs,
  # The host nixpkgs `pkgs` (provides pkgs.testers.runNixOSTest).
  pkgs,
  # The flake `self` (to read the committed horizon projections under
  # fixtures/horizon — the same projections projections-match-fieldlab pins to
  # `horizon-cli`).
  self,
  system,
}:

let
  inherit (inputs.nixpkgs) lib;

  constants = inputs.criomos-lib.lib.constants;

  # Read a committed horizon projection. This is the SAME deterministic
  # cluster-data -> config-data artifact the flake's projections-match-fieldlab
  # check proves equal to `horizon-cli --cluster <c> --node <n>`, so reading the
  # fixture IS reading the projection (and stays honest via that check).
  readHorizon = node: builtins.fromJSON (builtins.readFile "${self}/fixtures/horizon/${node}.json");

  # The criome domain of a node from its own projection (never invented).
  guestDomainOf =
    horizon: horizon.node.criomeDomainName or "${horizon.node.name}.${horizon.cluster.name}.criome";

  # The host's cluster-authored VmHost service (C1). The generator reads the
  # SAME datum test-vm-host.nix reads on the real host: services is a list of
  # single-key attrsets, one per NodeService variant.
  vmHostServiceOf =
    hostHorizon:
    let
      services = hostHorizon.node.services or [ ];
      entry = lib.findFirst (service: service ? VmHost) null services;
    in
    if entry == null then null else entry.VmHost;

  # The host's Pod-substrate guests — every exNode whose machine.superNode names
  # this host AND whose substrate is Pod (a VM the host runs), by sorted name.
  # This is the C5-relaxed hosted set: the C4 model filtered on behavesAs.testVm
  # (lean guests only); the host runs ANY Pod-on-it node regardless of its role,
  # so capacity and the per-guest index span all of them.
  hostedPodNamesOf =
    hostNodeName: hostHorizon:
    lib.sort lib.lessThan (
      lib.attrNames (
        lib.filterAttrs (
          _: exNode:
          (exNode.machine.superNode or null) == hostNodeName && (exNode.machine.species or null) == "Pod"
        ) (hostHorizon.exNodes or { })
      )
    );

  # Strip the prefix length from a CIDR / address, leaving the dotted-decimal.
  bareAddress = value: if value == null then null else builtins.head (lib.splitString "/" value);

  # The CIDR prefix length (the bit after `/`), as an int. `null` for a bare
  # address with no prefix.
  prefixLengthOf =
    value:
    let
      parts = lib.splitString "/" value;
    in
    if value == null || lib.length parts < 2 then null else lib.toInt (lib.elemAt parts 1);

  # Usable host slots in an IPv4 CIDR — the count of host endpoints the
  # generator can hand to guests. Mirrors horizon-rs TapSubnet::usable_host_count
  # (and Ipv4Net::hosts): 2^(32 - prefix) addresses minus the network and
  # broadcast addresses for any prefix shorter than /31. The host TapSubnet is
  # IPv4-only (enforced in horizon-rs), so this is always a /N IPv4 prefix.
  twoToThe = exponent: lib.foldl' (acc: _: acc * 2) 1 (lib.range 1 exponent);
  usableHostCount =
    cidr:
    let
      prefix = prefixLengthOf cidr;
      total = twoToThe (32 - prefix);
    in
    if prefix == null then
      null
    else if prefix >= 31 then
      total
    else
      total - 2;

  # Slice the host-side endpoint for a guest out of the host's guest_subnet,
  # mirroring test-vm-host.nix's hostTapAddress (base + index + 1). The hermetic
  # runNixOSTest path does not actually wire this tap (it uses the driver's own
  # test network), but the endpoint is still DERIVED from cluster data and
  # asserted-present, so the model — not a hand-stub — owns the address.
  hostTapAddressOf =
    vmHost: index:
    let
      base = bareAddress (vmHost.guestSubnet or null);
      octets = map lib.toInt (lib.splitString "." base);
      flat = (lib.elemAt octets 3) + index + 1;
    in
    "${toString (lib.elemAt octets 0)}.${toString (lib.elemAt octets 1)}."
    + "${toString ((lib.elemAt octets 2) + flat / 256)}.${toString (lib.mod flat 256)}";
in

{
  cluster,
  hostNode,
  vmNode,
  testScript,
  # The baked substrate-constraint set (C3). "microvm" (default) selects the
  # booting prebakes; "uefi" selects the BootOnce label set. This selects the
  # guestModule prebakes, NOT the runner machine type (see the crux note above).
  substrate ? "microvm",
  # The harness/deploy public key for the guest's root authorizedKeys. The
  # hermetic test reaches the guest over the driver backdoor, so this is null by
  # default; the live (C6) path supplies it.
  deployKey ? null,
  # Extra modules the author may compose onto the guest (rare — the point is to
  # need none). Substrate constraints never live here; they live in C3.
  extraGuestModules ? [ ],
  # The home profile toggle (proposal decision 4 — reuse deployment.includeHome).
  # `null` (default) DERIVES it from the role: a lean TestVm drops home, every
  # other role keeps it — so an Edge node author writes nothing and gets the
  # desktop's home, a lean node gets none. A base-home test sets it `true` on an
  # otherwise-lean TestVm node to isolate the home profile on a minimal system —
  # the ONLY case that authors this flag, and it IS the cluster-decision-4 flag.
  includeHome ? null,
}:

let
  guestHorizon = readHorizon vmNode;
  hostHorizon = readHorizon hostNode;

  guestName = guestHorizon.node.name;
  machine = guestHorizon.node.machine;

  vmHost = vmHostServiceOf hostHorizon;

  # KVM availability is a closed-set domain atom on the VmHost service —
  # `Available` (hardware acceleration present) or `Absent` (none). When the
  # cluster declares Absent (or no VmHost), the generator emits a TCG (software)
  # QEMU substrate rather than depending on the builder host happening to have
  # /dev/kvm. Read off cluster data, the same atom test-vm-host.nix reads.
  kvmAvailable = vmHost != null && (vmHost.kvm or "Absent") == "Available";

  # The host's declared capacity ceiling, if any (maximumGuests is omitted from
  # the projection when the cluster authored no ceiling).
  maximumGuests = if vmHost == null then null else (vmHost.maximumGuests or null);

  # The guest's index among the host's hosted POD guests, by sorted name — the
  # deterministic key test-vm-host.nix uses to slice per-guest endpoints. C5:
  # the hosted set is every Pod-on-host node (any role), not just lean TestVms.
  hostedGuestNames = hostedPodNamesOf hostNode hostHorizon;
  guestIndex = lib.lists.findFirstIndex (name: name == guestName) null hostedGuestNames;
  hostedCount = lib.length hostedGuestNames;

  # The host-side endpoint sliced from the cluster-authored subnet (asserted, so
  # a host that forgot to declare VmHost fails the test rather than silently
  # losing its address to a Nix default).
  hostTapAddress =
    if vmHost == null || guestIndex == null then null else hostTapAddressOf vmHost guestIndex;

  # The C3 substrate profile, substrate-parameterized.
  substrateProfile = import "${inputs.criomos}/modules/nixos/test-substrate.nix" {
    inherit substrate deployKey;
  };

  # An unfree-allowing pkgs for the runner (see the call site for why). Built
  # from the same locked nixpkgs the flake pins, only flipping allowUnfree.
  unfreePkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
  };

  # ---- substrate sanity, asserted from cluster data (Spirit [dqg3]) ----------
  # These are model invariants the generator depends on; a violation is a
  # cluster-authoring error, surfaced loudly at eval rather than as a mid-boot
  # mystery.
  #
  # C5 relaxation: the guest must be a Pod-SUBSTRATE node (a VM the host runs),
  # NOT necessarily a lean TestVm. Its ROLE (Edge / Router / TestVm / ...) is
  # whatever its projection derived; the generator tests that role's profile.
  guestIsPod = (machine.species or null) == "Pod";
  hostDeclaresVmHost = vmHost != null;
  hostHostsGuest = guestIndex != null;
  # The host's hosted Pod set must fit its declared ceiling (over-subscription
  # is a cluster-authoring error). Absent ceiling -> no limit.
  capacityOk = maximumGuests == null || hostedCount <= maximumGuests;

  # The hosted set (and any declared ceiling) must also fit the guest_subnet's
  # USABLE HOST SLOTS — each guest's host endpoint is sliced base + (index + 1)
  # out of this subnet, so a subnet too small for the guests would silently
  # slice outside the declared network (finding 1). The required slot count is
  # the larger of the actual hosted set and the advertised ceiling, so a host
  # whose ceiling already over-subscribes the subnet fails even before it fills.
  subnetHostSlots = if vmHost == null then null else usableHostCount (vmHost.guestSubnet or null);
  requiredSlots = if maximumGuests == null then hostedCount else lib.max hostedCount maximumGuests;
  subnetCapacityOk = subnetHostSlots == null || requiredSlots <= subnetHostSlots;

  # includeHome is DERIVED from the role unless the author overrode it: a lean
  # TestVm defaults to no home profile (the deploy-target case never wants it),
  # every other role keeps the production home profile. deployment.includeHome
  # ALONE then decides home in CriomOS (test-vm-guest.nix no longer re-wipes it).
  # So an Edge test gets the desktop's home for free; a base-home test sets the
  # override `true` to isolate the home profile on an otherwise-lean TestVm node
  # (proposal decision 4 — reuse includeHome).
  guestIsTestVm = guestHorizon.node.behavesAs.testVm or false;
  includeHomeResolved = if includeHome != null then includeHome else !guestIsTestVm;

  assertModel =
    value:
    assert lib.assertMsg guestIsPod
      "mkVmTest: vmNode ${vmNode} is not a Pod-substrate node (machine.species != Pod in its projection); only a Pod node runs as a VM on a host.";
    assert lib.assertMsg hostDeclaresVmHost
      "mkVmTest: hostNode ${hostNode} declares no VmHost service in its projection; it cannot host a test VM.";
    assert lib.assertMsg hostHostsGuest
      "mkVmTest: hostNode ${hostNode} does not host vmNode ${vmNode} (no Pod exNode with superNode == ${hostNode} named ${vmNode}).";
    assert lib.assertMsg capacityOk
      "mkVmTest: hostNode ${hostNode} hosts ${toString hostedCount} Pod guests but declares maximum_guests = ${toString maximumGuests}; raise the ceiling or move guests.";
    assert lib.assertMsg subnetCapacityOk
      "mkVmTest: hostNode ${hostNode} needs ${toString requiredSlots} guest tap slots but its VmHost.guest_subnet ${
        toString (vmHost.guestSubnet or null)
      } has only ${toString subnetHostSlots} usable host addresses; widen the subnet or reduce the hosted set.";
    value;

  guestModuleFromCluster =
    {
      lib,
      ...
    }:
    {
      imports = [
        inputs.criomos.nixosModules.criomos
        inputs.criomos.inputs.sops-nix.nixosModules.sops
        substrateProfile.guestModule
      ]
      # The home-manager NixOS module is only needed when the home profile is
      # kept (a production CriomOS consumer imports it alongside nixosModules.
      # criomos; the lean default path never references home-manager.*). Import
      # it exactly when includeHome is on, so a base-home guest gets the
      # `home-manager.users` option the projection's userHomes.nix populates.
      ++ lib.optionals includeHomeResolved [
        inputs.criomos.inputs.home-manager.nixosModules.home-manager
      ]
      ++ extraGuestModules;

      # --- size: 100% from the guest's projected machine facts ---------------
      virtualisation = {
        cores = machine.cores;
        memorySize = machine.ramGb * 1024; # MiB
        diskSize = machine.diskGb * 1024; # MiB
        # accel: cluster-decided. kvm Available -> KVM; Absent -> TCG software.
        # runNixOSTest's qemu-vm node uses KVM when /dev/kvm exists; force TCG
        # off the host's declared VmHost.kvm when the cluster says no hardware.
        qemu.options = lib.mkIf (!kvmAvailable) [ "-accel tcg" ];
      };

      # CriomOS sets system.stateVersion via its modules; pin it for the test
      # node merge as the fixtureSystem builder does.
      system.stateVersion = lib.mkDefault "26.05";
    };
in
assertModel (
  # The runner's pkgs allows unfree. A heavy role profile legitimately reaches
  # unfree leaves (an Edge desktop's nautilus archive support pulls unrar, etc.);
  # production CriomOS deploys build with NIXPKGS_ALLOW_UNFREE=1, so the hermetic
  # test — which builds its OWN pkgs and pins each node's nixpkgs.pkgs from this
  # one (making nixpkgs.config read-only on the node) — must grant the same
  # allowance HERE, where the test's pkgs is configured. runNixOSTest threads
  # THIS pkgs onto every node, so configuring it once covers the guest. A
  # test-harness concern matching the production build environment, not an OS
  # policy change.
  (
    (unfreePkgs.testers.runNixOSTest {
      name = "vm-test-${cluster}-${vmNode}";

      # The guest is a real CriomOS node built from its projection — never a
      # hand-stub. horizon is threaded as a per-node specialArg exactly as the
      # production nixosSystem receives it.
      node.specialArgs = {
        inherit constants;
        horizon = guestHorizon;
        inputs = inputs // {
          sops-nix = inputs.criomos.inputs.sops-nix;
          microvm = inputs.criomos.inputs.microvm;
          secrets.sopsFiles.routerWifiSaePasswords = "${self}/fixtures/secrets/routerWifiSaePasswords";
        };
        # includeHome derived from the role (a lean TestVm drops home; any other
        # role keeps the production home profile) — this is what makes a base-home
        # test simply "a node whose role keeps home", with zero per-test authoring.
        deployment = {
          includeHome = includeHomeResolved;
          includeComplex = false;
        };
      };

      nodes.${vmNode} = guestModuleFromCluster;

      # The author's testScript verbatim. ${vmNode} is the machine name the python
      # driver binds, so the script reads `${vmNode}.wait_for_unit(...)`.
      inherit testScript;

      # Carry the derived facts in the derivation env purely for observability
      # (they prove the address came from cluster data, not a literal).
      passthru = {
        inherit
          hostTapAddress
          guestIndex
          kvmAvailable
          hostedCount
          ;
        includeHome = includeHomeResolved;
        guestDomain = guestDomainOf guestHorizon;
      };
    }).overrideTestDerivation
      (old: {
        requiredSystemFeatures = (old.requiredSystemFeatures or [ ]) ++ [
          "nixos-test"
          "criomos-vm-testing"
        ];
      })
    // {
      # Evaluator-visible mirror of the scheduler gate above. The runNixOSTest
      # wrapper hides the underlying derivation env, so pure policy checks read
      # this field while the actual .drv carries requiredSystemFeatures.
      requiredSystemFeatures = [
        "nixos-test"
        "criomos-vm-testing"
      ];
    }
  )
)
