#!/usr/bin/env python3
"""Validated curses installer for this NixOS fleet."""

from __future__ import annotations

import argparse
import copy
import hashlib
import re
import socket
from contextlib import contextmanager
import curses
import json
import os
import pwd
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import textwrap
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable

from settings import Settings, DESKTOPS, keyboard_catalog, locale_catalog, nix_string
from storage import Disk, Filesystem, same_device, scan, storage_errors

SCRATCH = Path("/tmp/nixos-install")
TARGET = Path("/mnt")
UNSET_DEVICE = "/dev/disk/by-id/DISK-CONFIG-NOT-COMMITTED"
CHECKS = (
    "environment", "host", "system disk", "/home disk", "/data disk",
    "encryption", "root password", "sizes", "settings", "layout", "age key", "disko",
)


@dataclass
class Status:
    kind: str = "pending"
    summary: str = "not checked"

    @property
    def ready(self) -> bool:
        return self.kind in {"ok", "na"}

    @property
    def glyph(self) -> str:
        return {"pending": "·", "ok": "✓", "failed": "✗", "na": "○"}[self.kind]


@dataclass
class Facts:
    age_key_file: str
    sops_file: str
    root_password: str
    mutable_users: bool
    persist_ssh: bool

    @property
    def age_key_source(self) -> str:
        return "secrets/family-age-key.enc" if self.sops_file == "family.yaml" else "secrets/age-key.enc"


@dataclass
class Profile:
    host: str
    system_device: str = UNSET_DEVICE
    system_encrypt: bool = False
    esp_size: str = "1G"
    home_device: str | None = None
    home_encrypt: bool = False
    root_mode: str = "subvol"
    tmpfs_size: str = "6G"
    swap_size: str | None = None
    data_device: str | None = None
    data_fs_type: str = "btrfs"

    @classmethod
    def from_fleet(cls, host: str, value: dict) -> "Profile":
        system, home, data = value["system"], value["home"], value["data"]
        return cls(host, system.get("device") or UNSET_DEVICE, system["encrypt"], value["espSize"],
                   home.get("device"), home["encrypt"], value["rootMode"], value["tmpfsSize"],
                   value.get("swapSize"), data.get("device"), data["fsType"])

    def validate(self) -> list[str]:
        errors: list[str] = []
        if self.root_mode not in {"subvol", "tmpfs"}:
            errors.append("unknown root mode")
        if self.system_device == UNSET_DEVICE or not self.system_device:
            errors.append("no system disk selected")
        elif not self.system_device.startswith("/dev/disk/by-id/"):
            errors.append("system disk is not a by-id path")
        if self.home_device:
            if not self.home_device.startswith("/dev/disk/by-id/"):
                errors.append("/home disk is not a by-id path")
            if self.home_device == self.system_device:
                errors.append("/home disk and system disk are the same device")
        for label, value in (("ESP", self.esp_size), ("tmpfs", self.tmpfs_size if self.root_mode == "tmpfs" else "1G"), ("swap", self.swap_size)):
            if value is not None and not is_size(value):
                errors.append(f"{label} size {value!r} is not like 32G")
        return errors

    def to_nix(self) -> str:
        lines = [
            f"# {self.host}'s disks.", "{", "  fleet.disk = {", "    enable = true;",
            f"    system.device = {nix_string(self.system_device)};", f"    system.encrypt = {'true' if self.system_encrypt else 'false'};",
        ]
        if self.esp_size != "1G": lines.append(f'    espSize = "{self.esp_size}";')
        if self.home_device:
            lines += [f"    home.device = {nix_string(self.home_device)};", f"    home.encrypt = {'true' if self.home_encrypt else 'false'};"]
        lines.append(f'    rootMode = "{self.root_mode}";')
        if self.root_mode == "tmpfs" and self.tmpfs_size != "6G": lines.append(f'    tmpfsSize = "{self.tmpfs_size}";')
        if self.swap_size: lines.append(f'    swapSize = "{self.swap_size}";')
        if self.data_device:
            lines += [f"    data.device = {nix_string(self.data_device)};", f"    data.fsType = {nix_string(self.data_fs_type)};"]
        return "\n".join(lines + ["  };", "}", ""])


def is_size(value: str) -> bool:
    return len(value) > 1 and value[-1:] in "KMGTP" and value[:-1].isdigit() and int(value[:-1]) > 0


def child_env() -> dict[str, str]:
    """Avoid carrying the live ISO user's HOME into root-run Nix commands."""
    env = os.environ.copy()
    if os.geteuid() == 0:
        env["HOME"] = pwd.getpwuid(0).pw_dir
        # These paths commonly point into the ISO user's home too.
        env.pop("XDG_CACHE_HOME", None)
        env.pop("XDG_CONFIG_HOME", None)
    return env


def command(args: list[str], what: str, *, input_text: str | None = None) -> str:
    result = subprocess.run(args, input=input_text, text=True, capture_output=True, env=child_env())
    if result.returncode:
        detail = "\n".join(part for part in (result.stderr.strip(), result.stdout.strip()) if part)
        raise RuntimeError(f"{what} failed: {detail}")
    return result.stdout


def nix(repo: Path, args: list[str], what: str) -> str:
    return command(["nix", "--extra-experimental-features", "nix-command flakes", *args], what)


def local_flake(repo: Path) -> str:
    """Keep generated, intentionally untracked provisioning files in the flake source."""
    return f"path:{repo}"


def hosts(repo: Path) -> list[str]:
    text = nix(repo, ["eval", "--raw", f"{local_flake(repo)}#nixosConfigurations", "--apply", 'c: builtins.concatStringsSep "\\n" (builtins.attrNames c)'], "listing hosts")
    return [host for host in text.splitlines() if host]


def facts(repo: Path, host: str) -> Facts:
    apply = """c:
let bool = b: if b then "true" else "false";
    stores = builtins.attrValues (c.environment.persistence or { });
    persistSsh = builtins.any (s: builtins.any (d: (d.directory or d) == "/etc/ssh") (s.directories or [ ])) stores;
in ''
  ageKeyFile=${c.sops.age.keyFile}
  sopsFile=${builtins.baseNameOf (toString c.sops.defaultSopsFile)}
  rootPassword=${c.fleet.accounts.rootPassword}
  mutableUsers=${bool c.users.mutableUsers}
  persistSsh=${bool persistSsh}
''"""
    raw = nix(repo, ["eval", "--raw", f"{local_flake(repo)}#nixosConfigurations.{host}.config", "--apply", apply], "reading host facts")
    values = dict(line.split("=", 1) for line in raw.splitlines() if "=" in line)
    if "ageKeyFile" not in values: raise RuntimeError("no sops.age.keyFile in the host configuration")
    return Facts(values["ageKeyFile"], values.get("sopsFile", ""), values.get("rootPassword", "none"), values.get("mutableUsers", "true") == "true", values.get("persistSsh", "false") == "true")


def saved_choices() -> dict | None:
    if subprocess.run(["mountpoint", "-q", str(TARGET)], capture_output=True).returncode:
        return None
    path = TARGET / "persist/nixos-install/choices.json"
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) and value.get("version") == 1 else None
    except (OSError, ValueError):
        return None


def host_defaults(repo: Path, host: str) -> dict:
    apply = '''c: let
      u = c.users.users.${c.fleet.primaryUser};
      desktop = if c.fleet.desktop != "inherit" then c.fleet.desktop
        else if c.services.desktopManager.gnome.enable then "gnome"
        else if c.services.desktopManager.plasma6.enable then "plasma6"
        else "none";
    in {
      settings = {
        hostname = c.networking.hostName; username = c.fleet.primaryUser;
        full_name = u.description; locale = c.i18n.defaultLocale;
        region = c.i18n.extraLocaleSettings.LC_TIME or c.i18n.defaultLocale;
        timezone = c.time.timeZone;
        keyboard_model = c.services.xserver.xkb.model;
        keyboard_layout = c.services.xserver.xkb.layout;
        keyboard_variant = c.services.xserver.xkb.variant;
        inherit desktop;
        auto_login = c.services.displayManager.autoLogin.enable;
        allow_unfree = c.nixpkgs.config.allowUnfree or false;
      };
      users = builtins.attrNames c.users.users;
      disk = c.fleet.disk;
      rootType = c.fileSystems."/".fsType;
      rootOptions = c.fileSystems."/".options;
      systemDevice = c.fileSystems."/nix".device or c.fileSystems."/".device;
      homeDevice = c.fileSystems."/home".device or null;
      data = c.fileSystems."/data" or null;
      luks = c.boot.initrd.luks.devices;
      swap = map (s: { size = s.size or null; }) c.swapDevices;
      adminUser = c.fleet.adminUser;
      family = c.family.enable or false;
      persistentRoot = (c.environment.persistence or {}) != {};
    }'''
    return json.loads(nix(repo, ["eval", "--json", f"{local_flake(repo)}#nixosConfigurations.{host}.config", "--apply", apply], "reading installation defaults"))


def disk_for_mount(device: str | None, luks: dict, disks: list[Disk]) -> str | None:
    if not device:
        return None
    if device.startswith("/dev/mapper/"):
        device = luks.get(Path(device).name, {}).get("device", device)
    if not Path(device).exists():
        return None
    try:
        parents = json.loads(command(["lsblk", "-s", "-J", "-o", "NAME,TYPE", device], "identifying existing disk"))
        def walk(nodes):
            for node in nodes:
                if node["type"] == "disk":
                    yield node["name"]
                yield from walk(node.get("children", []))
        names = set(walk(parents["blockdevices"]))
        return next((d.by_id for d in disks if d.name in names), None) if len(names) == 1 else None
    except (RuntimeError, ValueError):
        return None


class Board:
    """Editable decisions. Background validation operates on an independent copy."""

    def __init__(self, repo: Path, host_names: list[str], selected: str | None = None, allow_writes: bool = True):
        self.repo, self.hosts, self.allow_writes = Path(repo), host_names, allow_writes
        saved = saved_choices()
        inferred = (saved or {}).get("profile", {}).get("host")
        if not inferred and socket.gethostname() in host_names:
            inferred = socket.gethostname()
        selected = selected or inferred or (host_names[0] if len(host_names) == 1 else None)
        self.host_index = host_names.index(selected) if selected in host_names else -1
        self.profile: Profile | None = None
        self.settings = Settings()
        self.facts: Facts | None = None
        self.base_facts: Facts | None = None
        self.disks: list[Disk] = []
        self.filesystems: list[Filesystem] = []
        self.reserved_users: set[str] = set()
        self.supports_tmpfs = False
        self.admin_user = "sheath"
        self.family = False
        self.luks_passphrase = self.age_passphrase = self.root_password = self.user_password = self.disko = ""
        self.stage: Path | None = None
        self.status = {name: Status() for name in CHECKS}

    @property
    def host(self) -> str:
        return self.hosts[self.host_index] if self.host_index >= 0 else ""

    def cleanup(self) -> None:
        if self.stage:
            shutil.rmtree(self.stage, ignore_errors=True)
            self.stage = None

    def set_status(self, name: str, kind: str, summary: str) -> None:
        self.status[name] = Status(kind, summary)

    def invalidate(self, *names: str) -> None:
        for name in names:
            self.status[name] = Status()

    def set_encryption(self, enabled: bool) -> None:
        if self.profile:
            self.profile.system_encrypt = self.profile.home_encrypt = enabled
            if not enabled:
                self.luks_passphrase = ""
            self.invalidate("layout", "encryption")
            self.check("encryption")

    def load_host(self) -> None:
        if not self.host:
            self.set_status("host", "failed", "choose a fleet profile")
            return
        try:
            defaults = host_defaults(self.repo, self.host)
            self.facts = self.base_facts = facts(self.repo, self.host)
            self.disks, self.filesystems = scan()
            profile = Profile.from_fleet(self.host, defaults["disk"])
            self.supports_tmpfs = defaults["persistentRoot"]
            if not defaults["disk"]["enable"]:
                profile.root_mode = "tmpfs" if defaults["rootType"] == "tmpfs" else "subvol"
                profile.system_encrypt = bool(defaults["luks"])
                profile.home_encrypt = profile.system_encrypt
                profile.system_device = disk_for_mount(defaults["systemDevice"], defaults["luks"], self.disks) or UNSET_DEVICE
                if defaults["homeDevice"] and defaults["homeDevice"] != defaults["systemDevice"]:
                    profile.home_device = disk_for_mount(defaults["homeDevice"], defaults["luks"], self.disks)
                for option in defaults["rootOptions"]:
                    if option.startswith("size="):
                        profile.tmpfs_size = option.removeprefix("size=")
                swap = next((s for s in defaults["swap"] if s.get("size")), None)
                if swap:
                    profile.swap_size = f"{swap['size']}M"
                if defaults["data"]:
                    profile.data_device = defaults["data"]["device"]
                    profile.data_fs_type = defaults["data"]["fsType"]
            values = {k: v for k, v in defaults["settings"].items() if v is not None}
            self.settings = Settings(**values)
            self.reserved_users = set(defaults["users"]) - {self.settings.username}
            self.admin_user = defaults["adminUser"]
            self.family = defaults["family"]
            saved = saved_choices()
            if saved and saved.get("profile", {}).get("host") == self.host:
                profile = Profile(**saved["profile"])
                self.settings = Settings(**saved["settings"])
            self.profile = profile
            if profile.system_device == UNSET_DEVICE:
                protected = next((fs.members for fs in self.filesystems if same_device(fs.path, profile.data_device)), set())
                candidates = [d for d in self.disks if d.automatic and d.path not in protected]
                if len(candidates) == 1:
                    profile.system_device = candidates[0].by_id
            self.set_status("host", "ok", self.host)
        except (RuntimeError, OSError, KeyError, TypeError, ValueError, subprocess.SubprocessError) as error:
            self.set_status("host", "failed", str(error))

    def resume_matches(self) -> bool:
        saved = saved_choices()
        if not saved or not self.profile or not partition_complete():
            return False
        original = saved.get("profile", {})
        if original.get("host") != self.host:
            return False
        # Any change to partitioning invalidates resume, including encryption and sizes.
        for key, value in asdict(self.profile).items():
            old = original.get(key)
            if key in {"system_device", "home_device", "data_device"}:
                if old != value and not same_device(old, value):
                    return False
            elif old != value:
                return False
        try:
            if set(saved.get("mount_uuids", {})) != {"/nix", "/home", "/boot", "/persist"}:
                return False
            for mount, uuid in saved["mount_uuids"].items():
                actual = command(["findmnt", "-rn", "-M", str(TARGET / mount.lstrip("/")), "-o", "UUID"], "checking resume mounts").strip()
                if not uuid or actual != uuid:
                    return False
                source = command(["findmnt", "-rn", "-M", str(TARGET / mount.lstrip("/")), "-o", "SOURCE"], "checking resume devices").strip().split("[", 1)[0]
                parent = disk_for_mount(source, {}, self.disks)
                selected = self.profile.home_device if mount == "/home" and self.profile.home_device else self.profile.system_device
                if not same_device(parent, selected):
                    return False
            return True
        except RuntimeError:
            return False

    def check_cheap(self) -> None:
        for name in CHECKS:
            if name not in {"layout", "age key", "disko"}:
                self.check(name)

    def check_all(self) -> None:
        if not self.profile:
            self.load_host()
        self.check_cheap()
        if not self.profile or not self.facts:
            return
        self.check("layout")
        self.check("age key")
        self.check("disko")

    def check(self, name: str) -> None:
        try:
            checker = {
                "environment": self.check_environment, "host": lambda: self.status["host"],
                "system disk": self.check_system_disk, "/home disk": self.check_home_disk,
                "/data disk": self.check_data_disk, "encryption": self.check_encryption,
                "root password": self.check_root_password, "sizes": self.check_sizes,
                "settings": self.check_settings, "layout": self.check_layout,
                "age key": self.check_age_key, "disko": self.check_disko,
            }[name]
            self.status[name] = checker()
        except (RuntimeError, OSError, KeyError, TypeError, ValueError, subprocess.SubprocessError) as error:
            self.set_status(name, "failed", str(error))

    def check_environment(self) -> Status:
        bad = []
        if os.geteuid() != 0:
            bad.append("not running as root")
        if not Path("/sys/firmware/efi").is_dir():
            bad.append("boot the installer in UEFI mode")
        if not (self.repo / "flake.nix").is_file() or not (self.repo / ".git").exists():
            bad.append("not a configuration checkout")
        for tool in ("nix", "nixos-install", "nixos-generate-config", "nixos-enter", "age", "age-plugin-batchpass", "mkpasswd", "lsblk"):
            if not shutil.which(tool):
                bad.append(f"{tool} is missing")
        return Status("failed", "; ".join(bad)) if bad else Status("ok", "UEFI and installation tools available")

    def describe(self, path: str) -> str | None:
        disk = next((d for d in self.disks if same_device(d.by_id, path) or same_device(d.path, path)), None)
        return disk.label if disk else None

    def check_system_disk(self) -> Status:
        if not self.profile:
            return Status()
        p = self.profile
        errors = storage_errors(self.disks, self.filesystems, p.system_device, p.home_device,
                                p.data_device, p.data_fs_type, resume=self.resume_matches(), target=str(TARGET))
        return Status("failed", "; ".join(errors)) if errors else Status("ok", self.describe(p.system_device))

    def check_home_disk(self) -> Status:
        if not self.profile:
            return Status()
        path = self.profile.home_device
        if not path:
            return Status("na", "on the system disk")
        if same_device(path, self.profile.system_device):
            return Status("failed", "same physical disk as system")
        return Status("ok", self.describe(path)) if self.describe(path) else Status("failed", "selected home disk is missing")

    def check_data_disk(self) -> Status:
        if not self.profile:
            return Status()
        if not self.profile.data_device:
            return Status("na", "none")
        fs = next((f for f in self.filesystems if same_device(f.path, self.profile.data_device)), None)
        if not fs or fs.fs_type != self.profile.data_fs_type:
            return Status("failed", "preserved filesystem is missing or its type changed")
        return Status("ok", fs.label)

    def check_encryption(self) -> Status:
        if not self.profile:
            return Status()
        if not (self.profile.system_encrypt or (self.profile.home_device and self.profile.home_encrypt)):
            return Status("ok", "off")
        return Status("ok", "LUKS2 passphrase supplied") if self.luks_passphrase else Status("failed", "enter the encryption passphrase")

    def password_exists(self, name: str) -> bool:
        return self.resume_matches() and (TARGET / "persist/secrets" / name).is_file()

    def check_root_password(self) -> Status:
        if not self.base_facts:
            return Status()
        policy = self.settings.root_password_mode
        needed = policy == "custom" or (policy == "inherit" and self.base_facts.root_password == "persist")
        if needed and not (self.root_password or self.password_exists("root-password")):
            return Status("failed", "enter the root recovery password")
        return Status("ok", policy)

    def check_sizes(self) -> Status:
        if not self.profile:
            return Status()
        p = self.profile
        errors = [e for e in p.validate() if "size" in e or "mode" in e]
        if p.root_mode == "tmpfs" and not self.supports_tmpfs:
            errors.append("this profile has no complete persistence configuration for a tmpfs root")
        if not errors:
            disk = next((d for d in self.disks if same_device(d.by_id, p.system_device)), None)
            def size(value):
                return int(value[:-1]) * 1024 ** ("KMGTP".index(value[-1]) + 1) if value else 0
            if disk and size(p.esp_size) + size(p.swap_size) + 8 * 1024**3 >= disk.size_bytes:
                errors.append("system disk needs space for EFI, swap and at least 8 GiB of system data")
        return Status("failed", "; ".join(errors)) if errors else Status("ok", f"EFI {p.esp_size}, swap {p.swap_size or 'none'}, root {p.root_mode}")

    def check_settings(self) -> Status:
        errors = self.settings.validate(self.reserved_users)
        if self.settings.user_password_mode == "custom" and not (self.user_password or self.password_exists("login-password")):
            errors.append("enter a login password")
        return Status("failed", "; ".join(errors)) if errors else Status("ok", "settings are valid")

    @property
    def provisioning_dir(self) -> Path:
        return (self.stage or self.repo) / "provisioning" / self.host

    def check_layout(self) -> Status:
        if not self.profile or not self.status["settings"].ready or not self.status["sizes"].ready:
            return Status("pending", "waiting for valid settings and sizes")
        if errors := self.profile.validate():
            return Status("pending", "; ".join(errors))
        self.cleanup()
        self.stage = Path(tempfile.mkdtemp(prefix="nixos-installer-"))
        shutil.copytree(self.repo, self.stage, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns(".git", "__pycache__", "result", "result-*", "provisioning", "target"))
        path = self.provisioning_dir
        path.mkdir(parents=True)
        (path / "disk.nix").write_text(self.profile.to_nix())
        (path / "settings.nix").write_text(self.settings.to_nix())
        (path / "default.nix").write_text(provisioning_module())
        hardware = command(["nixos-generate-config", "--show-hardware-config", "--no-filesystems"], "detecting hardware")
        (path / "hardware.nix").write_text(hardware)
        target = f"{local_flake(self.stage)}#nixosConfigurations.{self.host}.config.system.build"
        # Evaluating the entire derivation catches package/driver policy conflicts before ERASE.
        nix(self.stage, ["eval", "--raw", target + ".toplevel.drvPath"], "checking the complete system (including unfree software policy)")
        nix(self.stage, ["build", "--no-link", target + ".diskoScript"], "checking the partitioning script")
        validate_target_config(self.stage, self.host, self.profile)
        self.facts = facts(self.stage, self.host)
        return Status("ok", "system and partitioning configuration verified")

    def check_age_key(self) -> Status:
        if not self.facts:
            return Status()
        destination = TARGET / self.facts.age_key_file.lstrip("/")
        if self.resume_matches() and destination.is_file():
            key = destination
        else:
            key = None
        source = self.repo / self.facts.age_key_source
        if not key and not self.age_passphrase:
            return Status("failed", "enter the fleet secrets passphrase")
        with tempfile.TemporaryDirectory(prefix="installer-agecheck-") as directory:
            if not key:
                key = Path(directory) / "key"
                age_decrypt(source, key, self.age_passphrase)
            # Validate syntax and the public identity, without printing private key material.
            public = command(["age-keygen", "-y", str(key)], "checking the secrets key").strip()
            recipients = re.findall(r"recipient: (age1[0-9a-z]+)", (self.repo / "secrets" / self.facts.sops_file).read_text())
            if public not in recipients:
                return Status("failed", "this key is not a recipient of the selected profile secrets")
        return Status("ok", "fleet secrets key verified")

    def check_disko(self) -> Status:
        rev = nix(self.repo, ["eval", "--raw", "--impure", "--expr", f"(builtins.fromJSON (builtins.readFile {nix_string(str(self.repo / 'flake.lock'))})).nodes.disko.locked.rev"], "reading Disko version").strip()
        out = nix(self.repo, ["build", "--no-link", "--print-out-paths", f"github:nix-community/disko/{rev}"], "preparing disk tools")
        self.disko = f"{out.strip()}/bin/disko"
        return Status("ok", "disk tools ready")

    @property
    def ready(self) -> bool:
        return bool(self.stage and self.host and all(status.ready for status in self.status.values()))


@contextmanager
def keyboard_preview(settings):
    """Temporarily apply XKB choices on a Linux console, restoring even after Escape."""
    try:
        tty = os.ttyname(sys.stdin.fileno())
    except OSError:
        tty = ""
    if not re.fullmatch(r"/dev/tty[0-9]+", tty):
        yield "Live-session layout (selected layout preview requires a Linux console)"
        return
    original = command(["dumpkeys", "-C", tty], "saving console keyboard")
    keymap = command(["ckbcomp", "-model", settings.keyboard_model, "-layout", settings.keyboard_layout,
                      "-variant", settings.keyboard_variant], "compiling keyboard layout")
    try:
        command(["loadkeys", "-C", tty, "-"], "previewing keyboard", input_text=keymap)
        yield f"Test {settings.keyboard_layout}/{settings.keyboard_variant or 'default'}"
    finally:
        command(["loadkeys", "-C", tty, "-"], "restoring console keyboard", input_text=original)


def age_decrypt(source: Path, destination: Path, passphrase: str) -> None:
    """Decrypt a small secrets key without terminal prompts or logging its contents."""
    result = subprocess.run(
        ["age", "-d", "-j", "batchpass", str(source)],
        stdin=subprocess.DEVNULL, capture_output=True,
        env=child_env() | {"AGE_PASSPHRASE": passphrase, "AGE_PASSPHRASE_FD": ""},
    )
    if result.returncode:
        raise RuntimeError(f"age decrypt failed: {result.stderr.decode(errors='replace').strip()}")
    # Do not replace an existing key on failure or expose a new key before chmod.
    with os.fdopen(os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600), "wb") as output:
        os.fchmod(output.fileno(), 0o600)
        output.write(result.stdout)


def shell_quote(value: str) -> str: return "'" + value.replace("'", "'\\''") + "'"


@contextmanager
def luks_key(passphrase: str):
    """Expose the selected passphrase only while a Disko script needs it."""
    key = SCRATCH / "luks.key"
    created = False
    if passphrase:
        SCRATCH.mkdir(mode=0o700, exist_ok=True)
        if SCRATCH.is_symlink() or SCRATCH.stat().st_uid != os.geteuid():
            raise RuntimeError("unsafe encryption scratch directory")
        SCRATCH.chmod(0o700)
        # Refuse stale files/symlinks, and set permissions before writing any secret.
        with os.fdopen(os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
            created = True
            output.write(passphrase)
    try:
        yield
    finally:
        if created:
            key.unlink(missing_ok=True)


def provisioning_module() -> str:
    """The local overlay that combines generated disk and hardware facts."""
    return """{ lib, ... }:
{
  imports = lib.optionals (builtins.pathExists ./disk.nix) [ ./disk.nix ]
    ++ lib.optionals (builtins.pathExists ./hardware.nix) [ ./hardware.nix ]
    ++ lib.optionals (builtins.pathExists ./settings.nix) [ ./settings.nix ];
  fleet.hardware.isPlaceholder = lib.mkIf (builtins.pathExists ./hardware.nix) (lib.mkForce false);
}
"""


def validate_target_config(repo: Path, host: str, profile: Profile) -> None:
    """Reject a target flake that lost the generated disk or hardware modules."""
    apply = """c: {
  diskEnabled = c.fleet.disk.enable;
  placeholder = c.fleet.hardware.isPlaceholder;
  root = { inherit (c.fileSystems."/") device fsType; };
  boot = { inherit (c.fileSystems."/boot") device fsType; };
  home = { inherit (c.fileSystems."/home") device fsType; };
  luks = builtins.mapAttrs (_: d: { inherit (d) device keyFile; }) c.boot.initrd.luks.devices;
}"""
    value = json.loads(nix(repo, ["eval", "--json", f"{local_flake(repo)}#nixosConfigurations.{host}.config", "--apply", apply], "validating the target configuration"))
    expected_root_type = "tmpfs" if profile.root_mode == "tmpfs" else "btrfs"
    expected_root_device = "/dev/mapper/cryptroot" if profile.system_encrypt else "/dev/disk/by-partlabel/disk-system-root"
    expected_home_device = (
        expected_root_device if not profile.home_device
        else "/dev/mapper/crypthome" if profile.home_encrypt
        else "/dev/disk/by-partlabel/disk-home-home"
    )
    errors = []
    if not value["diskEnabled"]: errors.append("fleet.disk is disabled")
    if value["placeholder"]: errors.append("generated hardware is still marked as a placeholder")
    if value["root"]["fsType"] != expected_root_type: errors.append(f"/ is {value['root']['fsType']}, expected {expected_root_type}")
    if profile.root_mode != "tmpfs" and value["root"]["device"] != expected_root_device: errors.append(f"/ uses {value['root']['device']}, expected {expected_root_device}")
    if value["boot"] != {"device": "/dev/disk/by-partlabel/disk-system-ESP", "fsType": "vfat"}: errors.append("/boot is not Disko's system ESP")
    if value["home"]["device"] != expected_home_device: errors.append(f"/home uses {value['home']['device']}, expected {expected_home_device}")
    for name, enabled in (("cryptroot", profile.system_encrypt), ("crypthome", bool(profile.home_device and profile.home_encrypt))):
        luks = value["luks"].get(name)
        backing = f"/dev/disk/by-partlabel/disk-{'system-root' if name == 'cryptroot' else 'home-home'}"
        if enabled and (not luks or luks["device"] != backing or luks["keyFile"] is not None): errors.append(f"{name} will not prompt for the expected partition at boot")
        if not enabled and luks: errors.append(f"unexpected boot-time LUKS device {name}")
    if errors: raise RuntimeError("target configuration is not bootable: " + "; ".join(errors))


def stream(args: list[str], what: str, log: Callable[[str], None], input_text: str | None = None) -> None:
    process = subprocess.Popen(args, stdin=subprocess.PIPE if input_text is not None else None, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=child_env())
    if input_text is not None: process.stdin.write(input_text); process.stdin.close()
    assert process.stdout
    for line in process.stdout: log(line.rstrip())
    if process.wait(): raise RuntimeError(f"{what} failed ({process.returncode})")


def partition_complete() -> bool:
    """Whether the mounted target has recorded its destructive phase."""
    state = TARGET / "persist/nixos-install/state"
    return subprocess.run(["mountpoint", "-q", str(TARGET)], capture_output=True).returncode == 0 and state.is_file() and "partition" in state.read_text().splitlines()


def run_install(board: Board, log: Callable[[str], None]) -> None:
    if not board.allow_writes:
        raise RuntimeError("dry run cannot install")
    if not board.ready or not board.profile or not board.facts or not board.stage:
        raise RuntimeError("installation settings have not passed validation")
    context = board
    context.disks, context.filesystems = scan()
    context.check_cheap()
    if not context.ready:
        raise RuntimeError("devices or settings changed; review the failed checks")
    resume = context.resume_matches()
    if partition_complete() and not resume:
        raise RuntimeError("mounted installation does not match the selected profile and disks")
    state_dir = TARGET / "persist/nixos-install"
    admin = context.admin_user if context.family else context.settings.username
    dest = TARGET / "home" / admin / "nixos"
    choices = {"version": 1, "profile": asdict(context.profile), "settings": asdict(context.settings)}
    signature = hashlib.sha256(json.dumps(choices, sort_keys=True).encode()).hexdigest()

    def state_file() -> Path:
        return state_dir / "state"

    def marked(name: str) -> bool:
        return state_file().is_file() and name in state_file().read_text().splitlines()

    def mark(name: str) -> None:
        state_dir.mkdir(parents=True, exist_ok=True)
        completed = state_file().read_text().splitlines() if state_file().is_file() else []
        if name not in completed:
            state_file().write_text("\n".join([*completed, name]) + "\n")

    def phase(name: str, action: Callable[[], None]) -> None:
        log(f"== {name}")
        action()
        mark(name)

    if not resume:
        def partition() -> None:
            with luks_key(context.luks_passphrase):
                stream([context.disko, "--mode", "destroy,format,mount", "--yes-wipe-all-disks", "--flake", f"{local_flake(context.stage)}#{context.host}"], "partitioning", log)
            state_dir.mkdir(parents=True, exist_ok=True)
            choices["mount_uuids"] = {
                mount: command(["findmnt", "-rn", "-M", str(TARGET / mount.lstrip("/")), "-o", "UUID"], "recording installed filesystems").strip()
                for mount in ("/nix", "/home", "/boot", "/persist")
            }
            (state_dir / "choices.json").write_text(json.dumps(choices, indent=2) + "\n")
            (state_dir / "choices.json").chmod(0o600)
        phase("partition", partition)
    else:
        log("== partition (matching installation already mounted)")
        choices["mount_uuids"] = saved_choices()["mount_uuids"]

    def config() -> None:
        # Retain Git metadata for ordinary use, but stage only encrypted repository secrets.
        if dest.resolve() == context.repo.resolve() or context.repo.resolve().is_relative_to(dest.resolve()):
            raise RuntimeError("run the installer from outside the target checkout")
        shutil.rmtree(dest, ignore_errors=True)
        shutil.copytree(context.repo, dest, symlinks=True,
                        ignore=shutil.ignore_patterns("provisioning", "result", "result-*", "__pycache__", "target"))
        provision = dest / "provisioning" / context.host
        provision.mkdir(parents=True, exist_ok=True)
        for name in ("default.nix", "disk.nix", "settings.nix", "hardware.nix"):
            shutil.copyfile(context.provisioning_dir / name, state_dir / name)
            (state_dir / name).chmod(0o600)
            shutil.copyfile(state_dir / name, provision / name)
        validate_target_config(dest, context.host, context.profile)
        log("validated generated settings, disks and hardware in the target configuration")
        (state_dir / "choices.json").write_text(json.dumps(choices, indent=2) + "\n")
        (state_dir / "choices.json").chmod(0o600)

    def secrets() -> None:
        destination = TARGET / context.facts.age_key_file.lstrip("/")
        if not (resume and destination.is_file()):
            destination.parent.mkdir(parents=True, exist_ok=True)
            age_decrypt(context.repo / context.facts.age_key_source, destination, context.age_passphrase)
            destination.chmod(0o600)
        ssh_dir = TARGET / "etc/ssh"
        persistent_ssh_dir = TARGET / "persist/etc/ssh"
        key_specs = (("ed25519", "ssh_host_ed25519_key"), ("rsa", "ssh_host_rsa_key"))
        host_keys = [ssh_dir / name for _, name in key_specs]
        if not all(path.is_file() for path in host_keys):
            ssh_dir.mkdir(parents=True, exist_ok=True)
            for kind, name in key_specs:
                key = ssh_dir / name
                persistent = persistent_ssh_dir / name
                if context.facts.persist_ssh and persistent.is_file():
                    shutil.copy2(persistent, key)
                elif not key.exists():
                    stream(["ssh-keygen", "-t", kind, "-f", str(key), "-N", ""], "creating SSH host key", log)
        if context.facts.persist_ssh:
            persistent_ssh_dir.mkdir(parents=True, exist_ok=True)
            for _, name in key_specs:
                shutil.copy2(ssh_dir / name, persistent_ssh_dir / name)
        for name, password in (("login-password", context.user_password), ("root-password", context.root_password)):
            if password:
                path = TARGET / "persist/secrets" / name
                path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as output:
                    output.write(command(["mkpasswd", "-m", "sha-512", "--stdin"], "hashing password", input_text=password).rstrip() + "\n")
                path.chmod(0o600)

    phase("config", config)
    phase("secrets", secrets)
    previous = state_dir / "installed-settings"
    if not (marked("install-local-provisioning") and previous.is_file() and previous.read_text() == signature
            and not (context.user_password or context.root_password)
            and (TARGET / "nix/var/nix/profiles/system").is_symlink()):
        phase("install", lambda: stream(["nixos-install", "--root", str(TARGET), "--no-root-passwd", "--flake", f"{local_flake(dest)}#{context.host}"], "nixos-install", log))
        mark("install-local-provisioning")
        previous.write_text(signature)
    else:
        log("== install (identical settings already installed)")
    phase("finalize", lambda: stream(["nixos-enter", "--root", str(TARGET), "-c", f"chown -R {shell_quote(admin + ':' + admin)} {shell_quote('/home/' + admin)}"], "fixing home ownership", log))


class Tui:
    def __init__(self, board: Board):
        self.board, self.row, self.message = board, 0, "Checking defaults automatically"
        self.log = []
        self.events = queue.Queue()
        self.install_thread = self.validation_thread = None
        self.revision = 0
        self.current_phase = ""
        self.completed = False
        self.closed = False

    def rows(self):
        b, s, p = self.board, self.board.settings, self.board.profile
        rows = [("host", "Fleet profile", b.host or "choose a profile")]
        if p:
            rows += [(key, label, getattr(s, key)) for key, label in (
                ("hostname", "Computer name"), ("locale", "Language"), ("region", "Regional format"),
                ("timezone", "Time zone"), ("keyboard_model", "Keyboard model"),
                ("keyboard_layout", "Keyboard layout"), ("keyboard_variant", "Keyboard variant"),
                ("username", "Login name"), ("full_name", "Full name"),
                ("user_password_mode", "Login password"), ("root_password_mode", "Root password"),
                ("auto_login", "Automatic login"), ("desktop", "Desktop"), ("allow_unfree", "Allow unfree software"))]
            rows += [("keyboard_test", "Keyboard typing test", "Enter to test (console previews selected layout)")]
            rows += [(key, label, getattr(p, key) or "none") for key, label in (
                ("system_device", "System disk (ERASE)"), ("home_device", "Separate /home disk (ERASE)"),
                ("data_device", "Preserve /data filesystem"), ("system_encrypt", "Encrypt system"),
                ("home_encrypt", "Encrypt separate /home"), ("root_mode", "Root filesystem"),
                ("esp_size", "EFI partition size"), ("swap_size", "Swap file size"), ("tmpfs_size", "Tmpfs root size"))]
            rows += [("luks_passphrase", "Encryption passphrase", "supplied" if b.luks_passphrase else "not supplied"),
                     ("age_passphrase", "Fleet secrets passphrase", "supplied" if b.age_passphrase else "not supplied")]
        rows += [("check:" + name, name, f"{status.glyph} {status.summary}") for name, status in b.status.items()]
        return rows

    def run(self, screen):
        curses.curs_set(0)
        screen.keypad(True)
        screen.timeout(150)
        self.start_validation()
        try:
            while True:
                self.pump()
                self.draw(screen)
                try:
                    key = screen.get_wch()
                except curses.error:
                    continue
                if self.install_thread and self.install_thread.is_alive():
                    continue
                if key in ("q", "Q") or (self.completed and key == "\n"):
                    return
                if key in (curses.KEY_UP, "k"):
                    self.row = max(0, self.row - 1)
                elif key in (curses.KEY_DOWN, "j"):
                    self.row = min(len(self.rows()) - 1, self.row + 1)
                elif key in ("v", "V"):
                    self.changed()
                elif key in ("r", "R"):
                    self.start_install(screen)
                elif key in ("m", "M"):
                    self.remount()
                elif key in ("\n", curses.KEY_ENTER, " "):
                    self.edit(screen, self.rows()[self.row][0])
        finally:
            self.closed = True
            self.board.cleanup()

    @staticmethod
    def add(screen, y, x, text, style=0):
        try:
            screen.addnstr(y, x, str(text), max(0, screen.getmaxyx()[1] - x - 1), style)
        except curses.error:
            pass

    def draw(self, screen):
        screen.erase()
        height, width = screen.getmaxyx()
        state = "COMPLETE" if self.completed else "CHECKING" if self.validation_thread else "READY" if self.board.ready else "NEEDS ATTENTION"
        self.add(screen, 0, 0, f"NixOS installer | {self.board.host} | {state}", curses.A_BOLD)
        rows = self.rows()
        self.row = min(self.row, len(rows) - 1)
        count = max(1, height - 5)
        start = max(0, min(self.row - count // 2, len(rows) - count))
        for i, (_, label, value) in enumerate(rows[start:start + count]):
            self.add(screen, i + 2, 0, f"{label:<31} {value}", curses.A_REVERSE if start + i == self.row else 0)
        if self.install_thread:
            for i, line in enumerate(self.log[-count:]):
                self.add(screen, i + 2, 0, " " * (width - 1))
                self.add(screen, i + 2, 0, line)
        self.add(screen, height - 2, 0, self.message.replace("\n", " "))
        self.add(screen, height - 1, 0, "j/k move | Enter edit/details | automatic checks | v recheck | m mount existing | r install | q exit")
        screen.refresh()

    def prompt(self, screen, label, secret=False, initial=""):
        value = list(initial)
        curses.curs_set(1)
        screen.timeout(-1)
        try:
            while True:
                height, width = screen.getmaxyx()
                self.add(screen, height - 1, 0, " " * (width - 1))
                self.add(screen, height - 1, 0, f"{label}: " + ("*" * len(value) if secret else "".join(value)))
                screen.refresh()
                key = screen.get_wch()
                if key == "\x1b": return None
                if key in ("\n", curses.KEY_ENTER): return "".join(value)
                if key in (curses.KEY_BACKSPACE, "\b", "\x7f"):
                    if value: value.pop()
                elif key == "\x15": value.clear()
                elif isinstance(key, str) and key.isprintable(): value.append(key)
        finally:
            curses.curs_set(0)
            screen.timeout(150)

    def choose(self, screen, label, options, current=None):
        visible = list(range(len(options)))
        index = options.index(current) if current in options else 0
        screen.timeout(-1)
        try:
            while True:
                screen.erase()
                height, _ = screen.getmaxyx()
                self.add(screen, 0, 0, label + " (arrows, / filter, Enter; Esc cancels)")
                count = max(1, height - 2)
                start = max(0, min(index - count // 2, len(visible) - count))
                for i, original in enumerate(visible[start:start + count]):
                    self.add(screen, i + 1, 0, options[original], curses.A_REVERSE if start + i == index else 0)
                screen.refresh()
                key = screen.get_wch()
                if key == "\x1b": return None
                if key in ("\n", curses.KEY_ENTER) and visible: return visible[index]
                if key == "/":
                    query = self.prompt(screen, "Filter (blank shows all)")
                    screen.timeout(-1)
                    if query is not None:
                        visible = [i for i, option in enumerate(options) if query.casefold() in option.casefold()]
                        index = 0
                if visible:
                    if key in (curses.KEY_UP, "k"): index = (index - 1) % len(visible)
                    if key in (curses.KEY_DOWN, "j"): index = (index + 1) % len(visible)
        finally:
            screen.timeout(150)
            self.draw(screen)

    def password(self, screen, label, confirm=True):
        first = self.prompt(screen, label, True)
        if first is None: return None
        if confirm and first != self.prompt(screen, "Confirm " + label, True):
            self.message = "Passwords did not match; no change made"
            return None
        return first

    def edit(self, screen, name):
        b = self.board
        if name.startswith("check:"):
            summary = b.status[name[6:]].summary
            self.choose(screen, name[6:], summary.splitlines() or ["No details"])
            return
        if name == "host":
            choice = self.choose(screen, "Fleet profile", b.hosts, b.host)
            if choice is not None and choice != b.host_index:
                b.cleanup()
                self.board = Board(b.repo, b.hosts, b.hosts[choice], b.allow_writes)
                self.changed()
            return
        if not b.profile: return
        if name == "keyboard_test":
            try:
                with keyboard_preview(b.settings) as label:
                    self.prompt(screen, label)
            except (RuntimeError, OSError) as error:
                self.message = str(error)
            return
        if name in {"age_passphrase", "luks_passphrase"}:
            value = self.password(screen, name.replace("_", " "), name != "age_passphrase")
            if value is not None:
                setattr(b, name, value)
                self.changed()
            return
        if name in {"system_device", "home_device", "data_device"}:
            items = b.filesystems if name == "data_device" else b.disks
            paths = [f.path for f in items] if name == "data_device" else [d.by_id for d in items]
            labels = ["none"] + [item.label for item in items]
            current = getattr(b.profile, name)
            selected = next((labels[i + 1] for i, path in enumerate(paths) if same_device(path, current)), "none")
            choice = self.choose(screen, name, labels, selected)
            if choice is None: return
            value = paths[choice - 1] if choice else None
            if choice and not value:
                self.message = "Disk has no stable by-id path"
                return
            setattr(b.profile, name, value or (UNSET_DEVICE if name == "system_device" else None))
            if choice and name == "data_device": b.profile.data_fs_type = items[choice - 1].fs_type
            self.changed()
            return
        target = b.settings if hasattr(b.settings, name) else b.profile
        old = getattr(target, name)
        options = None
        if isinstance(old, bool): options = [False, True]
        elif name == "desktop": options = list(DESKTOPS)
        elif name in {"locale", "region"}: options = locale_catalog()
        elif name == "timezone":
            from zoneinfo import available_timezones
            options = sorted(available_timezones())
        elif name == "root_mode": options = ["subvol", "tmpfs"]
        elif name == "user_password_mode": options = ["inherit", "custom"]
        elif name == "root_password_mode": options = ["inherit", "user", "locked", "custom"]
        elif name.startswith("keyboard_"):
            try:
                models, layouts = keyboard_catalog()
                options = sorted(models if name == "keyboard_model" else layouts if name == "keyboard_layout" else layouts.get(b.settings.keyboard_layout, {""}))
            except OSError as error:
                self.message = str(error)
                return
        if options is not None:
            choice = self.choose(screen, name, [str(v) or "default" for v in options], str(old) or "default")
            if choice is None: return
            value = options[choice]
        else:
            value = self.prompt(screen, name + " (Ctrl-U clears)", initial=str(old or ""))
            if value is None: return
        if name in {"user_password_mode", "root_password_mode"} and (value == "custom" or (name == "root_password_mode" and value == "inherit" and b.base_facts.root_password == "persist")):
            password = self.password(screen, "Login password" if name == "user_password_mode" else "Root password")
            if password is None: return
            setattr(b, "user_password" if name == "user_password_mode" else "root_password", password)
        setattr(target, name, value or None if name == "swap_size" else value)
        if name == "keyboard_layout": b.settings.keyboard_variant = ""
        if name == "desktop" and value == "none": b.settings.auto_login = False
        if name == "user_password_mode" and value != "custom": b.user_password = ""
        if name == "root_password_mode" and value not in {"custom", "inherit"}: b.root_password = ""
        self.changed()

    def changed(self):
        self.revision += 1
        self.board.invalidate(*(name for name in CHECKS if name != "host"))
        self.message = "Checking edited settings automatically"
        if not self.validation_thread: self.start_validation()

    def start_validation(self):
        revision = self.revision
        snapshot = copy.deepcopy(self.board)
        snapshot.stage = None
        def validate():
            event = "validated"
            try:
                if not snapshot.profile:
                    snapshot.load_host()
                    if snapshot.profile:
                        event = "loaded"
                    else:
                        snapshot.check_cheap()
                else:
                    snapshot.disks, snapshot.filesystems = scan()
                    snapshot.check_all()
            except Exception as error:
                snapshot.set_status("environment", "failed", str(error))
            if self.closed:
                snapshot.cleanup()
            else:
                self.events.put((event, (revision, snapshot)))
        self.validation_thread = threading.Thread(target=validate, daemon=True)
        self.validation_thread.start()

    def remount(self):
        if self.validation_thread or not self.board.stage or not self.board.status["layout"].ready or not self.board.status["encryption"].ready or not self.board.disko:
            self.message = "Select the existing layout and wait for its configuration check before mounting"
            return
        b = self.board
        def mount():
            try:
                with luks_key(b.luks_passphrase):
                    command([b.disko, "--mode", "mount", "--flake", f"{local_flake(b.stage)}#{b.host}"], "mounting existing installation")
                if not saved_choices():
                    raise RuntimeError("Mounted target has no saved installation choices")
                self.events.put(("mounted", ""))
            except Exception as error:
                self.events.put(("failed", str(error)))
        self.message = "Mounting existing filesystems"
        self.install_thread = threading.Thread(target=mount, daemon=True)
        self.install_thread.start()

    def start_install(self, screen):
        if self.validation_thread or not self.board.ready:
            self.message = "Resolve failed checks before installing"
            return
        if not self.board.resume_matches():
            p = self.board.profile
            disks = [path for path in (p.system_device, p.home_device) if path]
            screen.erase()
            height, width = screen.getmaxyx()
            lines = ["These disks and ALL their contents will be erased:"]
            for path in disks:
                lines += textwrap.wrap(path + " — " + (self.board.describe(path) or ""), max(20, width - 2))
            lines += textwrap.wrap("Preserved /data: " + (p.data_device or "none"), max(20, width - 2))
            if len(lines) + 3 > height:
                self.message = "Enlarge the terminal to display every disk before confirming"
                return
            for i, line in enumerate(lines): self.add(screen, i + 1, 0, line)
            if self.prompt(screen, "Type ERASE to erase every disk listed above") != "ERASE": return
        self.log.clear()
        self.message = "Installing"
        def install():
            try:
                run_install(self.board, lambda line: self.events.put(("log", line)))
                self.events.put(("done", "Installed. Remove installation media and reboot."))
            except Exception as error:
                self.events.put(("failed", str(error)))
        self.install_thread = threading.Thread(target=install, daemon=True)
        self.install_thread.start()

    def pump(self):
        while True:
            try: kind, value = self.events.get_nowait()
            except queue.Empty: return
            if kind in {"loaded", "validated"}:
                revision, snapshot = value
                self.validation_thread = None
                if revision == self.revision:
                    self.board.cleanup()
                    self.board = snapshot
                    if kind == "loaded":
                        self.message = "Defaults loaded; checking the system in the background"
                        self.start_validation()
                    else:
                        self.message = "Ready to install" if snapshot.ready else "Review failed checks below the settings"
                else:
                    snapshot.cleanup()
                    self.start_validation()
            elif kind == "mounted":
                old = self.board
                self.board = Board(old.repo, old.hosts, old.host, old.allow_writes)
                self.board.luks_passphrase = old.luks_passphrase
                self.board.age_passphrase = old.age_passphrase
                old.cleanup()
                self.install_thread = None
                self.changed()
            elif kind == "log": self.log.append(value)
            elif kind == "done":
                self.completed = True
                self.current_phase = "complete"
                self.message = value
            else:
                self.current_phase = "failed"
                self.message = value
                self.log.append(value)


def dry_run(board: Board) -> int:
    board.load_host(); board.check_all(); print(f"host: {board.host}\n")
    for name in CHECKS: print(f"{board.status[name].glyph} {name:<14} {board.status[name].summary}")
    print("\nNo source or target files changed; checks use temporary files and the Nix store.")
    result = 0 if board.ready else 1
    board.cleanup()
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path("."), help="configuration flake (default: current directory)")
    parser.add_argument("--host", help="preselect a host")
    parser.add_argument("--dry-run", action="store_true", help="validate without changing anything")
    parser.add_argument("--list-hosts", action="store_true", help="print flake hosts")
    args = parser.parse_args(); repo = args.repo.resolve()
    try:
        host_names = hosts(repo)
        if args.list_hosts: print("\n".join(host_names)); return 0
        if not host_names: raise RuntimeError("the flake defines no hosts")
        if args.host and args.host not in host_names: raise RuntimeError(f"no such host: {args.host}")
        board = Board(repo, host_names, args.host, not args.dry_run)
        if args.dry_run: return dry_run(board)
        if os.geteuid() != 0: raise RuntimeError("the installer must run as root")
        curses.wrapper(Tui(board).run); return 0
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr); return 1


if __name__ == "__main__": raise SystemExit(main())
