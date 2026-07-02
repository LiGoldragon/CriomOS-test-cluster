# Faithful two-guest reachability test for the test-vm-host.nix guest-networking
# fix (CriomOS branch vm-guest-networking). The standard harness boots guests as
# sibling qemu-vm nodes on the driver net and NEVER wires the real tap; this test
# instead boots ONE host node (atlas, a real CriomOS router VmHost built from its
# projection) which boots TWO lean TestVm guests as NESTED microvms via
# test-vm-host.nix, then proves guest alpha (5::7) reaches guest beta (5::8) over
# the real tap path (guest binds nodeIp -> host fe80::1 gateway -> host forwards
# vmt*<->vmt* through the router firewall).
#
# The guests are minimal (no sshd); a TEST-ONLY probe is injected into each
# nested guest's config (extending microvm.vms.<g>.config from the host node) —
# beta runs a TCP echo listener, alpha pings + TCP-connects beta and prints a
# sentinel to its console, which microvm forwards to the microvm@alpha journal on
# the host, where the testScript asserts it.
{
  inputs,
  pkgs,
  self,
  system,
}:
let
  inherit (inputs.nixpkgs) lib;
  constants = inputs.criomos-lib.lib.constants;

  hostNode = "atlas";
  guestA = "alpha";
  guestB = "beta";
  guestAIp = "5::7";
  guestBIp = "5::8";
  tcpPort = "9999";

  atlasHorizonRaw = builtins.fromJSON (builtins.readFile "${self}/fixtures/horizon/${hostNode}.json");
  # atlas is a LargeAiRouter; the AI facet drags in a multi-GB LLM model that is
  # irrelevant to (and would dwarf) this networking test. Zero the largeAi facet
  # so llm.nix (mkIf behavesAs.largeAi) is inert — the router + VmHost facets
  # (which carry the nftables forward chain + microvm host under test) stay.
  atlasHorizon = atlasHorizonRaw // {
    node = atlasHorizonRaw.node // {
      behavesAs = atlasHorizonRaw.node.behavesAs // {
        largeAi = false;
      };
    };
  };

  unfreePkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
  };

  # Force off the router/desktop services that cannot come up in a hermetic VM
  # (no wifi hardware, no peers) so atlas reaches multi-user.target. The nftables
  # ruleset, systemd-networkd, IPv6 forwarding, and the microvm host stay — those
  # are exactly what the fix exercises.
  hostSubstrate =
    { lib, ... }:
    {
      # CriomOS normalize.nix sets documentation.* = true (plain), which
      # conflicts with the nixos-test framework's false. Force it off (as
      # test-vm-guest.nix does for guests).
      documentation.enable = lib.mkForce false;
      documentation.nixos.enable = lib.mkForce false;
      documentation.man.enable = lib.mkForce false;

      # The router declares a sops-encrypted wifi SAE-password secret; the
      # fixture placeholder is not a real sops file, and hostapd (its only
      # consumer) is forced off here — skip the build-time sops file check.
      sops.validateSopsFiles = lib.mkForce false;

      # These services fail uselessly in the hermetic VM (no upstream network)
      # and flood journald, which then rate-limits and DROPS the nested guests'
      # microvm@<g> console entries (the reachability sentinels). Silence them
      # and turn journald rate-limiting off so no guest sentinel is dropped.
      services.tailscale.enable = lib.mkForce false;
      services.headscale.enable = lib.mkForce false;
      services.nix-serve.enable = lib.mkForce false;
      services.printing.enable = lib.mkForce false;
      services.journald.extraConfig = lib.mkForce ''
        RateLimitIntervalSec=0
        RateLimitBurst=0
      '';

      services.hostapd.enable = lib.mkForce false;
      services.yggdrasil.enable = lib.mkForce false;
      services.greetd.enable = lib.mkForce false;
      programs.regreet.enable = lib.mkForce false;
      systemd.services.wpa_supplicant.enable = lib.mkForce false;
      systemd.services.hostapd-backup-wireless.enable = lib.mkForce false;
      systemd.services.complex-init.enable = lib.mkForce false;
      networking.useHostResolvConf = lib.mkForce false;
      # Do not block boot on the (unconfigured) driver/uplink interfaces.
      systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;
      boot.initrd.systemd.enable = lib.mkForce false;

      # Nested microvm guests need /dev/kvm inside atlas and enough headroom.
      microvm.host.enable = lib.mkDefault true;
      virtualisation = {
        cores = 8;
        memorySize = 16384;
        # The nested guests autoCreate their root.img under /var/lib/microvms on
        # THIS node's disk; the default 1 GiB node disk is far too small (the
        # guest root mount fails on ENOSPC). Give atlas ample room for both
        # guest images.
        diskSize = 30720;
        qemu.options = [
          "-cpu"
          "host"
        ];
      };
    };

  # TEST-ONLY probe injection into the nested guests (extends the minimal config
  # test-vm-host.nix emits). beta listens; alpha probes and prints sentinels.
  guestProbes = {
    microvm.vms.${guestB}.config = {
      environment.systemPackages = [
        pkgs.netcat-openbsd
        pkgs.iputils
      ];
      networking.firewall.allowedTCPPorts = [ (lib.toInt tcpPort) ];
      systemd.services.reach-listener = {
        description = "TCP echo listener for reachability probe";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Restart = "always";
          RestartSec = "1s";
        };
        script = ''
          while true; do
            echo "beta-alive" | ${pkgs.netcat-openbsd}/bin/nc -6 -l ${tcpPort} || true
          done
        '';
      };
    };
    microvm.vms.${guestA}.config = {
      environment.systemPackages = [
        pkgs.netcat-openbsd
        pkgs.iputils
      ];
      systemd.services.reach-probe = {
        description = "probe reachability to peer guest beta";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          StandardOutput = "journal+console";
          StandardError = "journal+console";
        };
        script = ''
          set +e
          echo "PROBE-START-alpha addr=$(${pkgs.iputils}/bin/ping -6 -c0 ${guestBIp} 2>/dev/null; ip -6 addr show 2>/dev/null | tr -d '\n')"
          for i in $(seq 1 45); do
            if ${pkgs.iputils}/bin/ping -c1 -W2 ${guestBIp} >/dev/null 2>&1; then
              echo "REACH-PING-OK-alpha-to-beta"
              break
            fi
            sleep 2
          done
          for i in $(seq 1 20); do
            reply="$(${pkgs.netcat-openbsd}/bin/nc -6 -w3 ${guestBIp} ${tcpPort} 2>/dev/null)"
            if [ "$reply" = "beta-alive" ]; then
              echo "REACH-TCP-OK-alpha-to-beta"
              break
            fi
            sleep 2
          done
          echo "PROBE-DONE-alpha"
        '';
      };
    };
  };

  atlasNode =
    { ... }:
    {
      imports = [
        inputs.criomos.nixosModules.criomos
        inputs.criomos.inputs.sops-nix.nixosModules.sops
        hostSubstrate
        guestProbes
      ];
      system.stateVersion = lib.mkDefault "26.05";
    };
in
unfreePkgs.testers.runNixOSTest {
  name = "nested-vm-guest-reachability";

  node.specialArgs = {
    inherit constants;
    horizon = atlasHorizon;
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

  nodes.${hostNode} = atlasNode;

  testScript = ''
    ${hostNode}.start()
    ${hostNode}.wait_for_unit("multi-user.target")

    # nested KVM present, and the two guest microvm units exist (built by
    # test-vm-host.nix from the projection).
    print("/dev/kvm:", ${hostNode}.execute("ls -l /dev/kvm")[1])
    ${hostNode}.succeed("systemctl cat microvm@${guestA}.service >/dev/null")
    ${hostNode}.succeed("systemctl cat microvm@${guestB}.service >/dev/null")

    # the host tap networks carry fe80::1 + the /128 route to each guest.
    print("host tap nets:", ${hostNode}.execute("cat /etc/systemd/network/05-test-vm-*.network")[1])

    # where do the guest root images live, and is there room?
    print("df:", ${hostNode}.execute("df -h /var/lib/microvms /var / /tmp 2>&1")[1])
    print("mounts:", ${hostNode}.execute("findmnt -no SOURCE,FSTYPE,SIZE /var/lib/microvms /var / 2>&1; mount | grep -E 'tmpfs|microvms' 2>&1")[1])

    # boot both guests (non-autostart).
    ${hostNode}.succeed("systemctl start microvm@${guestB}.service microvm@${guestA}.service")
    ${hostNode}.wait_until_succeeds("systemctl is-active microvm@${guestA}.service", timeout=180)
    ${hostNode}.wait_until_succeeds("systemctl is-active microvm@${guestB}.service", timeout=180)

    # give the guests time to boot and bind their tap addresses.
    ${hostNode}.sleep(60)

    # host routing/tap state (informational).
    print("host -6 route:", ${hostNode}.execute("ip -6 route")[1])
    print("host tap addrs:", ${hostNode}.execute("ip -6 addr show")[1])

    # --- host <-> guest reachability (host forwards + guest bound its nodeIp) ---
    ${hostNode}.wait_until_succeeds("ping -c1 -W2 ${guestAIp}", timeout=120)
    ${hostNode}.wait_until_succeeds("ping -c1 -W2 ${guestBIp}", timeout=120)
    print("HOST<->GUEST OK: host reaches both ${guestAIp} and ${guestBIp}")

    # --- guest A -> guest B reachability (the whole point) ---
    # alpha's boot probe pinged + TCP-connected beta; the sentinels reach the
    # host via the microvm@alpha journal.
    # Wait for alpha's probe to FINISH (PROBE-DONE is printed after both the
    # ping and TCP attempts), then capture its journal ONCE and assert both
    # sentinels from that single snapshot — robust to journald timing.
    ${hostNode}.wait_until_succeeds(
        "journalctl -u microvm@${guestA}.service --no-pager | grep -q PROBE-DONE-alpha",
        timeout=180,
    )
    j = ${hostNode}.execute("journalctl -u microvm@${guestA}.service --no-pager")[1]
    print("=== microvm@${guestA} journal (tail) ===")
    print("\n".join(j.splitlines()[-50:]))
    assert "REACH-PING-OK-alpha-to-beta" in j, "guest A could not PING guest B"
    assert "REACH-TCP-OK-alpha-to-beta" in j, "guest A could not TCP-connect guest B (mirror path)"

    print("NESTED REACHABILITY GREEN: guest ${guestA} reaches guest ${guestB} by ping AND TCP over the real tap path")
  '';
}
