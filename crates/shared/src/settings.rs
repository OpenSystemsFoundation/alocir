use eframe::egui::{self, Align2, CornerRadius, FontId, Rect, Sense, Stroke, StrokeKind};

use crate::glyphs;
use crate::theme::ColorScheme;

pub struct SettingsState {
    pub open: bool,
    pub scheme: ColorScheme,
    /// The scheme whose style the egui context currently has.
    applied: Option<ColorScheme>,
    /// Watch the whole scanned tree for changes, not just the folder shown.
    /// Cheap on macOS (FSEvents) and Windows; on Linux inotify needs one
    /// watch per folder, so it is opt-in there.
    pub watch_subfolders: bool,
    /// Why watching subfolders isn't working, if it isn't (set by the app).
    pub watch_status: Option<String>,
}

impl Default for SettingsState {
    fn default() -> Self {
        Self::new()
    }
}

impl SettingsState {
    pub fn new() -> Self {
        Self::with_scheme(ColorScheme::DarkMode)
    }

    pub fn with_scheme(scheme: ColorScheme) -> Self {
        SettingsState {
            open: false,
            scheme,
            applied: None,
            watch_subfolders: !cfg!(target_os = "linux"),
            watch_status: None,
        }
    }

    /// Restyle egui when the scheme has changed (and on the first frame).
    /// Cheap to call every frame.
    pub fn apply_theme(&mut self, ctx: &egui::Context) {
        if self.applied != Some(self.scheme) {
            self.scheme.apply(ctx);
            self.applied = Some(self.scheme);
        }
    }
}

/// A miniature treemap drawn in `scheme`'s own colours.
fn paint_swatch(painter: &egui::Painter, rect: Rect, scheme: ColorScheme) {
    let theme = scheme.theme();
    let palette = scheme.palette();
    let radius = CornerRadius::same(palette.radius.min(4));
    painter.rect_filled(rect, radius, palette.canvas);
    painter.rect_stroke(
        rect,
        radius,
        Stroke::new(1.0_f32, palette.border),
        StrokeKind::Inside,
    );

    let inner = rect.shrink(3.0);
    let tile_radius = CornerRadius::same(palette.radius.min(2));
    // (x0, y0, x1, y1) as fractions of `inner`, name to colour by, is_dir
    let tiles: [(f32, f32, f32, f32, &str, bool); 5] = [
        (0.0, 0.0, 0.46, 1.0, "Documents", true),
        (0.46, 0.0, 0.76, 0.58, "Pictures", true),
        (0.76, 0.0, 1.0, 0.58, "movie.mp4", false),
        (0.46, 0.58, 0.82, 1.0, "archive.zip", false),
        (0.82, 0.58, 1.0, 1.0, "src", true),
    ];
    for (x0, y0, x1, y1, name, is_dir) in tiles {
        let tile = Rect::from_min_max(
            inner.lerp_inside(egui::vec2(x0, y0)),
            inner.lerp_inside(egui::vec2(x1, y1)),
        )
        .shrink(0.75);
        painter.rect_filled(tile, tile_radius, theme.color_for_node(name, is_dir));
    }
}

/// One selectable row: swatch, name, light/dark note and a check mark.
fn scheme_row(ui: &mut egui::Ui, scheme: ColorScheme, selected: bool) -> egui::Response {
    let palette_color = |ui: &egui::Ui| ui.visuals().clone();
    let (rect, response) =
        ui.allocate_exact_size(egui::vec2(ui.available_width(), 46.0), Sense::click());
    let response = response.on_hover_cursor(egui::CursorIcon::PointingHand);

    if ui.is_rect_visible(rect) {
        let v = palette_color(ui);
        let radius = v.widgets.inactive.corner_radius;
        let fill = if selected {
            v.widgets.active.weak_bg_fill
        } else if response.hovered() {
            v.widgets.hovered.weak_bg_fill
        } else {
            v.widgets.inactive.weak_bg_fill
        };
        let stroke = if selected {
            Stroke::new(1.5_f32, v.hyperlink_color)
        } else {
            v.widgets.inactive.bg_stroke
        };
        let painter = ui.painter();
        painter.rect_filled(rect, radius, fill);
        painter.rect_stroke(rect, radius, stroke, StrokeKind::Inside);

        let swatch = Rect::from_min_size(
            rect.min + egui::vec2(8.0, 7.0),
            egui::vec2(64.0, rect.height() - 14.0),
        );
        paint_swatch(painter, swatch, scheme);

        let text_x = swatch.right() + 12.0;
        painter.text(
            egui::pos2(text_x, rect.center().y - 8.0),
            Align2::LEFT_CENTER,
            scheme.name(),
            FontId::proportional(14.0),
            v.strong_text_color(),
        );
        painter.text(
            egui::pos2(text_x, rect.center().y + 9.0),
            Align2::LEFT_CENTER,
            if scheme.is_dark() { "Dark" } else { "Light" },
            FontId::proportional(11.5),
            v.weak_text_color(),
        );
        if selected {
            painter.text(
                egui::pos2(rect.right() - 14.0, rect.center().y),
                Align2::RIGHT_CENTER,
                glyphs::CHECK,
                FontId::proportional(15.0),
                v.hyperlink_color,
            );
        }
    }

    response.widget_info(|| {
        egui::WidgetInfo::selected(egui::WidgetType::RadioButton, true, selected, scheme.name())
    });
    response
}

pub fn show_settings_window(ctx: &egui::Context, state: &mut SettingsState) {
    if !state.open {
        return;
    }

    // Escape closes the window (unless a text field or menu wants the key).
    if !ctx.wants_keyboard_input() && ctx.input(|i| i.key_pressed(egui::Key::Escape)) {
        state.open = false;
        return;
    }

    let mut open = state.open;
    egui::Window::new("Settings")
        .collapsible(false)
        .resizable(false)
        .open(&mut open)
        .anchor(Align2::CENTER_CENTER, [0.0, 0.0])
        .show(ctx, |ui| {
            ui.set_width(320.0);

            ui.label(egui::RichText::new("Color scheme").strong());
            ui.add_space(2.0);
            ui.spacing_mut().item_spacing.y = 6.0;
            for &scheme in ColorScheme::ALL {
                if scheme_row(ui, scheme, state.scheme == scheme).clicked() {
                    // Picked up by `SettingsState::apply_theme` on the next frame.
                    state.scheme = scheme;
                    ctx.request_repaint();
                }
            }

            if cfg!(target_os = "linux") {
                ui.add_space(10.0);
                ui.checkbox(
                    &mut state.watch_subfolders,
                    "Watch subfolders for changes (uses more system resources)",
                );
                if let Some(status) = &state.watch_status {
                    ui.label(egui::RichText::new(status).small().weak());
                }
            }

            ui.add_space(10.0);
            ui.separator();
            ui.add_space(4.0);
            ui.horizontal(|ui| {
                ui.label(egui::RichText::new("Alocir").strong());
                ui.weak(concat!("v", env!("CARGO_PKG_VERSION")));
            });
            ui.weak("Cross-platform disk space visualizer, inspired by SpaceSniffer.");
        });
    state.open = open;
}
