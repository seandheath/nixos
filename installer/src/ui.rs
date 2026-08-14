//! The installer dashboard.
//!
//! One screen: every requirement, what was chosen for it, and whether it works. The run is
//! gated on all of them, and once it starts nothing else is asked -- every secret was
//! collected while the board was being filled in.

use crate::checks::{self, Board, CheckId, Status};
use crate::disks::Disk;
use crate::phases;

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

type Term = Terminal<CrosstermBackend<Stdout>>;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Role {
    System,
    Home,
    Data,
}

/// A row editor, or a gate. Everything the operator types lives here.
pub enum Modal {
    None,
    Hosts(usize),
    Disks(usize),
    Toggle,
    Text {
        value: String,
        what: CheckId,
    },
    Secret {
        first: String,
        second: String,
        confirming: bool,
        what: CheckId,
    },
    Erase(String),
    Error(String),
}

impl Modal {
    fn is_open(&self) -> bool {
        !matches!(self, Modal::None)
    }
}

pub struct App {
    pub board: Board,
    pub modal: Modal,
    pub row: usize,
    pub log: Vec<String>,
    pub phase_done: Vec<bool>,
    pub running: bool,
    pub status: String,
    quit: bool,
}

impl App {
    pub fn new(board: Board) -> Self {
        App {
            board,
            modal: Modal::None,
            row: 0,
            log: Vec::new(),
            phase_done: vec![false; phases::ALL.len()],
            running: false,
            status: "press v to check everything, Enter to edit a row".into(),
            quit: false,
        }
    }

    fn selected(&self) -> CheckId {
        checks::ALL[self.row.min(checks::ALL.len() - 1)]
    }

    fn refresh_phases(&mut self) {
        if let Ok(ctx) = self.board.ctx() {
            self.phase_done = phases::ALL.iter().map(|p| p.is_done(&ctx)).collect();
        }
    }
}

pub fn run(board: Board) -> io::Result<()> {
    let mut term = setup()?;
    let mut app = App::new(board);
    let res = event_loop(&mut term, &mut app);
    let _ = teardown(&mut term);
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
        if key.kind == KeyEventKind::Press {
            handle_key(app, key.code);
        }
    }
}

/// No terminal handle here: nothing suspends the TUI any more, because every phase runs
/// without asking a question.
pub fn handle_key(app: &mut App, code: KeyCode) {
    if app.modal.is_open() {
        return modal_key(app, code);
    }
    match code {
        KeyCode::Char('q') => app.quit = true,
        KeyCode::Up | KeyCode::Char('k') => app.row = app.row.saturating_sub(1),
        KeyCode::Down | KeyCode::Char('j') => app.row = (app.row + 1).min(checks::ALL.len() - 1),
        KeyCode::Enter => open_editor(app),
        KeyCode::Char('c') => {
            let id = app.selected();
            app.status = format!("checking {}...", id.label());
            app.board.check(id);
        }
        KeyCode::Char('v') => {
            app.status = "checking everything...".into();
            app.board.check_all();
            app.status = if app.board.ready() {
                "all checks pass -- press r to install".into()
            } else {
                "some checks failed".into()
            };
        }
        KeyCode::Char('m') => remount(app),
        KeyCode::Char('r') => start_run(app),
        _ => {}
    }
}

/// Enter opens the editor a row needs; rows with nothing to edit just re-check.
fn open_editor(app: &mut App) {
    match app.selected() {
        CheckId::Host => app.modal = Modal::Hosts(app.board.host_idx),
        CheckId::SystemDisk | CheckId::HomeDisk | CheckId::DataDisk => app.modal = Modal::Disks(0),
        CheckId::Encryption => app.modal = Modal::Toggle,
        CheckId::RootPassword => {
            app.modal = Modal::Secret {
                first: String::new(),
                second: String::new(),
                confirming: false,
                what: CheckId::RootPassword,
            }
        }
        CheckId::AgeKey => {
            app.modal = Modal::Secret {
                first: String::new(),
                second: String::new(),
                confirming: false,
                what: CheckId::AgeKey,
            }
        }
        CheckId::Sizes => {
            let v = app
                .board
                .profile
                .as_ref()
                .and_then(|p| p.swap_size.clone())
                .unwrap_or_default();
            app.modal = Modal::Text {
                value: v,
                what: CheckId::Sizes,
            }
        }
        id => {
            app.status = format!("checking {}...", id.label());
            app.board.check(id);
        }
    }
}

fn remount(app: &mut App) {
    let ctx = match app.board.ctx() {
        Ok(c) => c,
        Err(e) => {
            app.modal = Modal::Error(e);
            return;
        }
    };
    let mut lines = Vec::new();
    match phases::remount(&ctx, &mut |l| lines.push(l.to_string())) {
        Ok(()) => {
            app.log.extend(lines);
            app.refresh_phases();
            app.status = "mounted the existing target".into();
        }
        Err(e) => {
            app.log.extend(lines);
            app.modal = Modal::Error(format!("could not mount: {e}"));
        }
    }
}

fn start_run(app: &mut App) {
    if !app.board.ready() {
        let unmet: Vec<&str> = checks::ALL
            .iter()
            .filter(|id| !app.board.status(**id).satisfied())
            .map(|id| id.label())
            .collect();
        app.modal = Modal::Error(format!("not ready:\n  {}", unmet.join("\n  ")));
        return;
    }
    app.refresh_phases();
    if self_destructive(app) {
        app.modal = Modal::Erase(String::new());
    } else {
        execute_pending(app);
    }
}

fn self_destructive(app: &App) -> bool {
    phases::ALL
        .iter()
        .zip(&app.phase_done)
        .any(|(p, done)| p.is_destructive() && !*done)
}

/// Runs every pending phase with no further interaction.
fn execute_pending(app: &mut App) {
    let ctx = match app.board.ctx() {
        Ok(c) => c,
        Err(e) => {
            app.modal = Modal::Error(e);
            return;
        }
    };
    app.running = true;

    for (i, phase) in phases::ALL.iter().enumerate() {
        if app.phase_done[i] {
            continue;
        }
        app.status = format!("running {}", phase.name());
        app.log
            .push(format!("== {}: {}", phase.name(), phase.describe()));

        let mut lines = Vec::new();
        let result = phase.run(&ctx, &mut |l| lines.push(l.to_string()));
        app.log.extend(lines);

        match result {
            Ok(()) => {
                app.phase_done[i] = true;
                app.log.push(format!("   {} done", phase.name()));
            }
            Err(e) => {
                app.log.push(format!("   {} FAILED: {e}", phase.name()));
                app.modal = Modal::Error(format!("{} failed:\n{e}", phase.name()));
                app.status = format!("{} failed", phase.name());
                app.running = false;
                return;
            }
        }
    }

    app.running = false;
    app.status = "installed".into();
    app.log.push(String::new());
    app.log.push(format!(
        "Commit disk-config/{h}.nix and hardware/{h}.nix, then push: every host",
        h = app.board.host()
    ));
    app.log
        .push("rebuilds from github:seandheath/nixos nightly and would revert them.".into());
}

// --- modals ----------------------------------------------------------------------------

fn modal_key(app: &mut App, code: KeyCode) {
    match &mut app.modal {
        Modal::None => {}
        Modal::Error(_) => {
            if matches!(code, KeyCode::Enter | KeyCode::Esc) {
                app.modal = Modal::None;
            }
        }
        Modal::Hosts(idx) => match code {
            KeyCode::Up | KeyCode::Char('k') => *idx = idx.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => {
                *idx = (*idx + 1).min(app.board.hosts.len().saturating_sub(1))
            }
            KeyCode::Esc => app.modal = Modal::None,
            KeyCode::Enter => {
                let chosen = *idx;
                app.modal = Modal::None;
                app.board.host_idx = chosen;
                app.status = format!("evaluating {}...", app.board.host());
                app.board.load_host();
            }
            _ => {}
        },
        Modal::Disks(idx) => match code {
            KeyCode::Up | KeyCode::Char('k') => *idx = idx.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => {
                *idx = (*idx + 1).min(app.board.disks.len().saturating_sub(1))
            }
            KeyCode::Esc => app.modal = Modal::None,
            KeyCode::Char('s') => assign_at(app, Some(Role::System)),
            KeyCode::Char('h') => assign_at(app, Some(Role::Home)),
            KeyCode::Char('d') => assign_at(app, Some(Role::Data)),
            KeyCode::Char('x') => assign_at(app, None),
            KeyCode::Enter => {
                app.modal = Modal::None;
                app.board.check_cheap();
            }
            _ => {}
        },
        Modal::Toggle => match code {
            KeyCode::Esc => app.modal = Modal::None,
            KeyCode::Char('y') | KeyCode::Char('n') | KeyCode::Char(' ') | KeyCode::Enter => {
                let on = match code {
                    KeyCode::Char('y') => true,
                    KeyCode::Char('n') => false,
                    _ => !app.board.profile.as_ref().is_some_and(|p| p.system_encrypt),
                };
                if let Some(p) = app.board.profile.as_mut() {
                    p.system_encrypt = on;
                    // One passphrase opens every volume, so the flags move together.
                    p.home_encrypt = on;
                }
                app.board.invalidate(CheckId::Encryption);
                if on {
                    app.modal = Modal::Secret {
                        first: String::new(),
                        second: String::new(),
                        confirming: false,
                        what: CheckId::Encryption,
                    };
                } else {
                    app.board.luks_passphrase.clear();
                    app.modal = Modal::None;
                    app.board.check_cheap();
                }
            }
            _ => {}
        },
        Modal::Text { value, what } => match code {
            KeyCode::Char(c) => value.push(c),
            KeyCode::Backspace => {
                value.pop();
            }
            KeyCode::Esc => app.modal = Modal::None,
            KeyCode::Enter => {
                let (v, id) = (value.clone(), *what);
                app.modal = Modal::None;
                if let Some(p) = app.board.profile.as_mut() {
                    p.swap_size = (!v.trim().is_empty()).then(|| v.trim().to_string());
                }
                app.board.invalidate(id);
                app.board.check_cheap();
            }
            _ => {}
        },
        Modal::Secret {
            first,
            second,
            confirming,
            what,
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
                    return;
                }
                if first != second {
                    app.modal = Modal::Error("they did not match".into());
                    return;
                }
                let (secret, id) = (first.clone(), *what);
                app.modal = Modal::None;
                match id {
                    CheckId::Encryption => app.board.luks_passphrase = secret,
                    CheckId::AgeKey => app.board.age_passphrase = secret,
                    CheckId::RootPassword => app.board.root_password = secret,
                    _ => {}
                }
                app.board.invalidate(id);
                app.board.check_cheap();
                // The age passphrase is only meaningful if it decrypts, so prove it now.
                if id == CheckId::AgeKey {
                    app.status = "checking the age key...".into();
                    app.board.check(CheckId::AgeKey);
                }
            }
            _ => {}
        },
        Modal::Erase(buf) => match code {
            KeyCode::Char(c) => buf.push(c),
            KeyCode::Backspace => {
                buf.pop();
            }
            KeyCode::Esc => app.modal = Modal::None,
            KeyCode::Enter => {
                if buf == "ERASE" {
                    app.modal = Modal::None;
                    execute_pending(app);
                } else {
                    app.modal = Modal::Error("not confirmed".into());
                }
            }
            _ => {}
        },
    }
}

fn assign_at(app: &mut App, role: Option<Role>) {
    let idx = match &app.modal {
        Modal::Disks(i) => *i,
        _ => return,
    };
    assign(app, idx, role);
}

/// A disk holds one role; assigning it clears whatever it had before.
pub fn assign(app: &mut App, idx: usize, role: Option<Role>) {
    let Some(disk) = app.board.disks.get(idx).cloned() else {
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
    let Some(p) = app.board.profile.as_mut() else {
        return;
    };

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
        // Preserved, never formatted.
        Some(Role::Data) => p.data_device = Some(by_id),
        None => {}
    }
    app.board.invalidate(CheckId::SystemDisk);
}

pub fn role_of(app: &App, disk: &Disk) -> Option<Role> {
    let p = app.board.profile.as_ref()?;
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

// --- drawing ---------------------------------------------------------------------------

fn draw(f: &mut Frame, app: &App) {
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(8),
            Constraint::Length(8),
            Constraint::Length(3),
        ])
        .split(f.area());

    let ready = app.board.ready();
    f.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                "NixOS installer",
                Style::default().add_modifier(Modifier::BOLD),
            ),
            Span::raw(format!("   {}   ", app.board.host())),
            Span::styled(
                if ready { "READY" } else { "incomplete" },
                Style::default().fg(if ready { Color::Green } else { Color::Yellow }),
            ),
            Span::raw(format!("   {}", app.status)),
        ]))
        .block(Block::default().borders(Borders::ALL)),
        rows[0],
    );

    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(58), Constraint::Percentage(42)])
        .split(rows[1]);
    draw_board(f, cols[0], app);
    draw_detail(f, cols[1], app);
    draw_phases(f, rows[2], app);

    f.render_widget(
        Paragraph::new(
            "j/k move   Enter edit   c check row   v check all   m mount existing   r install   q quit",
        )
        .block(Block::default().borders(Borders::ALL)),
        rows[3],
    );

    draw_modal(f, app);
}

fn draw_board(f: &mut Frame, area: Rect, app: &App) {
    let items: Vec<ListItem> = checks::ALL
        .iter()
        .enumerate()
        .map(|(i, id)| {
            let st = app.board.status(*id);
            let colour = match st {
                Status::Ok(_) => Color::Green,
                Status::Failed(_) => Color::Red,
                Status::NotApplicable(_) => Color::DarkGray,
                Status::Pending => Color::Yellow,
            };
            let mut style = Style::default().fg(colour);
            if i == app.row {
                style = style.add_modifier(Modifier::REVERSED);
            }
            ListItem::new(format!(
                "{} {:<14} {}",
                st.glyph(),
                id.label(),
                truncate(st.summary(), area.width.saturating_sub(20) as usize)
            ))
            .style(style)
        })
        .collect();
    f.render_widget(
        List::new(items).block(Block::default().borders(Borders::ALL).title(" checklist ")),
        area,
    );
}

/// The selected row in full: the rendered layout, the disk table, or the whole error.
fn draw_detail(f: &mut Frame, area: Rect, app: &App) {
    let id = app.selected();
    let mut lines: Vec<Line> = Vec::new();

    if let Status::Failed(e) = app.board.status(id) {
        for l in e.lines() {
            lines.push(Line::from(Span::styled(
                l.to_string(),
                Style::default().fg(Color::Red),
            )));
        }
        lines.push(Line::from(""));
    }

    match id {
        CheckId::Layout => {
            if let Some(p) = app.board.profile.as_ref() {
                for l in p.to_nix().lines() {
                    lines.push(Line::from(l.to_string()));
                }
            }
        }
        CheckId::SystemDisk | CheckId::HomeDisk | CheckId::DataDisk => {
            for d in &app.board.disks {
                let role = match role_of(app, d) {
                    Some(Role::System) => "system",
                    Some(Role::Home) => "/home ",
                    Some(Role::Data) => "/data ",
                    None => "      ",
                };
                lines.push(Line::from(format!("[{role}] {}", d.label())));
            }
        }
        CheckId::Host => {
            if let Some(fa) = app.board.facts.as_ref() {
                lines.push(Line::from(format!("age key   {}", fa.age_key_file)));
                lines.push(Line::from(format!("  from    {}", fa.age_key_source())));
                lines.push(Line::from(format!("root pw   {}", fa.root_password)));
                lines.push(Line::from(format!(
                    "/etc/ssh  persisted: {}",
                    fa.persist_ssh
                )));
            }
        }
        _ => {}
    }

    f.render_widget(
        Paragraph::new(lines).wrap(Wrap { trim: false }).block(
            Block::default()
                .borders(Borders::ALL)
                .title(format!(" {} ", id.label())),
        ),
        area,
    );
}

fn draw_phases(f: &mut Frame, area: Rect, app: &App) {
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(40), Constraint::Percentage(60)])
        .split(area);

    let items: Vec<ListItem> = phases::ALL
        .iter()
        .zip(&app.phase_done)
        .map(|(p, done)| {
            let style = if *done {
                Style::default().fg(Color::Green)
            } else if p.is_destructive() {
                Style::default().fg(Color::Red)
            } else {
                Style::default()
            };
            ListItem::new(format!("[{}] {}", if *done { "x" } else { " " }, p.name())).style(style)
        })
        .collect();
    let title = if app.phase_done.first() == Some(&false) {
        " phases -- if ALREADY INSTALLED press m to mount first "
    } else {
        " phases "
    };
    f.render_widget(
        List::new(items).block(Block::default().borders(Borders::ALL).title(title)),
        cols[0],
    );

    let height = cols[1].height.saturating_sub(2) as usize;
    let start = app.log.len().saturating_sub(height);
    f.render_widget(
        Paragraph::new(app.log[start..].join("\n"))
            .wrap(Wrap { trim: false })
            .block(Block::default().borders(Borders::ALL).title(" log ")),
        cols[1],
    );
}

fn draw_modal(f: &mut Frame, app: &App) {
    let (title, body, colour) = match &app.modal {
        Modal::None => return,
        Modal::Error(e) => (" error ", e.clone(), Color::Red),
        Modal::Hosts(idx) => (
            " host ",
            app.board
                .hosts
                .iter()
                .enumerate()
                .map(|(i, h)| format!("{} {h}", if i == *idx { ">" } else { " " }))
                .collect::<Vec<_>>()
                .join("\n"),
            Color::Cyan,
        ),
        Modal::Disks(idx) => (
            " disks -- s system, h /home, d /data, x clear, Enter done ",
            app.board
                .disks
                .iter()
                .enumerate()
                .map(|(i, d)| {
                    let role = match role_of(app, d) {
                        Some(Role::System) => "system",
                        Some(Role::Home) => "/home ",
                        Some(Role::Data) => "/data ",
                        None => "      ",
                    };
                    format!(
                        "{} [{role}] {}{}",
                        if i == *idx { ">" } else { " " },
                        d.label(),
                        if d.by_id.is_some() {
                            ""
                        } else {
                            "  (no by-id link)"
                        }
                    )
                })
                .collect::<Vec<_>>()
                .join("\n"),
            Color::Cyan,
        ),
        Modal::Toggle => (
            " encryption ",
            "Encrypt this host with LUKS2?\n\n  y  yes, and set a passphrase\n  n  no\n\n\
             Off by default: nothing is encrypted unless you say so."
                .into(),
            Color::Cyan,
        ),
        Modal::Text { value, .. } => (
            " swap size ",
            format!("Btrfs swapfile size, e.g. 32G. Empty for none.\n\n> {value}"),
            Color::Cyan,
        ),
        Modal::Secret {
            first,
            second,
            confirming,
            what,
        } => (
            match what {
                CheckId::Encryption => " LUKS passphrase ",
                CheckId::AgeKey => " age key passphrase ",
                _ => " root password ",
            },
            format!(
                "{}\n\n{}: {}",
                match what {
                    CheckId::Encryption =>
                        "One passphrase opens every encrypted volume on this host.",
                    CheckId::AgeKey =>
                        "The passphrase for the committed age key. Checked immediately.",
                    _ => "Hashed with mkpasswd and written to /persist/secrets.",
                },
                if *confirming { "Again" } else { "Enter" },
                "*".repeat(if *confirming {
                    second.len()
                } else {
                    first.len()
                })
            ),
            Color::Yellow,
        ),
        Modal::Erase(buf) => (
            " destructive ",
            format!(
                "{}\n\nEverything on these disks will be erased.\n\
                 Type ERASE to continue: {buf}",
                disks_to_wipe(app)
            ),
            Color::Red,
        ),
    };

    let area = centered(64, 50, f.area());
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

fn disks_to_wipe(app: &App) -> String {
    let Some(p) = app.board.profile.as_ref() else {
        return String::new();
    };
    let mut out = vec![format!("  system: {}", p.system_device)];
    if let Some(h) = &p.home_device {
        out.push(format!("  /home:  {h}"));
    }
    if let Some(d) = &p.data_device {
        out.push(format!("  /data:  {d}   PRESERVED, not formatted"));
    }
    out.join("\n")
}

fn truncate(s: &str, max: usize) -> String {
    let one_line = s.replace('\n', " ");
    if one_line.chars().count() <= max || max == 0 {
        one_line
    } else {
        format!(
            "{}…",
            one_line
                .chars()
                .take(max.saturating_sub(1))
                .collect::<String>()
        )
    }
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
    use crate::nix::Facts;
    use crate::profile::{Profile, RootMode};
    use ratatui::backend::TestBackend;

    fn render(app: &App) -> String {
        let mut t = Terminal::new(TestBackend::new(110, 34)).unwrap();
        t.draw(|f| draw(f, app)).unwrap();
        t.backend()
            .buffer()
            .content
            .iter()
            .map(|c| c.symbol())
            .collect()
    }

    fn app() -> App {
        let mut board = Board::new("/repo", vec!["gentlemenpupil".into(), "sulfur".into()]);
        board.facts = Some(Facts {
            age_key_file: "/home/sheath/.config/sops/age/keys.txt".into(),
            sops_file: "family.yaml".into(),
            root_password: "none".into(),
            mutable_users: false,
            persist_ssh: false,
        });
        board.profile = Some(Profile {
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
        });
        board.disks = vec![Disk {
            name: "nvme0n1".into(),
            size: "1T".into(),
            model: "Samsung".into(),
            serial: "1".into(),
            by_id: Some("/dev/disk/by-id/nvme-A".into()),
        }];
        App::new(board)
    }

    #[test]
    fn the_board_lists_every_requirement() {
        let a = app();
        let out = render(&a);
        for id in checks::ALL {
            assert!(out.contains(id.label()), "missing row: {}", id.label());
        }
    }

    #[test]
    fn a_failed_row_shows_its_reason_in_the_detail_pane() {
        let mut a = app();
        a.board
            .set(CheckId::Layout, Status::Failed("disko said no".into()));
        a.row = checks::ALL
            .iter()
            .position(|c| *c == CheckId::Layout)
            .unwrap();
        assert!(render(&a).contains("disko said no"));
    }

    #[test]
    fn the_header_only_says_ready_when_every_row_is_satisfied() {
        let mut a = app();
        assert!(render(&a).contains("incomplete"));
        for id in checks::ALL {
            a.board.set(id, Status::Ok("fine".into()));
        }
        assert!(render(&a).contains("READY"));
    }

    #[test]
    fn r_is_refused_while_anything_is_unmet() {
        let mut a = app();
        a.board.set(CheckId::Layout, Status::Failed("nope".into()));
        start_run(&mut a);
        match &a.modal {
            Modal::Error(e) => assert!(e.contains("layout")),
            _ => panic!("expected a refusal listing the unmet rows"),
        }
    }

    #[test]
    fn a_ready_board_asks_for_erase_before_partitioning() {
        let mut a = app();
        for id in checks::ALL {
            a.board.set(id, Status::Ok("fine".into()));
        }
        a.phase_done = vec![false; phases::ALL.len()];
        start_run(&mut a);
        assert!(
            matches!(a.modal, Modal::Erase(_)),
            "the destructive phase must still be confirmed"
        );
        assert!(render(&a).contains("Type ERASE"));
    }

    #[test]
    fn secrets_are_never_drawn() {
        let mut a = app();
        a.modal = Modal::Secret {
            first: "hunter2".into(),
            second: String::new(),
            confirming: false,
            what: CheckId::AgeKey,
        };
        let out = render(&a);
        assert!(!out.contains("hunter2"));
        assert!(out.contains("*******"));
    }

    #[test]
    fn turning_encryption_off_clears_the_passphrase() {
        let mut a = app();
        a.board.luks_passphrase = "old".into();
        a.board.profile.as_mut().unwrap().system_encrypt = true;
        a.modal = Modal::Toggle;
        modal_key(&mut a, KeyCode::Char('n'));
        assert!(!a.board.profile.as_ref().unwrap().system_encrypt);
        assert!(
            a.board.luks_passphrase.is_empty(),
            "a stale passphrase must not survive turning encryption off"
        );
    }

    #[test]
    fn assigning_a_role_moves_it_off_the_previous_disk() {
        let mut a = app();
        a.board.disks.push(Disk {
            name: "sda".into(),
            size: "2T".into(),
            model: "B".into(),
            serial: "2".into(),
            by_id: Some("/dev/disk/by-id/ata-B".into()),
        });
        assign(&mut a, 1, Some(Role::Home));
        assert_eq!(
            a.board.profile.as_ref().unwrap().home_device.as_deref(),
            Some("/dev/disk/by-id/ata-B")
        );
        assign(&mut a, 1, Some(Role::System));
        let p = a.board.profile.as_ref().unwrap();
        assert_eq!(p.system_device, "/dev/disk/by-id/ata-B");
        assert_eq!(p.home_device, None);
    }

    #[test]
    fn a_disk_with_no_stable_link_is_refused() {
        let mut a = app();
        a.board.disks = vec![Disk {
            name: "vda".into(),
            size: "1T".into(),
            model: String::new(),
            serial: String::new(),
            by_id: None,
        }];
        assign(&mut a, 0, Some(Role::System));
        match &a.modal {
            Modal::Error(e) => assert!(e.contains("by-id")),
            _ => panic!("expected a refusal: kernel names reorder across boots"),
        }
    }
}
