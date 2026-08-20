{ pkgs
, mcClient
, # Where "on hydrogen" servers are reached and controlled. The control channel is SSH
  # behind a forced command; see modules/minecraft-servers.nix.
  hydrogenHost ? "mc.luckyobserver.com"
, hydrogenUser ? "mcctl"
, defaultPlayer ? ""
, defaultServer ? ""
, controlKeyFile ? ""
}:

# The pre-launcher for machines that are not the couch: choose a player, choose a server,
# then start the game. Servers are rootless podman containers created on demand, here or on
# hydrogen.
#
# The couch has its own menu (modules/minecraft-couch.nix) because its job is different --
# several players on one screen, pads assigned to seats. Both draw with the same widgets.
#
# Identity is asked, not wired: minecraft-client derives the offline UUID and the game
# directory from the name, so this only has to choose one.
let
  ctl = import ./minecraft-server-ctl.nix { inherit pkgs; };
  nameRe = "^[A-Za-z0-9_]{3,16}$";
  serverRe = "^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$";
in
pkgs.writers.writePython3Bin "minecraft-launcher"
  {
    libraries = [ pkgs.minecraft-menu ];
    # E501: UI strings read better than they wrap.
    flakeIgnore = [ "E501" ];
  }
  ''
    """Pick a player and a server, bring the server up, then play."""
    import os
    import re
    import subprocess
    import sys
    import time

    from minecraft_menu import (
        ADDRESS_KEYS,
        Input,
        confirm,
        draw,
        load_json,
        menu,
        message,
        save_json,
        type_text,
    )

    MC_CLIENT = "${pkgs.lib.getExe mcClient}"
    CTL = "${pkgs.lib.getExe ctl}"
    SSH = "${pkgs.openssh}/bin/ssh"
    HYDROGEN_HOST = "${hydrogenHost}"
    HYDROGEN_USER = "${hydrogenUser}"
    DEFAULT_PLAYER = ${builtins.toJSON defaultPlayer}
    DEFAULT_SERVER = ${builtins.toJSON defaultServer}
    CONTROL_KEY = ${builtins.toJSON controlKeyFile}

    STATE = os.path.join(
        os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")),
        "minecraft", "launcher.json",
    )

    NAME_RE = re.compile("${nameRe}")
    SERVER_RE = re.compile("${serverRe}")

    LOCAL, HYDROGEN, REMOTE = "local", "hydrogen", "remote"
    WHERE_LABEL = {
        LOCAL: "on this machine",
        HYDROGEN: "on hydrogen",
        REMOTE: "elsewhere",
    }


    # ---------------------------------------------------------------------- state

    def load():
        data = load_json(STATE, {})
        players = data.get("players", [])
        servers = data.get("servers", [])
        # The ordinary Minecraft icon already has a configured identity. Make that same
        # player available here automatically; the launcher roster is only for additional
        # players, not a second setup step for the machine's owner.
        if DEFAULT_PLAYER and DEFAULT_PLAYER not in players:
            players.insert(0, DEFAULT_PLAYER)
        if DEFAULT_SERVER:
            host, _, port_text = DEFAULT_SERVER.partition(":")
            port = int(port_text) if port_text else 25565
            known = any(
                server.get("where") == REMOTE and server.get("host") == host and server.get("port", 25565) == port
                for server in servers
            )
            if not known:
                servers.insert(0, {
                    "name": "Family world",
                    "where": REMOTE,
                    "host": host,
                    "port": port,
                })
        # Hydrogen is the source of truth for shared worlds. Merge its real directories
        # into the local cache so every laptop sees worlds created by every other laptop.
        try:
            for line in ctl_run(HYDROGEN, "worlds").splitlines():
                name, state, port_text = (line.split("\t") + ["", ""])[:3]
                if not name:
                    continue
                found = next((s for s in servers if s.get("where") == HYDROGEN and s.get("name") == name), None)
                if found is None:
                    found = {"name": name, "where": HYDROGEN, "port": None}
                    servers.append(found)
                if port_text:
                    found["port"] = int(port_text)
        except (RuntimeError, ValueError):
            # Offline laptops can still use cached entries and local worlds.
            pass
        save(players, servers)
        return players, servers


    def save(players, servers):
        save_json(STATE, {"players": players, "servers": servers})


    # -------------------------------------------------------------- server control

    def ctl_run(where, *args, timeout=600):
        """Run the control script, locally or on hydrogen.

        Identical arguments either way -- hydrogen exposes the same script behind a
        forced command, so there is one implementation rather than two.
        """
        if where == HYDROGEN:
            cmd = hydrogen_ssh() + list(args)
        else:
            cmd = [CTL] + list(args)
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if done.returncode != 0:
            raise RuntimeError((done.stderr or done.stdout).strip() or "control command failed")
        return done.stdout.strip()


    def ctl_spawn(where, *args):
        """Same, but non-blocking, so a progress screen can be drawn while it runs."""
        if where == HYDROGEN:
            cmd = hydrogen_ssh() + list(args)
        else:
            cmd = [CTL] + list(args)
        return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


    def hydrogen_ssh():
        cmd = [SSH, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
               "-o", "StrictHostKeyChecking=accept-new"]
        if CONTROL_KEY:
            cmd += ["-o", "IdentitiesOnly=yes", "-i", CONTROL_KEY]
        return cmd + ["%s@%s" % (HYDROGEN_USER, HYDROGEN_HOST)]


    def wait_with_progress(inp, server):
        """Bring a server up, drawing progress. Returns True once it is ready.

        First start generates a world, which takes long enough that a frozen screen
        looks like a hang.
        """
        where, name = server["where"], server["name"]
        try:
            state = ctl_run(where, "status", name).split("\t")[0]
        except RuntimeError as err:
            message(inp, "Could not reach the server host", [str(err)])
            return False

        try:
            if state == "absent":
                port = ctl_run(where, "create", name, timeout=120)
                server["port"] = int(port)
            elif state != "running":
                port = ctl_run(where, "start", name, timeout=120)
                server["port"] = int(port)
        except (RuntimeError, ValueError) as err:
            message(inp, "Could not start %s" % name, [str(err)])
            return False

        proc = ctl_spawn(where, "wait", name, "600")
        started = time.time()
        while proc.poll() is None:
            spin = "|/-\\"[int((time.time() - started) * 2) % 4]
            draw(
                "Starting %s %s" % (name, spin),
                ["", "     %s, %ds" % (WHERE_LABEL[where], int(time.time() - started)), "",
                 "     A new world takes a minute or two to generate."],
                "",
            )
            time.sleep(0.4)
        if proc.returncode != 0:
            err = (proc.stderr.read() or "").strip()
            logs = ""
            try:
                logs = ctl_run(where, "logs", name, "15")
            except RuntimeError:
                pass
            message(inp, "%s did not come up" % name, [err] + logs.splitlines()[-10:])
            return False
        return True


    # -------------------------------------------------------------------- players

    def choose_player(inp, players, servers):
        while True:
            options = list(players) + ["Add a player", "Remove a player", "Quit"]
            idx = menu(inp, "Who is playing?", options)
            if idx is None or options[idx] == "Quit":
                return None
            if options[idx] == "Add a player":
                name = type_text(
                    inp, "New player name:",
                    footer="3-16 letters, digits or _   |   or just type on the keyboard",
                    validate=lambda t: validate_player(t, players),
                )
                if name:
                    players.append(name)
                    save(players, servers)
                continue
            if options[idx] == "Remove a player":
                if not players:
                    continue
                pick = menu(inp, "Remove which player?", players + ["Back"])
                if pick is None or pick == len(players):
                    continue
                gone = players[pick]
                if confirm(inp, "Remove %s?" % gone, ["Their character and world are untouched."]):
                    players.remove(gone)
                    save(players, servers)
                continue
            return options[idx]


    def validate_player(name, players):
        if not NAME_RE.match(name):
            return "Use 3-16 letters, digits or underscore. Minecraft rejects the rest."
        if name in players:
            return "%s is already on the list." % name
        return None


    # -------------------------------------------------------------------- servers

    def describe(server):
        where = server["where"]
        if server["name"] == "Family world" and where == REMOTE:
            return "%s   shared" % server["name"]
        if where == REMOTE:
            return "%s   %s:%s" % (server["name"], server["host"], server.get("port", 25565))
        if where == HYDROGEN:
            return "%s   shared" % server["name"]
        return "%s   only this computer" % server["name"]


    def choose_server(inp, players, servers):
        while True:
            options = [describe(s) for s in servers] + ["Create a new world", "Forget a world", "Back"]
            idx = menu(inp, "Which world?", options)
            if idx is None or options[idx] == "Back":
                return None
            if options[idx] == "Create a new world":
                add_server(inp, players, servers)
                continue
            if options[idx] == "Forget a world":
                remove_server(inp, players, servers)
                continue
            return servers[idx]


    def add_server(inp, players, servers):
        taken = [s["name"] for s in servers]
        name = type_text(
            inp, "New server name:",
            footer="a short name for this world",
            validate=lambda t: validate_server(t, taken),
        )
        if not name:
            return

        where_idx = menu(inp, "Who can play in %s?" % name, [
            "Everyone -- shared on hydrogen",
            "Only players on this computer",
            "Join a world hosted somewhere else",
            "Back",
        ])
        if where_idx is None or where_idx == 3:
            return
        where = [HYDROGEN, LOCAL, REMOTE][where_idx]

        server = {"name": name, "where": where}
        if where == REMOTE:
            address = type_text(
                inp, "Address:", keys=ADDRESS_KEYS,
                footer="host or host:port   |   or just type it",
                validate=validate_address,
            )
            if not address:
                return
            host, _, port = address.partition(":")
            server["host"] = host
            server["port"] = int(port) if port else 25565
        else:
            # Created lazily on first play, so adding an entry cannot fail here and the
            # container only exists once it is actually wanted.
            server["port"] = None

        servers.append(server)
        save(players, servers)


    def validate_server(name, taken):
        if not SERVER_RE.match(name):
            return "Start with a letter or digit; letters, digits, _ . - only."
        if name in taken:
            return "There is already a server called %s." % name
        return None


    def validate_address(address):
        host, _, port = address.partition(":")
        if not host:
            return "Enter a host name or address."
        if port and not port.isdigit():
            return "The port after ':' must be a number."
        return None


    def remove_server(inp, players, servers):
        if not servers:
            return
        labels = [describe(s) for s in servers]
        pick = menu(inp, "Remove which server?", labels + ["Back"])
        if pick is None or pick == len(servers):
            return
        server = servers[pick]
        body = ["The entry goes; the world stays on disk."]
        if server["where"] == REMOTE:
            body = ["Only the entry goes. Nothing on that server is touched."]
        if not confirm(inp, "Remove %s?" % server["name"], body):
            return
        if server["where"] in (LOCAL, HYDROGEN):
            try:
                ctl_run(server["where"], "remove", server["name"])
            except RuntimeError as err:
                message(inp, "Could not remove the container", [str(err)])
        servers.remove(server)
        save(players, servers)


    # ----------------------------------------------------------------------- play

    def address_of(server):
        if server["where"] == REMOTE:
            return "%s:%s" % (server["host"], server.get("port", 25565))
        if server["where"] == HYDROGEN:
            return "%s:%s" % (HYDROGEN_HOST, server["port"])
        return "127.0.0.1:%s" % server["port"]


    def main():
        players, servers = load()
        inp = Input()
        try:
            while True:
                player = choose_player(inp, players, servers)
                if player is None:
                    return 0
                server = choose_server(inp, players, servers)
                if server is None:
                    continue
                if server["where"] in (LOCAL, HYDROGEN):
                    if not wait_with_progress(inp, server):
                        continue
                    save(players, servers)
                break
        finally:
            # Releasing the pads matters: SDL has to open them when the game starts.
            inp.close()

        os.system("clear")
        argv = [MC_CLIENT, "--name", player, "--server", address_of(server)]
        os.execv(MC_CLIENT, argv)


    if __name__ == "__main__":
        try:
            sys.exit(main())
        except KeyboardInterrupt:
            os.system("clear")
            sys.exit(130)
  ''
