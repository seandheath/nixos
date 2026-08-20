# Valheim on Hydrogen

The private server is `Hydrogen`, its world is `family`, and it listens only on the family
and admin WireGuard interfaces. Family clients connect to `10.41.0.1:2456`; sulfur can
also test `10.42.0.2:2456`. It is deliberately absent from the public server list.

## Client setup

1. Open r2modman and select Valheim.
2. Create a profile named `Hydrogen`.
3. In Settings, import the local mod `/etc/valheim/Hydrogen-Mostly-Vanilla-1.0.0.zip`.
4. Launch with **Start modded**. Do not update individual mods: the checked-in profile and
   server must move together.

## Server operations

```console
systemctl status valheim
journalctl -u valheim -f
sudo systemctl restart valheim
sudo systemctl start valheim-update
```

`valheim-update` is the only normal update path. It stops cleanly (which creates a local
backup), marks the next start for a staged SteamCMD update, and starts the service. The
container image and mod versions remain pinned by Nix, so change those in the same commit
as the client manifest. Keep them frozen across Valheim 1.0 until compatibility is tested.

World data and seven days of hourly/shutdown snapshots live under `/var/lib/valheim` and
are included in all three Borg jobs. Restore only while `valheim.service` is stopped.
