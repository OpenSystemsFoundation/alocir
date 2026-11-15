//! Small widgets shared by the start screen and the scan/treemap views.

use alocir_shared::theme::{contrast, ColorScheme};
use eframe::egui::{
    self, Align, Button, Color32, CornerRadius, Layout, Rect, Response, RichText, Ui, UiBuilder,
    Vec2,
};

/// Lay `add_contents` out top-down and horizontally centred, in a block of
/// (at most) `size` placed slightly above the middle of the remaining space.
pub fn centered_block<R>(ui: &mut Ui, size: Vec2, add_contents: impl FnOnce(&mut Ui) -> R) -> R {
    let avail = ui.available_rect_before_wrap();
    let size = size.min(avail.size());
    let center = avail.center() - egui::vec2(0.0, avail.height() * 0.04);
    let rect = Rect::from_center_size(center, size);
    ui.allocate_new_ui(
        UiBuilder::new()
            .max_rect(rect)
            .layout(Layout::top_down(Align::Center)),
        add_contents,
    )
    .inner
}

/// The main action of a screen or dialog, filled with the theme's accent colour.
pub fn primary_button(ui: &mut Ui, enabled: bool, text: RichText, min_size: Vec2) -> Response {
    let accent = ui.visuals().hyperlink_color;
    let on_accent = if contrast(Color32::WHITE, accent) >= 3.0 {
        Color32::WHITE
    } else {
        Color32::BLACK
    };
    ui.add_enabled(
        enabled,
        Button::new(text.color(on_accent))
            .fill(accent)
            .min_size(min_size),
    )
}

/// A square toolbar button showing one glyph from `alocir_shared::glyphs`.
pub fn icon_button(ui: &mut Ui, enabled: bool, glyph: &str, tooltip: &str) -> Response {
    ui.add_enabled(
        enabled,
        Button::new(RichText::new(glyph).size(16.0)).min_size(egui::vec2(30.0, 28.0)),
    )
    .on_hover_text(tooltip)
    .on_disabled_hover_text(tooltip)
}

/// The app mark: a tiny treemap in the scheme's tile colours.
pub fn paint_logo(painter: &egui::Painter, rect: Rect, scheme: ColorScheme) {
    let theme = scheme.theme();
    let palette = scheme.palette();
    let unit = rect.width() / 16.0;
    let radius = |k: f32| CornerRadius::same(((palette.radius as f32) * k).round() as u8);
    painter.rect_filled(rect, radius(2.0), palette.canvas);

    let inner = rect.shrink(unit * 1.5);
    // (x0, y0, x1, y1) as fractions of `inner`, name to colour by, is_dir
    let tiles: [(f32, f32, f32, f32, &str, bool); 5] = [
        (0.0, 0.0, 0.56, 1.0, "Documents", true),
        (0.56, 0.0, 1.0, 0.44, "movie.mp4", false),
        (0.56, 0.44, 0.8, 1.0, "Pictures", true),
        (0.8, 0.44, 1.0, 0.74, "archive.zip", false),
        (0.8, 0.74, 1.0, 1.0, "notes.txt", false),
    ];
    for (x0, y0, x1, y1, name, is_dir) in tiles {
        let tile = Rect::from_min_max(
            inner.lerp_inside(egui::vec2(x0, y0)),
            inner.lerp_inside(egui::vec2(x1, y1)),
        )
        .shrink(unit * 0.3);
        painter.rect_filled(tile, radius(0.35), theme.color_for_node(name, is_dir));
    }
}

/// A big value over a small caption, e.g. "12,345" / "items".
pub fn stat(ui: &mut Ui, value: &str, caption: &str) {
    ui.vertical_centered(|ui| {
        ui.spacing_mut().item_spacing.y = 2.0;
        ui.label(RichText::new(value).size(22.0).strong());
        ui.label(RichText::new(caption).small().weak());
    });
}
