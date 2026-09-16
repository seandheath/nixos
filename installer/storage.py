"""Read-only block-device inventory used for both defaults and the final wipe gate."""

from dataclasses import dataclass, field
import json
from pathlib import Path
import subprocess

BY_ID = Path("/dev/disk/by-id")


def by_id_for(device: Path) -> str | None:
    try:
        target = device.resolve(strict=True)
    except OSError:
        return None
    for link in sorted(BY_ID.iterdir() if BY_ID.is_dir() else (),
                       key=lambda p: (not p.name.startswith(("wwn-", "nvme-eui.")), p.name)):
        try:
            if link.resolve(strict=True) == target:
                return str(link)
        except OSError:
            continue
    return None


def same_device(a: str | None, b: str | None) -> bool:
    return bool(a and b and Path(a).resolve() == Path(b).resolve())


@dataclass
class Disk:
    name: str
    size: str
    model: str
    serial: str
    by_id: str | None
    size_bytes: int = 0
    blank: bool = False
    external: bool = False
    readonly: bool = False
    mounts: set[str] = field(default_factory=set)
    uuids: set[str] = field(default_factory=set)

    @property
    def path(self) -> str:
        return str(Path("/dev") / self.name)

    @property
    def label(self) -> str:
        return f"{self.name}  {self.size}  {self.model or 'unknown'}  {self.serial}"

    @property
    def automatic(self) -> bool:
        return bool(self.by_id and self.size_bytes and self.blank and not
                    (self.external or self.readonly or self.mounts))


@dataclass
class Filesystem:
    uuid: str
    fs_type: str
    members: set[str] = field(default_factory=set)

    @property
    def path(self) -> str:
        return "/dev/disk/by-uuid/" + self.uuid

    @property
    def label(self) -> str:
        return f"{self.fs_type}  {self.uuid}  ({', '.join(sorted(self.members))}; preserved)"


def inventory(data: dict) -> tuple[list[Disk], list[Filesystem]]:
    """Keep all members of filesystems sharing a UUID, including partition parents."""
    disks = {}
    filesystems = {}

    def visit(node, parent=None):
        name = node["name"].removeprefix("/dev/")
        if node["type"] == "disk":
            size = int(node.get("size") or 0)
            parent = disks.setdefault(name, Disk(
                name, f"{size / 1024**3:.1f} GiB", (node.get("model") or "").strip(),
                node.get("serial") or "", by_id_for(Path("/dev") / name), size,
                not (node.get("children") or node.get("fstype") or node.get("pttype")),
                bool(node.get("rm") or node.get("tran") in {"usb", "firewire"}), bool(node.get("ro"))))
        if parent:
            parent.mounts.update(m for m in node.get("mountpoints") or [] if m)
            if node.get("uuid"):
                parent.uuids.add(node["uuid"])
                if node.get("fstype") in {"btrfs", "ext4", "xfs", "f2fs", "vfat", "ntfs", "exfat"}:
                    fs = filesystems.setdefault(node["uuid"], Filesystem(node["uuid"], node["fstype"]))
                    fs.members.add(parent.path)
        for child in node.get("children", []):
            visit(child, parent)

    for node in data["blockdevices"]:
        visit(node)
    # lsblk can attach a mounted multi-device filesystem to only one of its parents.
    for fs in filesystems.values():
        mounts = set().union(*(d.mounts for d in disks.values() if d.path in fs.members))
        for disk in disks.values():
            if disk.path in fs.members:
                disk.mounts.update(mounts)
    return list(disks.values()), list(filesystems.values())


def scan() -> tuple[list[Disk], list[Filesystem]]:
    result = subprocess.run(
        ["lsblk", "-b", "-J", "-o", "NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,UUID,PTTYPE,MOUNTPOINTS,RO,RM,TRAN"],
        check=True, text=True, capture_output=True)
    return inventory(json.loads(result.stdout))


def storage_errors(disks: list[Disk], filesystems: list[Filesystem], system: str,
                   home: str | None, data: str | None, data_type: str, *, resume=False,
                   target="/mnt") -> list[str]:
    errors = []
    selected = []
    preserved = next((fs for fs in filesystems if same_device(fs.path, data)), None) if data else None
    if data and not preserved:
        errors.append("preserved /data filesystem is missing")
    if preserved and preserved.fs_type != data_type:
        errors.append(f"/data is {preserved.fs_type}, not {data_type}")
    for role, path in (("system", system), ("home", home)):
        if role == "home" and not path:
            continue
        disk = next((d for d in disks if same_device(d.path, path) or same_device(d.by_id, path)), None)
        if not disk or not disk.by_id or not disk.size_bytes:
            errors.append(f"select an available {role} disk with a stable by-id name")
            continue
        if disk.path in selected:
            errors.append("system and home refer to the same physical disk")
        selected.append(disk.path)
        if disk.readonly:
            errors.append(f"{role} disk is read-only")
        if preserved and disk.path in preserved.members:
            errors.append(f"{role} disk belongs to preserved /data")
        busy = {m for m in disk.mounts if not (resume and (m == target or m.startswith(target + "/")))}
        if busy:
            errors.append(f"{role} disk is in use: {', '.join(sorted(busy))}")
    return errors
