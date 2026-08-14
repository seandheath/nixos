//! TUI installer for this NixOS fleet.

mod checks;
mod disks;
mod nix;
mod phases;
mod profile;
mod ui;

use checks::Board;
use std::process::ExitCode;

pub const BY_ID: &str = "/dev/disk/by-id";
pub const SCRATCH: &str = "/tmp/nixos-install";
pub const TARGET: &str = "/mnt";

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
  --host HOST   preselect the host
  --dry-run     run every check, print the result, and change nothing
  --list-hosts  print every host in the flake

Run with no arguments for the dashboard."
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
    match run(&args) {
        Ok(code) => code,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: &Args) -> Result<ExitCode, String> {
    if args.list_hosts {
        for h in nix::hosts(&args.repo).map_err(|e| e.to_string())? {
            println!("{h}");
        }
        return Ok(ExitCode::SUCCESS);
    }

    let hosts = nix::hosts(&args.repo).map_err(|e| e.to_string())?;
    if hosts.is_empty() {
        return Err("the flake defines no hosts".into());
    }
    let mut board = Board::new(&args.repo, hosts);
    if let Some(h) = &args.host {
        board.host_idx = board
            .hosts
            .iter()
            .position(|x| x == h)
            .ok_or_else(|| format!("no such host: {h}"))?;
    }

    if args.dry_run {
        return Ok(dry_run(board));
    }
    if !is_root() {
        return Err("the installer must run as root".into());
    }
    ui::run(board).map_err(|e| e.to_string())?;
    Ok(ExitCode::SUCCESS)
}

/// Every check, reported, with nothing changed. Useful over SSH, where there is no
/// terminal for the dashboard.
fn dry_run(mut board: Board) -> ExitCode {
    board.allow_writes = false;
    println!("host: {}\n", board.host());
    board.load_host();
    board.check_all();

    for id in checks::ALL {
        let st = board.status(id);
        println!("{} {:<14} {}", st.glyph(), id.label(), st.summary());
    }

    let unmet: Vec<&str> = checks::ALL
        .iter()
        .filter(|id| !board.status(**id).satisfied())
        .map(|id| id.label())
        .collect();

    println!("\nNo file was written and no disk was touched.");
    if unmet.is_empty() {
        ExitCode::SUCCESS
    } else {
        // Passphrases cannot be entered without the dashboard, so those rows fail here
        // by construction rather than indicating a problem.
        println!("unmet: {}", unmet.join(", "));
        ExitCode::FAILURE
    }
}

pub fn is_root() -> bool {
    // SAFETY: geteuid takes no arguments and cannot fail.
    unsafe { libc_geteuid() == 0 }
}

// Avoids a libc dependency for one call.
extern "C" {
    #[link_name = "geteuid"]
    fn libc_geteuid() -> u32;
}

#[cfg(test)]
mod tests {
    use super::*;
    use checks::Status;

    #[test]
    fn dry_run_reports_unmet_rows_rather_than_claiming_success() {
        // A board that was never loaded has pending rows, so the summary must not be "ready".
        let board = Board::new("/definitely/not/a/repo", vec!["nohost".into()]);
        let unmet: Vec<&str> = checks::ALL
            .iter()
            .filter(|id| !board.status(**id).satisfied())
            .map(|id| id.label())
            .collect();
        assert!(!unmet.is_empty());
        assert!(matches!(
            board.status(checks::CheckId::Layout),
            Status::Pending
        ));
    }
}
