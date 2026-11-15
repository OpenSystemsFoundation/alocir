mod app;
mod ui;

use alocir_shared::glyphs;
use alocir_shared::settings::{show_settings_window, SettingsState};
use alocir_shared::theme::ColorScheme;
use eframe::egui::{self, RichText};
use std::collections::HashSet;
use std::ffi::OsString;
use std::path::PathBuf;

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
}

impl AlocirApp {
    fn new(cli: Cli) -> Self {
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
        AlocirApp {
            state: AppState::Start,
            settings: SettingsState::with_scheme(cli.scheme.unwrap_or(ColorScheme::DarkMode)),
            initial_folder,
            error,
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

            ui::centered_block(ui, egui::vec2(460.0, 400.0), |ui| {
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
                if let Some(home) = home_dir() {
                    ui.add_space(4.0);
                    if ui
                        .add(
                            egui::Button::new("Scan Home Folder").min_size(egui::vec2(240.0, 32.0)),
                        )
                        .on_hover_text(home.to_string_lossy())
                        .clicked()
                    {
                        chosen = Some(home);
                    }
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

impl eframe::App for AlocirApp {
    fn update(&mut self, ctx: &egui::Context, frame: &mut eframe::Frame) {
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

    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([1200.0, 800.0])
            .with_min_inner_size([480.0, 320.0])
            .with_title("Alocir")
            .with_icon(std::sync::Arc::new(alocir_shared::icon::app_icon())),
        ..Default::default()
    };

    eframe::run_native(
        "Alocir",
        options,
        Box::new(|_cc| Ok(Box::new(AlocirApp::new(cli)))),
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
