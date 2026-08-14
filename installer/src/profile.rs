//! The install profile: what the operator chose, and how it renders to Nix.
//!
//! `disk-config/<host>.nix` is the single source of truth. There is no second profile
//! format: this struct is read back out of the evaluated `fleet.disk` option tree and
//! rendered into the same file, which is the one that has to be committed anyway.

use serde::Deserialize;
use std::fmt::Write as _;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RootMode {
    Subvol,
    Tmpfs,
}

impl RootMode {
    pub fn as_nix(self) -> &'static str {
        match self {
            RootMode::Subvol => "subvol",
            RootMode::Tmpfs => "tmpfs",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "subvol" => Some(RootMode::Subvol),
            "tmpfs" => Some(RootMode::Tmpfs),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Profile {
    pub host: String,
    pub system_device: String,
    pub system_encrypt: bool,
    pub esp_size: String,
    pub home_device: Option<String>,
    pub home_encrypt: bool,
    pub root_mode: RootMode,
    pub tmpfs_size: String,
    pub swap_size: Option<String>,
    pub data_device: Option<String>,
    pub data_fs_type: String,
}

/// The shape `nix eval --json .#nixosConfigurations.<host>.config.fleet.disk` produces.
#[derive(Debug, Deserialize)]
pub struct FleetDisk {
    pub enable: bool,
    pub system: DeviceOpt,
    #[serde(rename = "espSize")]
    pub esp_size: String,
    pub home: DeviceOpt,
    #[serde(rename = "rootMode")]
    pub root_mode: String,
    #[serde(rename = "tmpfsSize")]
    pub tmpfs_size: String,
    #[serde(rename = "swapSize")]
    pub swap_size: Option<String>,
    pub data: DataOpt,
}

#[derive(Debug, Deserialize)]
pub struct DeviceOpt {
    pub device: Option<String>,
    pub encrypt: bool,
}

#[derive(Debug, Deserialize)]
pub struct DataOpt {
    pub device: Option<String>,
    #[serde(rename = "fsType")]
    pub fs_type: String,
}

/// The sentinel `system.device` default, which means "never installed from here".
pub const UNSET_DEVICE: &str = "/dev/disk/by-id/DISK-CONFIG-NOT-COMMITTED";

impl Profile {
    /// Build from an evaluated `fleet.disk`, so an existing layout is edited rather than
    /// re-entered. A host with no `disk-config` yields the module's defaults.
    pub fn from_fleet_disk(host: &str, d: FleetDisk) -> Self {
        Profile {
            host: host.to_string(),
            system_device: d.system.device.unwrap_or_else(|| UNSET_DEVICE.to_string()),
            system_encrypt: d.system.encrypt,
            esp_size: d.esp_size,
            home_device: d.home.device,
            home_encrypt: d.home.encrypt,
            root_mode: RootMode::parse(&d.root_mode).unwrap_or(RootMode::Subvol),
            tmpfs_size: d.tmpfs_size,
            swap_size: d.swap_size,
            data_device: d.data.device,
            data_fs_type: d.data.fs_type,
        }
    }

    pub fn validate(&self) -> Result<(), Vec<String>> {
        let mut errs = Vec::new();

        if self.system_device == UNSET_DEVICE || self.system_device.is_empty() {
            errs.push("no system disk selected".into());
        }
        if !self.system_device.starts_with("/dev/disk/by-id/") {
            errs.push(format!(
                "system disk {} is not a by-id path; kernel names reorder across boots",
                self.system_device
            ));
        }
        if let Some(h) = &self.home_device {
            if !h.starts_with("/dev/disk/by-id/") {
                errs.push(format!("/home disk {h} is not a by-id path"));
            }
            if *h == self.system_device {
                errs.push("the /home disk and the system disk are the same device".into());
            }
        }
        if let Some(s) = &self.swap_size {
            if !is_size(s) {
                errs.push(format!("swap size {s:?} is not a size like 32G"));
            }
        }
        if !is_size(&self.esp_size) {
            errs.push(format!(
                "ESP size {:?} is not a size like 1G",
                self.esp_size
            ));
        }
        if self.root_mode == RootMode::Tmpfs && !is_size(&self.tmpfs_size) {
            errs.push(format!(
                "tmpfs size {:?} is not a size like 6G",
                self.tmpfs_size
            ));
        }

        if errs.is_empty() {
            Ok(())
        } else {
            Err(errs)
        }
    }

    /// Render `disk-config/<host>.nix`.
    pub fn to_nix(&self) -> String {
        let mut s = String::new();
        let _ = writeln!(
            s,
            "# {}'s disks. The by-id paths are read only by `disko --mode format`; the",
            self.host
        );
        let _ = writeln!(
            s,
            "# booted system mounts by partlabel, so they need not be right to boot."
        );
        let _ = writeln!(s, "{{");
        let _ = writeln!(s, "  fleet.disk = {{");
        let _ = writeln!(s, "    enable = true;");
        let _ = writeln!(s, "    system.device = \"{}\";", self.system_device);
        let _ = writeln!(s, "    system.encrypt = {};", self.system_encrypt);
        if self.esp_size != "1G" {
            let _ = writeln!(s, "    espSize = \"{}\";", self.esp_size);
        }
        if let Some(h) = &self.home_device {
            let _ = writeln!(s, "    home.device = \"{h}\";");
            let _ = writeln!(s, "    home.encrypt = {};", self.home_encrypt);
        }
        let _ = writeln!(s, "    rootMode = \"{}\";", self.root_mode.as_nix());
        if self.root_mode == RootMode::Tmpfs && self.tmpfs_size != "6G" {
            let _ = writeln!(s, "    tmpfsSize = \"{}\";", self.tmpfs_size);
        }
        if let Some(sw) = &self.swap_size {
            let _ = writeln!(s, "    swapSize = \"{sw}\";");
        }
        if let Some(d) = &self.data_device {
            let _ = writeln!(s, "    data.device = \"{d}\";");
            let _ = writeln!(s, "    data.fsType = \"{}\";", self.data_fs_type);
        }
        let _ = writeln!(s, "  }};");
        let _ = writeln!(s, "}}");
        s
    }
}

/// A disko size: digits followed by a unit, e.g. `32G`.
pub fn is_size(s: &str) -> bool {
    let Some(unit) = s.chars().last() else {
        return false;
    };
    if !matches!(unit, 'K' | 'M' | 'G' | 'T' | 'P') {
        return false;
    }
    let digits = &s[..s.len() - 1];
    !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Profile {
        Profile {
            host: "vizualwanderer".into(),
            system_device: "/dev/disk/by-id/nvme-SAMPLE_SYS".into(),
            system_encrypt: true,
            esp_size: "1G".into(),
            home_device: None,
            home_encrypt: true,
            root_mode: RootMode::Subvol,
            tmpfs_size: "6G".into(),
            swap_size: None,
            data_device: None,
            data_fs_type: "btrfs".into(),
        }
    }

    #[test]
    fn sizes() {
        assert!(is_size("32G"));
        assert!(is_size("512M"));
        assert!(!is_size("32"));
        assert!(!is_size("G"));
        assert!(!is_size(""));
        assert!(!is_size("32GB"));
    }

    #[test]
    fn renders_minimal_layout() {
        let nix = sample().to_nix();
        assert!(nix.contains("enable = true;"));
        assert!(nix.contains("system.device = \"/dev/disk/by-id/nvme-SAMPLE_SYS\";"));
        assert!(nix.contains("system.encrypt = true;"));
        assert!(nix.contains("rootMode = \"subvol\";"));
        // Defaults are left out so the committed file stays readable.
        assert!(!nix.contains("espSize"));
        assert!(!nix.contains("tmpfsSize"));
        assert!(!nix.contains("swapSize"));
        assert!(!nix.contains("home.device"));
        assert!(!nix.contains("data.device"));
    }

    #[test]
    fn renders_two_disk_encrypted_layout() {
        let mut p = sample();
        p.home_device = Some("/dev/disk/by-id/ata-SAMPLE_HOME".into());
        p.root_mode = RootMode::Tmpfs;
        p.swap_size = Some("32G".into());
        let nix = p.to_nix();
        assert!(nix.contains("home.device = \"/dev/disk/by-id/ata-SAMPLE_HOME\";"));
        assert!(nix.contains("home.encrypt = true;"));
        assert!(nix.contains("rootMode = \"tmpfs\";"));
        assert!(nix.contains("swapSize = \"32G\";"));
    }

    #[test]
    fn rejects_unset_and_unstable_devices() {
        let mut p = sample();
        p.system_device = UNSET_DEVICE.into();
        assert!(p.validate().is_err());

        let mut p = sample();
        p.system_device = "/dev/nvme0n1".into();
        let errs = p.validate().unwrap_err();
        assert!(errs.iter().any(|e| e.contains("by-id")));
    }

    #[test]
    fn rejects_same_disk_twice() {
        let mut p = sample();
        p.home_device = Some(p.system_device.clone());
        let errs = p.validate().unwrap_err();
        assert!(errs.iter().any(|e| e.contains("same device")));
    }

    #[test]
    fn accepts_a_valid_profile() {
        assert!(sample().validate().is_ok());
    }

    #[test]
    fn reads_module_defaults() {
        // Exactly what `nix eval --json ...config.fleet.disk` emits for a host with no
        // disk-config committed.
        let json = r#"{"data":{"device":null,"fsType":"btrfs"},"enable":false,
            "espSize":"1G","home":{"device":null,"encrypt":true},
            "passwordFile":"/tmp/nixos-install/luks.key","rootMode":"subvol",
            "swapSize":null,
            "system":{"device":"/dev/disk/by-id/DISK-CONFIG-NOT-COMMITTED","encrypt":true},
            "tmpfsSize":"6G"}"#;
        let d: FleetDisk = serde_json::from_str(json).expect("parses");
        assert!(!d.enable);
        let p = Profile::from_fleet_disk("vizualwanderer", d);
        assert_eq!(p.system_device, UNSET_DEVICE);
        assert_eq!(p.root_mode, RootMode::Subvol);
        assert_eq!(p.swap_size, None);
        // Defaults alone are not installable: a disk must be chosen first.
        assert!(p.validate().is_err());
    }
}
