//! The checklist model: every requirement, what was chosen for it, and whether it works.
//!
//! `Board` owns the state so the UI is pure presentation. Each row has a validator that
//! answers "does this actually work", not merely "is it set" -- the layout row builds the
//! partitioning script, and the age row really decrypts the key.

use crate::disks::Disk;
use crate::nix::{self, Facts};
use crate::phases::{self, Ctx};
use crate::profile::{self, Profile};

use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Status {
    /// Not checked yet, or invalidated by an edit elsewhere.
    Pending,
    Ok(String),
    Failed(String),
    /// Optional and deliberately unset, e.g. no separate /home disk.
    NotApplicable(String),
}

impl Status {
    /// Whether this row no longer blocks the run.
    pub fn satisfied(&self) -> bool {
        matches!(self, Status::Ok(_) | Status::NotApplicable(_))
    }

    pub fn glyph(&self) -> &'static str {
        match self {
            Status::Pending => "·",
            Status::Ok(_) => "✔",
            Status::Failed(_) => "✘",
            Status::NotApplicable(_) => "○",
        }
    }

    pub fn summary(&self) -> &str {
        match self {
            Status::Pending => "not checked",
            Status::Ok(s) | Status::Failed(s) | Status::NotApplicable(s) => s,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CheckId {
    Environment,
    Host,
    SystemDisk,
    HomeDisk,
    DataDisk,
    Encryption,
    RootPassword,
    Sizes,
    Layout,
    AgeKey,
    Disko,
}

pub const ALL: [CheckId; 11] = [
    CheckId::Environment,
    CheckId::Host,
    CheckId::SystemDisk,
    CheckId::HomeDisk,
    CheckId::DataDisk,
    CheckId::Encryption,
    CheckId::RootPassword,
    CheckId::Sizes,
    CheckId::Layout,
    CheckId::AgeKey,
    CheckId::Disko,
];

impl CheckId {
    pub fn label(self) -> &'static str {
        match self {
            CheckId::Environment => "environment",
            CheckId::Host => "host",
            CheckId::SystemDisk => "system disk",
            CheckId::HomeDisk => "/home disk",
            CheckId::DataDisk => "/data disk",
            CheckId::Encryption => "encryption",
            CheckId::RootPassword => "root password",
            CheckId::Sizes => "sizes",
            CheckId::Layout => "layout",
            CheckId::AgeKey => "age key",
            CheckId::Disko => "disko",
        }
    }

    /// Slow enough to be worth running only on request: each shells out to nix.
    pub fn is_expensive(self) -> bool {
        matches!(self, CheckId::Layout | CheckId::AgeKey | CheckId::Disko)
    }

    /// Rows reset to Pending when this one is edited, so a stale green never gates a run.
    pub fn invalidates(self) -> &'static [CheckId] {
        match self {
            CheckId::Host => &[
                CheckId::Layout,
                CheckId::AgeKey,
                CheckId::RootPassword,
                CheckId::Encryption,
            ],
            CheckId::SystemDisk | CheckId::HomeDisk | CheckId::DataDisk | CheckId::Sizes => {
                &[CheckId::Layout]
            }
            CheckId::Encryption => &[CheckId::Layout],
            _ => &[],
        }
    }

    fn index(self) -> usize {
        ALL.iter().position(|c| *c == self).expect("in ALL")
    }
}

pub struct Board {
    pub repo: String,
    pub hosts: Vec<String>,
    pub host_idx: usize,

    pub facts: Option<Facts>,
    pub profile: Option<Profile>,
    pub disks: Vec<Disk>,

    pub luks_passphrase: String,
    pub age_passphrase: String,
    pub root_password: String,

    pub disko: String,
    /// False under --dry-run. The layout check writes disk-config/<host>.nix to validate
    /// it; on an already-installed machine that file would set fleet.disk.enable = true
    /// and the next local rebuild would try to replace its live filesystems.
    pub allow_writes: bool,
    status: Vec<Status>,
}

impl Board {
    pub fn new(repo: &str, hosts: Vec<String>) -> Self {
        Board {
            repo: repo.to_string(),
            hosts,
            host_idx: 0,
            facts: None,
            profile: None,
            disks: Vec::new(),
            luks_passphrase: String::new(),
            age_passphrase: String::new(),
            root_password: String::new(),
            disko: String::new(),
            allow_writes: true,
            status: vec![Status::Pending; ALL.len()],
        }
    }

    pub fn host(&self) -> &str {
        self.hosts.get(self.host_idx).map_or("", String::as_str)
    }

    pub fn status(&self, id: CheckId) -> &Status {
        &self.status[id.index()]
    }

    pub fn set(&mut self, id: CheckId, s: Status) {
        self.status[id.index()] = s;
    }

    pub fn invalidate(&mut self, id: CheckId) {
        for dep in id.invalidates() {
            self.set(*dep, Status::Pending);
        }
    }

    /// Every row satisfied. The run is gated on this.
    pub fn ready(&self) -> bool {
        ALL.iter().all(|id| self.status(*id).satisfied())
    }

    pub fn layout_path(&self) -> PathBuf {
        Path::new(&self.repo).join(format!("disk-config/{}.nix", self.host()))
    }

    /// Load the host's configuration. Slow: a full module-system evaluation.
    pub fn load_host(&mut self) {
        let host = self.host().to_string();
        let fd = match nix::fleet_disk(&self.repo, &host) {
            Ok(v) => v,
            Err(e) => {
                self.set(CheckId::Host, Status::Failed(e.to_string()));
                return;
            }
        };
        let facts = match nix::facts(&self.repo, &host) {
            Ok(v) => v,
            Err(e) => {
                self.set(CheckId::Host, Status::Failed(e.to_string()));
                return;
            }
        };

        let committed = fd.enable;
        let mut profile = Profile::from_fleet_disk(&host, fd);
        self.disks = crate::disks::list(Path::new(crate::BY_ID)).unwrap_or_default();
        if profile.system_device == profile::UNSET_DEVICE {
            if let Some(d) = self.disks.iter().find_map(|d| d.by_id.clone()) {
                profile.system_device = d;
            }
        }

        let summary = format!(
            "{} · {} · {}",
            if facts.sops_file == "family.yaml" {
                "family"
            } else {
                "fleet"
            },
            if facts.mutable_users {
                "passwd after install"
            } else {
                "declarative passwords"
            },
            if committed {
                "layout committed"
            } else {
                "no layout yet"
            }
        );
        self.facts = Some(facts);
        self.profile = Some(profile);
        self.set(CheckId::Host, Status::Ok(summary));
        self.invalidate(CheckId::Host);
        self.check_cheap();
    }

    /// Run everything that does not shell out to nix.
    pub fn check_cheap(&mut self) {
        for id in ALL {
            if !id.is_expensive() {
                let s = self.evaluate(id);
                self.set(id, s);
            }
        }
    }

    pub fn check(&mut self, id: CheckId) {
        let s = self.evaluate(id);
        self.set(id, s);
    }

    pub fn check_all(&mut self) {
        for id in ALL {
            let s = self.evaluate(id);
            self.set(id, s);
        }
    }

    fn evaluate(&mut self, id: CheckId) -> Status {
        match id {
            CheckId::Environment => environment(Path::new(&self.repo), crate::is_root()),
            // Set by load_host; re-evaluating would mean another 30-second evaluation.
            CheckId::Host => self.status(CheckId::Host).clone(),
            CheckId::SystemDisk => self.system_disk(),
            CheckId::HomeDisk => self.home_disk(),
            CheckId::DataDisk => self.data_disk(),
            CheckId::Encryption => self.encryption(),
            CheckId::RootPassword => self.root_pw(),
            CheckId::Sizes => self.sizes(),
            CheckId::Layout => self.layout(),
            CheckId::AgeKey => self.age_key(),
            CheckId::Disko => self.disko_cli(),
        }
    }

    fn system_disk(&self) -> Status {
        let Some(p) = self.profile.as_ref() else {
            return Status::Pending;
        };
        if p.system_device == profile::UNSET_DEVICE || p.system_device.is_empty() {
            return Status::Failed("no system disk selected".into());
        }
        if !p.system_device.starts_with("/dev/disk/by-id/") {
            return Status::Failed(format!(
                "{} is not a by-id path; kernel names reorder across boots",
                p.system_device
            ));
        }
        match self.describe(&p.system_device) {
            Some(d) => Status::Ok(d),
            None => Status::Failed(format!(
                "{} is not present in this machine",
                p.system_device
            )),
        }
    }

    fn home_disk(&self) -> Status {
        let Some(p) = self.profile.as_ref() else {
            return Status::Pending;
        };
        let Some(home) = p.home_device.as_deref() else {
            return Status::NotApplicable("/home is a subvolume of the system disk".into());
        };
        if home == p.system_device {
            return Status::Failed("same device as the system disk".into());
        }
        match self.describe(home) {
            Some(d) => Status::Ok(d),
            None => Status::Failed(format!("{home} is not present in this machine")),
        }
    }

    fn data_disk(&self) -> Status {
        let Some(p) = self.profile.as_ref() else {
            return Status::Pending;
        };
        let Some(data) = p.data_device.as_deref() else {
            return Status::NotApplicable("none".into());
        };
        // Preserved, never formatted, so it must already hold a filesystem.
        match blkid(data, "TYPE") {
            Some(t) => Status::Ok(format!("{data}  ({t}, preserved)")),
            None => Status::Failed(format!("no filesystem found on {data}")),
        }
    }

    fn encryption(&self) -> Status {
        let Some(p) = self.profile.as_ref() else {
            return Status::Pending;
        };
        if !p.system_encrypt {
            return Status::Ok("off".into());
        }
        if self.luks_passphrase.is_empty() {
            return Status::Failed("LUKS2 selected but no passphrase set".into());
        }
        Status::Ok(format!(
            "LUKS2, passphrase set ({} volume{})",
            1 + usize::from(p.home_device.is_some() && p.home_encrypt),
            if p.home_device.is_some() && p.home_encrypt {
                "s share one passphrase"
            } else {
                ""
            }
        ))
    }

    fn root_pw(&self) -> Status {
        let Some(f) = self.facts.as_ref() else {
            return Status::Pending;
        };
        // Only "persist" hosts read a hash the installer writes; sops and none do not.
        if f.root_password != "persist" {
            return Status::NotApplicable(format!("from {}", f.root_password));
        }
        if self.root_password.is_empty() {
            return Status::Failed("this host reads /persist/secrets/root-password".into());
        }
        Status::Ok("set".into())
    }

    fn sizes(&self) -> Status {
        let Some(p) = self.profile.as_ref() else {
            return Status::Pending;
        };
        let mut bad = Vec::new();
        if !profile::is_size(&p.esp_size) {
            bad.push(format!("ESP {:?}", p.esp_size));
        }
        if p.root_mode == profile::RootMode::Tmpfs && !profile::is_size(&p.tmpfs_size) {
            bad.push(format!("tmpfs {:?}", p.tmpfs_size));
        }
        if let Some(s) = &p.swap_size {
            if !profile::is_size(s) {
                bad.push(format!("swap {s:?}"));
            }
        }
        if bad.is_empty() {
            Status::Ok(format!(
                "ESP {} · swap {} · root {}",
                p.esp_size,
                p.swap_size.as_deref().unwrap_or("none"),
                p.root_mode.as_nix()
            ))
        } else {
            Status::Failed(format!("not a size like 32G: {}", bad.join(", ")))
        }
    }

    /// Writes the layout and has disko build it. The strongest check short of running it.
    fn layout(&mut self) -> Status {
        let Some(p) = self.profile.as_ref() else {
            return Status::Pending;
        };
        if let Err(errs) = p.validate() {
            return Status::Failed(errs.join("; "));
        }
        if !self.allow_writes {
            return Status::Ok("valid; not built (a dry run does not write the layout)".into());
        }
        let path = self.layout_path();
        if let Some(d) = path.parent() {
            if let Err(e) = std::fs::create_dir_all(d) {
                return Status::Failed(e.to_string());
            }
        }
        if let Err(e) = std::fs::write(&path, p.to_nix()) {
            return Status::Failed(e.to_string());
        }
        // Untracked files are invisible to flake evaluation, and disko reads the flake.
        if let Err(e) = git_add(&self.repo, &format!("disk-config/{}.nix", self.host())) {
            return Status::Failed(e);
        }
        match nix::build_disko_script(&self.repo, self.host()) {
            Ok(_) => Status::Ok("disko accepts the layout".into()),
            Err(e) => Status::Failed(last_lines(&e.to_string(), 6)),
        }
    }

    fn age_key(&self) -> Status {
        let Some(f) = self.facts.as_ref() else {
            return Status::Pending;
        };
        let src = Path::new(&self.repo).join(f.age_key_source());
        if !src.is_file() {
            return Status::Failed(format!("{} is missing", src.display()));
        }
        if self.age_passphrase.is_empty() {
            return Status::Failed(format!("passphrase for {} not set", f.age_key_source()));
        }
        // Decrypt for real, to a temp file that is removed either way.
        let probe = std::env::temp_dir().join(format!("installer-agecheck-{}", std::process::id()));
        let _ = std::fs::remove_file(&probe);
        let result = phases::age_decrypt(&src, &probe, &self.age_passphrase);
        let looks_like_key =
            std::fs::read_to_string(&probe).is_ok_and(|s| s.contains("AGE-SECRET-KEY"));
        let _ = std::fs::remove_file(&probe);

        match result {
            Ok(()) if looks_like_key => Status::Ok(format!("{} decrypts", f.age_key_source())),
            Ok(()) => Status::Failed("decrypted, but the result is not an age key".into()),
            Err(e) => Status::Failed(e.to_string()),
        }
    }

    fn disko_cli(&mut self) -> Status {
        match nix::disko_bin(&self.repo) {
            Ok(path) => {
                self.disko = path.clone();
                Status::Ok("built from the locked revision".into())
            }
            Err(e) => Status::Failed(last_lines(&e.to_string(), 6)),
        }
    }

    fn describe(&self, by_id: &str) -> Option<String> {
        let d = self
            .disks
            .iter()
            .find(|d| d.by_id.as_deref() == Some(by_id))?;
        Some(format!(
            "{}  {}  {}",
            d.name,
            d.size,
            by_id.rsplit('/').next().unwrap_or(by_id)
        ))
    }

    pub fn ctx(&self) -> Result<Ctx, String> {
        Ok(Ctx {
            repo: PathBuf::from(&self.repo),
            target: PathBuf::from(crate::TARGET),
            host: self.host().to_string(),
            facts: self.facts.clone().ok_or("host not loaded")?,
            disko: self.disko.clone(),
            scratch: PathBuf::from(crate::SCRATCH),
            luks_passphrase: self.luks_passphrase.clone(),
            age_passphrase: self.age_passphrase.clone(),
            root_password: self.root_password.clone(),
        })
    }
}

/// Pure so it can be tested without being root.
pub fn environment(repo: &Path, root: bool) -> Status {
    let mut bad = Vec::new();
    if !root {
        bad.push("not running as root");
    }
    if !Path::new("/sys/firmware/efi").is_dir() {
        bad.push("not booted in UEFI mode");
    }
    if !repo.join("flake.nix").is_file() {
        bad.push("not the configuration repository");
    }
    if !repo.join(".git").exists() {
        bad.push("not a git checkout; untracked files are invisible to nix");
    }
    if !phases::which("script") {
        bad.push("script(1) is missing; it supplies the pty age needs");
    }
    if !phases::which("age") && !phases::which("rage") {
        bad.push("neither age nor rage is on PATH");
    }
    if bad.is_empty() {
        Status::Ok("root · UEFI · git checkout".into())
    } else {
        Status::Failed(bad.join("; "))
    }
}

fn blkid(dev: &str, field: &str) -> Option<String> {
    let out = std::process::Command::new("blkid")
        .args(["-s", field, "-o", "value", dev])
        .output()
        .ok()?;
    let v = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !v.is_empty()).then_some(v)
}

fn git_add(repo: &str, rel: &str) -> Result<(), String> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(repo)
        .arg("add")
        .arg(rel)
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

/// nix errors are long; the tail carries the actual failure.
fn last_lines(s: &str, n: usize) -> String {
    let lines: Vec<&str> = s.lines().filter(|l| !l.trim().is_empty()).collect();
    lines[lines.len().saturating_sub(n)..].join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile::RootMode;

    fn facts(root_password: &str, sops: &str) -> Facts {
        Facts {
            age_key_file: "/home/sheath/.config/sops/age/keys.txt".into(),
            sops_file: sops.into(),
            root_password: root_password.into(),
            mutable_users: false,
            persist_ssh: false,
        }
    }

    fn profile() -> Profile {
        Profile {
            host: "gentlemenpupil".into(),
            system_device: "/dev/disk/by-id/nvme-A".into(),
            system_encrypt: false,
            esp_size: "1G".into(),
            home_device: None,
            home_encrypt: false,
            root_mode: RootMode::Subvol,
            tmpfs_size: "6G".into(),
            swap_size: None,
            data_device: None,
            data_fs_type: "btrfs".into(),
        }
    }

    fn board() -> Board {
        let mut b = Board::new("/repo", vec!["gentlemenpupil".into()]);
        b.facts = Some(facts("none", "family.yaml"));
        b.profile = Some(profile());
        b.disks = vec![Disk {
            name: "nvme0n1".into(),
            size: "1T".into(),
            model: "Samsung".into(),
            serial: "1".into(),
            by_id: Some("/dev/disk/by-id/nvme-A".into()),
        }];
        b
    }

    #[test]
    fn a_present_by_id_disk_passes_and_an_absent_one_does_not() {
        let mut b = board();
        assert!(matches!(b.system_disk(), Status::Ok(_)));

        b.profile.as_mut().unwrap().system_device = "/dev/disk/by-id/nvme-NOT-HERE".into();
        match b.system_disk() {
            Status::Failed(e) => assert!(e.contains("not present in this machine")),
            s => panic!("expected a failure, got {s:?}"),
        }
    }

    #[test]
    fn an_unstable_device_path_is_refused() {
        let mut b = board();
        b.profile.as_mut().unwrap().system_device = "/dev/nvme0n1".into();
        match b.system_disk() {
            Status::Failed(e) => assert!(e.contains("by-id")),
            s => panic!("expected a failure, got {s:?}"),
        }
    }

    #[test]
    fn a_single_disk_marks_home_not_applicable() {
        let b = board();
        match b.home_disk() {
            Status::NotApplicable(m) => assert!(m.contains("subvolume")),
            s => panic!("expected not-applicable, got {s:?}"),
        }
        assert!(
            b.home_disk().satisfied(),
            "optional rows must not block the run"
        );
    }

    #[test]
    fn encryption_off_needs_no_passphrase_but_on_does() {
        let mut b = board();
        assert_eq!(b.encryption(), Status::Ok("off".into()));

        b.profile.as_mut().unwrap().system_encrypt = true;
        match b.encryption() {
            Status::Failed(e) => assert!(e.contains("no passphrase")),
            s => panic!("expected a failure, got {s:?}"),
        }

        b.luks_passphrase = "hunter2".into();
        assert!(matches!(b.encryption(), Status::Ok(_)));
    }

    #[test]
    fn root_password_is_required_only_where_the_host_reads_one() {
        let mut b = board();
        assert!(b.root_pw().satisfied(), "rootPassword=none needs nothing");

        b.facts = Some(facts("sops", "secrets.yaml"));
        assert!(b.root_pw().satisfied(), "rootPassword=sops needs nothing");

        b.facts = Some(facts("persist", "secrets.yaml"));
        assert!(!b.root_pw().satisfied(), "rootPassword=persist needs one");
        b.root_password = "s3cret".into();
        assert!(b.root_pw().satisfied());
    }

    #[test]
    fn sizes_reject_junk() {
        let mut b = board();
        assert!(matches!(b.sizes(), Status::Ok(_)));
        b.profile.as_mut().unwrap().swap_size = Some("32GB".into());
        match b.sizes() {
            Status::Failed(e) => assert!(e.contains("swap")),
            s => panic!("expected a failure, got {s:?}"),
        }
    }

    /// A dry run must not be able to write disk-config/<host>.nix. On an already-installed
    /// machine that file sets fleet.disk.enable = true, and the next local rebuild would
    /// try to replace its live filesystems.
    #[test]
    fn a_dry_run_never_writes_the_layout() {
        let dir = std::env::temp_dir().join(format!("checks-dry-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let mut b = board();
        b.repo = dir.to_string_lossy().into_owned();
        b.allow_writes = false;

        let status = b.layout();
        assert!(
            matches!(status, Status::Ok(_)),
            "a valid profile should still report valid: {status:?}"
        );
        assert!(
            !dir.join("disk-config").exists(),
            "a dry run wrote a layout file"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn editing_a_disk_invalidates_the_layout() {
        let mut b = board();
        b.set(CheckId::Layout, Status::Ok("built".into()));
        b.invalidate(CheckId::SystemDisk);
        assert_eq!(*b.status(CheckId::Layout), Status::Pending);
    }

    #[test]
    fn changing_host_invalidates_the_layout_and_the_age_key() {
        let mut b = board();
        b.set(CheckId::Layout, Status::Ok("built".into()));
        b.set(CheckId::AgeKey, Status::Ok("decrypts".into()));
        b.invalidate(CheckId::Host);
        assert_eq!(*b.status(CheckId::Layout), Status::Pending);
        assert_eq!(*b.status(CheckId::AgeKey), Status::Pending);
    }

    #[test]
    fn the_run_gate_needs_every_row_satisfied() {
        let mut b = board();
        for id in ALL {
            b.set(id, Status::Ok("fine".into()));
        }
        assert!(b.ready());

        b.set(CheckId::Layout, Status::Pending);
        assert!(!b.ready(), "an unchecked row must block the run");

        b.set(CheckId::Layout, Status::Failed("nope".into()));
        assert!(!b.ready());

        b.set(CheckId::Layout, Status::Ok("built".into()));
        b.set(CheckId::HomeDisk, Status::NotApplicable("none".into()));
        assert!(b.ready(), "optional rows count as satisfied");
    }

    #[test]
    fn environment_reports_each_problem_it_finds() {
        match environment(Path::new("/definitely/not/a/repo"), false) {
            Status::Failed(e) => {
                assert!(e.contains("not running as root"));
                assert!(e.contains("not the configuration repository"));
            }
            s => panic!("expected a failure, got {s:?}"),
        }
    }

    #[test]
    fn nix_errors_are_trimmed_to_the_tail() {
        let long = (1..=20)
            .map(|i| format!("line{i}"))
            .collect::<Vec<_>>()
            .join("\n");
        let out = last_lines(&long, 3);
        assert_eq!(out, "line18\nline19\nline20");
    }
}
