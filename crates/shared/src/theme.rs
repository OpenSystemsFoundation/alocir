use eframe::egui::{
    self, Color32, CornerRadius, FontFamily, FontId, Margin, Shadow, Stroke, Style, TextStyle,
    Visuals,
};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum ColorScheme {
    DarkMode,
    Retro,
    MacOsX,
    Windows98,
    WindowsXp,
    Matrix,
}

impl ColorScheme {
    pub const ALL: &'static [ColorScheme] = &[
        ColorScheme::DarkMode,
        ColorScheme::Retro,
        ColorScheme::MacOsX,
        ColorScheme::Windows98,
        ColorScheme::WindowsXp,
        ColorScheme::Matrix,
    ];

    pub fn name(self) -> &'static str {
        match self {
            ColorScheme::DarkMode => "Dark Mode",
            ColorScheme::Retro => "SNES",
            ColorScheme::MacOsX => "Mac OS X",
            ColorScheme::Windows98 => "Windows 98",
            ColorScheme::WindowsXp => "Windows XP",
            ColorScheme::Matrix => "Matrix",
        }
    }

    pub fn is_dark(self) -> bool {
        match self {
            ColorScheme::DarkMode => true,
            ColorScheme::Retro => true,
            ColorScheme::MacOsX => false,
            ColorScheme::Windows98 => false,
            ColorScheme::WindowsXp => false,
            ColorScheme::Matrix => true,
        }
    }

    /// Look a scheme up by name, ignoring case, spaces and punctuation
    /// ("Windows 98", "windows98", "win98", "mac", "dark", ...).
    pub fn from_name(name: &str) -> Option<ColorScheme> {
        let key: String = name
            .chars()
            .filter(|c| c.is_alphanumeric())
            .flat_map(char::to_lowercase)
            .collect();
        Some(match key.as_str() {
            "dark" | "darkmode" => ColorScheme::DarkMode,
            "snes" | "retro" => ColorScheme::Retro,
            "mac" | "macos" | "macosx" | "osx" | "light" => ColorScheme::MacOsX,
            "windows98" | "win98" | "98" => ColorScheme::Windows98,
            "windowsxp" | "winxp" | "xp" => ColorScheme::WindowsXp,
            "matrix" => ColorScheme::Matrix,
            _ => return None,
        })
    }

    /// Colours for everything that is not a treemap tile: panels, windows,
    /// buttons, menus and text.
    pub fn palette(self) -> UiPalette {
        let rgb = Color32::from_rgb;
        match self {
            ColorScheme::DarkMode => UiPalette {
                panel: rgb(27, 29, 35),
                window: rgb(35, 38, 46),
                canvas: rgb(18, 19, 23),
                surface: rgb(46, 50, 60),
                surface_hover: rgb(58, 63, 76),
                surface_active: rgb(70, 76, 92),
                border: rgb(62, 67, 80),
                text: rgb(230, 232, 238),
                text_weak: rgb(168, 174, 188),
                accent: rgb(66, 133, 244),
                accent_text: Color32::WHITE,
                danger: rgb(255, 110, 110),
                radius: 6,
            },
            ColorScheme::Retro => UiPalette {
                panel: rgb(30, 26, 46),
                window: rgb(40, 34, 61),
                canvas: rgb(20, 17, 32),
                surface: rgb(53, 45, 82),
                surface_hover: rgb(68, 58, 104),
                surface_active: rgb(84, 72, 128),
                border: rgb(77, 66, 112),
                text: rgb(230, 227, 242),
                text_weak: rgb(165, 159, 192),
                accent: rgb(132, 100, 220),
                accent_text: Color32::WHITE,
                danger: rgb(255, 120, 130),
                radius: 4,
            },
            ColorScheme::MacOsX => UiPalette {
                panel: rgb(236, 236, 236),
                window: rgb(246, 246, 246),
                canvas: rgb(214, 216, 220),
                surface: rgb(255, 255, 255),
                surface_hover: rgb(240, 245, 252),
                surface_active: rgb(222, 233, 248),
                border: rgb(196, 196, 200),
                text: rgb(30, 30, 32),
                text_weak: rgb(105, 105, 112),
                accent: rgb(10, 108, 223),
                accent_text: Color32::WHITE,
                danger: rgb(200, 40, 40),
                radius: 6,
            },
            ColorScheme::Windows98 => UiPalette {
                panel: rgb(192, 192, 192),
                window: rgb(192, 192, 192),
                canvas: rgb(128, 128, 128),
                surface: rgb(192, 192, 192),
                surface_hover: rgb(212, 208, 200),
                surface_active: rgb(168, 168, 168),
                border: rgb(96, 96, 96),
                text: Color32::BLACK,
                text_weak: rgb(64, 64, 64),
                accent: rgb(0, 0, 128),
                accent_text: Color32::WHITE,
                danger: rgb(170, 0, 0),
                radius: 0,
            },
            ColorScheme::WindowsXp => UiPalette {
                panel: rgb(236, 233, 216),
                window: rgb(245, 243, 231),
                canvas: rgb(172, 168, 153),
                surface: rgb(255, 255, 255),
                surface_hover: rgb(227, 236, 251),
                surface_active: rgb(200, 216, 245),
                border: rgb(172, 168, 153),
                text: Color32::BLACK,
                text_weak: rgb(92, 90, 80),
                accent: rgb(36, 94, 219),
                accent_text: Color32::WHITE,
                danger: rgb(190, 30, 30),
                radius: 3,
            },
            ColorScheme::Matrix => UiPalette {
                panel: rgb(2, 8, 2),
                window: rgb(4, 14, 4),
                canvas: Color32::BLACK,
                surface: rgb(6, 26, 6),
                surface_hover: rgb(10, 44, 10),
                surface_active: rgb(14, 62, 14),
                border: rgb(16, 96, 16),
                text: rgb(60, 255, 90),
                text_weak: rgb(34, 168, 56),
                accent: rgb(0, 190, 50),
                accent_text: Color32::BLACK,
                danger: rgb(255, 90, 90),
                radius: 0,
            },
        }
    }

    /// A complete egui style for this scheme: type scale, spacing, and
    /// visuals for widgets, panels, windows and menus.
    pub fn style(self) -> Style {
        let p = self.palette();
        let text_styles = [
            (
                TextStyle::Heading,
                FontId::new(18.0, FontFamily::Proportional),
            ),
            (TextStyle::Body, FontId::new(14.0, FontFamily::Proportional)),
            (
                TextStyle::Button,
                FontId::new(14.0, FontFamily::Proportional),
            ),
            (
                TextStyle::Small,
                FontId::new(11.5, FontFamily::Proportional),
            ),
            (
                TextStyle::Monospace,
                FontId::new(12.5, FontFamily::Monospace),
            ),
        ]
        .into();
        let mut style = Style {
            text_styles,
            ..Style::default()
        };

        style.spacing.item_spacing = egui::vec2(8.0, 6.0);
        style.spacing.button_padding = egui::vec2(10.0, 5.0);
        style.spacing.window_margin = Margin::same(14);
        style.spacing.menu_margin = Margin::same(6);
        style.spacing.interact_size = egui::vec2(32.0, 26.0);
        style.spacing.tooltip_width = 420.0;
        style.interaction.tooltip_delay = 0.35;

        let radius = CornerRadius::same(p.radius);
        let mut v = if self.is_dark() {
            Visuals::dark()
        } else {
            Visuals::light()
        };

        v.panel_fill = p.panel;
        v.window_fill = p.window;
        v.window_stroke = Stroke::new(1.0_f32, p.border);
        v.window_corner_radius = CornerRadius::same(p.radius.saturating_mul(2).min(10));
        v.menu_corner_radius = radius;
        v.extreme_bg_color = if self.is_dark() { p.canvas } else { p.surface };
        v.faint_bg_color = p.surface;
        v.code_bg_color = p.surface;
        v.hyperlink_color = p.accent;
        v.error_fg_color = p.danger;
        // Selected text keeps its own colour, so the highlight is a soft tint;
        // the stroke is the focus ring. Solid accent fills use `hyperlink_color`.
        v.selection.bg_fill = mix(p.accent, p.surface, 0.55);
        v.selection.stroke = Stroke::new(1.0_f32, p.accent);
        v.text_cursor.stroke = Stroke::new(2.0_f32, p.accent);

        // Flat schemes (radius 0) get a hard retro drop shadow, the rest a soft one.
        let shadow = if p.radius == 0 {
            Shadow {
                offset: [3, 3],
                blur: 0,
                spread: 0,
                color: Color32::from_black_alpha(110),
            }
        } else {
            Shadow {
                offset: [0, 6],
                blur: 18,
                spread: 0,
                color: Color32::from_black_alpha(if self.is_dark() { 110 } else { 50 }),
            }
        };
        v.window_shadow = shadow;
        v.popup_shadow = Shadow {
            blur: shadow.blur / 2,
            offset: [shadow.offset[0], shadow.offset[1] / 2 + 1],
            ..shadow
        };

        let w = &mut v.widgets;
        w.noninteractive.bg_fill = p.panel;
        w.noninteractive.weak_bg_fill = p.panel;
        w.noninteractive.bg_stroke = Stroke::new(1.0_f32, p.border);
        w.noninteractive.fg_stroke = Stroke::new(1.0_f32, p.text);
        w.noninteractive.corner_radius = radius;

        w.inactive.bg_fill = p.surface;
        w.inactive.weak_bg_fill = p.surface;
        w.inactive.bg_stroke = Stroke::new(1.0_f32, p.border);
        w.inactive.fg_stroke = Stroke::new(1.0_f32, p.text);
        w.inactive.corner_radius = radius;
        w.inactive.expansion = 0.0;

        w.hovered.bg_fill = p.surface_hover;
        w.hovered.weak_bg_fill = p.surface_hover;
        w.hovered.bg_stroke = Stroke::new(1.0_f32, p.accent);
        w.hovered.fg_stroke = Stroke::new(1.5_f32, p.text);
        w.hovered.corner_radius = radius;
        w.hovered.expansion = 0.0;

        w.active.bg_fill = p.surface_active;
        w.active.weak_bg_fill = p.surface_active;
        w.active.bg_stroke = Stroke::new(1.0_f32, p.accent);
        w.active.fg_stroke = Stroke::new(1.5_f32, p.text);
        w.active.corner_radius = radius;
        w.active.expansion = 0.0;

        w.open = w.hovered;

        style.visuals = v;
        style
    }

    /// Make `ctx` use this scheme's style, whatever the system theme is.
    pub fn apply(self, ctx: &egui::Context) {
        ctx.set_theme(if self.is_dark() {
            egui::Theme::Dark
        } else {
            egui::Theme::Light
        });
        let style = self.style();
        ctx.all_styles_mut(|s| *s = style.clone());
    }

    pub fn theme(self) -> ThemeColors {
        match self {
            ColorScheme::DarkMode => ThemeColors {
                dir_base: [40, 70, 140],
                dir_range: [30, 40, 80],
                file_base: [50, 120, 50],
                file_range: [50, 80, 50],
                dir_border: Color32::from_rgb(200, 200, 255),
                file_border: Color32::from_rgb(200, 255, 200),
                text_primary: Color32::WHITE,
                text_secondary: Color32::from_rgb(220, 220, 220),
                indicator: Color32::WHITE,
                hover_boost: 30,
            },
            ColorScheme::Retro => ThemeColors {
                // SNES-inspired: purple/lavender dirs, muted blue-grey files
                dir_base: [75, 50, 130],
                dir_range: [40, 30, 50],
                file_base: [80, 80, 110],
                file_range: [35, 35, 40],
                dir_border: Color32::from_rgb(150, 120, 200),
                file_border: Color32::from_rgb(140, 140, 170),
                text_primary: Color32::from_rgb(230, 230, 240),
                text_secondary: Color32::from_rgb(180, 175, 200),
                indicator: Color32::from_rgb(200, 180, 255),
                hover_boost: 25,
            },
            ColorScheme::MacOsX => ThemeColors {
                dir_base: [24, 88, 178],
                dir_range: [20, 20, 30],
                file_base: [176, 184, 194],
                file_range: [30, 25, 25],
                dir_border: Color32::from_rgb(24, 78, 160),
                file_border: Color32::from_rgb(140, 148, 160),
                text_primary: Color32::from_rgb(30, 30, 30),
                text_secondary: Color32::from_rgb(80, 80, 80),
                indicator: Color32::from_rgb(30, 30, 30),
                hover_boost: 20,
            },
            ColorScheme::Windows98 => ThemeColors {
                dir_base: [0, 0, 128],
                dir_range: [20, 20, 40],
                file_base: [0, 120, 120],
                file_range: [1, 24, 24],
                dir_border: Color32::from_rgb(255, 255, 255),
                file_border: Color32::from_rgb(223, 223, 223),
                text_primary: Color32::WHITE,
                text_secondary: Color32::from_rgb(192, 192, 192),
                indicator: Color32::from_rgb(255, 255, 0),
                hover_boost: 35,
            },
            ColorScheme::WindowsXp => ThemeColors {
                dir_base: [0, 78, 152],
                dir_range: [30, 30, 40],
                file_base: [55, 126, 34],
                file_range: [30, 40, 30],
                dir_border: Color32::from_rgb(60, 150, 220),
                file_border: Color32::from_rgb(100, 180, 80),
                text_primary: Color32::WHITE,
                text_secondary: Color32::from_rgb(220, 230, 240),
                indicator: Color32::WHITE,
                hover_boost: 25,
            },
            ColorScheme::Matrix => ThemeColors {
                dir_base: [0, 70, 0],
                dir_range: [10, 40, 10],
                file_base: [0, 50, 0],
                file_range: [10, 40, 10],
                dir_border: Color32::from_rgb(0, 200, 0),
                file_border: Color32::from_rgb(0, 150, 0),
                text_primary: Color32::from_rgb(0, 255, 0),
                text_secondary: Color32::from_rgb(0, 200, 0),
                indicator: Color32::from_rgb(0, 255, 0),
                hover_boost: 20,
            },
        }
    }
}

/// Colours for the app chrome (see [`ColorScheme::palette`]).
#[derive(Clone, Copy)]
pub struct UiPalette {
    /// Toolbar, status bar and start screen background.
    pub panel: Color32,
    /// Floating windows and menus.
    pub window: Color32,
    /// Behind the treemap tiles (shows through the gaps).
    pub canvas: Color32,
    /// Buttons and other controls.
    pub surface: Color32,
    pub surface_hover: Color32,
    pub surface_active: Color32,
    pub border: Color32,
    pub text: Color32,
    pub text_weak: Color32,
    /// Primary actions, selection and focus.
    pub accent: Color32,
    /// Text on top of `accent`.
    pub accent_text: Color32,
    /// Destructive actions and errors.
    pub danger: Color32,
    /// Corner radius for controls; 0 for the square retro schemes.
    pub radius: u8,
}

/// WCAG relative luminance of an opaque colour, 0.0 (black) to 1.0 (white).
pub fn luminance(c: Color32) -> f32 {
    fn lin(v: u8) -> f32 {
        let v = v as f32 / 255.0;
        if v <= 0.04045 {
            v / 12.92
        } else {
            ((v + 0.055) / 1.055).powf(2.4)
        }
    }
    0.2126 * lin(c.r()) + 0.7152 * lin(c.g()) + 0.0722 * lin(c.b())
}

/// WCAG contrast ratio between two opaque colours, 1.0 to 21.0.
pub fn contrast(a: Color32, b: Color32) -> f32 {
    let (la, lb) = (luminance(a), luminance(b));
    (la.max(lb) + 0.05) / (la.min(lb) + 0.05)
}

/// Mix `c` towards black (`t` = 0 keeps it, 1 gives black).
pub fn darken(c: Color32, t: f32) -> Color32 {
    let k = 1.0 - t.clamp(0.0, 1.0);
    Color32::from_rgb(
        (c.r() as f32 * k) as u8,
        (c.g() as f32 * k) as u8,
        (c.b() as f32 * k) as u8,
    )
}

/// Linear mix of two opaque colours (`t` = 0 gives `a`, 1 gives `b`).
pub fn mix(a: Color32, b: Color32, t: f32) -> Color32 {
    let t = t.clamp(0.0, 1.0);
    let ch = |x: u8, y: u8| (x as f32 + (y as f32 - x as f32) * t).round() as u8;
    Color32::from_rgb(ch(a.r(), b.r()), ch(a.g(), b.g()), ch(a.b(), b.b()))
}

/// Lowest contrast at which a theme's own label colour is kept on a tile.
const MIN_LABEL_CONTRAST: f32 = 3.5;

pub struct ThemeColors {
    pub dir_base: [u8; 3],
    pub dir_range: [u8; 3],
    pub file_base: [u8; 3],
    pub file_range: [u8; 3],
    pub dir_border: Color32,
    pub file_border: Color32,
    pub text_primary: Color32,
    pub text_secondary: Color32,
    pub indicator: Color32,
    pub hover_boost: u8,
}

impl ThemeColors {
    pub fn color_for_node(&self, name: &str, is_dir: bool) -> Color32 {
        // Hashing a &str gives the same value as hashing the equivalent String,
        // so colours are unchanged; this just avoids an allocation per tile.
        let hash_input: &str = if is_dir {
            name
        } else {
            name.rsplit('.').next().unwrap_or("")
        };
        let mut hasher = DefaultHasher::new();
        hash_input.hash(&mut hasher);
        let h = hasher.finish();

        let (base, range) = if is_dir {
            (&self.dir_base, &self.dir_range)
        } else {
            (&self.file_base, &self.file_range)
        };

        Color32::from_rgb(
            base[0].saturating_add((h % range[0].max(1) as u64) as u8),
            base[1].saturating_add(((h >> 8) % range[1].max(1) as u64) as u8),
            base[2].saturating_add(((h >> 16) % range[2].max(1) as u64) as u8),
        )
    }

    /// Primary and secondary label colours that are readable on a tile filled
    /// with `bg`: the theme's own text colours when they contrast enough,
    /// otherwise near-white or near-black, whichever reads better.
    pub fn label_colors(&self, bg: Color32) -> (Color32, Color32) {
        if contrast(self.text_primary, bg) >= MIN_LABEL_CONTRAST {
            let secondary = if contrast(self.text_secondary, bg) >= MIN_LABEL_CONTRAST {
                self.text_secondary
            } else {
                mix(self.text_primary, bg, 0.2)
            };
            return (self.text_primary, secondary);
        }
        let light = Color32::from_rgb(250, 250, 250);
        let dark = Color32::from_rgb(20, 20, 22);
        let primary = if contrast(light, bg) >= contrast(dark, bg) {
            light
        } else {
            dark
        };
        (primary, mix(primary, bg, 0.22))
    }

    pub fn hover_color(&self, base: Color32) -> Color32 {
        Color32::from_rgb(
            base.r().saturating_add(self.hover_boost),
            base.g().saturating_add(self.hover_boost),
            base.b().saturating_add(self.hover_boost),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_schemes_have_names() {
        for &scheme in ColorScheme::ALL {
            assert!(!scheme.name().is_empty());
        }
    }

    #[test]
    fn all_schemes_count() {
        assert_eq!(ColorScheme::ALL.len(), 6);
    }

    #[test]
    fn dark_schemes_identified() {
        assert!(ColorScheme::DarkMode.is_dark());
        assert!(ColorScheme::Retro.is_dark());
        assert!(ColorScheme::Matrix.is_dark());
    }

    #[test]
    fn light_schemes_identified() {
        assert!(!ColorScheme::MacOsX.is_dark());
        assert!(!ColorScheme::Windows98.is_dark());
        assert!(!ColorScheme::WindowsXp.is_dark());
    }

    #[test]
    fn color_for_dir_uses_dir_palette() {
        let theme = ColorScheme::DarkMode.theme();
        let color = theme.color_for_node("mydir", true);
        // Should be in dir_base range (blue-ish for dark mode)
        assert!(color.r() >= theme.dir_base[0]);
        assert!(color.g() >= theme.dir_base[1]);
        assert!(color.b() >= theme.dir_base[2]);
    }

    #[test]
    fn color_for_file_uses_file_palette() {
        let theme = ColorScheme::DarkMode.theme();
        let color = theme.color_for_node("test.rs", false);
        assert!(color.r() >= theme.file_base[0]);
        assert!(color.g() >= theme.file_base[1]);
        assert!(color.b() >= theme.file_base[2]);
    }

    #[test]
    fn same_extension_same_color() {
        let theme = ColorScheme::DarkMode.theme();
        let c1 = theme.color_for_node("foo.rs", false);
        let c2 = theme.color_for_node("bar.rs", false);
        assert_eq!(c1, c2);
    }

    #[test]
    fn different_extension_may_differ() {
        let theme = ColorScheme::DarkMode.theme();
        let c1 = theme.color_for_node("foo.rs", false);
        let c2 = theme.color_for_node("foo.txt", false);
        // Not guaranteed to differ due to hash collisions, but verify both produce colors
        assert_ne!((c1.r(), c1.g(), c1.b()), (0, 0, 0));
        assert_ne!((c2.r(), c2.g(), c2.b()), (0, 0, 0));
    }

    #[test]
    fn dir_color_deterministic() {
        let theme = ColorScheme::Matrix.theme();
        let c1 = theme.color_for_node("src", true);
        let c2 = theme.color_for_node("src", true);
        assert_eq!(c1, c2);
    }

    #[test]
    fn hover_color_brighter() {
        let theme = ColorScheme::DarkMode.theme();
        let base = Color32::from_rgb(100, 100, 100);
        let hover = theme.hover_color(base);
        assert!(hover.r() > base.r());
        assert!(hover.g() > base.g());
        assert!(hover.b() > base.b());
    }

    #[test]
    fn hover_color_saturates_at_255() {
        let theme = ColorScheme::Windows98.theme(); // hover_boost = 35
        let base = Color32::from_rgb(240, 240, 240);
        let hover = theme.hover_color(base);
        assert_eq!(hover.r(), 255);
        assert_eq!(hover.g(), 255);
        assert_eq!(hover.b(), 255);
    }

    #[test]
    fn each_scheme_produces_valid_theme() {
        for &scheme in ColorScheme::ALL {
            let theme = scheme.theme();
            // Verify hover_boost is reasonable
            assert!(theme.hover_boost > 0);
            assert!(theme.hover_boost <= 50);
            // Verify colors are non-zero for at least some channels
            let has_color =
                theme.dir_base.iter().any(|&c| c > 0) || theme.file_base.iter().any(|&c| c > 0);
            assert!(has_color, "Scheme {} has no color", scheme.name());
        }
    }
    #[test]
    fn scheme_names_round_trip() {
        for &scheme in ColorScheme::ALL {
            assert!(ColorScheme::from_name(scheme.name()) == Some(scheme));
        }
        assert!(ColorScheme::from_name("win98") == Some(ColorScheme::Windows98));
        assert!(ColorScheme::from_name("MAC-OS-X") == Some(ColorScheme::MacOsX));
        assert!(ColorScheme::from_name("nope").is_none());
    }

    #[test]
    fn chrome_text_is_readable_on_every_scheme() {
        for &scheme in ColorScheme::ALL {
            let p = scheme.palette();
            for bg in [p.panel, p.window, p.surface, p.surface_hover] {
                assert!(contrast(p.text, bg) >= 7.0, "{} text", scheme.name());
                assert!(contrast(p.text_weak, bg) >= 4.0, "{} weak", scheme.name());
                assert!(contrast(p.danger, bg) >= 3.5, "{} danger", scheme.name());
            }
            assert!(
                contrast(p.accent_text, p.accent) >= 3.5,
                "{} accent",
                scheme.name()
            );
            assert_eq!(scheme.style().visuals.dark_mode, scheme.is_dark());
        }
    }

    #[test]
    fn tile_labels_are_readable_on_every_scheme() {
        for &scheme in ColorScheme::ALL {
            let theme = scheme.theme();
            for i in 0..500 {
                for is_dir in [true, false] {
                    let bg = theme.color_for_node(&format!("name{i}.ext{i}"), is_dir);
                    // Plain tile, hovered tile and the darker directory header.
                    for bg in [bg, theme.hover_color(bg), darken(bg, 0.28)] {
                        let (primary, secondary) = theme.label_colors(bg);
                        assert!(
                            contrast(primary, bg) >= MIN_LABEL_CONTRAST,
                            "{} primary on {bg:?}",
                            scheme.name()
                        );
                        assert!(
                            contrast(secondary, bg) >= 2.5,
                            "{} secondary on {bg:?}",
                            scheme.name()
                        );
                    }
                }
            }
        }
    }

    /// Every symbol the UI draws must exist in egui's bundled fonts, which are
    /// the only fonts used on all platforms.
    #[test]
    fn ui_glyphs_exist_in_bundled_fonts() {
        let ctx = egui::Context::default();
        ColorScheme::DarkMode.apply(&ctx);
        let _ = ctx.run(Default::default(), |ctx| {
            ctx.fonts(|f| {
                let font = FontId::proportional(14.0);
                for c in crate::glyphs::ALL.chars() {
                    assert!(
                        f.has_glyph(&font, c),
                        "missing glyph {c:?} (U+{:04X})",
                        c as u32
                    );
                }
            });
        });
    }
}
