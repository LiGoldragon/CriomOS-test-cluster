# Feasibility spike: can a runNixOSTest node boot a NESTED microvm.nix guest on
# prometheus (nested KVM), and is the guest's console observable from the host
# via the microvm@<name>.service journal? This is the load-bearing unknown for a
# faithful test of test-vm-host.nix tap networking (the standard harness boots
# guests as sibling qemu-vm nodes on the driver net, never as real microvms).
#
# No fix, no fixtures, no cluster machinery — one host node with one inline
# minimal microvm guest that prints a boot sentinel to its console.
{
  inputs,
  pkgs,
  system,
}:
let
  inherit (inputs.nixpkgs) lib;
in
pkgs.testers.runNixOSTest {
  name = "nested-microvm-spike";

  nodes.vmhost =
    { ... }:
    {
      imports = [ inputs.criomos.inputs.microvm.nixosModules.host ];

      networking.firewall.enable = false;

      virtualisation = {
        cores = 6;
        memorySize = 8192;
        # Expose the host CPU so the nested microvm guest gets /dev/kvm (nested
        # SVM is enabled on prometheus). If nested KVM is unavailable the guest
        # qemu would fail here — the spike surfaces exactly that.
        qemu.options = [
          "-cpu"
          "host"
        ];
      };

      microvm.host.enable = true;
      # Start the guest by hand in the test — never at host boot.
      microvm.autostart = [ ];

      microvm.vms.g1 = {
        autostart = false;
        config = {
          microvm = {
            hypervisor = "qemu";
            vcpu = 1;
            mem = 1024;
            volumes = [
              {
                image = "/var/lib/microvms/g1/root.img";
                mountPoint = "/";
                size = 2048;
                autoCreate = true;
                fsType = "ext4";
                label = "nixos";
              }
            ];
          };
          networking.hostName = "g1";
          system.stateVersion = "26.05";
          # A boot sentinel on the guest console (serial), which microvm's
          # qemu forwards to the microvm@g1.service stdout -> host journal.
          systemd.services.boot-marker = {
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "oneshot";
              StandardOutput = "journal+console";
            };
            script = "echo NESTED-GUEST-BOOTED-OK";
          };
        };
      };
    };

  testScript = ''
    vmhost.start()
    vmhost.wait_for_unit("multi-user.target")
    # nested KVM presence inside the host node (informational).
    print("=== /dev/kvm inside vmhost ===")
    print(vmhost.execute("ls -l /dev/kvm")[1])
    print(vmhost.execute("systemctl cat microvm@g1.service | head -40")[1])

    vmhost.succeed("systemctl start microvm@g1.service")
    vmhost.wait_until_succeeds("systemctl is-active microvm@g1.service", timeout=180)
    # give the nested guest time to boot to multi-user.
    vmhost.sleep(90)

    out = vmhost.execute("journalctl -u microvm@g1.service --no-pager")[1]
    print("=== microvm@g1.service journal ===")
    print(out)
    assert "NESTED-GUEST-BOOTED-OK" in out, (
        "nested microvm guest did not reach its boot sentinel — see journal above"
    )
    print("NESTED SPIKE GREEN: a nested microvm guest booted and its console is host-observable")
  '';
}
