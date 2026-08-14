//! TUI installer for this NixOS fleet.

mod disks;
mod nix;
mod phases;
mod profile;

use phases::{Ctx, Phase};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const BY_ID: &str = "/dev/disk/by-id";
const SCRATCH: &str = "/tmp/nixos-install";
const TARGET: &str = "/mnt";

struct Args {
    repo: String,
    host: Option<String>,
    dry_run: bool,
    list_hosts: bool,
    run: bool,
}

fn usage() {
    eprintln!(
        "usage: installer [--repo PATH] [--host HOST] [--dry-run|--run] [--list-hosts]

  --repo PATH   the configuration flake (default: the current directory)
  --host HOST   skip the host picker
  --dry-run     report what would happen and touch nothing
  --run         execute the pending phases without the TUI
  --list-hosts  print every host in the flake

Run with no arguments for the TUI."
    );
}

fn parse_args() -> Result<Args, String> {
    let mut a = Args {
        repo: ".".into(),
        host: None,
        dry_run: false,
        list_hosts: false,
        run: false,
    };
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--repo" => a.repo = it.next().ok_or("--repo needs a path")?,
            "--host" => a.host = Some(it.next().ok_or("--host needs a name")?),
            "--dry-run" => a.dry_run = true,
            "--run" => a.run = true,
            "--list-hosts" => a.list_hosts = true,
            "-h" | "--help" => {
                usage();
                std::process::exit(0);
            }
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    Ok(a)
}

fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("error: {e}");
            usage();
            return ExitCode::FAILURE;
        }
    };

    if let Err(e) = run(&args) {
        eprintln!("error: {e}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

fn run(args: &Args) -> Result<(), String> {
    if args.list_hosts {
        for h in nix::hosts(&args.repo).map_err(|e| e.to_string())? {
            println!("{h}");
        }
        return Ok(());
    }

    if args.dry_run {
        let host = args
            .host
            .clone()
            .ok_or("--dry-run needs --host until the TUI can pick one")?;
        return dry_run(&args.repo, &host);
    }

    if args.run {
        let host = args
            .host
            .clone()
            .ok_or("--run needs --host until the TUI can pick one")?;
        return execute(&args.repo, &host);
    }

    Err("the TUI is not built yet; use --dry-run --host HOST, --run, or --list-hosts".into())
}

/// Build the phase context. `disko` is only resolved when something may actually run,
/// because building it is slow and the inspection predicates do not need it.
fn context(repo: &str, host: &str, facts: nix::Facts, with_disko: bool) -> Result<Ctx, String> {
    let disko = if with_disko {
        nix::disko_bin(repo).map_err(|e| e.to_string())?
    } else {
        String::new()
    };
    Ok(Ctx {
        repo: PathBuf::from(repo),
        target: PathBuf::from(TARGET),
        host: host.to_string(),
        facts,
        disko,
        scratch: PathBuf::from(SCRATCH),
    })
}

fn phase_status(ctx: &Ctx) -> Vec<(Phase, bool)> {
    phases::ALL.iter().map(|p| (*p, p.is_done(ctx))).collect()
}

fn execute(repo: &str, host: &str) -> Result<(), String> {
    if !is_root() {
        return Err("the installer must run as root".into());
    }
    let facts = nix::facts(repo, host).map_err(|e| e.to_string())?;
    let ctx = context(repo, host, facts, true)?;

    for (phase, done) in phase_status(&ctx) {
        if done {
            println!("== {} (already done)", phase.name());
            continue;
        }
        if phase.is_destructive() {
            return Err(format!(
                "{} is pending and is destructive; run it from the TUI, which confirms first",
                phase.name()
            ));
        }
        println!("== {}: {}", phase.name(), phase.describe());
        phase
            .run(&ctx, &mut |line| println!("   {line}"))
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn is_root() -> bool {
    // SAFETY: geteuid is always safe; it takes no arguments and cannot fail.
    unsafe { libc_geteuid() == 0 }
}

// Avoids a libc dependency for one call.
extern "C" {
    #[link_name = "geteuid"]
    fn libc_geteuid() -> u32;
}

/// Report the target's state without touching it.
fn dry_run(repo: &str, host: &str) -> Result<(), String> {
    let fd = nix::fleet_disk(repo, host).map_err(|e| e.to_string())?;
    let configured = fd.enable;
    let p = profile::Profile::from_fleet_disk(host, fd);
    let facts = nix::facts(repo, host).map_err(|e| e.to_string())?;

    println!("host:          {host}");
    println!(
        "layout:        {}",
        if configured {
            "committed in disk-config/"
        } else {
            "none yet (module defaults shown)"
        }
    );
    println!(
        "age key:       {} <- {}",
        facts.age_key_file,
        facts.age_key_source()
    );
    println!("root password: {}", facts.root_password);
    println!(
        "passwords:     {}",
        if facts.mutable_users {
            "set with passwd after install"
        } else {
            "declarative; nothing to run"
        }
    );
    println!("persists /etc/ssh: {}", facts.persist_ssh);

    println!("\ndisks visible now:");
    match disks::list(Path::new(BY_ID)) {
        Ok(ds) if ds.is_empty() => println!("  (none)"),
        Ok(ds) => {
            for d in ds {
                println!(
                    "  {}  {}",
                    d.label(),
                    d.by_id.as_deref().unwrap_or("** no stable by-id link **")
                );
            }
        }
        Err(e) => println!("  (could not enumerate: {e})"),
    }

    println!("\nrendered disk-config/{host}.nix:\n");
    print!("{}", p.to_nix());

    match p.validate() {
        Ok(()) => println!("\nprofile is installable."),
        Err(errs) => {
            println!("\nnot installable yet:");
            for e in errs {
                println!("  - {e}");
            }
        }
    }

    // Status comes from inspecting the target, so this reads correctly on a fresh run, a
    // resume and a re-install alike.
    let ctx = context(repo, host, facts, false)?;
    println!("\nphases:");
    for (phase, done) in phase_status(&ctx) {
        println!(
            "  [{}] {:<10} {}{}",
            if done { "x" } else { " " },
            phase.name(),
            phase.describe(),
            if phase.is_destructive() {
                "  <-- confirmation required"
            } else {
                ""
            }
        );
    }
    println!("\nnothing above was executed.");
    Ok(())
}
