# standardTest — the role-derived STANDARD testScript a node gets for free.
#
# This is the directive's "fallback to be test-run for the standard test": the
# default `testScript` a node receives when no custom entry exists in the
# flake's `customTests` registry. It is NOT trivial — it asserts the
# load-bearing units and properties of every role the node's projection sets,
# so a newly-declared node of any role gets a meaningful, role-faithful test
# with ZERO authoring. Declaring the node IS getting a real test.
#
# 100% CLUSTER-DATA-DERIVED (Spirit [aipc] — no fake/stub): the assertions are
# selected purely from the node's projected `behavesAs` facets (and its
# projected `users` for the home layer). The author writes nothing; the role
# the node plays decides which fragments fire, exactly as the same projection
# decides which CriomOS module trees light up. A lean node gets only the
# universal base; an Edge node additionally gets the desktop fragment; a Router
# node the router fragment; a largeAi node the llama-router fragment.
#
# ONE CONCEPT per fragment (Spirit [xxgp]): each row of the facet -> fragment
# table is "the standard role test for <facet>" — it proves that role's single
# defining invariant came up in a real boot, and nothing else. The fragments
# concatenate into one node's standard script; the whole script is still "this
# node boots into the roles its projection declares".
#
#   standardTestFor { machineName = "edge_desktop"; behavesAs = {...};
#                     users = {...}; includeHome = true; }
#     -> a runNixOSTest python testScript string (reads like prose)
#
# The machineName is the python driver's binding for the node (the runNixOSTest
# driver mangles a node name's dashes to underscores: edge-desktop -> the
# `edge_desktop` machine object), so the fragments call `${machineName}.<op>`.

{
  lib,
}:

let
  inherit (lib) optionalString concatStringsSep;

  # ---- the facet -> fragment table -----------------------------------------
  # Each builder takes the python machine name and returns a single-concept
  # block of runNixOSTest assertions for that role. The PATTERN comment in
  # every block names "the standard role test for <facet>" so the generated
  # script reads as a sequence of named role invariants.

  # PATTERN: the standard role test for EVERY node — it booted far enough to run
  # a login service. The universal floor: stage-2 reached multi-user and sshd
  # (the operator login surface every CriomOS node carries) is up and active.
  # This is exactly today's `test-vm-guest-boots-sshd` invariant, now the base
  # layer every standard test starts from.
  universalFragment = m: ''
    # the standard role test for any node: it boots and its login surface is up
    ${m}.wait_for_unit("multi-user.target")
    ${m}.wait_for_unit("sshd.service")
    ${m}.succeed("systemctl is-active sshd.service")
  '';

  # PATTERN: the standard role test for `behavesAs.edge` — a desktop OS. An Edge
  # node's projection lights edge/default.nix, which emits the display-manager
  # stack: the dbus system bus, the greetd (regreet) display manager reaching
  # its greeter at boot, the gnome-keyring secret daemon and the niri compositor
  # on PATH, and polkit as the installed authorization daemon. These are the
  # load-bearing units that make a node "one you log into graphically".
  edgeFragment = m: ''
    # the standard role test for edge: the desktop display-manager stack comes up
    ${m}.wait_for_unit("dbus.service")
    ${m}.wait_for_unit("greetd.service")
    ${m}.succeed("test -x /run/current-system/sw/bin/gnome-keyring-daemon")
    ${m}.succeed("test -x /run/current-system/sw/bin/niri")
    ${m}.succeed("systemctl cat polkit.service | grep -q polkitd")
  '';

  # PATTERN: the standard role test for `behavesAs.router` — the gateway stack. A
  # Router node's projection lights router/default.nix: the hostapd access-point
  # and the kea DHCPv4 server are active, and IPv4 forwarding (the defining
  # gateway property) is on. These are the units a router exists to run.
  routerFragment = m: ''
    # the standard role test for router: the access-point + dhcp + forwarding
    ${m}.wait_for_unit("hostapd.service")
    ${m}.wait_for_unit("kea-dhcp4-server.service")
    ${m}.succeed("test \"$(cat /proc/sys/net/ipv4/conf/all/forwarding)\" = 1")
  '';

  # PATTERN: the standard role test for `behavesAs.largeAi` — the model router. A
  # largeAi node's projection lights llm.nix, which emits a per-node
  # `<node>-llama-router.service` (the on-demand multi-model llama.cpp serving
  # unit). The unit name carries the node name (the projection's nodeName), so
  # the fragment is parameterized by it. It is a long-running on-demand service;
  # assert it is loaded and wanted (present in the boot graph), not necessarily
  # already-active, since it serves on demand.
  largeAiFragment = m: nodeName: ''
    # the standard role test for largeAi: the per-node llama.cpp router unit exists
    ${m}.succeed("systemctl cat ${nodeName}-llama-router.service | grep -q llama")
    ${m}.succeed("systemctl is-enabled ${nodeName}-llama-router.service || systemctl show -p WantedBy ${nodeName}-llama-router.service | grep -q multi-user.target")
  '';

  # PATTERN: the standard role test for a KEPT HOME profile — home-manager
  # activated. When the node keeps its home profile (includeHome resolved true),
  # CriomOS imports the home-manager NixOS module and userHomes.nix populates a
  # home-manager activation unit per projected user (`home-manager-<user>.service`).
  # Assert each projected user's activation ran. Derived from the node's projected
  # `users`, never hand-named.
  homeFragment = m: userNames: concatStringsSep "" (map (user: ''
    # the standard role test for a kept home profile: home-manager activated for ${user}
    ${m}.wait_for_unit("home-manager-${user}.service")
    ${m}.succeed("systemctl is-active home-manager-${user}.service")
  '') userNames);

in

# Build the standard testScript for one node from its projection.
{
  # The python driver's machine binding (node name with dashes -> underscores).
  machineName,
  # The node's projected name (drives the per-node `<node>-llama-router` unit).
  nodeName,
  # The node's projected `behavesAs` facet record.
  behavesAs,
  # The node's projected `users` record (attrset keyed by user name).
  users ? { },
  # Whether the home profile is kept on this node (the same includeHomeResolved
  # mkVmTest computed — so the standard test agrees with the home profile the
  # generator actually built).
  includeHome ? false,
}:

let
  m = machineName;
  isEdge = behavesAs.edge or false;
  isRouter = behavesAs.router or false;
  isLargeAi = behavesAs.largeAi or false;
  userNames = lib.attrNames users;
in
universalFragment m
+ optionalString isEdge (edgeFragment m)
+ optionalString isRouter (routerFragment m)
+ optionalString isLargeAi (largeAiFragment m nodeName)
+ optionalString (includeHome && userNames != [ ]) (homeFragment m userNames)
