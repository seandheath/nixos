//! The install phases.
//!
//! Completion is derived by inspecting the target, not by trusting a scratch file, so a
//! fresh run, a resume and a deliberate re-install all take the same path. Only
//! `partition` is destructive; everything after it is idempotent.

use crate::nix::Facts;
use std::io::{self, BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub struct Ctx {
    /// The checkout being installed from.
    pub repo: PathBuf,
    /// Where the new system is mounted, normally /mnt.
    pub target: PathBuf,
    pub host: String,
    pub facts: Facts,
    /// Path to the disko CLI built from the locked revision.
    pub disko: String,
    /// tmpfs working area; holds the LUKS key file during formatting.
    pub scratch: PathBuf,
}

impl Ctx {
    /// The configuration copied onto the target, which is what nixos-install builds.
    pub fn dest(&self) -> PathBuf {
        self.target.join("home/sheath/nixos")
    }

    /// On @persist deliberately: /tmp dies with the live ISO and a tmpfs root evaporates
    /// on reboot, which is exactly when a resume matters.
    fn state_file(&self) -> PathBuf {
        self.target.join("persist/nixos-install/state")
    }

    fn mark(&self, phase: &str) -> io::Result<()> {
        let f = self.state_file();
        if let Some(d) = f.parent() {
            std::fs::create_dir_all(d)?;
        }
        let mut done = self.marks();
        if !done.iter().any(|d| d == phase) {
            done.push(phase.to_string());
        }
        std::fs::write(&f, done.join("\n") + "\n")
    }

    fn marks(&self) -> Vec<String> {
        std::fs::read_to_string(self.state_file())
            .map(|s| s.lines().map(str::to_string).collect())
            .unwrap_or_default()
    }

    fn is_marked(&self, phase: &str) -> bool {
        self.marks().iter().any(|d| d == phase)
    }

    fn luks_key(&self) -> PathBuf {
        self.scratch.join("luks.key")
    }

    /// Absolute path of a target-relative file, e.g. the host's age key destination.
    fn under_target(&self, abs: &str) -> PathBuf {
        self.target.join(abs.trim_start_matches('/'))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Partition,
    Hardware,
    Config,
    Secrets,
    Install,
    Finalize,
}

pub const ALL: [Phase; 6] = [
    Phase::Partition,
    Phase::Hardware,
    Phase::Config,
    Phase::Secrets,
    Phase::Install,
    Phase::Finalize,
];

impl Phase {
    pub fn name(self) -> &'static str {
        match self {
            Phase::Partition => "partition",
            Phase::Hardware => "hardware",
            Phase::Config => "config",
            Phase::Secrets => "secrets",
            Phase::Install => "install",
            Phase::Finalize => "finalize",
        }
    }

    pub fn describe(self) -> &'static str {
        match self {
            Phase::Partition => "partition and mount the disks (DESTRUCTIVE)",
            Phase::Hardware => "generate hardware/<host>.nix",
            Phase::Config => "copy the configuration onto the target",
            Phase::Secrets => "install the age key, host keys and root password",
            Phase::Install => "nixos-install",
            Phase::Finalize => "fix ownership and report",
        }
    }

    /// True for phases that drive an interactive passphrase prompt on /dev/tty and so
    /// cannot have their output captured: the committed age key is scrypt-encrypted and
    /// `age -d` reads its passphrase from the terminal, never from stdin.
    pub fn needs_tty(self) -> bool {
        matches!(self, Phase::Secrets | Phase::Finalize)
    }

    pub fn is_destructive(self) -> bool {
        self == Phase::Partition
    }

    pub fn is_done(self, ctx: &Ctx) -> bool {
        match self {
            Phase::Partition => is_mountpoint(&ctx.target) && ctx.is_marked(self.name()),
            Phase::Hardware => {
                let f = hardware_file(ctx);
                // The placeholder is not a real hardware description; treat it as absent.
                std::fs::read_to_string(f).is_ok_and(|s| !s.contains("_placeholder"))
            }
            Phase::Config => {
                let layout = format!("disk-config/{}.nix", ctx.host);
                ctx.dest().join("flake.nix").is_file()
                    && same_file(&ctx.repo.join(&layout), &ctx.dest().join(&layout))
            }
            Phase::Secrets => std::fs::metadata(ctx.under_target(&ctx.facts.age_key_file))
                .is_ok_and(|m| m.len() > 0),
            Phase::Install => ctx
                .target
                .join("nix/var/nix/profiles/system")
                .symlink_metadata()
                .is_ok(),
            // Cheap and idempotent; always worth re-running.
            Phase::Finalize => false,
        }
    }

    pub fn run(self, ctx: &Ctx, log: &mut dyn FnMut(&str)) -> io::Result<()> {
        match self {
            Phase::Partition => partition(ctx, log)?,
            Phase::Hardware => hardware(ctx, log)?,
            Phase::Config => config(ctx, log)?,
            Phase::Secrets => secrets(ctx, log)?,
            Phase::Install => install(ctx, log)?,
            Phase::Finalize => finalize(ctx, log)?,
        }
        ctx.mark(self.name())
    }
}

fn hardware_file(ctx: &Ctx) -> PathBuf {
    ctx.repo.join(format!("hardware/{}.nix", ctx.host))
}

fn is_mountpoint(p: &Path) -> bool {
    Command::new("mountpoint")
        .arg("-q")
        .arg(p)
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (std::fs::read(a), std::fs::read(b)) {
        (Ok(x), Ok(y)) => x == y,
        _ => false,
    }
}

/// Run a command, streaming both streams into the log a line at a time.
fn stream(mut cmd: Command, what: &str, log: &mut dyn FnMut(&str)) -> io::Result<()> {
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn()?;

    let stderr = child.stderr.take().expect("piped");
    let collector = std::thread::spawn(move || {
        let mut lines = Vec::new();
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            lines.push(line);
        }
        lines
    });

    if let Some(stdout) = child.stdout.take() {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            log(&line);
        }
    }

    let status = child.wait()?;
    for line in collector.join().unwrap_or_default() {
        log(&line);
    }
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!("{what} failed ({status})")))
    }
}

/// Run a command with the terminal handed straight to it, for interactive prompts.
fn passthrough(mut cmd: Command, what: &str) -> io::Result<()> {
    let status = cmd.status()?;
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!("{what} failed ({status})")))
    }
}

/// The one irreversible step. The caller is responsible for having confirmed it.
fn partition(ctx: &Ctx, log: &mut dyn FnMut(&str)) -> io::Result<()> {
    log("partitioning with disko");
    let mut c = Command::new(&ctx.disko);
    c.args([
        "--mode",
        "destroy,format,mount",
        "--yes-wipe-all-disks",
        "--flake",
    ])
    .arg(format!("{}#{}", ctx.repo.display(), ctx.host));
    stream(c, "disko", log)
}

/// Re-mount an already-installed target. Needs no by-id path: disko opens LUKS and
/// mounts by partlabel, which is what makes a resume work after an ISO reboot.
pub fn remount(ctx: &Ctx, log: &mut dyn FnMut(&str)) -> io::Result<()> {
    log("re-mounting the target");
    let mut c = Command::new(&ctx.disko);
    c.args(["--mode", "mount", "--flake"])
        .arg(format!("{}#{}", ctx.repo.display(), ctx.host));
    stream(c, "disko --mode mount", log)
}

fn hardware(ctx: &Ctx, log: &mut dyn FnMut(&str)) -> io::Result<()> {
    let dest = hardware_file(ctx);
    // Never clobber a hand-tuned file: sulfur's kernelParams and hydrogen's quirks live
    // here and nixos-generate-config does not know about them.
    if std::fs::read_to_string(&dest).is_ok_and(|s| !s.contains("_placeholder")) {
        log("hardware config already exists and is not a placeholder; leaving it alone");
        return Ok(());
    }

    let mut c = Command::new("nixos-generate-config");
    c.arg("--root").arg(&ctx.target).arg("--no-filesystems");
    stream(c, "nixos-generate-config", log)?;

    let generated = ctx.target.join("etc/nixos/hardware-configuration.nix");
    std::fs::copy(&generated, &dest)?;
    log(&format!("wrote {}", dest.display()));

    // Untracked files are invisible to flake evaluation, and nixos-install reads the flake.
    git_add(ctx, &format!("hardware/{}.nix", ctx.host), log)
}

pub fn git_add(ctx: &Ctx, rel: &str, log: &mut dyn FnMut(&str)) -> io::Result<()> {
    let mut c = Command::new("git");
    c.arg("-C").arg(&ctx.repo).arg("add").arg(rel);
    stream(c, "git add", log)
}

fn config(ctx: &Ctx, log: &mut dyn FnMut(&str)) -> io::Result<()> {
    let dest = ctx.dest();
    log(&format!("copying the configuration to {}", dest.display()));
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if dest.exists() {
        std::fs::remove_dir_all(&dest)?;
    }
    let mut c = Command::new("cp");
    c.arg("-a").arg(&ctx.repo).arg(&dest);
    stream(c, "copying the configuration", log)
}

fn secrets(ctx: &Ctx, log: &mut dyn FnMut(&str)) -> io::Result<()> {
    let src = ctx.repo.join(ctx.facts.age_key_source());
    if !src.is_file() {
        return Err(io::Error::other(format!(
            "{} is missing; restore it from git before installing",
            src.display()
        )));
    }

    let dest = ctx.under_target(&ctx.facts.age_key_file);
    if let Some(d) = dest.parent() {
        std::fs::create_dir_all(d)?;
    }
    log(&format!(
        "decrypting {} -> {}",
        src.display(),
        dest.display()
    ));

    // Interactive: the committed key is scrypt-encrypted and age prompts on /dev/tty.
    let mut c = Command::new("sh");
    c.arg("-c").arg(format!(
        "{} -d {} > {}",
        age_tool(),
        shell_quote(&src.to_string_lossy()),
        shell_quote(&dest.to_string_lossy())
    ));
    if let Err(e) = passthrough(c, "age decrypt") {
        let _ = std::fs::remove_file(&dest);
        return Err(e);
    }
    set_mode(&dest, 0o600)?;

    if ctx.facts.persist_ssh {
        let dir = ctx.target.join("persist/etc/ssh");
        std::fs::create_dir_all(&dir)?;
        for (kind, name) in [
            ("ed25519", "ssh_host_ed25519_key"),
            ("rsa", "ssh_host_rsa_key"),
        ] {
            let path = dir.join(name);
            if path.exists() {
                continue;
            }
            log(&format!("generating {kind} host key"));
            let mut c = Command::new("ssh-keygen");
            c.args(["-t", kind]);
            if kind == "rsa" {
                c.args(["-b", "4096"]);
            }
            c.arg("-f").arg(&path).args(["-N", ""]);
            stream(c, "ssh-keygen", log)?;
        }
    }

    if ctx.facts.root_password == "persist" {
        let dir = ctx.target.join("persist/secrets");
        std::fs::create_dir_all(&dir)?;
        set_mode(&dir, 0o700)?;
        let path = dir.join("root-password");
        if path.exists() {
            log("root password already set");
        } else {
            log("set root's password (read from /persist/secrets/root-password at boot)");
            let mut c = Command::new("sh");
            c.arg("-c").arg(format!(
                "mkpasswd -m sha-512 > {}",
                shell_quote(&path.to_string_lossy())
            ));
            passthrough(c, "mkpasswd")?;
            set_mode(&path, 0o600)?;
        }
    }
    Ok(())
}

fn install(ctx: &Ctx, log: &mut dyn FnMut(&str)) -> io::Result<()> {
    log("running nixos-install");
    let mut c = Command::new("nixos-install");
    c.arg("--root").arg(&ctx.target).arg("--flake").arg(format!(
        "{}#{}",
        ctx.dest().display(),
        ctx.host
    ));
    stream(c, "nixos-install", log)
}

fn finalize(ctx: &Ctx, log: &mut dyn FnMut(&str)) -> io::Result<()> {
    // users/sheath.nix sets no createHome, so NixOS will not chown a home the installer
    // already created as root.
    log("fixing ownership of /home/sheath");
    let mut c = Command::new("nixos-enter");
    c.arg("--root")
        .arg(&ctx.target)
        .args(["-c", "chown -R sheath:sheath /home/sheath"]);
    if let Err(e) = stream(c, "chown", log) {
        log(&format!("warning: {e}; fix it after first boot"));
    }
    Ok(())
}

fn age_tool() -> &'static str {
    if which("age") {
        "age"
    } else if which("rage") {
        "rage"
    } else {
        "nix --extra-experimental-features 'nix-command flakes' run nixpkgs#age --"
    }
}

fn which(bin: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|d| d.join(bin).is_file()))
        .unwrap_or(false)
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

fn set_mode(p: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(mode))
}

/// Write the shared LUKS passphrase. Every encrypted volume on the host formats from
/// this one file, so a single passphrase opens them all and systemd prompts once.
pub fn write_luks_key(ctx: &Ctx, passphrase: &str) -> io::Result<()> {
    std::fs::create_dir_all(&ctx.scratch)?;
    set_mode(&ctx.scratch, 0o700)?;
    let key = ctx.luks_key();
    std::fs::write(&key, passphrase)?;
    set_mode(&key, 0o600)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx_at(root: &Path) -> Ctx {
        Ctx {
            repo: root.join("repo"),
            target: root.join("mnt"),
            host: "testhost".into(),
            facts: Facts {
                age_key_file: "/persist/secrets/age-keys.txt".into(),
                sops_file: "secrets.yaml".into(),
                root_password: "persist".into(),
                mutable_users: false,
                persist_ssh: true,
            },
            disko: "/nonexistent/disko".into(),
            scratch: root.join("scratch"),
        }
    }

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("phases-test-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("repo/hardware")).unwrap();
        std::fs::create_dir_all(d.join("mnt")).unwrap();
        d
    }

    #[test]
    fn placeholder_hardware_counts_as_not_done() {
        let d = tmpdir("hw");
        let ctx = ctx_at(&d);
        assert!(!Phase::Hardware.is_done(&ctx), "missing file is not done");

        std::fs::write(
            d.join("repo/hardware/testhost.nix"),
            "{ ... }: { imports = [ ./_placeholder.nix ]; }",
        )
        .unwrap();
        assert!(
            !Phase::Hardware.is_done(&ctx),
            "a placeholder is not a real hardware description"
        );

        std::fs::write(
            d.join("repo/hardware/testhost.nix"),
            "{ boot.initrd.availableKernelModules = [ \"nvme\" ]; }",
        )
        .unwrap();
        assert!(Phase::Hardware.is_done(&ctx));
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn secrets_done_only_when_the_key_is_non_empty() {
        let d = tmpdir("secrets");
        let ctx = ctx_at(&d);
        assert!(!Phase::Secrets.is_done(&ctx));

        let key = d.join("mnt/persist/secrets/age-keys.txt");
        std::fs::create_dir_all(key.parent().unwrap()).unwrap();
        std::fs::write(&key, "").unwrap();
        assert!(
            !Phase::Secrets.is_done(&ctx),
            "an empty key is not installed"
        );

        std::fs::write(&key, "AGE-SECRET-KEY-1...\n").unwrap();
        assert!(Phase::Secrets.is_done(&ctx));
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn config_done_requires_the_layout_to_match() {
        let d = tmpdir("config");
        let ctx = ctx_at(&d);
        let layout = "disk-config/testhost.nix";
        std::fs::create_dir_all(d.join("repo/disk-config")).unwrap();
        std::fs::write(d.join("repo").join(layout), "{ a = 1; }").unwrap();

        assert!(!Phase::Config.is_done(&ctx), "nothing copied yet");

        let dest = ctx.dest();
        std::fs::create_dir_all(dest.join("disk-config")).unwrap();
        std::fs::write(dest.join("flake.nix"), "{}").unwrap();
        std::fs::write(dest.join(layout), "{ a = 2; }").unwrap();
        assert!(
            !Phase::Config.is_done(&ctx),
            "a stale layout on the target must re-copy"
        );

        std::fs::write(dest.join(layout), "{ a = 1; }").unwrap();
        assert!(Phase::Config.is_done(&ctx));
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn state_marks_survive_and_accumulate() {
        let d = tmpdir("state");
        let ctx = ctx_at(&d);
        assert!(!ctx.is_marked("partition"));
        ctx.mark("partition").unwrap();
        ctx.mark("partition").unwrap();
        ctx.mark("install").unwrap();
        assert!(ctx.is_marked("partition"));
        assert!(ctx.is_marked("install"));
        assert_eq!(ctx.marks().len(), 2, "marks are not duplicated");
        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn only_partition_is_destructive() {
        let destructive: Vec<_> = ALL.iter().filter(|p| p.is_destructive()).collect();
        assert_eq!(destructive, vec![&Phase::Partition]);
    }

    #[test]
    fn quoting_survives_awkward_paths() {
        assert_eq!(shell_quote("/tmp/a b"), "'/tmp/a b'");
        assert_eq!(shell_quote("it's"), r"'it'\''s'");
    }
}
