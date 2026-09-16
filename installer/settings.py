"""Ordinary installation choices; generated Nix contains references, never passwords."""

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import xml.etree.ElementTree as ET
from zoneinfo import available_timezones


DESKTOPS = ("gnome", "plasma6", "xfce", "pantheon", "cinnamon", "mate",
            "enlightenment", "lxqt", "budgie", "none")
PASSWORD_DIR = "/persist/secrets"


def nix_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False).replace("${", r"\${")


def locale_catalog() -> list[str]:
    path = Path(os.environ.get("INSTALLER_LOCALES", "/run/current-system/sw/share/i18n/SUPPORTED"))
    return sorted({line.split("/", 1)[0] for line in path.read_text().splitlines()
                   if "/UTF-8" in line and not line.startswith("#")})


def keyboard_catalog() -> tuple[set[str], dict[str, set[str]]]:
    path = os.environ.get("INSTALLER_XKB", "/run/current-system/sw/share/X11/xkb/rules/base.xml")
    root = ET.parse(path).getroot()
    models = {e.text for e in root.findall("modelList/model/configItem/name")}
    layouts = {
        e.findtext("configItem/name"): {""} | {v.text for v in e.findall("variantList/variant/configItem/name")}
        for e in root.findall("layoutList/layout")
    }
    return models, layouts


@dataclass
class Settings:
    hostname: str = ""
    username: str = "sheath"
    full_name: str = "sheath"
    locale: str = "en_US.UTF-8"
    region: str = "en_US.UTF-8"
    timezone: str = "America/New_York"
    keyboard_model: str = "pc104"
    keyboard_layout: str = "us"
    keyboard_variant: str = ""
    desktop: str = "gnome"
    auto_login: bool = False
    allow_unfree: bool = True
    user_password_mode: str = "inherit"
    root_password_mode: str = "inherit"

    def validate(self, reserved_users: set[str] = frozenset()) -> list[str]:
        errors = []
        if not re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?", self.hostname) or self.hostname == "localhost":
            errors.append("hostname must be 1–63 letters, digits or hyphens; not localhost")
        if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,30}", self.username) or self.username in reserved_users | {"root", "nobody", "nixos"}:
            errors.append("username is invalid or already belongs to another account")
        if ":" in self.full_name or any(ord(c) < 32 or ord(c) == 127 for c in self.full_name):
            errors.append("full name cannot contain a colon or control characters")
        try:
            locales = locale_catalog()
        except OSError as error:
            locales = []
            errors.append(f"cannot validate locales: {error}")
        for name, value in (("language", self.locale), ("regional format", self.region)):
            if value not in locales:
                errors.append(f"invalid {name} locale")
        if self.timezone not in available_timezones():
            errors.append("unknown timezone")
        if self.desktop not in DESKTOPS:
            errors.append("unknown desktop")
        if self.auto_login and self.desktop == "none":
            errors.append("automatic graphical login requires a desktop")
        if self.user_password_mode not in {"inherit", "custom"}:
            errors.append("unknown login password policy")
        if self.root_password_mode not in {"inherit", "locked", "user", "custom"}:
            errors.append("unknown root password policy")
        try:
            models, layouts = keyboard_catalog()
            if self.keyboard_model not in models:
                errors.append("unknown keyboard model")
            if self.keyboard_layout not in layouts or self.keyboard_variant not in layouts[self.keyboard_layout]:
                errors.append("unknown keyboard layout or variant")
        except (OSError, ET.ParseError) as error:
            errors.append(f"cannot validate keyboard settings: {error}")
        return errors

    def to_nix(self) -> str:
        values = {
            "networking.hostName": self.hostname,
            "fleet.primaryUser": self.username,
            "fleet.desktop": self.desktop,
            "i18n.defaultLocale": self.locale,
            "time.timeZone": self.timezone,
            "services.xserver.xkb.model": self.keyboard_model,
            "services.xserver.xkb.layout": self.keyboard_layout,
            "services.xserver.xkb.variant": self.keyboard_variant,
            f"users.users.{nix_string(self.username)}.description": self.full_name,
        }
        lines = ["# Machine-local installer choices. Passwords live outside the Nix store.", "{ config, lib, ... }:", "{"]
        lines += [f"  {key} = lib.mkForce {nix_string(value)};" for key, value in values.items()]
        lines += [
            "  fleet.provisioning.enable = true;",
            "  console.useXkbConfig = lib.mkForce true;",
            '  i18n.defaultCharset = lib.mkForce "UTF-8";',
            "  i18n.localeCharsets = lib.mkForce {};",
            f"  nixpkgs.config.allowUnfree = lib.mkForce {str(self.allow_unfree).lower()};",
            f"  services.displayManager.autoLogin.enable = lib.mkForce {str(self.auto_login).lower()};",
            f"  services.displayManager.autoLogin.user = lib.mkForce {nix_string(self.username)};",
            "  i18n.extraLocaleSettings = lib.mkForce {",
        ]
        for category in ("ADDRESS", "IDENTIFICATION", "MEASUREMENT", "MONETARY", "NAME", "NUMERIC", "PAPER", "TELEPHONE", "TIME"):
            lines.append(f"    LC_{category} = {nix_string(self.region)};")
        lines += ["  };"]
        if self.user_password_mode == "custom":
            lines.append(f"  users.users.{nix_string(self.username)}.hashedPasswordFile = lib.mkForce {nix_string(PASSWORD_DIR + '/login-password')};")
        if self.root_password_mode != "inherit":
            lines.append('  fleet.accounts.rootPassword = lib.mkForce "none";')
            root = {
                "locked": "null",
                "user": f"config.users.users.{nix_string(self.username)}.hashedPasswordFile",
                "custom": nix_string(PASSWORD_DIR + "/root-password"),
            }[self.root_password_mode]
            lines.append(f"  users.users.root.hashedPasswordFile = lib.mkForce {root};")
            if self.root_password_mode == "locked":
                lines.append('  users.users.root.hashedPassword = lib.mkForce "!";')
        return "\n".join(lines + ["}", ""])
