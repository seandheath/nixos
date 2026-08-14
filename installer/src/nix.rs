//! Wrappers over the `nix` CLI.
//!
//! Every invocation carries `--extra-experimental-features`: the live ISO ships with
//! flakes off, and every one of these commands needs them.

use crate::profile::FleetDisk;
use std::io;
use std::process::Command;

/// Facts read from the host's own configuration rather than inferred from the disk
/// layout. Inferring the age-key path from "is this impermanence?" is what put sulfur's
/// key in /persist, where nothing reads it.
#[derive(Debug, Clone)]
pub struct Facts {
    pub age_key_file: String,
    pub sops_file: String,
    pub root_password: String,
    pub mutable_users: bool,
    pub persist_ssh: bool,
}

impl Facts {
    /// The family key decrypts secrets/family.yaml and nothing else -- not the Borg
    /// repository key, not the Nextcloud admin password. See .sops.yaml.
    pub fn age_key_source(&self) -> &'static str {
        if self.sops_file == "family.yaml" {
            "secrets/family-age-key.enc"
        } else {
            "secrets/age-key.enc"
        }
    }
}

fn nix() -> Command {
    let mut c = Command::new("nix");
    c.args(["--extra-experimental-features", "nix-command flakes"]);
    c
}

fn run(mut c: Command, what: &str) -> io::Result<String> {
    let out = c.output()?;
    if !out.status.success() {
        return Err(io::Error::other(format!(
            "{what} failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Every host in the flake. The family laptops have no `hosts/<name>.nix`, so listing
/// that directory cannot name them -- that mistake wiped a disk on 2026-08-14.
pub fn hosts(repo: &str) -> io::Result<Vec<String>> {
    let mut c = nix();
    c.args([
        "eval",
        "--raw",
        &format!("{repo}#nixosConfigurations"),
        "--apply",
        r#"c: builtins.concatStringsSep "\n" (builtins.attrNames c)"#,
    ]);
    Ok(run(c, "listing hosts")?
        .lines()
        .map(str::to_string)
        .filter(|l| !l.is_empty())
        .collect())
}

pub fn fleet_disk(repo: &str, host: &str) -> io::Result<FleetDisk> {
    let mut c = nix();
    c.args([
        "eval",
        "--json",
        &format!("{repo}#nixosConfigurations.{host}.config.fleet.disk"),
    ]);
    let json = run(c, "reading fleet.disk")?;
    serde_json::from_str(&json).map_err(|e| io::Error::other(format!("fleet.disk: {e}")))
}

/// Emitted as `key=value` lines rather than JSON so the expression stays readable, and
/// inlined rather than imported from a file, which pure evaluation mode forbids.
const FACTS_APPLY: &str = r#"c:
let
  bool = b: if b then "true" else "false";
  persistSsh =
    let stores = builtins.attrValues (c.environment.persistence or { });
    in builtins.any
         (s: builtins.any (d: (d.directory or d) == "/etc/ssh") (s.directories or [ ]))
         stores;
in ''
  ageKeyFile=${c.sops.age.keyFile}
  sopsFile=${builtins.baseNameOf (toString c.sops.defaultSopsFile)}
  rootPassword=${c.fleet.accounts.rootPassword}
  mutableUsers=${bool c.users.mutableUsers}
  persistSsh=${bool persistSsh}
''"#;

pub fn facts(repo: &str, host: &str) -> io::Result<Facts> {
    let mut c = nix();
    c.args([
        "eval",
        "--raw",
        &format!("{repo}#nixosConfigurations.{host}.config"),
        "--apply",
        FACTS_APPLY,
    ]);
    let out = run(c, "reading host facts")?;
    parse_facts(&out)
}

fn parse_facts(out: &str) -> io::Result<Facts> {
    let mut age_key_file = None;
    let mut sops_file = None;
    let mut root_password = None;
    let mut mutable_users = None;
    let mut persist_ssh = None;

    for line in out.lines() {
        let line = line.trim();
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        match k {
            "ageKeyFile" => age_key_file = Some(v.to_string()),
            "sopsFile" => sops_file = Some(v.to_string()),
            "rootPassword" => root_password = Some(v.to_string()),
            "mutableUsers" => mutable_users = Some(v == "true"),
            "persistSsh" => persist_ssh = Some(v == "true"),
            _ => {}
        }
    }

    Ok(Facts {
        age_key_file: age_key_file
            .ok_or_else(|| io::Error::other("no sops.age.keyFile in the host's config"))?,
        sops_file: sops_file.unwrap_or_default(),
        root_password: root_password.unwrap_or_else(|| "none".into()),
        mutable_users: mutable_users.unwrap_or(true),
        persist_ssh: persist_ssh.unwrap_or(false),
    })
}

/// Build the host's partitioning script. This is disko itself accepting the layout, so it
/// is the strongest check available without touching a disk.
pub fn build_disko_script(repo: &str, host: &str) -> io::Result<String> {
    let mut c = nix();
    c.args([
        "build",
        "--no-link",
        "--print-out-paths",
        &format!("{repo}#nixosConfigurations.{host}.config.system.build.diskoScript"),
    ]);
    Ok(run(c, "building the partitioning script")?
        .trim()
        .to_string())
}

/// The locked disko revision, so the CLI matches the module the layout was built against.
pub fn disko_bin(repo: &str) -> io::Result<String> {
    let mut c = nix();
    c.args([
        "eval",
        "--raw",
        "--impure",
        "--expr",
        &format!(
            "(builtins.fromJSON (builtins.readFile {repo}/flake.lock)).nodes.disko.locked.rev"
        ),
    ]);
    let rev = run(c, "reading the locked disko revision")?;

    let mut c = nix();
    c.args([
        "build",
        "--no-link",
        "--print-out-paths",
        &format!("github:nix-community/disko/{}", rev.trim()),
    ]);
    Ok(format!("{}/bin/disko", run(c, "building disko")?.trim()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_facts_output() {
        // Exactly what the apply expression emits for sulfur.
        let out = "  ageKeyFile=/home/sheath/.config/sops/age/keys.txt\n\
                   \x20 sopsFile=secrets.yaml\n\
                   \x20 rootPassword=persist\n\
                   \x20 mutableUsers=false\n\
                   \x20 persistSsh=true\n";
        let f = parse_facts(out).unwrap();
        assert_eq!(f.age_key_file, "/home/sheath/.config/sops/age/keys.txt");
        assert_eq!(f.root_password, "persist");
        assert!(!f.mutable_users);
        assert!(f.persist_ssh);
        assert_eq!(f.age_key_source(), "secrets/age-key.enc");
    }

    #[test]
    fn family_hosts_take_the_family_key() {
        let out = "ageKeyFile=/home/sheath/.config/sops/age/keys.txt\n\
                   sopsFile=family.yaml\n\
                   rootPassword=none\n\
                   mutableUsers=false\n\
                   persistSsh=false\n";
        let f = parse_facts(out).unwrap();
        assert_eq!(f.age_key_source(), "secrets/family-age-key.enc");
    }

    #[test]
    fn hydrogen_keeps_its_persist_key_path() {
        let out = "ageKeyFile=/persist/secrets/age-keys.txt\nsopsFile=secrets.yaml\n";
        let f = parse_facts(out).unwrap();
        assert_eq!(f.age_key_file, "/persist/secrets/age-keys.txt");
    }

    #[test]
    fn a_missing_key_path_is_an_error_not_a_default() {
        assert!(parse_facts("sopsFile=secrets.yaml\n").is_err());
    }
}
