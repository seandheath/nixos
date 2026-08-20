#!/usr/bin/env python3
"""Validated curses installer for this NixOS fleet."""

from __future__ import annotations

import argparse
import curses
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

BY_ID = Path("/dev/disk/by-id")
SCRATCH = Path("/tmp/nixos-install")
TARGET = Path("/mnt")
UNSET_DEVICE = "/dev/disk/by-id/DISK-CONFIG-NOT-COMMITTED"
CHECKS = (
    "environment", "host", "system disk", "/home disk", "/data disk",
    "encryption", "root password", "sizes", "layout", "age key", "disko",
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
class Disk:
    name: str
    size: str
    model: str
    serial: str
    by_id: str | None

    @property
    def label(self) -> str:
        return f"{self.name:<12} {self.size:>8}  {self.model or 'unknown'}"


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
            f'    system.device = "{self.system_device}";', f"    system.encrypt = {'true' if self.system_encrypt else 'false'};",
        ]
        if self.esp_size != "1G": lines.append(f'    espSize = "{self.esp_size}";')
        if self.home_device:
            lines += [f'    home.device = "{self.home_device}";', f"    home.encrypt = {'true' if self.home_encrypt else 'false'};"]
        lines.append(f'    rootMode = "{self.root_mode}";')
        if self.root_mode == "tmpfs" and self.tmpfs_size != "6G": lines.append(f'    tmpfsSize = "{self.tmpfs_size}";')
        if self.swap_size: lines.append(f'    swapSize = "{self.swap_size}";')
        if self.data_device:
            lines += [f'    data.device = "{self.data_device}";', f'    data.fsType = "{self.data_fs_type}";']
        return "\n".join(lines + ["  };", "}", ""])


def is_size(value: str) -> bool:
    return len(value) > 1 and value[-1:] in "KMGTP" and value[:-1].isdigit()


def command(args: list[str], what: str, *, input_text: str | None = None) -> str:
    result = subprocess.run(args, input=input_text, text=True, capture_output=True)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"{what} failed: {detail}")
    return result.stdout


def nix(repo: Path, args: list[str], what: str) -> str:
    return command(["nix", "--extra-experimental-features", "nix-command flakes", *args], what)


def hosts(repo: Path) -> list[str]:
    text = nix(repo, ["eval", "--raw", f"{repo}#nixosConfigurations", "--apply", 'c: builtins.concatStringsSep "\\n" (builtins.attrNames c)'], "listing hosts")
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
    raw = nix(repo, ["eval", "--raw", f"{repo}#nixosConfigurations.{host}.config", "--apply", apply], "reading host facts")
    values = dict(line.split("=", 1) for line in raw.splitlines() if "=" in line)
    if "ageKeyFile" not in values: raise RuntimeError("no sops.age.keyFile in the host configuration")
    return Facts(values["ageKeyFile"], values.get("sopsFile", ""), values.get("rootPassword", "none"), values.get("mutableUsers", "true") == "true", values.get("persistSsh", "false") == "true")


def fleet_disk(repo: Path, host: str) -> dict:
    return json.loads(nix(repo, ["eval", "--json", f"{repo}#nixosConfigurations.{host}.config.fleet.disk"], "reading fleet.disk"))


def list_disks() -> list[Disk]:
    data = json.loads(command(["lsblk", "-d", "-J", "-o", "NAME,SIZE,MODEL,SERIAL,TYPE"], "listing disks"))
    result = []
    for disk in data["blockdevices"]:
        if disk.get("type") != "disk": continue
        dev = Path("/dev") / disk["name"]
        result.append(Disk(disk["name"], disk.get("size") or "", (disk.get("model") or "").strip(), disk.get("serial") or "", by_id_for(dev)))
    return result


def by_id_for(device: Path) -> str | None:
    try: target = device.resolve(strict=True)
    except OSError: return None
    fallback = None
    for link in BY_ID.iterdir() if BY_ID.is_dir() else ():
        try: matches = link.resolve(strict=True) == target
        except OSError: continue
        if matches:
            if link.name.startswith(("wwn-", "nvme-eui.")): fallback = str(link)
            else: return str(link)
    return fallback


class Board:
    """Installer decisions and the validation status for each decision."""

    def __init__(self, repo: Path, host_names: list[str], selected: str | None = None, allow_writes: bool = True):
        self.repo, self.hosts, self.allow_writes = repo, host_names, allow_writes
        self.host_index = host_names.index(selected) if selected else 0
        self.profile: Profile | None = None
        self.facts: Facts | None = None
        self.disks: list[Disk] = []
        self.luks_passphrase = self.age_passphrase = self.root_password = self.disko = ""
        self.status = {name: Status() for name in CHECKS}

    @property
    def host(self) -> str: return self.hosts[self.host_index]

    def set_status(self, name: str, kind: str, summary: str) -> None: self.status[name] = Status(kind, summary)

    def invalidate(self, *names: str) -> None:
        for name in names: self.status[name] = Status()

    def set_encryption(self, enabled: bool) -> None:
        """Apply the fleet's shared-LUKS policy and invalidate the layout."""
        if not self.profile:
            return
        self.profile.system_encrypt = enabled
        self.profile.home_encrypt = enabled
        if not enabled:
            self.luks_passphrase = ""
        self.invalidate("layout")
        self.check("encryption")

    def load_host(self) -> None:
        try:
            profile = Profile.from_fleet(self.host, fleet_disk(self.repo, self.host))
            self.facts, self.disks = facts(self.repo, self.host), list_disks()
            if profile.system_device == UNSET_DEVICE:
                profile.system_device = next((d.by_id for d in self.disks if d.by_id), UNSET_DEVICE)
            self.profile = profile
            source = "family" if self.facts.sops_file == "family.yaml" else "fleet"
            self.set_status("host", "ok", f"{source} · {'passwd after install' if self.facts.mutable_users else 'declarative passwords'}")
            self.invalidate("layout", "age key", "root password", "encryption")
            self.check_cheap()
        except (RuntimeError, OSError, KeyError, json.JSONDecodeError) as error:
            self.set_status("host", "failed", str(error))

    def check_cheap(self) -> None:
        for name in CHECKS:
            if name not in {"layout", "age key", "disko"}: self.check(name)

    def check_all(self) -> None:
        for name in CHECKS: self.check(name)

    def check(self, name: str) -> None:
        try:
            checker = {
                "environment": self.check_environment,
                "host": self.check_host,
                "system disk": self.check_system_disk,
                "/home disk": self.check_home_disk,
                "/data disk": self.check_data_disk,
                "encryption": self.check_encryption,
                "root password": self.check_root_password,
                "sizes": self.check_sizes,
                "layout": self.check_layout,
                "age key": self.check_age_key,
                "disko": self.check_disko,
            }[name]
            self.status[name] = checker()
        except (RuntimeError, OSError, KeyError, json.JSONDecodeError) as error:
            self.set_status(name, "failed", str(error))

    def check_environment(self) -> Status:
        bad = []
        if os.geteuid() != 0: bad.append("not running as root")
        if not Path("/sys/firmware/efi").is_dir(): bad.append("not booted in UEFI mode")
        if not (self.repo / "flake.nix").is_file(): bad.append("not the configuration repository")
        if not (self.repo / ".git").is_dir(): bad.append("not a git checkout")
        if not shutil.which("script"): bad.append("script(1) is missing")
        if not (shutil.which("age") or shutil.which("rage")): bad.append("neither age nor rage is on PATH")
        return Status("failed", "; ".join(bad)) if bad else Status("ok", "root · UEFI · git checkout")

    def check_host(self) -> Status: return self.status["host"]

    def describe(self, path: str) -> str | None:
        disk = next((d for d in self.disks if d.by_id == path), None)
        return f"{disk.name}  {disk.size}  {Path(path).name}" if disk else None

    def check_system_disk(self) -> Status:
        if not self.profile: return Status()
        path = self.profile.system_device
        if path == UNSET_DEVICE: return Status("failed", "no system disk selected")
        if not path.startswith("/dev/disk/by-id/"): return Status("failed", "not a by-id path")
        return Status("ok", self.describe(path)) if self.describe(path) else Status("failed", f"{path} is not present")

    def check_home_disk(self) -> Status:
        if not self.profile: return Status()
        path = self.profile.home_device
        if not path: return Status("na", "/home is a system-disk subvolume")
        if path == self.profile.system_device: return Status("failed", "same device as system disk")
        return Status("ok", self.describe(path)) if self.describe(path) else Status("failed", f"{path} is not present")

    def check_data_disk(self) -> Status:
        if not self.profile: return Status()
        if not self.profile.data_device: return Status("na", "none")
        output = subprocess.run(["blkid", "-s", "TYPE", "-o", "value", self.profile.data_device], text=True, capture_output=True)
        return Status("ok", f"{self.profile.data_device} ({output.stdout.strip()}, preserved)") if output.returncode == 0 and output.stdout.strip() else Status("failed", "no filesystem found")

    def check_encryption(self) -> Status:
        if not self.profile: return Status()
        if not self.profile.system_encrypt: return Status("ok", "off")
        if not self.luks_passphrase: return Status("failed", "LUKS2 selected but no passphrase set")
        volumes = 1 + int(bool(self.profile.home_device and self.profile.home_encrypt))
        return Status("ok", f"LUKS2, passphrase set ({volumes} volume{'s' if volumes > 1 else ''})")

    def check_root_password(self) -> Status:
        if not self.facts: return Status()
        if self.facts.root_password != "persist": return Status("na", f"from {self.facts.root_password}")
        return Status("ok", "set") if self.root_password else Status("failed", "this host reads /persist/secrets/root-password")

    def check_sizes(self) -> Status:
        if not self.profile: return Status()
        errors = self.profile.validate()
        errors = [error for error in errors if "size" in error]
        if errors: return Status("failed", "; ".join(errors))
        return Status("ok", f"ESP {self.profile.esp_size} · swap {self.profile.swap_size or 'none'} · root {self.profile.root_mode}")

    def check_layout(self) -> Status:
        if not self.profile: return Status()
        if errors := self.profile.validate(): return Status("failed", "; ".join(errors))
        if not self.allow_writes: return Status("ok", "valid; not built (dry run)")
        path = self.provisioning_dir / "disk.nix"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.profile.to_nix())
        (self.provisioning_dir / "default.nix").write_text(provisioning_module())
        nix(self.repo, ["build", "--no-link", "--print-out-paths", f"path:{self.repo}#nixosConfigurations.{self.host}.config.system.build.diskoScript"], "building the partitioning script")
        return Status("ok", "disko accepts the layout")

    @property
    def provisioning_dir(self) -> Path:
        return self.repo / "provisioning" / self.host

    def check_age_key(self) -> Status:
        if not self.facts: return Status()
        source = self.repo / self.facts.age_key_source
        if not source.is_file(): return Status("failed", f"{source} is missing")
        if not self.age_passphrase: return Status("failed", f"passphrase for {self.facts.age_key_source} not set")
        with tempfile.NamedTemporaryFile(prefix="installer-agecheck-", delete=False) as temp: probe = Path(temp.name)
        try:
            age_decrypt(source, probe, self.age_passphrase)
            return Status("ok", f"{self.facts.age_key_source} decrypts") if "AGE-SECRET-KEY" in probe.read_text() else Status("failed", "decrypted result is not an age key")
        finally: probe.unlink(missing_ok=True)

    def check_disko(self) -> Status:
        rev = nix(self.repo, ["eval", "--raw", "--impure", "--expr", f"(builtins.fromJSON (builtins.readFile {self.repo}/flake.lock)).nodes.disko.locked.rev"], "reading locked disko revision").strip()
        out = nix(self.repo, ["build", "--no-link", "--print-out-paths", f"github:nix-community/disko/{rev}"], "building disko")
        self.disko = f"{out.strip()}/bin/disko"
        return Status("ok", "built from the locked revision")

    @property
    def ready(self) -> bool: return all(status.ready for status in self.status.values())


def age_decrypt(source: Path, destination: Path, passphrase: str) -> None:
    tool = "rage" if shutil.which("rage") and not shutil.which("age") else "age"
    inner = f"{tool} -d -o {shell_quote(str(destination))} {shell_quote(str(source))}"
    command(["script", "-qec", inner, "/dev/null"], "age decrypt", input_text=passphrase + "\n")
    if not destination.is_file(): raise RuntimeError("age produced no output; the passphrase is probably wrong")


def shell_quote(value: str) -> str: return "'" + value.replace("'", "'\\''") + "'"


def provisioning_module() -> str:
    """The local overlay that combines generated disk and hardware facts."""
    return """{ lib, ... }:
{
  imports = lib.optionals (builtins.pathExists ./disk.nix) [ ./disk.nix ]
    ++ lib.optionals (builtins.pathExists ./hardware.nix) [ ./hardware.nix ];
  fleet.hardware.isPlaceholder = lib.mkIf (builtins.pathExists ./hardware.nix) (lib.mkForce false);
}
"""


def stream(args: list[str], what: str, log: Callable[[str], None], input_text: str | None = None) -> None:
    process = subprocess.Popen(args, stdin=subprocess.PIPE if input_text is not None else None, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if input_text is not None: process.stdin.write(input_text); process.stdin.close()
    assert process.stdout
    for line in process.stdout: log(line.rstrip())
    if process.wait(): raise RuntimeError(f"{what} failed ({process.returncode})")


def partition_complete() -> bool:
    """Whether the mounted target has recorded its destructive phase."""
    state = TARGET / "persist/nixos-install/state"
    return subprocess.run(["mountpoint", "-q", str(TARGET)], capture_output=True).returncode == 0 and state.is_file() and "partition" in state.read_text().splitlines()


def run_install(board: Board, log: Callable[[str], None]) -> None:
    assert board.profile and board.facts
    context = board
    def state_file() -> Path: return TARGET / "persist/nixos-install/state"
    def marked(name: str) -> bool: return name in state_file().read_text().splitlines() if state_file().is_file() else False
    def mark(name: str) -> None:
        state_file().parent.mkdir(parents=True, exist_ok=True)
        completed = state_file().read_text().splitlines() if state_file().is_file() else []
        if name not in completed: state_file().write_text("\n".join([*completed, name]) + "\n")
    def done(name: str) -> bool:
        if name == "partition": return partition_complete() and marked(name)
        if name == "hardware":
            path = TARGET / "persist/nixos-install/hardware.nix"
            return path.is_file() and path.stat().st_size > 0
        if name == "config":
            source, copy = context.provisioning_dir / "disk.nix", TARGET / "home/sheath/nixos" / "provisioning" / context.host / "disk.nix"
            return (TARGET / "home/sheath/nixos/flake.nix").is_file() and source.is_file() and copy.is_file() and source.read_bytes() == copy.read_bytes()
        if name == "secrets":
            key = TARGET / context.facts.age_key_file.lstrip("/")
            return key.is_file() and key.stat().st_size > 0
        if name == "install": return (TARGET / "nix/var/nix/profiles/system").is_symlink()
        return False
    def phase(name: str, action: Callable[[], None]) -> None:
        if done(name): log(f"== {name} (already complete)"); return
        log(f"== {name}"); action(); mark(name)
    def partition() -> None:
        if context.luks_passphrase:
            SCRATCH.mkdir(mode=0o700, exist_ok=True); key = SCRATCH / "luks.key"; key.write_text(context.luks_passphrase); key.chmod(0o600)
        try: stream([context.disko, "--mode", "destroy,format,mount", "--yes-wipe-all-disks", "--flake", f"{context.repo}#{context.host}"], "disko", log)
        finally: (SCRATCH / "luks.key").unlink(missing_ok=True)
    def hardware() -> None:
        dest = TARGET / "persist/nixos-install/hardware.nix"
        if dest.is_file() and dest.stat().st_size > 0: log("local hardware configuration already exists; leaving it alone"); return
        stream(["nixos-generate-config", "--root", str(TARGET), "--no-filesystems"], "nixos-generate-config", log)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(TARGET / "etc/nixos/hardware-configuration.nix", dest)
        dest.chmod(0o600)
        log(f"wrote {dest}")
    def config() -> None:
        dest = TARGET / "home/sheath/nixos"; shutil.rmtree(dest, ignore_errors=True); dest.parent.mkdir(parents=True, exist_ok=True); stream(["cp", "-a", str(context.repo), str(dest)], "copying configuration", log)
        persistent = TARGET / "persist/nixos-install"
        persistent.mkdir(parents=True, exist_ok=True)
        for name in ("default.nix", "disk.nix"):
            shutil.copyfile(context.provisioning_dir / name, persistent / name)
            (persistent / name).chmod(0o600)
        provision = dest / "provisioning" / context.host
        provision.mkdir(parents=True, exist_ok=True)
        for name in ("default.nix", "disk.nix", "hardware.nix"):
            shutil.copyfile(persistent / name, provision / name)
    def secrets() -> None:
        destination = TARGET / context.facts.age_key_file.lstrip("/"); destination.parent.mkdir(parents=True, exist_ok=True); age_decrypt(context.repo / context.facts.age_key_source, destination, context.age_passphrase); destination.chmod(0o600)
        if context.facts.persist_ssh:
            ssh_dir = TARGET / "persist/etc/ssh"; ssh_dir.mkdir(parents=True, exist_ok=True)
            for kind, name in (("ed25519", "ssh_host_ed25519_key"), ("rsa", "ssh_host_rsa_key")):
                key = ssh_dir / name
                if not key.exists():
                    args = ["ssh-keygen", "-t", kind, "-f", str(key), "-N", ""]
                    if kind == "rsa": args[3:3] = ["-b", "4096"]
                    stream(args, "ssh-keygen", log)
        if context.facts.root_password == "persist":
            password = TARGET / "persist/secrets/root-password"; password.parent.mkdir(parents=True, exist_ok=True); password.parent.chmod(0o700)
            if not password.exists(): password.write_text(command(["mkpasswd", "-m", "sha-512", "--stdin"], "hashing root password", input_text=context.root_password).rstrip() + "\n"); password.chmod(0o600)
    phase("partition", partition); phase("hardware", hardware); phase("config", config); phase("secrets", secrets)
    phase("install", lambda: stream(["nixos-install", "--root", str(TARGET), "--flake", f"{TARGET}/home/sheath/nixos#{context.host}"], "nixos-install", log))
    def finalize() -> None:
        try:
            stream(["nixos-enter", "--root", str(TARGET), "-c", "chown -R sheath:sheath /home/sheath"], "fixing ownership", log)
        except RuntimeError as error:
            log(f"warning: {error}; fix ownership after first boot")
    phase("finalize", finalize)


class Tui:
    def __init__(self, board: Board):
        self.board, self.row, self.message = board, 0, "Enter edits a decision; v validates all"
        self.log: list[str] = []
        self.events: queue.Queue[tuple[str, str]] = queue.Queue()
        self.install_thread: threading.Thread | None = None
        self.current_phase = ""
        self.phase_started = 0.0
        self.spinner = 0

    def run(self, screen: curses.window) -> None:
        curses.curs_set(0); screen.keypad(True); screen.timeout(150)
        self.board.load_host()
        while True:
            self.pump()
            self.spinner = (self.spinner + 1) % 4
            self.draw(screen)
            try: key = screen.get_wch()
            except curses.error: continue
            if self.install_thread and self.install_thread.is_alive():
                continue
            if key in ("q", "Q"): return
            if key in (curses.KEY_UP, "k"): self.row = max(0, self.row - 1)
            elif key in (curses.KEY_DOWN, "j"): self.row = min(len(CHECKS) - 1, self.row + 1)
            elif key in ("v", "V"): self.board.check_all(); self.message = "all decisions validated" if self.board.ready else "some decisions need attention"
            elif key in ("r", "R"): self.start_install(screen)
            elif key in ("m", "M"): self.remount()
            elif key in ("\n", curses.KEY_ENTER, " "): self.edit(screen, CHECKS[self.row])

    def draw(self, screen: curses.window) -> None:
        screen.erase(); height, width = screen.getmaxyx(); running = self.install_thread and self.install_thread.is_alive()
        ready = "INSTALLING" if running else ("READY" if self.board.ready else "INCOMPLETE")
        progress = ""
        if running and self.current_phase:
            elapsed = int(time.monotonic() - self.phase_started)
            progress = f"  {'|/-\\'[self.spinner]} {self.current_phase} {elapsed // 60}m{elapsed % 60:02d}s"
        self.add(screen, 0, 0, f"NixOS installer   {self.board.host}   {ready}{progress}   {self.message}")
        self.add(screen, 1, 0, "─" * max(1, width - 1))
        for index, name in enumerate(CHECKS):
            status = self.board.status[name]; prefix = ">" if index == self.row else " "
            self.add(screen, index + 2, 0, f"{prefix} {status.glyph} {name:<14} {status.summary}", curses.A_REVERSE if index == self.row else 0)
        detail_y = len(CHECKS) + 3
        if detail_y < height - 3:
            selected = CHECKS[self.row]
            detail = "\n".join(self.log[-max(1, height - detail_y - 3):]) if self.install_thread else (self.board.profile.to_nix() if selected == "layout" and self.board.profile else self.board.status[selected].summary)
            self.add(screen, detail_y, 0, "─" * max(1, width - 1))
            for index, line in enumerate(detail.splitlines()[:height - detail_y - 3]): self.add(screen, detail_y + 1 + index, 0, line)
        help_text = "installing — live output below" if self.install_thread and self.install_thread.is_alive() else "j/k move  Enter select/edit  v validate all  m mount existing  r install  q quit"
        self.add(screen, height - 2, 0, help_text)
        screen.refresh()

    @staticmethod
    def add(screen: curses.window, y: int, x: int, text: str, style: int = 0) -> None:
        try: screen.addnstr(y, x, text, max(0, screen.getmaxyx()[1] - x - 1), style)
        except curses.error: pass

    def prompt(self, screen: curses.window, label: str, secret: bool = False, initial: str = "") -> str | None:
        height, width = screen.getmaxyx(); value = list(initial); curses.curs_set(1); screen.timeout(-1)
        try:
            while True:
                self.add(screen, height - 1, 0, " " * (width - 1)); shown = "*" * len(value) if secret else "".join(value)
                self.add(screen, height - 1, 0, f"{label}: {shown}"); screen.refresh(); key = screen.get_wch()
                if key == "\x1b": return None
                if key in ("\n", curses.KEY_ENTER): return "".join(value)
                if key in (curses.KEY_BACKSPACE, "\b", "\x7f"): value.pop()
                elif isinstance(key, str) and key.isprintable(): value.append(key)
        finally:
            curses.curs_set(0); screen.timeout(150)

    def choose(self, screen: curses.window, label: str, options: list[str]) -> int | None:
        index = 0; screen.timeout(-1)
        try:
            while True:
                height, _ = screen.getmaxyx(); self.add(screen, height - 3, 0, f"{label}: " + "  ".join((f"[{value}]" if i == index else value) for i, value in enumerate(options))); screen.refresh(); key = screen.get_wch()
                if key == "\x1b": return None
                if key in ("\n", curses.KEY_ENTER): return index
                if key in (curses.KEY_LEFT, "h"): index = (index - 1) % len(options)
                if key in (curses.KEY_RIGHT, "l"): index = (index + 1) % len(options)
        finally:
            screen.timeout(150)

    def edit(self, screen: curses.window, name: str) -> None:
        if name == "host":
            choice = self.choose(screen, "host", self.board.hosts)
            if choice is not None: self.board.host_index = choice; self.board.load_host()
        elif name in {"system disk", "/home disk", "/data disk"}: self.assign_disk(screen, name)
        elif name == "encryption" and self.board.profile:
            choice = self.choose(screen, "system encryption", ["off", "LUKS2"])
            if choice is not None:
                self.board.set_encryption(bool(choice))
                if choice:
                    self.set_secret(screen, "luks_passphrase", "LUKS passphrase")
                    self.board.check("encryption")
        elif name == "root password": self.set_secret(screen, "root_password", "root password"); self.board.check(name)
        elif name == "age key": self.set_secret(screen, "age_passphrase", "age key passphrase"); self.board.check(name)
        elif name == "sizes" and self.board.profile: self.edit_sizes(screen)
        else: self.board.check(name)

    def set_secret(self, screen: curses.window, attribute: str, label: str) -> None:
        first = self.prompt(screen, label, True)
        if first is None: return
        second = self.prompt(screen, "confirm " + label, True)
        if first != second: self.message = "values did not match"; return
        setattr(self.board, attribute, first)

    def assign_disk(self, screen: curses.window, role: str) -> None:
        options = ["none"] + [f"{disk.label} {'(no by-id)' if not disk.by_id else ''}" for disk in self.board.disks]
        choice = self.choose(screen, role, options)
        if choice is None or not self.board.profile: return
        path = None if choice == 0 else self.board.disks[choice - 1].by_id
        if choice and not path: self.message = "that disk has no stable by-id path"; return
        profile = self.board.profile
        if role == "system disk": profile.system_device = path or UNSET_DEVICE
        elif role == "/home disk": profile.home_device = path
        else: profile.data_device = path
        self.board.invalidate("layout"); self.board.check_cheap()

    def edit_sizes(self, screen: curses.window) -> None:
        assert self.board.profile
        mode = self.choose(screen, "root mode", ["subvol", "tmpfs"])
        if mode is None: return
        p = self.board.profile; p.root_mode = ("subvol", "tmpfs")[mode]
        for label, attr in (("ESP size", "esp_size"), ("tmpfs size (if tmpfs)", "tmpfs_size"), ("swap size (blank for none)", "swap_size")):
            if attr == "tmpfs_size" and p.root_mode != "tmpfs": continue
            value = self.prompt(screen, label, initial=getattr(p, attr) or "")
            if value is None: return
            setattr(p, attr, value or None if attr == "swap_size" else value)
        self.board.invalidate("layout"); self.board.check("sizes")

    def remount(self) -> None:
        if not self.board.disko: self.board.check("disko")
        if self.board.disko:
            try: command([self.board.disko, "--mode", "mount", "--flake", f"{self.board.repo}#{self.board.host}"], "mounting target"); self.message = "target mounted"
            except RuntimeError as error: self.message = str(error)

    def start_install(self, screen: curses.window) -> None:
        if not self.board.ready: self.message = "validate every checklist row before installing"; return
        if not partition_complete():
            confirmation = self.prompt(screen, "Type ERASE to partition the selected system disk")
            if confirmation != "ERASE": self.message = "installation not confirmed"; return
        self.log.clear(); self.current_phase = ""; self.phase_started = time.monotonic(); self.message = "installing"
        def install() -> None:
            try:
                run_install(self.board, lambda line: self.events.put(("log", line)))
                self.events.put(("done", "installed; provisioning state is stored in /persist/nixos-install"))
            except (RuntimeError, OSError) as error:
                self.events.put(("failed", str(error)))
        self.install_thread = threading.Thread(target=install, daemon=True)
        self.install_thread.start()

    def pump(self) -> None:
        """Move worker events onto the screen-owning thread."""
        while True:
            try: kind, value = self.events.get_nowait()
            except queue.Empty: return
            if kind == "log":
                self.log.append(value)
                if value.startswith("== "):
                    self.current_phase = value.removeprefix("== ").split(" (", 1)[0]
                    self.phase_started = time.monotonic()
            elif kind == "done": self.current_phase = "complete"; self.message = value
            else: self.current_phase = "failed"; self.message = f"install failed: {value}"; self.log.append(value)


def dry_run(board: Board) -> int:
    board.load_host(); board.check_all(); print(f"host: {board.host}\n")
    for name in CHECKS: print(f"{board.status[name].glyph} {name:<14} {board.status[name].summary}")
    print("\nNo file was written and no disk was touched.")
    return 0 if board.ready else 1


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
