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

    // Collected up front so the run needs no interaction once it starts. Empty when the
    // host does not need them: no encryption, or rootPassword is not "persist".
    pub luks_passphrase: String,
    pub age_passphrase: String,
    pub root_password: String,
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

/// The one irreversible step. The caller is responsible for having confirmed it.
fn partition(ctx: &Ctx, log: &mut dyn FnMut(&str)) -> io::Result<()> {
    if !ctx.luks_passphrase.is_empty() {
        write_luks_key(ctx)?;
    }
    log("partitioning with disko");
    let mut c = Command::new(&ctx.disko);
    c.args([
        "--mode",
        "destroy,format,mount",
        "--yes-wipe-all-disks",
        "--flake",
    ])
    .arg(format!("{}#{}", ctx.repo.display(), ctx.host));
    let result = stream(c, "disko", log);
    // The headers hold the passphrase now; nothing later reads the file.
    let _ = std::fs::remove_file(ctx.luks_key());
    result
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

    if let Err(e) = age_decrypt(&src, &dest, &ctx.age_passphrase) {
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
            log("hashing root's password (read from /persist/secrets/root-password at boot)");
            // --stdin keeps this non-interactive; the password never reaches argv.
            let hash = pipe_to(
                Command::new("mkpasswd"),
                ["-m", "sha-512", "--stdin"],
                &ctx.root_password,
                "mkpasswd",
            )?;
            std::fs::write(&path, hash.trim_end().to_owned() + "\n")?;
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

pub fn which(bin: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|d| d.join(bin).is_file()))
        .unwrap_or(false)
}

fn age_tool() -> &'static str {
    if which("rage") && !which("age") {
        "rage"
    } else {
        "age"
    }
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// Run a command with its stdin fed from a string, returning stdout.
fn pipe_to<I, S>(mut cmd: Command, args: I, stdin: &str, what: &str) -> io::Result<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<std::ffi::OsStr>,
{
    use std::io::Write;
    cmd.args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn()?;
    child
        .stdin
        .take()
        .expect("piped")
        .write_all(stdin.as_bytes())?;
    let out = child.wait_with_output()?;
    if !out.status.success() {
        return Err(io::Error::other(format!(
            "{what} failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The command run inside the pty. The passphrase is deliberately not a parameter: it
/// arrives on stdin, so it never reaches argv and cannot be read out of `ps`.
fn age_command(src: &Path, dest: &Path) -> String {
    format!(
        "{} -d -o {} {}",
        age_tool(),
        shell_quote(&dest.to_string_lossy()),
        shell_quote(&src.to_string_lossy())
    )
}

/// Decrypt a scrypt-encrypted age file without a terminal.
///
/// `age -d` refuses a piped passphrase -- "standard input is not a terminal, and /dev/tty
/// is not available" -- so `script` supplies a pty and the passphrase arrives on its
/// stdin. It is never an argument, so it does not appear in `ps`. `script -e` propagates
/// age's exit status, and a wrong passphrase leaves no output file behind.
pub fn age_decrypt(src: &Path, dest: &Path, passphrase: &str) -> io::Result<()> {
    let inner = age_command(src, dest);
    let out = pipe_to(
        Command::new("script"),
        ["-qec", inner.as_str(), "/dev/null"],
        &format!("{passphrase}\n"),
        "age decrypt",
    );
    match out {
        // A wrong passphrase fails the inner command, which -e surfaces; the missing
        // output file is the backstop.
        Ok(_) if dest.is_file() => Ok(()),
        Ok(_) => Err(io::Error::other(
            "age produced no output; the passphrase is probably wrong",
        )),
        Err(e) => Err(e),
    }
}

fn set_mode(p: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(mode))
}

/// Write the shared LUKS passphrase where disko's passwordFile option expects it. Every
/// encrypted volume on the host formats from this one file, so a single passphrase opens
/// them all and systemd prompts once.
pub fn write_luks_key(ctx: &Ctx) -> io::Result<()> {
    std::fs::create_dir_all(&ctx.scratch)?;
    set_mode(&ctx.scratch, 0o700)?;
    let key = ctx.luks_key();
    std::fs::write(&key, &ctx.luks_passphrase)?;
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
            luks_passphrase: String::new(),
            age_passphrase: String::new(),
            root_password: String::new(),
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
    fn the_age_command_never_carries_the_passphrase() {
        let cmd = age_command(
            Path::new("/repo/secrets/age-key.enc"),
            Path::new("/mnt/persist/secrets/age-keys.txt"),
        );
        // Exactly: tool, -d, -o, dest, src. Anything else risks a secret in argv.
        assert!(cmd.contains(" -d -o "));
        assert!(cmd.ends_with("'/repo/secrets/age-key.enc'"));
        assert!(
            !cmd.contains("passphrase") && !cmd.contains("--password"),
            "the passphrase must arrive on stdin, never in the command line: {cmd}"
        );
    }

    /// The mechanism the whole non-interactive run rests on: age refuses a piped
    /// passphrase, so `script` supplies a pty. Skipped where age is absent, e.g. the nix
    /// build sandbox.
    #[test]
    fn age_round_trips_through_the_pty() {
        if !which("age") || !which("script") {
            eprintln!("skipping: age or script is not on PATH");
            return;
        }
        let d = tmpdir("age");
        let plain = d.join("plain.txt");
        let enc = d.join("key.age");
        let out = d.join("out.txt");
        std::fs::write(&plain, "AGE-SECRET-KEY-1ROUNDTRIP").unwrap();

        // Encrypting needs the same pty trick, which is itself the proof it works.
        let encrypt = format!(
            "age -p -o {} {}",
            shell_quote(&enc.to_string_lossy()),
            shell_quote(&plain.to_string_lossy())
        );
        pipe_to(
            Command::new("script"),
            ["-qec", encrypt.as_str(), "/dev/null"],
            "hunter2\nhunter2\n",
            "age encrypt",
        )
        .expect("encrypt");
        assert!(enc.is_file(), "fixture was not encrypted");

        age_decrypt(&enc, &out, "hunter2").expect("correct passphrase decrypts");
        assert_eq!(
            std::fs::read_to_string(&out).unwrap(),
            "AGE-SECRET-KEY-1ROUNDTRIP"
        );

        // A wrong passphrase must fail loudly and leave nothing behind.
        let bad = d.join("bad.txt");
        assert!(age_decrypt(&enc, &bad, "wrong").is_err());
        assert!(
            !bad.exists(),
            "a failed decrypt must not leave a partial key"
        );

        std::fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn quoting_survives_awkward_paths() {
        assert_eq!(shell_quote("/tmp/a b"), "'/tmp/a b'");
        assert_eq!(shell_quote("it's"), r"'it'\''s'");
    }
}
