//! Block-device enumeration and stable-path resolution.

use serde::Deserialize;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Disk {
    /// Kernel name, e.g. `nvme0n1`. Never written to a config: it reorders across boots.
    pub name: String,
    pub size: String,
    pub model: String,
    pub serial: String,
    /// Resolved `/dev/disk/by-id/...`, absent if the kernel exposes no stable link.
    pub by_id: Option<String>,
}

impl Disk {
    pub fn dev_path(&self) -> String {
        format!("/dev/{}", self.name)
    }

    pub fn label(&self) -> String {
        let model = if self.model.is_empty() {
            "unknown"
        } else {
            &self.model
        };
        format!("{:<12} {:>8}  {}", self.name, self.size, model)
    }
}

#[derive(Debug, Deserialize)]
struct LsblkOut {
    blockdevices: Vec<LsblkDev>,
}

#[derive(Debug, Deserialize)]
struct LsblkDev {
    name: String,
    #[serde(default)]
    size: Option<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    serial: Option<String>,
    #[serde(rename = "type", default)]
    dev_type: Option<String>,
}

/// Whole disks only: no partitions, loop devices or optical drives.
pub fn list(by_id_dir: &Path) -> io::Result<Vec<Disk>> {
    let out = Command::new("lsblk")
        .args(["-d", "-J", "-o", "NAME,SIZE,MODEL,SERIAL,TYPE"])
        .output()?;
    if !out.status.success() {
        return Err(io::Error::other(format!(
            "lsblk failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    let parsed: LsblkOut = serde_json::from_slice(&out.stdout)
        .map_err(|e| io::Error::other(format!("could not parse lsblk output: {e}")))?;

    Ok(parsed
        .blockdevices
        .into_iter()
        .filter(|d| d.dev_type.as_deref() == Some("disk"))
        .map(|d| {
            let dev = PathBuf::from(format!("/dev/{}", d.name));
            Disk {
                by_id: by_id_for(&dev, by_id_dir),
                name: d.name,
                size: d.size.unwrap_or_default(),
                model: d.model.unwrap_or_default().trim().to_string(),
                serial: d.serial.unwrap_or_default(),
            }
        })
        .collect())
}

/// Prefer a model+serial link. `wwn-` and `nvme-eui.` are equally stable but say nothing
/// to a human reading the committed disk-config months later, so they are a fallback.
pub fn by_id_for(dev: &Path, by_id_dir: &Path) -> Option<String> {
    let target = std::fs::canonicalize(dev).ok()?;
    let mut fallback: Option<String> = None;

    for entry in std::fs::read_dir(by_id_dir).ok()?.flatten() {
        let link = entry.path();
        if std::fs::canonicalize(&link).ok().as_ref() != Some(&target) {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with("wwn-") || name.starts_with("nvme-eui.") {
            fallback.get_or_insert_with(|| link.to_string_lossy().into_owned());
        } else {
            return Some(link.to_string_lossy().into_owned());
        }
    }
    fallback
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// A fake by-id directory whose links point at real files, so canonicalize works
    /// without needing actual block devices.
    fn fixture(dir: &Path, links: &[&str], target_name: &str) -> PathBuf {
        let target = dir.join(target_name);
        fs::write(&target, b"").unwrap();
        let by_id = dir.join("by-id");
        fs::create_dir_all(&by_id).unwrap();
        for l in links {
            std::os::unix::fs::symlink(&target, by_id.join(l)).unwrap();
        }
        target
    }

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("installer-test-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn prefers_model_serial_over_wwn() {
        let d = tmpdir("prefer");
        let target = fixture(
            &d,
            &["wwn-0x5001b448b9b2c0d1", "nvme-Samsung_SSD_990_PRO_S7DP"],
            "disk0",
        );
        let got = by_id_for(&target, &d.join("by-id")).expect("a link");
        assert!(got.ends_with("nvme-Samsung_SSD_990_PRO_S7DP"), "got {got}");
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn falls_back_to_wwn_when_that_is_all_there_is() {
        let d = tmpdir("fallback");
        let target = fixture(&d, &["wwn-0x5001b448b9b2c0d1"], "disk0");
        let got = by_id_for(&target, &d.join("by-id")).expect("a link");
        assert!(got.ends_with("wwn-0x5001b448b9b2c0d1"), "got {got}");
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn no_link_is_not_an_error_but_is_absent() {
        let d = tmpdir("none");
        let target = fixture(&d, &[], "disk0");
        assert_eq!(by_id_for(&target, &d.join("by-id")), None);
        fs::remove_dir_all(&d).unwrap();
    }
}
