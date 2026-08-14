//! TUI installer for this NixOS fleet.

mod disks;
mod nix;
mod profile;

use std::path::Path;
use std::process::ExitCode;

const BY_ID: &str = "/dev/disk/by-id";

struct Args {
    repo: String,
    host: Option<String>,
    dry_run: bool,
    list_hosts: bool,
}

fn usage() {
    eprintln!(
        "usage: installer [--repo PATH] [--host HOST] [--dry-run] [--list-hosts]

  --repo PATH   the configuration flake (default: the current directory)
  --host HOST   skip the host picker
  --dry-run     report what would happen and touch nothing
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
    };
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--repo" => a.repo = it.next().ok_or("--repo needs a path")?,
            "--host" => a.host = Some(it.next().ok_or("--host needs a name")?),
            "--dry-run" => a.dry_run = true,
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

    Err("the TUI is not built yet; use --dry-run --host HOST or --list-hosts".into())
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
    Ok(())
}
