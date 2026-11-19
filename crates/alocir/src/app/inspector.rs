//! The inspector on the right: the selected item (or the folder on screen),
//! what the folder holds by kind (which doubles as the colour legend), and
//! its largest files or the search results.

use super::TreemapApp;
use alocir_shared::file_ops::{quick_look, reveal_in_file_manager};
use alocir_shared::glyphs;
use alocir_shared::scanner::{format_size, FileNode};
use alocir_shared::summary::node_at;
use alocir_shared::text::{format_count, truncate_end, truncate_start};
use eframe::egui::{
    self, Align2, Color32, CornerRadius, FontId, Rect, RichText, Sense, Stroke, StrokeKind, Ui,
};
use std::path::PathBuf;

pub(super) enum InspectorAction {
    /// Show the folder containing this item (names from the root) and select it.
    Reveal(Vec<String>),
    ShowInFileManager(PathBuf),
    QuickLook(PathBuf),
    Trash(PathBuf),
}

impl TreemapApp {
    pub(super) fn show_inspector(&self, ui: &mut Ui) -> Option<InspectorAction> {
        let mut action = None;
        let focus_names = self.nav_names();
        let subject_names = self
            .selection
            .clone()
            .unwrap_or_else(|| focus_names.clone());
        let subject = self.node_at_names(&subject_names)?;
        let theme = self.settings.scheme.theme();

        egui::ScrollArea::vertical()
            .auto_shrink([false, false])
            .show(ui, |ui| {
                ui.spacing_mut().item_spacing.y = 6.0;

                // The item.
                ui.horizontal(|ui| {
                    let (glyph, color) = if subject.is_dir {
                        (glyphs::FOLDER, theme.color_for_node(&subject.name, true))
                    } else {
                        (glyphs::FILE, theme.kind_color(subject.kind))
                    };
                    ui.label(RichText::new(glyph).size(30.0).color(color));
                    ui.vertical(|ui| {
                        let name = if subject_names.is_empty() {
                            self.root_label()
                        } else {
                            subject.name.clone()
                        };
                        ui.add(
                            egui::Label::new(RichText::new(name).strong().size(15.0)).truncate(),
                        );
                        ui.label(RichText::new(format_size(subject.size)).size(20.0).strong());
                    });
                });
                if let Some((parent_names, _)) = subject_names.split_last().map(|(_, p)| (p, ())) {
                    if let Some(parent) = self.node_at_names(parent_names) {
                        let parent_name = if parent_names.is_empty() {
                            self.root_label()
                        } else {
                            parent.name.clone()
                        };
                        ui.weak(format!(
                            "{} of \u{201C}{}\u{201D}",
                            percent(subject.size, parent.size),
                            truncate_end(&parent_name, 28)
                        ));
                    }
                }
                let path = self.path_for(&subject_names);
                ui.add(
                    egui::Label::new(
                        RichText::new(truncate_start(&path.to_string_lossy(), 60))
                            .monospace()
                            .small()
                            .weak(),
                    )
                    .truncate(),
                )
                .on_hover_text(path.to_string_lossy());
                if subject.is_dir {
                    ui.weak(format!(
                        "{} items",
                        format_count(subject.children.len() as u64)
                    ));
                }

                ui.horizontal(|ui| {
                    let reveal = if cfg!(target_os = "macos") {
                        "Show in Finder"
                    } else {
                        "Show in file manager"
                    };
                    if ui.button(glyphs::NEW_SCAN).on_hover_text(reveal).clicked() {
                        action = Some(InspectorAction::ShowInFileManager(path.clone()));
                    }
                    let preview = if cfg!(target_os = "macos") {
                        "Quick Look (Space)"
                    } else {
                        "Open (Space)"
                    };
                    if ui.button(glyphs::EYE).on_hover_text(preview).clicked() {
                        action = Some(InspectorAction::QuickLook(path.clone()));
                    }
                    // Not the folder on screen itself: that would empty the map.
                    let can_trash = subject_names != focus_names;
                    if ui
                        .add_enabled(can_trash, egui::Button::new(glyphs::TRASH))
                        .on_hover_text("Move to Trash")
                        .clicked()
                    {
                        action = Some(InspectorAction::Trash(path.clone()));
                    }
                });

                let Some((_, summary)) = &self.summary else {
                    return;
                };

                // By kind, for the folder on screen.
                ui.add_space(10.0);
                ui.label(RichText::new("By Kind").small().strong().weak());
                let total: u64 = summary.kinds.iter().map(|k| k.bytes).sum();
                if total > 0 {
                    let (bar, _) = ui
                        .allocate_exact_size(egui::vec2(ui.available_width(), 8.0), Sense::hover());
                    let painter = ui.painter();
                    let mut x = bar.left();
                    for k in &summary.kinds {
                        let w = bar.width() * (k.bytes as f64 / total as f64) as f32;
                        if w >= 0.5 {
                            let seg = Rect::from_min_max(
                                egui::pos2(x, bar.top()),
                                egui::pos2((x + w).min(bar.right()), bar.bottom()),
                            );
                            painter.rect_filled(seg, CornerRadius::ZERO, theme.kind_color(k.kind));
                        }
                        x += w;
                    }
                    for k in &summary.kinds {
                        kind_row(ui, theme.kind_color(k.kind), k.kind.label(), k.bytes);
                    }
                } else {
                    ui.weak("No files");
                }

                // Search results, or the largest files below the folder.
                ui.add_space(10.0);
                let rows: Vec<(Vec<String>, &FileNode)> = if let Some(result) =
                    self.search.result.as_ref().filter(|_| self.search_active())
                {
                    ui.label(
                        RichText::new(format!(
                            "{} {} {} {}",
                            format_count(self.search.count as u64),
                            if self.search.count == 1 {
                                "match"
                            } else {
                                "matches"
                            },
                            glyphs::DOT,
                            format_size(result.total_size)
                        ))
                        .small()
                        .strong()
                        .weak(),
                    );
                    let root = self.root.as_ref();
                    result
                        .matches
                        .iter()
                        .filter_map(|p| {
                            let node = node_at(root?, p)?;
                            Some((self.names_for_indices(p)?, node))
                        })
                        .collect()
                } else {
                    ui.label(RichText::new("Largest Files").small().strong().weak());
                    let focus = self.current_node();
                    summary
                        .largest_files
                        .iter()
                        .filter_map(|p| {
                            let node = node_at(focus?, p)?;
                            let mut names = focus_names.clone();
                            let mut n = focus?;
                            for &i in p {
                                n = n.children.get(i as usize)?;
                                names.push(n.name.clone());
                            }
                            Some((names, node))
                        })
                        .collect()
                };
                let selected = self.selection.as_ref();
                for (names, node) in rows {
                    let color = if node.is_dir {
                        theme.color_for_node(&node.name, true)
                    } else {
                        theme.kind_color(node.kind)
                    };
                    let is_selected = selected == Some(&names);
                    if node_row(ui, color, &node.name, node.size, is_selected)
                        .on_hover_text(self.path_for(&names).to_string_lossy())
                        .clicked()
                    {
                        action = Some(InspectorAction::Reveal(names));
                    }
                }
            });
        action
    }

    pub(super) fn apply_inspector_action(&mut self, action: InspectorAction, ctx: &egui::Context) {
        match action {
            InspectorAction::Reveal(names) => self.reveal(names),
            InspectorAction::ShowInFileManager(path) => reveal_in_file_manager(&path),
            InspectorAction::QuickLook(path) => quick_look(&path),
            InspectorAction::Trash(path) => self.do_trash(path, ctx),
        }
    }

    /// The scanned folder's name, or its path for a disk root.
    fn root_label(&self) -> String {
        self.scan_path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| self.scan_path.to_string_lossy().to_string())
    }
}

fn percent(part: u64, whole: u64) -> String {
    let pct = part as f64 / whole.max(1) as f64 * 100.0;
    if pct > 0.0 && pct < 1.0 {
        "<1%".to_string()
    } else {
        format!("{pct:.0}%")
    }
}

/// A legend row: colour swatch, kind, size.
fn kind_row(ui: &mut Ui, color: Color32, label: &str, bytes: u64) {
    let (rect, _) = ui.allocate_exact_size(egui::vec2(ui.available_width(), 18.0), Sense::hover());
    let painter = ui.painter();
    let swatch = Rect::from_center_size(
        egui::pos2(rect.left() + 6.0, rect.center().y),
        egui::vec2(10.0, 10.0),
    );
    painter.rect_filled(swatch, CornerRadius::same(2), color);
    let text = ui.visuals().text_color();
    painter.text(
        egui::pos2(rect.left() + 18.0, rect.center().y),
        Align2::LEFT_CENTER,
        label,
        FontId::proportional(13.0),
        text,
    );
    painter.text(
        egui::pos2(rect.right(), rect.center().y),
        Align2::RIGHT_CENTER,
        format_size(bytes),
        FontId::proportional(13.0),
        ui.visuals().weak_text_color(),
    );
}

/// A clickable list row: colour swatch, name, size.
fn node_row(ui: &mut Ui, color: Color32, name: &str, size: u64, selected: bool) -> egui::Response {
    let (rect, response) =
        ui.allocate_exact_size(egui::vec2(ui.available_width(), 20.0), Sense::click());
    let visuals = ui.visuals().clone();
    let painter = ui.painter();
    if selected || response.hovered() {
        let fill = if selected {
            visuals.selection.bg_fill
        } else {
            visuals.widgets.hovered.weak_bg_fill
        };
        painter.rect_filled(rect, CornerRadius::same(4), fill);
    }
    let swatch = Rect::from_center_size(
        egui::pos2(rect.left() + 8.0, rect.center().y),
        egui::vec2(9.0, 9.0),
    );
    painter.rect_filled(swatch, CornerRadius::same(2), color);
    painter.rect_stroke(
        swatch,
        CornerRadius::same(2),
        Stroke::new(0.5_f32, visuals.weak_text_color()),
        StrokeKind::Outside,
    );
    let size_text = format_size(size);
    let size_galley = painter.layout_no_wrap(
        size_text,
        FontId::proportional(12.5),
        visuals.weak_text_color(),
    );
    let name_room = (rect.width() - 22.0 - size_galley.size().x - 10.0).max(20.0);
    let max_chars = (name_room / 6.5) as usize;
    painter.text(
        egui::pos2(rect.left() + 18.0, rect.center().y),
        Align2::LEFT_CENTER,
        truncate_end(name, max_chars.max(4)),
        FontId::proportional(13.0),
        visuals.text_color(),
    );
    painter.galley(
        egui::pos2(
            rect.right() - 4.0 - size_galley.size().x,
            rect.center().y - size_galley.size().y / 2.0,
        ),
        size_galley,
        Color32::PLACEHOLDER,
    );
    response
}
