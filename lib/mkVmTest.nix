# mkVmTest — the cluster-data-generated VM-test generator (C4; design reports
# 50/4-design-proposal §2, 50/1-psyche-decisions).
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
#     vmNode     = "mercury";        # the TestVm guest to boot
#     testScript = ''<runNixOSTest python, reads like prose>'';
#     substrate  = "microvm";        # baked constraint set (default), NOT authored
#   } -> a runnable flake check (a runNixOSTest derivation)
#
# WHAT FLOWS FROM CLUSTER DATA (never authored per-test):
#   - the guest OS:     a real CriomOS nixosSystem with specialArgs.horizon =
#                       <vmNode projection>; the role (TestVm -> behavesAs.testVm)
#                       and every module gate come from that projection;
#   - the VM size:      virtualisation.{cores,memorySize,diskSize} read from the
#                       guest's projected machine.{cores,ramGb,diskGb};
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
    horizon:
    horizon.node.criomeDomainName or "${horizon.node.name}.${horizon.cluster.name}.criome";

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

  # Strip the prefix length from a CIDR / address, leaving the dotted-decimal.
  bareAddress = value: if value == null then null else builtins.head (lib.splitString "/" value);

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
}:

let
  guestHorizon = readHorizon vmNode;
  hostHorizon = readHorizon hostNode;

  guestName = guestHorizon.node.name;
  machine = guestHorizon.node.machine;

  vmHost = vmHostServiceOf hostHorizon;

  # The guest's index among the host's hosted TestVm guests, by sorted name —
  # the deterministic key test-vm-host.nix uses to slice per-guest endpoints.
  hostedGuestNames = lib.sort lib.lessThan (
    lib.attrNames (
      lib.filterAttrs (
        _: exNode:
        (exNode.machine.superNode or null) == hostNode && (exNode.behavesAs.testVm or false)
      ) (hostHorizon.exNodes or { })
    )
  );
  guestIndex = lib.lists.findFirstIndex (name: name == guestName) null hostedGuestNames;

  # The host-side endpoint sliced from the cluster-authored subnet (asserted, so
  # a host that forgot to declare VmHost fails the test rather than silently
  # losing its address to a Nix default).
  hostTapAddress =
    if vmHost == null || guestIndex == null then
      null
    else
      hostTapAddressOf vmHost guestIndex;

  # The C3 substrate profile, substrate-parameterized.
  substrateProfile = import "${inputs.criomos}/modules/nixos/test-substrate.nix" {
    inherit substrate deployKey;
  };

  # ---- substrate sanity, asserted from cluster data (Spirit [dqg3]) ----------
  # These are model invariants the generator depends on; a violation is a
  # cluster-authoring error, surfaced loudly at eval rather than as a mid-boot
  # mystery.
  guestIsTestVm = guestHorizon.node.behavesAs.testVm or false;
  hostDeclaresVmHost = vmHost != null;
  hostHostsGuest = guestIndex != null;

  assertModel =
    value:
    assert lib.assertMsg guestIsTestVm
      "mkVmTest: vmNode ${vmNode} is not a TestVm guest (behavesAs.testVm is false in its projection).";
    assert lib.assertMsg hostDeclaresVmHost
      "mkVmTest: hostNode ${hostNode} declares no VmHost service in its projection; it cannot host a test VM.";
    assert lib.assertMsg hostHostsGuest
      "mkVmTest: hostNode ${hostNode} does not host vmNode ${vmNode} (no exNode with superNode == ${hostNode} && behavesAs.testVm named ${vmNode}).";
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
      ++ extraGuestModules;

      # --- size: 100% from the guest's projected machine facts ---------------
      virtualisation = {
        cores = machine.cores;
        memorySize = machine.ramGb * 1024; # MiB
        diskSize = machine.diskGb * 1024; # MiB
      };

      # CriomOS sets system.stateVersion via its modules; pin it for the test
      # node merge as the fixtureSystem builder does.
      system.stateVersion = lib.mkDefault "26.05";
    };
in
assertModel (
  pkgs.testers.runNixOSTest {
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
      deployment = {
        includeHome = false;
      };
    };

    nodes.${vmNode} = guestModuleFromCluster;

    # The author's testScript verbatim. ${vmNode} is the machine name the python
    # driver binds, so the script reads `${vmNode}.wait_for_unit(...)`.
    inherit testScript;

    # Carry the derived facts in the derivation env purely for observability
    # (they prove the address came from cluster data, not a literal).
    passthru = {
      inherit hostTapAddress guestIndex;
      guestDomain = guestDomainOf guestHorizon;
    };
  }
)
