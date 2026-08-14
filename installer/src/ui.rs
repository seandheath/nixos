//! The installer TUI.
//!
//! Every option is chosen and reviewed before anything executes. Phases then run on this
//! thread, redrawing on each log line: the interactive ones have to hand the terminal to
//! a child process, and coordinating that with a worker thread buys nothing here.

use crate::disks::Disk;
use crate::nix::Facts;
use crate::phases::{self, Ctx, Phase};
use crate::profile::{Profile, RootMode};

use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use crossterm::{execute, ExecutableCommand};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, List, ListItem, Paragraph, Wrap};
use ratatui::{Frame, Terminal};

use std::io::{self, Stdout};
use std::path::{Path, PathBuf};

type Term = Terminal<CrosstermBackend<Stdout>>;

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
enum Screen {
    Host,
    Disks,
    Options,
    Review,
    Run,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Role {
    System,
    Home,
    Data,
}

#[derive(PartialEq, Eq)]
enum Modal {
    None,
    /// Typing ERASE, the last gate before the one destructive phase.
    Erase(String),
    /// The shared LUKS passphrase; every encrypted volume formats from it.
    Passphrase {
        first: String,
        second: String,
        confirming: bool,
    },
    Error(String),
}

pub struct App {
    repo: String,
    screen: Screen,
    modal: Modal,

    hosts: Vec<String>,
    host_idx: usize,

    facts: Option<Facts>,
    profile: Option<Profile>,

    disks: Vec<Disk>,
    disk_idx: usize,

    opt_idx: usize,
    editing: Option<String>,

    phase_done: Vec<bool>,
    log: Vec<String>,
    status: String,
    quit: bool,
}

const OPTIONS: [&str; 6] = [
    "encrypt with LUKS",
    "root mode",
    "tmpfs size",
    "swap size",
    "ESP size",
    "/data filesystem type",
];

impl App {
    pub fn new(repo: &str, hosts: Vec<String>) -> Self {
        App {
            repo: repo.to_string(),
            screen: Screen::Host,
            modal: Modal::None,
            hosts,
            host_idx: 0,
            facts: None,
            profile: None,
            disks: Vec::new(),
            disk_idx: 0,
            opt_idx: 0,
            editing: None,
            phase_done: vec![false; phases::ALL.len()],
            log: Vec::new(),
            status: String::new(),
            quit: false,
        }
    }

    fn host(&self) -> &str {
        &self.hosts[self.host_idx]
    }

    fn ctx(&self, with_disko: bool) -> Result<Ctx, String> {
        let facts = self.facts.clone().ok_or("host facts not loaded")?;
        let disko = if with_disko {
            crate::nix::disko_bin(&self.repo).map_err(|e| e.to_string())?
        } else {
            String::new()
        };
        Ok(Ctx {
            repo: PathBuf::from(&self.repo),
            target: PathBuf::from(crate::TARGET),
            host: self.host().to_string(),
            facts,
            disko,
            scratch: PathBuf::from(crate::SCRATCH),
        })
    }

    fn refresh_phase_status(&mut self) {
        if let Ok(ctx) = self.ctx(false) {
            self.phase_done = phases::ALL.iter().map(|p| p.is_done(&ctx)).collect();
        }
    }

    fn layout_path(&self) -> PathBuf {
        Path::new(&self.repo).join(format!("disk-config/{}.nix", self.host()))
    }
}

pub fn run(repo: &str, hosts: Vec<String>) -> io::Result<()> {
    let mut term = setup()?;
    let mut app = App::new(repo, hosts);
    let res = event_loop(&mut term, &mut app);
    teardown(&mut term)?;
    res
}

fn setup() -> io::Result<Term> {
    enable_raw_mode()?;
    let mut out = io::stdout();
    out.execute(EnterAlternateScreen)?;
    Terminal::new(CrosstermBackend::new(out))
}

fn teardown(term: &mut Term) -> io::Result<()> {
    disable_raw_mode()?;
    execute!(term.backend_mut(), LeaveAlternateScreen)?;
    term.show_cursor()
}

fn event_loop(term: &mut Term, app: &mut App) -> io::Result<()> {
    loop {
        term.draw(|f| draw(f, app))?;
        if app.quit {
            return Ok(());
        }
        let Event::Key(key) = event::read()? else {
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }
        handle_key(term, app, key.code);
    }
}

fn handle_key(term: &mut Term, app: &mut App, code: KeyCode) {
    if app.modal != Modal::None {
        return modal_key(term, app, code);
    }
    if app.editing.is_some() {
        return edit_key(app, code);
    }
    match code {
        KeyCode::Char('q') => app.quit = true,
        KeyCode::Esc => back(app),
        _ => match app.screen {
            Screen::Host => host_key(app, code),
            Screen::Disks => disks_key(app, code),
            Screen::Options => options_key(app, code),
            Screen::Review => review_key(app, code),
            Screen::Run => run_key(term, app, code),
        },
    }
}

fn back(app: &mut App) {
    app.screen = match app.screen {
        Screen::Host => Screen::Host,
        Screen::Disks => Screen::Host,
        Screen::Options => Screen::Disks,
        Screen::Review => Screen::Options,
        Screen::Run => Screen::Review,
    };
}

// --- host ------------------------------------------------------------------------------

fn host_key(app: &mut App, code: KeyCode) {
    match code {
        KeyCode::Up | KeyCode::Char('k') => app.host_idx = app.host_idx.saturating_sub(1),
        KeyCode::Down | KeyCode::Char('j') => {
            app.host_idx = (app.host_idx + 1).min(app.hosts.len().saturating_sub(1))
        }
        KeyCode::Enter => load_host(app),
        _ => {}
    }
}

/// Reads the host's own configuration. Slow -- a full module-system evaluation -- so the
/// status line says so before it blocks.
fn load_host(app: &mut App) {
    app.status = format!("evaluating {}...", app.host());

    let fd = match crate::nix::fleet_disk(&app.repo, app.host()) {
        Ok(v) => v,
        Err(e) => return app.modal = Modal::Error(e.to_string()),
    };
    let facts = match crate::nix::facts(&app.repo, app.host()) {
        Ok(v) => v,
        Err(e) => return app.modal = Modal::Error(e.to_string()),
    };

    let mut profile = Profile::from_fleet_disk(app.host(), fd);
    app.disks = crate::disks::list(Path::new(crate::BY_ID)).unwrap_or_default();

    // An existing layout may name a disk that is not in this machine; keep it, but do not
    // pretend it was seen.
    if profile.system_device == crate::profile::UNSET_DEVICE {
        if let Some(d) = app.disks.iter().find_map(|d| d.by_id.clone()) {
            profile.system_device = d;
        }
    }

    app.facts = Some(facts);
    app.profile = Some(profile);
    app.status.clear();
    app.refresh_phase_status();
    app.screen = Screen::Disks;
}

// --- disks -----------------------------------------------------------------------------

fn disks_key(app: &mut App, code: KeyCode) {
    match code {
        KeyCode::Up | KeyCode::Char('k') => app.disk_idx = app.disk_idx.saturating_sub(1),
        KeyCode::Down | KeyCode::Char('j') => {
            app.disk_idx = (app.disk_idx + 1).min(app.disks.len().saturating_sub(1))
        }
        KeyCode::Char('s') => assign(app, Some(Role::System)),
        KeyCode::Char('h') => assign(app, Some(Role::Home)),
        KeyCode::Char('d') => assign(app, Some(Role::Data)),
        KeyCode::Char('x') => assign(app, None),
        KeyCode::Enter => app.screen = Screen::Options,
        _ => {}
    }
}

fn assign(app: &mut App, role: Option<Role>) {
    let Some(disk) = app.disks.get(app.disk_idx).cloned() else {
        return;
    };
    let Some(p) = app.profile.as_mut() else {
        return;
    };

    let Some(by_id) = disk.by_id.clone() else {
        app.modal = Modal::Error(format!(
            "{} has no /dev/disk/by-id link. Kernel names reorder across boots, so it \
             cannot be written into a layout.",
            disk.name
        ));
        return;
    };

    // A disk holds one role: clear it from the others first.
    if p.system_device == by_id {
        p.system_device = crate::profile::UNSET_DEVICE.to_string();
    }
    if p.home_device.as_deref() == Some(by_id.as_str()) {
        p.home_device = None;
    }
    if p.data_device.as_deref() == Some(by_id.as_str()) {
        p.data_device = None;
    }

    match role {
        Some(Role::System) => p.system_device = by_id,
        Some(Role::Home) => p.home_device = Some(by_id),
        // Preserved, never formatted: mounted by-uuid so a multi-device btrfs assembles
        // its whole array. by-id here names the member the operator pointed at.
        Some(Role::Data) => p.data_device = Some(by_id),
        None => {}
    }
}

fn role_of(p: &Profile, disk: &Disk) -> Option<Role> {
    let by_id = disk.by_id.as_deref()?;
    if p.system_device == by_id {
        Some(Role::System)
    } else if p.home_device.as_deref() == Some(by_id) {
        Some(Role::Home)
    } else if p.data_device.as_deref() == Some(by_id) {
        Some(Role::Data)
    } else {
        None
    }
}

// --- options ---------------------------------------------------------------------------

fn options_key(app: &mut App, code: KeyCode) {
    match code {
        KeyCode::Up | KeyCode::Char('k') => app.opt_idx = app.opt_idx.saturating_sub(1),
        KeyCode::Down | KeyCode::Char('j') => {
            app.opt_idx = (app.opt_idx + 1).min(OPTIONS.len() - 1)
        }
        // Space changes the field, Enter moves on. Sharing Enter for both left this
        // screen with no way forward.
        KeyCode::Char(' ') => toggle_or_edit(app),
        KeyCode::Enter => app.screen = Screen::Review,
        _ => {}
    }
}

fn toggle_or_edit(app: &mut App) {
    let idx = app.opt_idx;
    let Some(p) = app.profile.as_mut() else {
        return;
    };
    match idx {
        0 => {
            p.system_encrypt = !p.system_encrypt;
            // One passphrase opens every volume, so the two flags move together.
            p.home_encrypt = p.system_encrypt;
        }
        1 => {
            p.root_mode = match p.root_mode {
                RootMode::Subvol => RootMode::Tmpfs,
                RootMode::Tmpfs => RootMode::Subvol,
            }
        }
        2 => app.editing = Some(p.tmpfs_size.clone()),
        3 => app.editing = Some(p.swap_size.clone().unwrap_or_default()),
        4 => app.editing = Some(p.esp_size.clone()),
        5 => app.editing = Some(p.data_fs_type.clone()),
        _ => {}
    }
}

fn edit_key(app: &mut App, code: KeyCode) {
    let Some(buf) = app.editing.as_mut() else {
        return;
    };
    match code {
        KeyCode::Char(c) => buf.push(c),
        KeyCode::Backspace => {
            buf.pop();
        }
        KeyCode::Esc => app.editing = None,
        KeyCode::Enter => {
            let value = buf.clone();
            app.editing = None;
            let idx = app.opt_idx;
            if let Some(p) = app.profile.as_mut() {
                match idx {
                    2 => p.tmpfs_size = value,
                    3 => p.swap_size = (!value.is_empty()).then_some(value),
                    4 => p.esp_size = value,
                    5 => p.data_fs_type = value,
                    _ => {}
                }
            }
        }
        _ => {}
    }
}

// --- review ----------------------------------------------------------------------------

fn review_key(app: &mut App, code: KeyCode) {
    match code {
        KeyCode::Char('w') => write_layout(app),
        KeyCode::Enter => {
            write_layout(app);
            if app.modal == Modal::None {
                app.refresh_phase_status();
                app.screen = Screen::Run;
            }
        }
        _ => {}
    }
}

fn write_layout(app: &mut App) {
    let Some(p) = app.profile.as_ref() else {
        return;
    };
    if let Err(errs) = p.validate() {
        app.modal = Modal::Error(errs.join("\n"));
        return;
    }
    let path = app.layout_path();
    if let Some(d) = path.parent() {
        if let Err(e) = std::fs::create_dir_all(d) {
            app.modal = Modal::Error(e.to_string());
            return;
        }
    }
    if let Err(e) = std::fs::write(&path, p.to_nix()) {
        app.modal = Modal::Error(e.to_string());
        return;
    }
    // Untracked files are invisible to flake evaluation, and disko reads the flake.
    if let Ok(ctx) = app.ctx(false) {
        let rel = format!("disk-config/{}.nix", app.host());
        let _ = phases::git_add(&ctx, &rel, &mut |_| {});
    }
    app.status = format!("wrote {}", path.display());
}

// --- run -------------------------------------------------------------------------------

fn run_key(term: &mut Term, app: &mut App, code: KeyCode) {
    match code {
        KeyCode::Char('r') => start_run(term, app),
        KeyCode::Char('R') => {
            app.refresh_phase_status();
            app.status = "re-checked the target".into();
        }
        KeyCode::Char('m') => remount(app),
        _ => {}
    }
}

/// Re-attach an already-installed machine. After an ISO reboot nothing is mounted, so
/// every phase reads as pending -- including the destructive one. Mounting first is what
/// turns a resume back into a resume instead of a re-partition.
fn remount(app: &mut App) {
    let ctx = match app.ctx(true) {
        Ok(c) => c,
        Err(e) => return app.modal = Modal::Error(e),
    };
    let mut lines = Vec::new();
    match phases::remount(&ctx, &mut |l| lines.push(l.to_string())) {
        Ok(()) => {
            app.log.extend(lines);
            app.refresh_phase_status();
            app.status = "mounted the existing target".into();
        }
        Err(e) => {
            app.log.extend(lines);
            app.modal = Modal::Error(format!("could not mount: {e}"));
        }
    }
}

fn start_run(term: &mut Term, app: &mut App) {
    let pending: Vec<Phase> = phases::ALL
        .iter()
        .zip(&app.phase_done)
        .filter(|(_, done)| !**done)
        .map(|(p, _)| *p)
        .collect();

    if pending.is_empty() {
        app.status = "nothing to do".into();
        return;
    }

    // Collect the destructive confirmation and the passphrase before anything runs.
    if pending.iter().any(|p| p.is_destructive()) {
        if app.profile.as_ref().is_some_and(|p| p.system_encrypt) {
            app.modal = Modal::Passphrase {
                first: String::new(),
                second: String::new(),
                confirming: false,
            };
        } else {
            app.modal = Modal::Erase(String::new());
        }
        return;
    }
    execute_pending(term, app);
}

fn execute_pending(term: &mut Term, app: &mut App) {
    let ctx = match app.ctx(true) {
        Ok(c) => c,
        Err(e) => {
            app.modal = Modal::Error(e);
            return;
        }
    };

    for (i, phase) in phases::ALL.iter().enumerate() {
        if app.phase_done[i] {
            continue;
        }
        app.status = format!("running {}", phase.name());
        app.log.push(format!("== {}", phase.name()));

        let result = if phase.needs_tty() {
            // age prompts for the key's passphrase on /dev/tty and mkpasswd reads the
            // root password there, so the TUI stands aside rather than capturing them.
            let _ = teardown(term);
            println!("\n== {}: {}\n", phase.name(), phase.describe());
            let r = phase.run(&ctx, &mut |line| println!("   {line}"));
            if let Ok(t) = setup() {
                *term = t;
            }
            r
        } else {
            let mut lines: Vec<String> = Vec::new();
            let r = phase.run(&ctx, &mut |line| lines.push(line.to_string()));
            app.log.extend(lines);
            r
        };

        match result {
            Ok(()) => {
                app.phase_done[i] = true;
                app.log.push(format!("   {} done", phase.name()));
            }
            Err(e) => {
                app.log.push(format!("   {} FAILED: {e}", phase.name()));
                app.modal = Modal::Error(format!("{} failed:\n{e}", phase.name()));
                app.status = format!("{} failed", phase.name());
                return;
            }
        }
        let _ = term.draw(|f| draw(f, app));
    }

    app.status = "all phases complete".into();
    app.log.push(String::new());
    app.log.push(format!(
        "Commit disk-config/{}.nix and hardware/{}.nix -- every host rebuilds from",
        app.host(),
        app.host()
    ));
    app.log
        .push("github:seandheath/nixos nightly, and an uncommitted layout is reverted.".into());
}

// --- modals ----------------------------------------------------------------------------

fn modal_key(term: &mut Term, app: &mut App, code: KeyCode) {
    match &mut app.modal {
        Modal::Error(_) => {
            if matches!(code, KeyCode::Enter | KeyCode::Esc) {
                app.modal = Modal::None;
            }
        }
        Modal::Erase(buf) => match code {
            KeyCode::Char(c) => buf.push(c),
            KeyCode::Backspace => {
                buf.pop();
            }
            KeyCode::Esc => app.modal = Modal::None,
            KeyCode::Enter => {
                if buf == "ERASE" {
                    app.modal = Modal::None;
                    execute_pending(term, app);
                } else {
                    app.modal = Modal::Error("not confirmed".into());
                }
            }
            _ => {}
        },
        Modal::Passphrase {
            first,
            second,
            confirming,
        } => match code {
            KeyCode::Char(c) => {
                if *confirming {
                    second.push(c)
                } else {
                    first.push(c)
                }
            }
            KeyCode::Backspace => {
                if *confirming {
                    second.pop();
                } else {
                    first.pop();
                };
            }
            KeyCode::Esc => app.modal = Modal::None,
            KeyCode::Enter => {
                if !*confirming {
                    if first.is_empty() {
                        return;
                    }
                    *confirming = true;
                } else if first == second {
                    let pass = first.clone();
                    app.modal = Modal::None;
                    if let Ok(ctx) = app.ctx(false) {
                        if let Err(e) = phases::write_luks_key(&ctx, &pass) {
                            app.modal = Modal::Error(e.to_string());
                            return;
                        }
                    }
                    app.modal = Modal::Erase(String::new());
                } else {
                    app.modal = Modal::Error("passphrases did not match".into());
                }
            }
            _ => {}
        },
        Modal::None => {}
    }
}

// --- drawing ---------------------------------------------------------------------------

fn draw(f: &mut Frame, app: &App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(5),
            Constraint::Length(3),
        ])
        .split(f.area());

    let host = if app.facts.is_some() {
        app.host().to_string()
    } else {
        "-".into()
    };
    let title = Paragraph::new(Line::from(vec![
        Span::styled(
            "NixOS installer",
            Style::default().add_modifier(Modifier::BOLD),
        ),
        Span::raw(format!("   host: {host}   ")),
        Span::styled(&app.status, Style::default().fg(Color::Yellow)),
    ]))
    .block(Block::default().borders(Borders::ALL));
    f.render_widget(title, chunks[0]);

    match app.screen {
        Screen::Host => draw_hosts(f, chunks[1], app),
        Screen::Disks => draw_disks(f, chunks[1], app),
        Screen::Options => draw_options(f, chunks[1], app),
        Screen::Review => draw_review(f, chunks[1], app),
        Screen::Run => draw_run(f, chunks[1], app),
    }

    let help = match app.screen {
        Screen::Host => "j/k move   Enter select   q quit",
        Screen::Disks => {
            "j/k move   s system   h /home   d /data   x clear   Enter next   Esc back"
        }
        Screen::Options => "j/k move   Space change   Enter continue   Esc back",
        Screen::Review => "w write layout   Enter write and continue   Esc back",
        Screen::Run => "r run pending   m mount existing   R re-check   Esc back   q quit",
    };
    f.render_widget(
        Paragraph::new(help).block(Block::default().borders(Borders::ALL)),
        chunks[2],
    );

    draw_modal(f, app);
}

fn draw_hosts(f: &mut Frame, area: Rect, app: &App) {
    let items: Vec<ListItem> = app
        .hosts
        .iter()
        .enumerate()
        .map(|(i, h)| {
            let style = if i == app.host_idx {
                Style::default().add_modifier(Modifier::REVERSED)
            } else {
                Style::default()
            };
            ListItem::new(h.clone()).style(style)
        })
        .collect();
    f.render_widget(
        List::new(items).block(Block::default().borders(Borders::ALL).title(" host ")),
        area,
    );
}

fn draw_disks(f: &mut Frame, area: Rect, app: &App) {
    let Some(p) = app.profile.as_ref() else {
        return;
    };
    let items: Vec<ListItem> = app
        .disks
        .iter()
        .enumerate()
        .map(|(i, d)| {
            let role = match role_of(p, d) {
                Some(Role::System) => "system",
                Some(Role::Home) => "/home ",
                Some(Role::Data) => "/data ",
                None => "      ",
            };
            let stable = if d.by_id.is_some() {
                ""
            } else {
                "  (no by-id link)"
            };
            let style = if i == app.disk_idx {
                Style::default().add_modifier(Modifier::REVERSED)
            } else {
                Style::default()
            };
            ListItem::new(format!("[{role}] {}{stable}", d.label())).style(style)
        })
        .collect();
    f.render_widget(
        List::new(items).block(
            Block::default()
                .borders(Borders::ALL)
                .title(" disks -- /data is preserved, never formatted "),
        ),
        area,
    );
}

fn draw_options(f: &mut Frame, area: Rect, app: &App) {
    let Some(p) = app.profile.as_ref() else {
        return;
    };
    let values = [
        if p.system_encrypt {
            "yes".into()
        } else {
            "no".into()
        },
        p.root_mode.as_nix().to_string(),
        p.tmpfs_size.clone(),
        p.swap_size.clone().unwrap_or_else(|| "none".into()),
        p.esp_size.clone(),
        p.data_fs_type.clone(),
    ];
    let items: Vec<ListItem> = OPTIONS
        .iter()
        .zip(values.iter())
        .enumerate()
        .map(|(i, (name, value))| {
            let shown = if i == app.opt_idx {
                app.editing.as_deref().unwrap_or(value)
            } else {
                value
            };
            let style = if i == app.opt_idx {
                Style::default().add_modifier(Modifier::REVERSED)
            } else {
                Style::default()
            };
            ListItem::new(format!("{name:<24} {shown}")).style(style)
        })
        .collect();
    f.render_widget(
        List::new(items).block(Block::default().borders(Borders::ALL).title(" options ")),
        area,
    );
}

fn draw_review(f: &mut Frame, area: Rect, app: &App) {
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(55), Constraint::Percentage(45)])
        .split(area);

    let nix = app.profile.as_ref().map(|p| p.to_nix()).unwrap_or_default();
    f.render_widget(
        Paragraph::new(nix).wrap(Wrap { trim: false }).block(
            Block::default()
                .borders(Borders::ALL)
                .title(" disk-config "),
        ),
        cols[0],
    );

    let mut lines = Vec::new();
    if let Some(fa) = app.facts.as_ref() {
        lines.push(Line::from(format!("age key   {}", fa.age_key_file)));
        lines.push(Line::from(format!("  from    {}", fa.age_key_source())));
        lines.push(Line::from(format!("root pw   {}", fa.root_password)));
        lines.push(Line::from(format!(
            "passwords {}",
            if fa.mutable_users {
                "passwd after install"
            } else {
                "declarative"
            }
        )));
        lines.push(Line::from(format!(
            "/etc/ssh  persisted: {}",
            fa.persist_ssh
        )));
    }
    lines.push(Line::from(""));
    match app.profile.as_ref().map(|p| p.validate()) {
        Some(Ok(())) => lines.push(Line::from(Span::styled(
            "installable",
            Style::default().fg(Color::Green),
        ))),
        Some(Err(errs)) => {
            for e in errs {
                lines.push(Line::from(Span::styled(
                    format!("- {e}"),
                    Style::default().fg(Color::Red),
                )));
            }
        }
        None => {}
    }
    f.render_widget(
        Paragraph::new(lines)
            .wrap(Wrap { trim: false })
            .block(Block::default().borders(Borders::ALL).title(" this host ")),
        cols[1],
    );
}

fn draw_run(f: &mut Frame, area: Rect, app: &App) {
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(8), Constraint::Min(3)])
        .split(area);

    let items: Vec<ListItem> = phases::ALL
        .iter()
        .zip(&app.phase_done)
        .map(|(p, done)| {
            let mark = if *done { "x" } else { " " };
            let style = if p.is_destructive() && !*done {
                Style::default().fg(Color::Red)
            } else if *done {
                Style::default().fg(Color::Green)
            } else {
                Style::default()
            };
            ListItem::new(format!("[{mark}] {:<10} {}", p.name(), p.describe())).style(style)
        })
        .collect();
    let title = if app.phase_done.first() == Some(&false) {
        " phases -- if this machine is ALREADY INSTALLED, press m to mount it first "
    } else {
        " phases "
    };
    f.render_widget(
        List::new(items).block(Block::default().borders(Borders::ALL).title(title)),
        rows[0],
    );

    let height = rows[1].height.saturating_sub(2) as usize;
    let start = app.log.len().saturating_sub(height);
    f.render_widget(
        Paragraph::new(app.log[start..].join("\n"))
            .wrap(Wrap { trim: false })
            .block(Block::default().borders(Borders::ALL).title(" log ")),
        rows[1],
    );
}

fn draw_modal(f: &mut Frame, app: &App) {
    let (title, body, colour) = match &app.modal {
        Modal::None => return,
        Modal::Error(e) => (" error ", e.clone(), Color::Red),
        Modal::Erase(buf) => (
            " destructive ",
            format!(
                "Every disk assigned a role above will be erased.\n\
                 /data, if set, is preserved.\n\n\
                 Type ERASE to continue: {buf}"
            ),
            Color::Red,
        ),
        Modal::Passphrase {
            first,
            second,
            confirming,
        } => (
            " LUKS passphrase ",
            format!(
                "One passphrase opens every encrypted volume on this host.\n\n{}: {}",
                if *confirming { "Again" } else { "Passphrase" },
                "*".repeat(if *confirming {
                    second.len()
                } else {
                    first.len()
                })
            ),
            Color::Yellow,
        ),
    };

    let area = centered(60, 40, f.area());
    f.render_widget(Clear, area);
    f.render_widget(
        Paragraph::new(body).wrap(Wrap { trim: false }).block(
            Block::default()
                .borders(Borders::ALL)
                .title(title)
                .border_style(Style::default().fg(colour)),
        ),
        area,
    );
}

fn centered(pct_x: u16, pct_y: u16, area: Rect) -> Rect {
    let v = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - pct_y) / 2),
            Constraint::Percentage(pct_y),
            Constraint::Percentage((100 - pct_y) / 2),
        ])
        .split(area);
    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - pct_x) / 2),
            Constraint::Percentage(pct_x),
            Constraint::Percentage((100 - pct_x) / 2),
        ])
        .split(v[1])[1]
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;

    /// Every cell's symbol, row after row. Enough for `contains` assertions.
    fn render(app: &App) -> String {
        let mut t = Terminal::new(TestBackend::new(100, 30)).unwrap();
        t.draw(|f| draw(f, app)).unwrap();
        t.backend()
            .buffer()
            .content
            .iter()
            .map(|c| c.symbol())
            .collect()
    }

    fn app_with_profile() -> App {
        let mut app = App::new("/repo", vec!["sulfur".into(), "hydrogen".into()]);
        app.facts = Some(Facts {
            age_key_file: "/home/sheath/.config/sops/age/keys.txt".into(),
            sops_file: "secrets.yaml".into(),
            root_password: "persist".into(),
            mutable_users: false,
            persist_ssh: true,
        });
        app.profile = Some(Profile {
            host: "sulfur".into(),
            system_device: "/dev/disk/by-id/nvme-SAMPLE".into(),
            system_encrypt: true,
            esp_size: "1G".into(),
            home_device: None,
            home_encrypt: true,
            root_mode: RootMode::Tmpfs,
            tmpfs_size: "6G".into(),
            swap_size: Some("32G".into()),
            data_device: None,
            data_fs_type: "btrfs".into(),
        });
        app
    }

    #[test]
    fn host_screen_lists_every_host() {
        let app = App::new("/repo", vec!["sulfur".into(), "vizualwanderer".into()]);
        let out = render(&app);
        assert!(out.contains("NixOS installer"));
        assert!(out.contains("sulfur"));
        assert!(out.contains("vizualwanderer"));
    }

    #[test]
    fn review_shows_the_hosts_own_age_key_path() {
        let mut app = app_with_profile();
        app.screen = Screen::Review;
        let out = render(&app);
        assert!(out.contains("/home/sheath/.config/sops/age/keys.txt"));
        assert!(out.contains("age-key.enc"));
        assert!(out.contains("installable"));
        assert!(out.contains("rootMode"));
    }

    #[test]
    fn review_reports_why_a_profile_is_not_installable() {
        let mut app = app_with_profile();
        app.screen = Screen::Review;
        app.profile.as_mut().unwrap().system_device = crate::profile::UNSET_DEVICE.into();
        let out = render(&app);
        assert!(out.contains("no system disk selected"));
    }

    #[test]
    fn run_screen_warns_before_repartitioning_an_installed_machine() {
        let mut app = app_with_profile();
        app.screen = Screen::Run;
        app.phase_done = vec![false; phases::ALL.len()];
        let out = render(&app);
        assert!(
            out.contains("ALREADY INSTALLED"),
            "an unmounted target must not silently look like a fresh disk"
        );
        assert!(out.contains("m mount existing"));

        // Once mounted, the hint goes away.
        app.phase_done[0] = true;
        assert!(!render(&app).contains("ALREADY INSTALLED"));
    }

    #[test]
    fn erase_modal_is_shown_before_anything_destructive() {
        let mut app = app_with_profile();
        app.screen = Screen::Run;
        app.modal = Modal::Erase("ER".into());
        let out = render(&app);
        assert!(out.contains("erased"));
        assert!(out.contains("Type ERASE to continue"));
    }

    #[test]
    fn passphrase_modal_never_echoes_the_passphrase() {
        let mut app = app_with_profile();
        app.screen = Screen::Run;
        app.modal = Modal::Passphrase {
            first: "hunter2".into(),
            second: String::new(),
            confirming: false,
        };
        let out = render(&app);
        assert!(!out.contains("hunter2"), "the passphrase must not be drawn");
        assert!(out.contains("*******"));
    }

    #[test]
    fn assigning_a_role_moves_it_off_the_previous_disk() {
        let mut app = app_with_profile();
        app.disks = vec![
            Disk {
                name: "nvme0n1".into(),
                size: "1T".into(),
                model: "A".into(),
                serial: "1".into(),
                by_id: Some("/dev/disk/by-id/nvme-A".into()),
            },
            Disk {
                name: "sda".into(),
                size: "2T".into(),
                model: "B".into(),
                serial: "2".into(),
                by_id: Some("/dev/disk/by-id/ata-B".into()),
            },
        ];
        app.disk_idx = 1;
        assign(&mut app, Some(Role::Home));
        assert_eq!(
            app.profile.as_ref().unwrap().home_device.as_deref(),
            Some("/dev/disk/by-id/ata-B")
        );

        // Re-assigning the same disk as system must clear its /home role, not hold both.
        assign(&mut app, Some(Role::System));
        let p = app.profile.as_ref().unwrap();
        assert_eq!(p.system_device, "/dev/disk/by-id/ata-B");
        assert_eq!(p.home_device, None);
    }

    /// Every screen must have a way forward. Options once had none: Enter changed the
    /// field under the cursor and nothing advanced, stranding the operator one screen
    /// short of installing.
    #[test]
    fn every_screen_leads_to_the_next() {
        let mut app = app_with_profile();
        app.disks = vec![Disk {
            name: "nvme0n1".into(),
            size: "1T".into(),
            model: "A".into(),
            serial: "1".into(),
            by_id: Some("/dev/disk/by-id/nvme-A".into()),
        }];

        app.screen = Screen::Disks;
        disks_key(&mut app, KeyCode::Enter);
        assert_eq!(app.screen, Screen::Options, "disks must reach options");

        options_key(&mut app, KeyCode::Enter);
        assert_eq!(app.screen, Screen::Review, "options must reach review");

        // Space still changes a field rather than navigating.
        app.screen = Screen::Options;
        app.opt_idx = 0;
        let before = app.profile.as_ref().unwrap().system_encrypt;
        options_key(&mut app, KeyCode::Char(' '));
        assert_eq!(app.screen, Screen::Options);
        assert_ne!(app.profile.as_ref().unwrap().system_encrypt, before);
    }

    #[test]
    fn a_single_disk_layout_keeps_home_on_the_system_disk() {
        let mut app = app_with_profile();
        app.disks = vec![Disk {
            name: "nvme0n1".into(),
            size: "1T".into(),
            model: "A".into(),
            serial: "1".into(),
            by_id: Some("/dev/disk/by-id/nvme-A".into()),
        }];
        app.disk_idx = 0;
        assign(&mut app, Some(Role::System));

        let p = app.profile.as_ref().unwrap();
        assert_eq!(
            p.home_device, None,
            "no second disk means /home is a subvolume"
        );
        assert!(p.validate().is_ok());
        assert!(!p.to_nix().contains("home.device"));
    }

    #[test]
    fn a_disk_with_no_stable_link_is_refused() {
        let mut app = app_with_profile();
        app.disks = vec![Disk {
            name: "vda".into(),
            size: "1T".into(),
            model: String::new(),
            serial: String::new(),
            by_id: None,
        }];
        app.disk_idx = 0;
        assign(&mut app, Some(Role::System));
        match &app.modal {
            Modal::Error(e) => assert!(e.contains("by-id")),
            _ => panic!("expected a refusal: kernel names reorder across boots"),
        }
    }
}
