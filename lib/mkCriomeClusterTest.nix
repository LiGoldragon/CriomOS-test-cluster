# mkCriomeClusterTest — a reusable networked criome cluster test generator.
#
# Designer report 704, Stage A. The author writes one declaration
# (`{ cluster, members }`) and gets a runnable `runNixOSTest` check that boots a
# real NixOS guest, runs the real `criome-daemon` as a systemd service, and runs
# the `criome-cluster-witness` against its socket — proving the 1-of-1
# authorization gate (authorized accepted, threshold-short rejected) with real
# blst BLS over a real Unix socket inside a real sandbox.
#
# Stage A is the criome half of the spirit gate. The spirit-daemon driving the
# gate and the cross-guest mirror fan-out (Stage B) land once spirit's
# gate-config arming (the documented remaining step) is built.
#
# The daemon follows the proven CriomOS `mirror.nix` shape: an `ExecStartPre`
# encodes the typed configuration into the single rkyv startup argument the
# daemon consumes; the daemon never parses text.
#
# SCOPE (honest): this minimal guest runs criome as ROOT. It proves the gate
# verdict logic + the meta socket in a real VM — NOT criome's per-Unix-user
# isolation (that needs a dedicated non-root service user + an assertion that a
# different unprivileged user is denied the socket) and NOT the full CriomOS
# test-substrate. Those are follow-ons (audit 704-4 B7).
{
  inputs,
  pkgs,
  system,
}:
{
  name ? "criome-cluster-1of1",
  cluster ? "fieldlab",
  members ? [ "alpha" ],
  # The witness binary run against the booted daemon: the 1-of-1 quorum witness
  # by default, or criome-auto-approve-witness-test for the auto-approve +
  # meta-Configure proof.
  witness ? "criome-cluster-witness-test",
}:
let
  criomePackage = inputs.criome.packages.${system}.cluster-witness;

  socketDirectory = "/run/criome";
  socketPath = "${socketDirectory}/criome.sock";
  storeDirectory = "/var/lib/criome";
  storePath = "${storeDirectory}/criome.sema";
  configurationPath = "${socketDirectory}/criome-daemon.rkyv";

  # Stage A realizes exactly ONE criome member (single guest, 1-of-1). `members`
  # is the forward seam for Stage B (multi-node quorum across guests), which is
  # not built yet — so reject >1 loudly rather than silently dropping the tail.
  member =
    if builtins.length members == 1 then
      builtins.head members
    else
      throw "mkCriomeClusterTest realizes one criome member (Stage A); multi-node quorum (Stage B) is unbuilt — got ${toString (builtins.length members)} members";
  machineName = builtins.replaceStrings [ "-" ] [ "_" ] member;

  criomeNode =
    { ... }:
    {
      environment.systemPackages = [ criomePackage ];

      systemd.tmpfiles.rules = [
        "d ${socketDirectory} 0755 root root -"
        "d ${storeDirectory} 0750 root root -"
      ];

      systemd.services.criome = {
        description = "criome authentication daemon (${cluster} 1-of-1 cluster test)";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStartPre = "${criomePackage}/bin/criome-write-configuration ${socketPath} ${storePath} ${configurationPath}";
          ExecStart = "${criomePackage}/bin/criome-daemon ${configurationPath}";
          Restart = "on-failure";
          RestartSec = "2s";
        };
      };
    };
in
pkgs.testers.runNixOSTest {
  inherit name;

  nodes.${member} = criomeNode;

  testScript = ''
    start_all()
    ${machineName}.wait_for_unit("criome.service")
    ${machineName}.wait_for_file("${socketPath}")
    ${machineName}.wait_for_file("${socketPath}.meta")
    # The witness runs against the booted daemon over real sockets: the 1-of-1
    # quorum proof (authorized accepted, threshold-short rejected), or the
    # auto-approve proof (meta Configure(AutoApprove) -> Configured, then an
    # evidence-less evaluation -> Authorized).
    ${machineName}.succeed("CRIOME_SOCKET=${socketPath} ${criomePackage}/bin/${witness}")
  '';
}
