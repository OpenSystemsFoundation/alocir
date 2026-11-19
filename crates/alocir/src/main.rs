mod app;
mod store;
mod ui;

use alocir_shared::glyphs;
use alocir_shared::settings::{show_settings_window, SettingsState};
use alocir_shared::theme::ColorScheme;
use eframe::egui::{self, RichText};
use std::collections::HashSet;
use std::ffi::OsString;
use std::path::PathBuf;
use std::time::{Duration, Instant};
use store::{Prefs, Recents};

const USAGE: &str = "\
Alocir - disk space visualizer

Usage: alocir [OPTIONS] [FOLDER]

Arguments:
  [FOLDER]        Folder to scan straight away, skipping the start screen

Options:
  --theme <NAME>  Color scheme: dark, purple, daylight, classic, sky or phosphor
  -h, --help      Print this help
  -V, --version   Print the version";

/// What the command line asked for.
#[derive(Default)]
struct Cli {
    folder: Option<PathBuf>,
    scheme: Option<ColorScheme>,
}

enum CliOutcome {
    Run(Cli),
    /// Print this and exit successfully (`--help`, `--version`).
    Print(String),
    /// Print this to stderr and exit with an error.
    Error(String),
}

fn parse_args(args: impl IntoIterator<Item = OsString>) -> CliOutcome {
    let mut cli = Cli::default();
    let mut args = args.into_iter();
    let mut only_positional = false;
    while let Some(arg) = args.next() {
        let text = arg.to_string_lossy();
        if only_positional || !text.starts_with('-') || text == "-" {
            if cli.folder.is_some() {
                return CliOutcome::Error("Only one folder can be given.".to_string());
            }
            cli.folder = Some(PathBuf::from(arg));
            continue;
        }
        let theme_name = if let Some(name) = text.strip_prefix("--theme=") {
            Some(name.to_string())
        } else if text == "--theme" {
            match args.next() {
                Some(name) => Some(name.to_string_lossy().to_string()),
                None => return CliOutcome::Error("--theme needs a name.".to_string()),
            }
        } else {
            None
        };
        if let Some(name) = theme_name {
            match ColorScheme::from_name(&name) {
                Some(scheme) => cli.scheme = Some(scheme),
                None => return CliOutcome::Error(format!("Unknown theme \"{name}\".")),
            }
            continue;
        }
        match text.as_ref() {
            "--" => only_positional = true,
            "-h" | "--help" => return CliOutcome::Print(USAGE.to_string()),
            "-V" | "--version" => {
                return CliOutcome::Print(format!("alocir {}", env!("CARGO_PKG_VERSION")))
            }
            // Old macOS versions pass a process serial number to apps opened from Finder.
            _ if text.starts_with("-psn_") => {}
            _ => return CliOutcome::Error(format!("Unknown option \"{text}\".")),
        }
    }
    CliOutcome::Run(cli)
}

/// The disk the system runs from: `/`, or the system drive on Windows.
#[cfg(not(feature = "app-store"))]
fn startup_disk() -> PathBuf {
    if cfg!(target_os = "windows") {
        let drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_string());
        PathBuf::from(format!("{drive}\\"))
    } else {
        PathBuf::from("/")
    }
}

/// The user's home folder, if the environment says where it is.
#[cfg(not(feature = "app-store"))]
fn home_dir() -> Option<PathBuf> {
    let var = if cfg!(target_os = "windows") {
        "USERPROFILE"
    } else {
        "HOME"
    };
    std::env::var_os(var)
        .map(PathBuf::from)
        .filter(|p| p.is_dir())
}

// One long-lived value per window, so the size gap between variants doesn't matter.
#[allow(clippy::large_enum_variant)]
enum AppState {
    Start,
    Scanning(app::TreemapApp),
}

struct AlocirApp {
    state: AppState,
    /// Used by the start screen, then handed to the scan view.
    settings: SettingsState,
    /// Folder to scan on the first frame (from the command line).
    initial_folder: Option<PathBuf>,
    /// A problem to show on the start screen, e.g. a bad folder argument.
    error: Option<String>,
    /// Where settings and recent folders are kept, if there is such a place.
    config_dir: Option<PathBuf>,
    recents: Recents,
    /// What was last written to (or read from) the settings file.
    saved_prefs: Prefs,
    /// The window's inner size, and when it last changed: it is saved once
    /// resizing has stopped for a moment.
    window_size: Option<[f32; 2]>,
    resized_at: Option<Instant>,
}

/// How long the window size must stay put before it is saved.
const RESIZE_SETTLE: Duration = Duration::from_millis(600);

impl AlocirApp {
    fn new(cli: Cli, config_dir: Option<PathBuf>, prefs: Prefs) -> Self {
        let mut error = None;
        let initial_folder = cli.folder.and_then(|folder| {
            // Resolve "." and friends so the folder has a real name to show.
            match std::fs::canonicalize(&folder) {
                Ok(path) if path.is_dir() => Some(strip_verbatim_prefix(path)),
                _ => {
                    error = Some(format!("\"{}\" is not a folder.", folder.display()));
                    None
                }
            }
        });
        let mut settings = SettingsState::new();
        prefs.apply_to(&mut settings);
        // A theme on the command line is for this run; it is saved only if
        // a setting is changed later.
        let mut saved_prefs = prefs.clone();
        if let Some(scheme) = cli.scheme {
            settings.scheme = scheme;
            saved_prefs.scheme = scheme;
        }
        let recents = config_dir.as_deref().map(Recents::load).unwrap_or_default();
        AlocirApp {
            state: AppState::Start,
            settings,
            initial_folder,
            error,
            config_dir,
            recents,
            window_size: prefs.window,
            saved_prefs,
            resized_at: None,
        }
    }

    /// Draw the start screen. Returns the folder to scan, once one is chosen.
    fn show_start_screen(&mut self, ctx: &egui::Context) -> Option<PathBuf> {
        let mut chosen: Option<PathBuf> = None;
        let scheme = self.settings.scheme;
        let palette = scheme.palette();

        // A folder dropped onto the window (a dropped file means its folder).
        let dropped = ctx.input(|i| i.raw.dropped_files.iter().find_map(|f| f.path.clone()));
        if let Some(path) = dropped {
            if path.is_dir() {
                chosen = Some(path);
            } else if let Some(parent) = path.parent().filter(|p| p.is_dir()) {
                chosen = Some(parent.to_path_buf());
            }
        }
        let drop_hover = ctx.input(|i| !i.raw.hovered_files.is_empty());

        egui::TopBottomPanel::top("start_bar")
            .frame(
                egui::Frame::new()
                    .fill(palette.panel)
                    .inner_margin(egui::Margin::symmetric(10, 7)),
            )
            .show_separator_line(false)
            .show(ctx, |ui| {
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui::icon_button(ui, true, glyphs::SETTINGS, "Settings").clicked() {
                        self.settings.open = !self.settings.open;
                    }
                });
            });

        egui::CentralPanel::default().show(ctx, |ui| {
            if drop_hover {
                ui.painter().rect_stroke(
                    ui.max_rect().shrink(6.0),
                    egui::CornerRadius::same(palette.radius.saturating_mul(2)),
                    egui::Stroke::new(2.0_f32, palette.accent),
                    egui::StrokeKind::Inside,
                );
            }

            let height = 400.0 + 44.0 * self.recents.entries.len().min(6) as f32;
            ui::centered_block(ui, egui::vec2(460.0, height), |ui| {
                let (logo, _) =
                    ui.allocate_exact_size(egui::vec2(76.0, 76.0), egui::Sense::hover());
                ui::paint_logo(ui.painter(), logo, scheme);
                ui.add_space(12.0);
                ui.label(RichText::new("Alocir").size(34.0).strong());
                ui.label(
                    RichText::new("See what is taking up your disk space.")
                        .size(15.0)
                        .weak(),
                );
                ui.add_space(26.0);

                let choose = ui::primary_button(
                    ui,
                    true,
                    RichText::new(format!("{}   Choose Folder\u{2026}", glyphs::NEW_SCAN))
                        .size(16.0),
                    egui::vec2(240.0, 44.0),
                );
                if choose.clicked() {
                    if let Some(path) = rfd::FileDialog::new()
                        .set_title("Select a directory to scan")
                        .pick_folder()
                    {
                        chosen = Some(path);
                    }
                }

                // The sandboxed store build can only read folders picked in the dialog.
                #[cfg(not(feature = "app-store"))]
                {
                    ui.add_space(6.0);
                    let disk = startup_disk();
                    let row_w = 240.0;
                    ui.allocate_ui_with_layout(
                        egui::vec2(row_w, 32.0),
                        egui::Layout::left_to_right(egui::Align::Center),
                        |ui| {
                            let half =
                                egui::vec2((row_w - ui.spacing().item_spacing.x) / 2.0, 32.0);
                            if let Some(home) = home_dir() {
                                if ui
                                    .add(
                                        egui::Button::new(format!("{}  Home", glyphs::HOME))
                                            .min_size(half),
                                    )
                                    .on_hover_text(format!("Scan {}", home.display()))
                                    .clicked()
                                {
                                    chosen = Some(home);
                                }
                            }
                            if ui
                                .add(
                                    egui::Button::new(format!("{}  Startup Disk", glyphs::DISK))
                                        .min_size(half),
                                )
                                .on_hover_text(format!("Scan {}", disk.display()))
                                .clicked()
                            {
                                chosen = Some(disk.clone());
                            }
                        },
                    );
                }

                // winit delivers file drops on macOS, Windows and X11 only.
                if cfg!(not(target_os = "linux")) {
                    ui.add_space(10.0);
                    ui.label(
                        RichText::new("or drop a folder onto this window")
                            .small()
                            .weak(),
                    );
                }

                if let Some(error) = &self.error {
                    ui.add_space(12.0);
                    ui.colored_label(palette.danger, format!("{}  {error}", glyphs::WARNING));
                }

                if !self.recents.entries.is_empty() {
                    ui.add_space(22.0);
                    if let Some(pick) = recent_list(ui, &self.recents, palette) {
                        match pick {
                            RecentPick::Open(path) if path.is_dir() => chosen = Some(path),
                            RecentPick::Open(path) => {
                                self.error =
                                    Some(format!("\"{}\" is no longer there.", path.display()));
                                self.recents.remove(&path);
                                self.save_recents();
                            }
                            RecentPick::Remove(path) => {
                                self.recents.remove(&path);
                                self.save_recents();
                            }
                        }
                    }
                }

                if cfg!(feature = "app-store") {
                    ui.add_space(18.0);
                    egui::Frame::new()
                        .fill(palette.surface)
                        .stroke(egui::Stroke::new(1.0_f32, palette.border))
                        .corner_radius(egui::CornerRadius::same(palette.radius))
                        .inner_margin(egui::Margin::symmetric(12, 8))
                        .show(ui, |ui| {
                            ui.label(
                                RichText::new(
                                    "To scan your whole disk, grant Alocir Full Disk Access in\n\
                                     System Settings > Privacy & Security.",
                                )
                                .small()
                                .color(palette.text_weak),
                            );
                        });
                }
            });
        });

        show_settings_window(ctx, &mut self.settings);
        chosen
    }
}

/// `canonicalize` on Windows returns `\\?\C:\...`; show and scan the plain
/// form when there is one.
fn strip_verbatim_prefix(path: PathBuf) -> PathBuf {
    if cfg!(target_os = "windows") {
        if let Some(text) = path.to_str() {
            if let Some(rest) = text.strip_prefix(r"\\?\") {
                if !rest.starts_with("UNC\\") {
                    return PathBuf::from(rest);
                }
            }
        }
    }
    path
}

impl AlocirApp {
    fn save_recents(&self) {
        if let Some(dir) = &self.config_dir {
            let _ = self.recents.save(dir);
        }
    }

    /// Keep the recent folders and saved settings up to date. Runs every
    /// frame; writes only when something changed.
    fn persist(&mut self, ctx: &egui::Context) {
        if let AppState::Scanning(app) = &mut self.state {
            if let Some((path, size)) = app.take_finished_scan() {
                self.recents.add(path, size);
                self.save_recents();
            }
        }
        let settings = match &mut self.state {
            AppState::Start => &mut self.settings,
            AppState::Scanning(app) => app.settings_mut(),
        };
        settings.recent_count = self.recents.entries.len();
        if std::mem::take(&mut settings.clear_recents) {
            self.recents.entries.clear();
            settings.recent_count = 0;
            if let Some(dir) = &self.config_dir {
                let _ = self.recents.save(dir);
            }
        }

        // The window size, once resizing settles (not while maximized or
        // full screen, which would come back as the normal size).
        let (size, special) = ctx.input(|i| {
            let v = i.viewport();
            (
                v.inner_rect
                    .map(|r| [r.width().round(), r.height().round()]),
                v.maximized.unwrap_or(false) || v.fullscreen.unwrap_or(false),
            )
        });
        if let Some(size) = size.filter(|_| !special) {
            if self.window_size != Some(size) {
                self.window_size = Some(size);
                self.resized_at = Some(Instant::now());
            }
        }
        if let Some(at) = self.resized_at {
            if at.elapsed() < RESIZE_SETTLE {
                ctx.request_repaint_after(RESIZE_SETTLE - at.elapsed());
                return;
            }
            self.resized_at = None;
        }
        let prefs = Prefs::from_settings(settings, self.window_size);
        if prefs != self.saved_prefs {
            if let Some(dir) = &self.config_dir {
                let _ = prefs.save(dir);
            }
            self.saved_prefs = prefs;
        }
    }
}

enum RecentPick {
    Open(PathBuf),
    Remove(PathBuf),
}

/// The recent folders on the start screen: name, path, size and when.
/// Right-click one to remove it.
fn recent_list(
    ui: &mut egui::Ui,
    recents: &Recents,
    palette: alocir_shared::theme::UiPalette,
) -> Option<RecentPick> {
    let mut pick = None;
    ui.label(
        RichText::new("Recent")
            .small()
            .strong()
            .color(palette.text_weak),
    );
    ui.add_space(2.0);
    let now = store::now();
    for entry in recents.entries.iter().take(6) {
        let (rect, response) =
            ui.allocate_exact_size(egui::vec2(380.0, 40.0), egui::Sense::click());
        let response = response.on_hover_cursor(egui::CursorIcon::PointingHand);
        let painter = ui.painter();
        let fill = if response.hovered() {
            palette.surface_hover
        } else {
            palette.surface
        };
        painter.rect_filled(rect, egui::CornerRadius::same(palette.radius), fill);
        let name = entry
            .path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| entry.path.display().to_string());
        let glyph = if entry.path.parent().is_none() {
            glyphs::DISK
        } else {
            glyphs::FOLDER
        };
        painter.text(
            rect.left_center() + egui::vec2(12.0, 0.0),
            egui::Align2::LEFT_CENTER,
            glyph,
            egui::FontId::proportional(16.0),
            palette.accent,
        );
        let left = rect.left() + 38.0;
        painter.text(
            egui::pos2(left, rect.top() + 12.0),
            egui::Align2::LEFT_CENTER,
            alocir_shared::text::truncate_end(&name, 30),
            egui::FontId::proportional(14.0),
            palette.text,
        );
        painter.text(
            egui::pos2(left, rect.bottom() - 11.0),
            egui::Align2::LEFT_CENTER,
            alocir_shared::text::truncate_start(&entry.path.display().to_string(), 36),
            egui::FontId::proportional(11.0),
            palette.text_weak,
        );
        painter.text(
            egui::pos2(rect.right() - 12.0, rect.top() + 12.0),
            egui::Align2::RIGHT_CENTER,
            alocir_shared::scanner::format_size(entry.size),
            egui::FontId::proportional(13.0),
            palette.text,
        );
        painter.text(
            egui::pos2(rect.right() - 12.0, rect.bottom() - 11.0),
            egui::Align2::RIGHT_CENTER,
            store::time_ago(entry.scanned, now),
            egui::FontId::proportional(11.0),
            palette.text_weak,
        );
        if response.clicked() {
            pick = Some(RecentPick::Open(entry.path.clone()));
        }
        response.context_menu(|ui| {
            if ui.button("Remove from Recents").clicked() {
                pick = Some(RecentPick::Remove(entry.path.clone()));
                ui.close_menu();
            }
        });
        ui.add_space(4.0);
    }
    pick
}

impl eframe::App for AlocirApp {
    fn update(&mut self, ctx: &egui::Context, frame: &mut eframe::Frame) {
        self.persist(ctx);
        match &mut self.state {
            AppState::Start => {
                self.settings.apply_theme(ctx);
                let chosen = match self.initial_folder.take() {
                    Some(path) => Some(path),
                    None => self.show_start_screen(ctx),
                };
                if let Some(path) = chosen {
                    ctx.send_viewport_cmd(egui::ViewportCommand::Title(format!(
                        "Alocir - {}",
                        path.display()
                    )));
                    let mut settings = std::mem::take(&mut self.settings);
                    self.error = None;
                    settings.open = false;
                    self.state = AppState::Scanning(app::TreemapApp::new(
                        path,
                        HashSet::new(),
                        settings,
                        ctx,
                    ));
                    ctx.request_repaint();
                }
            }
            AppState::Scanning(app) => app.update(ctx, frame),
        }
    }
}

fn main() -> eframe::Result<()> {
    let cli = match parse_args(std::env::args_os().skip(1)) {
        CliOutcome::Run(cli) => cli,
        CliOutcome::Print(text) => {
            println!("{text}");
            return Ok(());
        }
        CliOutcome::Error(message) => {
            eprintln!("alocir: {message}\n\n{USAGE}");
            std::process::exit(2);
        }
    };

    let config_dir = store::config_dir();
    let prefs = config_dir
        .as_deref()
        .map(Prefs::load)
        .unwrap_or_else(|| Prefs::from_settings(&SettingsState::new(), None));
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size(prefs.window.unwrap_or([1200.0, 800.0]))
            .with_min_inner_size([480.0, 320.0])
            .with_title("Alocir")
            .with_icon(std::sync::Arc::new(alocir_shared::icon::app_icon())),
        ..Default::default()
    };

    eframe::run_native(
        "Alocir",
        options,
        Box::new(|_cc| Ok(Box::new(AlocirApp::new(cli, config_dir, prefs)))),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> CliOutcome {
        parse_args(args.iter().map(OsString::from))
    }

    #[test]
    fn no_arguments_shows_the_start_screen() {
        let CliOutcome::Run(cli) = parse(&[]) else {
            panic!("expected to run");
        };
        assert!(cli.folder.is_none() && cli.scheme.is_none());
    }

    #[test]
    fn folder_and_theme_in_any_order() {
        for args in [
            &["/tmp/x", "--theme", "classic"][..],
            &["--theme=Classic", "/tmp/x"][..],
        ] {
            let CliOutcome::Run(cli) = parse(args) else {
                panic!("expected to run");
            };
            assert_eq!(cli.folder, Some(PathBuf::from("/tmp/x")));
            assert!(cli.scheme == Some(ColorScheme::Classic));
        }
    }

    #[test]
    fn double_dash_allows_folders_starting_with_a_dash() {
        let CliOutcome::Run(cli) = parse(&["--", "-odd"]) else {
            panic!("expected to run");
        };
        assert_eq!(cli.folder, Some(PathBuf::from("-odd")));
    }

    #[test]
    fn bad_input_is_an_error_and_help_prints() {
        assert!(matches!(parse(&["--theme", "nope"]), CliOutcome::Error(_)));
        assert!(matches!(parse(&["--theme"]), CliOutcome::Error(_)));
        assert!(matches!(parse(&["--bogus"]), CliOutcome::Error(_)));
        assert!(matches!(parse(&["a", "b"]), CliOutcome::Error(_)));
        assert!(matches!(parse(&["--help"]), CliOutcome::Print(_)));
        assert!(matches!(parse(&["-V"]), CliOutcome::Print(_)));
        assert!(matches!(parse(&["-psn_0_12345"]), CliOutcome::Run(_)));
    }
}
