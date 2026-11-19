//! What `TreemapApp` draws: the scanning screen, the toolbar, the
//! treemap, the status bar and the rename dialog.

use super::{RenameState, TreemapApp};
use crate::ui::{centered_block, icon_button, primary_button, stat};

use alocir_shared::context_menu::{build_context_menu, DeferredAction};
use alocir_shared::file_ops::{open_path, open_terminal, quick_look, reveal_in_file_manager};
use alocir_shared::glyphs;
use alocir_shared::scanner::{format_size, FileNode};
use alocir_shared::text::{format_count, format_duration, truncate_end, truncate_start};
use alocir_shared::theme::{darken, mix, ThemeColors};
use alocir_shared::treemap::{
    hit_test, move_selection, tile_nodes, tile_path, Direction, NestedOptions, Tile, TILE_INSET,
};
use eframe::egui::text::{CCursor, CCursorRange, LayoutJob, TextWrapping};
use eframe::egui::{
    self, Align, Color32, CornerRadius, FontId, Frame, Key, Layout, Margin, Rect, RichText, Sense,
    Stroke, StrokeKind, Ui,
};
use eframe::emath::pos2;
use std::cell::RefCell;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// How long an error stays in the status bar.
const NOTICE_DURATION: Duration = Duration::from_secs(6);

/// Longest breadcrumb label, in characters, before it is shortened.
const MAX_CRUMB_CHARS: usize = 28;

fn item_count_label(n: usize) -> String {
    if n == 1 {
        "1 item".to_string()
    } else {
        format!("{} items", format_count(n as u64))
    }
}

fn percent_label(part: u64, whole: u64) -> String {
    let pct = part as f64 / whole.max(1) as f64 * 100.0;
    if pct > 0.0 && pct < 0.1 {
        "<0.1%".to_string()
    } else {
        format!("{pct:.1}%")
    }
}

/// A centred message for when there are no tiles to draw.
fn empty_state(ui: &mut Ui, glyph: &str, title: &str, detail: &str) {
    centered_block(ui, egui::vec2(420.0, 150.0), |ui| {
        ui.label(RichText::new(glyph).size(40.0).weak());
        ui.add_space(4.0);
        ui.label(RichText::new(title).size(18.0).strong());
        ui.weak(detail);
    });
}

/// Lay out one line of text, ending in "…" if it is wider than `max_width`.
fn elided(
    painter: &egui::Painter,
    text: &str,
    font: FontId,
    color: Color32,
    max_width: f32,
) -> Arc<egui::Galley> {
    // Cut by characters first so a huge name costs no more than a short one;
    // egui then elides to the exact pixel width.
    let max_chars = (max_width / (font.size * 0.25)) as usize + 4;
    let mut job = LayoutJob::simple_singleline(truncate_end(text, max_chars), font, color);
    job.wrap = TextWrapping {
        max_width,
        max_rows: 1,
        break_anywhere: true,
        overflow_character: Some('\u{2026}'),
    };
    painter.layout_job(job)
}

/// Paint `lines` (already laid out) as a block centred on `center`.
fn paint_centered_lines(painter: &egui::Painter, center: egui::Pos2, lines: &[Arc<egui::Galley>]) {
    const GAP: f32 = 1.0;
    let total: f32 =
        lines.iter().map(|g| g.size().y).sum::<f32>() + GAP * lines.len().saturating_sub(1) as f32;
    let mut y = center.y - total / 2.0;
    for galley in lines {
        let size = galley.size();
        painter.galley(
            pos2(center.x - size.x / 2.0, y).round(),
            galley.clone(),
            Color32::PLACEHOLDER,
        );
        y += size.y + GAP;
    }
}

/// Name and size labels for one tile. Directories large enough get a darker
/// title strip (name left, like a window title) with their size and item
/// count in the body; files and small directories get centred labels.
/// Label colours come from `base` (the tile's resting colour) rather than
/// the fill `bg`, so they do not flip while the tile is hovered.
fn paint_tile_labels(
    painter: &egui::Painter,
    theme: &ThemeColors,
    inner: Rect,
    child: &FileNode,
    base: Color32,
    bg: Color32,
    radius: u8,
) {
    const PAD: f32 = 6.0;
    const HEADER: f32 = 22.0;
    let (w, h) = (inner.width(), inner.height());
    if w < 36.0 || h < 16.0 {
        return;
    }
    let text_w = w - 2.0 * PAD;

    if child.is_dir && w >= 72.0 && h >= 46.0 {
        let header = Rect::from_min_max(inner.min, pos2(inner.right(), inner.top() + HEADER));
        let header_bg = darken(bg, 0.28);
        painter.rect_filled(
            header.shrink(1.0),
            CornerRadius {
                nw: radius.saturating_sub(1),
                ne: radius.saturating_sub(1),
                sw: 0,
                se: 0,
            },
            header_bg,
        );
        let (primary, _) = theme.label_colors(darken(base, 0.28));
        let icon = painter.layout_no_wrap(
            glyphs::FOLDER.to_string(),
            FontId::proportional(12.5),
            primary,
        );
        let icon_w = icon.size().x + 5.0;
        painter.galley(
            pos2(header.left() + PAD, header.center().y - icon.size().y / 2.0),
            icon,
            primary,
        );
        let name = elided(
            painter,
            &child.name,
            FontId::proportional(12.5),
            primary,
            text_w - icon_w,
        );
        painter.galley(
            pos2(
                header.left() + PAD + icon_w,
                header.center().y - name.size().y / 2.0,
            )
            .round(),
            name,
            primary,
        );

        let body = Rect::from_min_max(pos2(inner.left(), header.bottom()), inner.max);
        let (primary, secondary) = theme.label_colors(base);
        let fs = (body.width().min(body.height()) * 0.2).clamp(11.5, 20.0);
        let mut lines = Vec::with_capacity(2);
        lines.push(elided(
            painter,
            &format_size(child.size),
            FontId::proportional(fs),
            primary,
            text_w,
        ));
        if body.height() >= fs * 2.0 + 22.0 && w >= 90.0 {
            lines.push(elided(
                painter,
                &item_count_label(child.children.len()),
                FontId::proportional((fs * 0.72).clamp(10.5, 13.0)),
                secondary,
                text_w,
            ));
        }
        paint_centered_lines(painter, body.center(), &lines);
        return;
    }

    let (primary, secondary) = theme.label_colors(base);
    let fs = (w.min(h) * 0.14).clamp(11.0, 15.0);
    let mut lines = Vec::with_capacity(2);
    lines.push(elided(
        painter,
        &child.name,
        FontId::proportional(fs),
        primary,
        text_w,
    ));
    if h >= fs * 2.0 + 12.0 && w >= 48.0 {
        lines.push(elided(
            painter,
            &format_size(child.size),
            FontId::proportional((fs * 0.88).max(10.5)),
            secondary,
            text_w,
        ));
    }
    paint_centered_lines(painter, inner.center(), &lines);
}

/// Only built while a tile is hovered.
fn tile_tooltip(ui: &mut Ui, child: &FileNode, parent_size: u64) {
    ui.spacing_mut().item_spacing.y = 3.0;
    ui.label(RichText::new(&child.name).strong());
    ui.label(format!(
        "{}  {}  {} of this folder",
        format_size(child.size),
        glyphs::DOT,
        percent_label(child.size, parent_size)
    ));
    if child.is_dir {
        ui.weak(format!(
            "Folder  {}  {}",
            glyphs::DOT,
            item_count_label(child.children.len())
        ));
        ui.weak("Click to open, right-click for actions");
    } else {
        ui.weak("File, right-click for actions");
    }
}

/// Breadcrumb trail for `root` followed by `names`. When the trail is wider
/// than the space left, the middle collapses into "…" and, failing that, the
/// labels are shortened. Returns the depth to navigate to if one was clicked.
fn breadcrumbs(ui: &mut Ui, root: &str, root_path: &str, names: &[&str]) -> Option<usize> {
    let mut labels: Vec<String> = std::iter::once(root)
        .chain(names.iter().copied())
        .map(|name| truncate_end(name, MAX_CRUMB_CHARS))
        .collect();
    let n = labels.len();

    let font = egui::TextStyle::Button.resolve(ui.style());
    let pad = ui.spacing().button_padding.x * 2.0 + ui.spacing().item_spacing.x;
    let text_width = |ui: &Ui, s: &str| {
        ui.fonts(|f| f.layout_no_wrap(s.to_string(), font.clone(), Color32::WHITE))
            .size()
            .x
    };
    let widths: Vec<f32> = labels.iter().map(|l| text_width(ui, l) + pad).collect();
    let sep_w = text_width(ui, glyphs::CHEVRON) + ui.spacing().item_spacing.x;
    let ellipsis_w = text_width(ui, glyphs::ELLIPSIS) + pad;
    let avail = ui.available_width() - 4.0;

    // Crumbs 1..start are hidden behind "…" (start == 1 hides nothing).
    let total = |start: usize, with_root: bool| -> f32 {
        let root_w = if with_root { widths[0] + sep_w } else { 0.0 };
        let hidden_w = if start > 1 || (!with_root && n > 1) {
            ellipsis_w + sep_w
        } else {
            0.0
        };
        let shown: f32 = widths[start.min(n)..].iter().sum();
        root_w + hidden_w + shown + sep_w * n.saturating_sub(start + 1) as f32
    };
    let mut start = 1;
    while start + 1 < n && total(start, true) > avail {
        start += 1;
    }
    let show_root = n == 1 || total(start, true) <= avail;
    let overflow = total(start, show_root) - avail;
    if overflow > 0.0 {
        // Still too wide: shorten the last crumb to what is left.
        let last = n - 1;
        let room = (widths[last] - overflow - pad).max(0.0);
        let chars = ((room / (font.size * 0.55)) as usize).max(4);
        let source = if last == 0 { root } else { names[last - 1] };
        labels[last] = truncate_end(source, chars.min(MAX_CRUMB_CHARS));
    }

    let mut clicked = None;
    let weak = ui.visuals().weak_text_color();
    let separator = |ui: &mut Ui| {
        ui.label(RichText::new(glyphs::CHEVRON).color(weak));
    };
    let mut first = true;
    for depth in 0..n {
        let hidden = (depth == 0 && !show_root) || (depth >= 1 && depth < start);
        if hidden {
            // One "…" stands in for the whole hidden run; it goes to the
            // deepest hidden folder.
            let run_end = if depth == 0 { start.max(1) } else { start };
            if depth == 0 || (depth == 1 && show_root) {
                if !first {
                    separator(ui);
                }
                first = false;
                let target = run_end - 1;
                let hint = std::iter::once(root_path)
                    .chain(names[..target].iter().copied())
                    .collect::<Vec<_>>()
                    .join(std::path::MAIN_SEPARATOR_STR);
                if ui
                    .selectable_label(false, RichText::new(glyphs::ELLIPSIS).color(weak))
                    .on_hover_text(hint)
                    .clicked()
                {
                    clicked = Some(target);
                }
            }
            continue;
        }
        if !first {
            separator(ui);
        }
        first = false;
        let is_current = depth == n - 1;
        let text = if is_current {
            RichText::new(&labels[depth]).strong()
        } else {
            RichText::new(&labels[depth])
        };
        let response = ui.selectable_label(false, text);
        let response = if depth == 0 {
            response.on_hover_text(root_path)
        } else if labels[depth] != names[depth - 1] {
            response.on_hover_text(names[depth - 1])
        } else {
            response
        };
        if response.clicked() && !is_current {
            clicked = Some(depth);
        }
    }
    clicked
}

impl TreemapApp {
    pub(super) fn show_scanning_ui(&self, ctx: &egui::Context) {
        // Keep the elapsed time ticking even when the scanner is quiet.
        ctx.request_repaint_after(Duration::from_millis(100));

        egui::CentralPanel::default().show(ctx, |ui| {
            let items = self.scan_progress.items_scanned.load(Ordering::Relaxed);
            let bytes = self.scan_progress.bytes_scanned.load(Ordering::Relaxed);
            let current = self.scan_progress.current_path.lock().unwrap().clone();
            let folder = self
                .scan_path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| self.root_path.clone());

            centered_block(ui, egui::vec2(560.0, 260.0), |ui| {
                ui.add(egui::Spinner::new().size(30.0));
                ui.add_space(10.0);
                ui.label(
                    RichText::new(format!("Scanning {}", truncate_end(&folder, 40)))
                        .size(20.0)
                        .strong(),
                );
                ui.weak(truncate_start(&self.root_path, 70));
                ui.add_space(18.0);

                ui.allocate_ui(egui::vec2(420.0, 52.0), |ui| {
                    ui.columns(3, |cols| {
                        stat(&mut cols[0], &format_count(items), "items");
                        stat(&mut cols[1], &format_size(bytes), "scanned");
                        stat(
                            &mut cols[2],
                            &format_duration(self.scan_started.elapsed()),
                            "elapsed",
                        );
                    });
                });

                ui.add_space(14.0);
                // Roughly as many characters as fit the block's width.
                let max_chars = (ui.available_width() / 7.2) as usize;
                ui.add(
                    egui::Label::new(
                        RichText::new(truncate_start(&current, max_chars.max(20)))
                            .monospace()
                            .weak(),
                    )
                    .truncate(),
                );
            });
        });
    }

    pub(super) fn show_rename_dialog(&mut self, ctx: &egui::Context) {
        let mut should_close = false;
        let mut should_rename = false;

        if let Some(state) = &mut self.rename_state {
            let old_name = state
                .path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            let trimmed = state.new_name.trim();
            let valid = !trimmed.is_empty()
                && trimmed != "."
                && trimmed != ".."
                && !trimmed.contains(std::path::is_separator);

            let mut open = true;
            egui::Window::new("Rename")
                .collapsible(false)
                .resizable(false)
                .open(&mut open)
                .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
                .show(ctx, |ui| {
                    ui.set_width(340.0);
                    ui.weak(format!("New name for \"{}\"", truncate_end(&old_name, 36)));

                    let id = ui.make_persistent_id("rename_field");
                    let response = ui.add(
                        egui::TextEdit::singleline(&mut state.new_name)
                            .id(id)
                            .desired_width(f32::INFINITY),
                    );
                    if state.focus_pending {
                        state.focus_pending = false;
                        response.request_focus();
                        // Select the name without its extension, as file
                        // managers do, so typing replaces just that part.
                        let stem_chars = match old_name.rfind('.') {
                            Some(dot) if dot > 0 && !state.is_dir => {
                                old_name[..dot].chars().count()
                            }
                            _ => old_name.chars().count(),
                        };
                        if let Some(mut edit) = egui::TextEdit::load_state(ctx, id) {
                            edit.cursor.set_char_range(Some(CCursorRange::two(
                                CCursor::new(0),
                                CCursor::new(stem_chars),
                            )));
                            edit.store(ctx, id);
                        }
                    }
                    let enter = response.lost_focus() && ui.input(|i| i.key_pressed(Key::Enter));
                    if enter && valid {
                        should_rename = true;
                    } else if enter {
                        response.request_focus();
                    }
                    if ui.input(|i| i.key_pressed(Key::Escape)) {
                        should_close = true;
                    }

                    if let Some(err) = &state.error {
                        ui.colored_label(ui.visuals().error_fg_color, err);
                    }

                    ui.add_space(6.0);
                    let row = egui::vec2(ui.available_width(), ui.spacing().interact_size.y);
                    ui.allocate_ui_with_layout(row, Layout::right_to_left(Align::Center), |ui| {
                        if primary_button(ui, valid, RichText::new("Rename"), egui::vec2(84.0, 0.0))
                            .clicked()
                        {
                            should_rename = true;
                        }
                        if ui
                            .add(egui::Button::new("Cancel").min_size(egui::vec2(84.0, 0.0)))
                            .clicked()
                        {
                            should_close = true;
                        }
                    });
                });
            if !open {
                should_close = true;
            }
        }

        if should_close {
            self.rename_state = None;
        } else if should_rename {
            self.apply_rename(ctx);
        }
    }

    fn apply_rename(&mut self, ctx: &egui::Context) {
        let Some(state) = &mut self.rename_state else {
            return;
        };
        let Some(parent) = state.path.parent() else {
            return;
        };
        let new_name = state.new_name.trim();
        let old_path = state.path.clone();
        let new_path = parent.join(new_name);
        if new_path == old_path {
            self.rename_state = None;
            return;
        }
        // `fs::rename` silently replaces an existing file on Unix. A name that
        // differs only by case is the same file on case-insensitive volumes.
        let case_only = old_path
            .file_name()
            .is_some_and(|old| old.to_string_lossy().to_lowercase() == new_name.to_lowercase());
        if !case_only && std::fs::symlink_metadata(&new_path).is_ok() {
            state.error = Some(format!("\"{new_name}\" already exists here."));
            state.focus_pending = true;
            return;
        }
        match std::fs::rename(&old_path, &new_path) {
            Ok(()) => {
                // Update the tree in place instead of rescanning
                // everything: drop the old entry, add the new one.
                self.rename_state = None;
                self.reconcile_path(&old_path, ctx);
                self.reconcile_path(&new_path, ctx);
            }
            Err(e) => {
                state.error = Some(e.to_string());
                state.focus_pending = true;
            }
        }
    }

    pub(super) fn show_treemap_ui(&mut self, ctx: &egui::Context) {
        let scheme = self.settings.scheme;
        let palette = scheme.palette();

        let mut go_up = false;
        let mut rescan = false;
        let mut crumb_click: Option<usize> = None;

        // Shortcuts that work whatever has the keyboard, unless a dialog or
        // menu owns the input.
        let rescan_shortcut = egui::KeyboardShortcut::new(egui::Modifiers::COMMAND, Key::R);
        let find_shortcut = egui::KeyboardShortcut::new(egui::Modifiers::COMMAND, Key::F);
        let inspector_shortcut =
            egui::KeyboardShortcut::new(egui::Modifiers::COMMAND | egui::Modifiers::ALT, Key::I);
        let dialog_open = self.rename_state.is_some() || self.settings.open;
        if !dialog_open && !ctx.is_context_menu_open() {
            ctx.input_mut(|i| {
                go_up = i.pointer.button_pressed(egui::PointerButton::Extra1);
                rescan = i.consume_shortcut(&rescan_shortcut) || i.key_pressed(Key::F5);
                if i.consume_shortcut(&find_shortcut) {
                    self.search.focus = true;
                }
                if i.consume_shortcut(&inspector_shortcut) {
                    self.settings.show_inspector = !self.settings.show_inspector;
                }
            });
        }

        let panel_frame = |x: i8, y: i8| {
            Frame::side_top_panel(&ctx.style()).inner_margin(Margin::symmetric(x, y))
        };

        egui::TopBottomPanel::top("toolbar")
            .frame(panel_frame(10, 7))
            .show(ctx, |ui| {
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    if icon_button(ui, true, glyphs::SETTINGS, "Settings").clicked() {
                        self.settings.open = !self.settings.open;
                    }
                    let inspector_tip = format!(
                        "Show or hide the inspector ({})",
                        ctx.format_shortcut(&inspector_shortcut)
                    );
                    if icon_button(ui, true, glyphs::INSPECTOR, &inspector_tip).clicked() {
                        self.settings.show_inspector = !self.settings.show_inspector;
                    }
                    if icon_button(ui, true, glyphs::NEW_SCAN, "New scan (opens a new window)")
                        .clicked()
                    {
                        super::spawn_new_instance();
                    }
                    ui.add_space(4.0);
                    self.search_field(ui, &find_shortcut);
                    if let Some(node) = self.current_node() {
                        ui.separator();
                        ui.label(RichText::new(format_size(node.size)).strong())
                            .on_hover_text("Total size of this folder");
                    }
                    ui.add_space(4.0);

                    // The rest of the row, left to right.
                    ui.with_layout(Layout::left_to_right(Align::Center), |ui| {
                        ui.set_clip_rect(ui.max_rect().intersect(ui.clip_rect()));
                        let at_root = self.nav_stack.is_empty();
                        let up_tip = if at_root {
                            "Already at the scanned folder"
                        } else {
                            "Up one level (Backspace)"
                        };
                        if icon_button(ui, !at_root, glyphs::UP, up_tip).clicked() {
                            go_up = true;
                        }
                        let rescan_tip =
                            format!("Rescan ({})", ctx.format_shortcut(&rescan_shortcut));
                        if icon_button(ui, true, glyphs::RESCAN, &rescan_tip).clicked() {
                            rescan = true;
                        }
                        ui.separator();

                        ui.spacing_mut().item_spacing.x = 2.0;
                        ui.spacing_mut().button_padding.x = 6.0;
                        let names = self.nav_names();
                        let names: Vec<&str> = names.iter().map(String::as_str).collect();
                        let root_label = self
                            .scan_path
                            .file_name()
                            .map(|n| n.to_string_lossy())
                            .unwrap_or_else(|| self.scan_path.to_string_lossy());
                        crumb_click = breadcrumbs(ui, &root_label, &self.root_path, &names);
                    });
                });
            });

        if self
            .notice
            .as_ref()
            .is_some_and(|(_, at)| at.elapsed() > NOTICE_DURATION)
        {
            self.notice = None;
        }

        // The status bar runs the full width, below the map and the
        // inspector.
        egui::TopBottomPanel::bottom("status")
            .frame(panel_frame(12, 4))
            .show(ctx, |ui| self.status_bar(ui));

        let mut inspector_action = None;
        if self.settings.show_inspector {
            self.refresh_summary();
            egui::SidePanel::right("inspector")
                .resizable(true)
                .default_width(290.0)
                .width_range(240.0..=460.0)
                .frame(panel_frame(14, 12))
                .show(ctx, |ui| {
                    inspector_action = self.show_inspector(ui);
                });
        }

        let mut outcome = egui::CentralPanel::default()
            .frame(Frame::new().fill(palette.canvas).inner_margin(3.0))
            .show(ctx, |ui| self.show_map(ui, dialog_open))
            .inner;

        // Apply what happened, now that nothing borrows the tree.
        self.hovered = outcome.hovered.take();
        if rescan || outcome.rescan {
            self.scan_started = Instant::now();
            self.hovered = None;
            self.trigger_rescan(ctx);
            return;
        }
        if let Some(action) = inspector_action {
            self.apply_inspector_action(action, ctx);
        }
        if let Some(depth) = crumb_click {
            self.nav_stack.truncate(depth);
            self.selection = None;
            self.hovered = None;
        } else if go_up {
            self.zoom_out();
        }
        self.apply_map_outcome(outcome, ctx);
    }

    /// The search field, in a right-to-left toolbar row.
    fn search_field(&mut self, ui: &mut Ui, shortcut: &egui::KeyboardShortcut) {
        if !self.search.text.is_empty()
            && ui
                .small_button(glyphs::CLOSE)
                .on_hover_text("Clear the search")
                .clicked()
        {
            self.search.text.clear();
            self.search_edited();
        }
        let id = ui.make_persistent_id("search_field");
        let response = ui.add(
            egui::TextEdit::singleline(&mut self.search.text)
                .id(id)
                .hint_text(format!("{}  Name, .ext, >100mb", glyphs::SEARCH))
                .desired_width(200.0),
        );
        let response = response.on_hover_text(format!(
            "Search by name, extension (.mov) or size (>1gb) ({})",
            ui.ctx().format_shortcut(shortcut)
        ));
        if response.changed() {
            self.search_edited();
        }
        if self.search.focus {
            self.search.focus = false;
            response.request_focus();
        }
        // Escape in the field clears it, like a system search field.
        if response.has_focus() && ui.input(|i| i.key_pressed(Key::Escape)) {
            self.search.text.clear();
            self.search_edited();
            response.surrender_focus();
        }
    }

    fn status_bar(&self, ui: &mut Ui) {
        let palette = self.settings.scheme.palette();
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            let mut right = String::new();
            if let Some(node) = self.current_node() {
                right.push_str(&item_count_label(node.children.len()));
            }
            if let Some(duration) = self.scan_duration {
                if !right.is_empty() {
                    right.push_str(&format!("  {}  ", glyphs::DOT));
                }
                right.push_str(&format!("Scanned in {}", format_duration(duration)));
            }
            ui.label(RichText::new(right).small().weak());
            ui.add_space(8.0);

            ui.with_layout(Layout::left_to_right(Align::Center), |ui| {
                let max_chars = ((ui.available_width() / 6.0) as usize).max(12);
                let hovered = self
                    .hovered
                    .as_deref()
                    .and_then(|path| self.focus_child(path));
                let text = if let Some((message, _)) = &self.notice {
                    RichText::new(format!("{}  {message}", glyphs::WARNING)).color(palette.danger)
                } else if let Some((child, parent_size)) = hovered {
                    RichText::new(format!(
                        "{}  {}  {}  {}  {}",
                        truncate_end(&child.name, max_chars.saturating_sub(24).max(8)),
                        glyphs::DOT,
                        format_size(child.size),
                        glyphs::DOT,
                        percent_label(child.size, parent_size),
                    ))
                } else {
                    let current = self.current_dir_path();
                    RichText::new(truncate_start(&current.to_string_lossy(), max_chars)).weak()
                };
                ui.add(egui::Label::new(text.small()).truncate());
            });
        });
    }

    /// The node at child-index `path` below the focused folder, and the
    /// size of its parent.
    fn focus_child(&self, path: &[usize]) -> Option<(&FileNode, u64)> {
        let mut parent = self.current_node()?;
        let (last, rest) = path.split_last()?;
        for &i in rest {
            parent = parent.children.get(i)?;
        }
        Some((parent.children.get(*last)?, parent.size))
    }

    /// Names from the scan root to the node at `path` below the focus.
    fn names_below_focus(&self, path: &[usize]) -> Option<Vec<String>> {
        let mut names = self.nav_names();
        let mut node = self.current_node()?;
        for &i in path {
            node = node.children.get(i)?;
            names.push(node.name.clone());
        }
        Some(names)
    }

    /// The treemap: nested tiles, one hit-tested area for the pointer, and
    /// the keyboard. Nothing in the tree changes here; what happened is
    /// returned and applied afterwards.
    fn show_map(&mut self, ui: &mut Ui, dialog_open: bool) -> MapOutcome {
        let mut outcome = MapOutcome::default();
        let bounds = ui.available_rect_before_wrap();
        self.refresh_layout(bounds);
        self.validate_selection();

        let Some(node) = self.current_node() else {
            centered_block(ui, egui::vec2(420.0, 190.0), |ui| {
                ui.label(RichText::new(glyphs::WARNING).size(40.0).weak());
                ui.add_space(4.0);
                ui.label(RichText::new("No data").size(18.0).strong());
                ui.weak("This folder could not be read, or it no longer exists.");
                ui.add_space(10.0);
                outcome.rescan = ui.button("Rescan").clicked();
            });
            return outcome;
        };
        if node.children.is_empty() {
            empty_state(
                ui,
                glyphs::FOLDER,
                "This folder is empty",
                &truncate_end(&node.name, 60),
            );
            return outcome;
        }
        let Some(layout) = &self.layout else {
            return outcome;
        };
        if layout.tiles.is_empty() {
            empty_state(
                ui,
                glyphs::FOLDER,
                "Nothing to show",
                &format!(
                    "{} here, all 0 bytes.",
                    item_count_label(node.children.len())
                ),
            );
            return outcome;
        }
        let tiles = &layout.tiles;
        let nodes = tile_nodes(tiles, node);
        let selected = self
            .selected_node()
            .and_then(|sel| nodes.iter().position(|n| std::ptr::eq(*n, sel)));
        let parent_size = |i: usize| {
            let parent = tiles[i].parent;
            if parent < 0 {
                node.size
            } else {
                nodes[parent as usize].size
            }
        };

        // Pointer: one area for the whole map, hit-tested against the tiles.
        let response = ui.allocate_rect(bounds, Sense::click());
        let hover = response.hover_pos().and_then(|p| hit_test(tiles, p));
        outcome.hovered = hover.map(|i| tile_path(tiles, i));
        if response.clicked() || response.secondary_clicked() {
            outcome.select = Some(hover.map(|i| tile_path(tiles, i)));
        }
        if response.double_clicked() {
            if let Some(i) = hover {
                if nodes[i].is_dir {
                    outcome.zoom = Some(tile_path(tiles, i));
                } else {
                    outcome.open = Some(tile_path(tiles, i));
                }
            }
        }
        let response = match hover {
            Some(i) => {
                response.on_hover_ui_at_pointer(|ui| tile_tooltip(ui, nodes[i], parent_size(i)))
            }
            None => response,
        };
        // The menu is for the tile right-clicked, kept while it stays open.
        let menu_target = if response.secondary_clicked() {
            let target = hover.and_then(|i| self.names_below_focus(&tile_path(tiles, i)));
            outcome.menu_target = Some(target.clone());
            target
        } else {
            self.menu_target.clone()
        };
        let deferred: RefCell<Option<DeferredAction>> = RefCell::new(None);
        let menu_open = response
            .context_menu(|ui| {
                let Some(names) = &menu_target else {
                    ui.close_menu();
                    return;
                };
                let Some(target) = self.node_at_names(names) else {
                    ui.close_menu();
                    return;
                };
                let path = self.path_for(names);
                build_context_menu(ui, &deferred, &path, &target.name, target.is_dir);
            })
            .is_some();
        let menu_tile = if menu_open {
            menu_target.as_ref().and_then(|names| {
                let target = self.node_at_names(names)?;
                nodes.iter().position(|n| std::ptr::eq(*n, target))
            })
        } else {
            None
        };
        outcome.action = deferred.into_inner();

        // Keyboard, when nothing else wants it.
        if !dialog_open && !ui.ctx().wants_keyboard_input() && !ui.ctx().is_context_menu_open() {
            outcome.key = map_key(ui, tiles, bounds, selected);
        }

        self.paint_tiles(
            ui,
            tiles,
            &nodes,
            &layout.kinds,
            hover.or(menu_tile),
            selected,
        );
        outcome
    }

    #[allow(clippy::too_many_arguments)]
    fn paint_tiles(
        &self,
        ui: &Ui,
        tiles: &[Tile],
        nodes: &[&FileNode],
        kinds: &std::collections::HashMap<usize, alocir_shared::kind::FileKind>,
        hot: Option<usize>,
        selected: Option<usize>,
    ) {
        let theme = self.settings.scheme.theme();
        let palette = self.settings.scheme.palette();
        let searching = self.search_active();
        let labels = self.settings.show_labels;
        let painter = ui.painter();
        let radius = palette.radius.min(3);

        for (i, tile) in tiles.iter().enumerate() {
            let inner = tile.rect.shrink(TILE_INSET);
            let child = nodes[i];
            let dominant = kinds.get(&(child as *const FileNode as usize)).copied();
            let mut base = theme.tile_color(child, dominant);
            if searching && child.mark == 0 {
                // Fade what doesn't match, and isn't above a match.
                base = mix(base, palette.canvas, 0.72);
            }
            let is_hot = hot == Some(i);
            let bg = if is_hot {
                theme.hover_color(base)
            } else {
                base
            };
            let edge = if child.is_dir {
                theme.dir_border
            } else {
                theme.file_border
            };
            let small = inner.width().min(inner.height()) < 8.0;
            let corner = CornerRadius::same(if small { 0 } else { radius });

            if tile.shows_children {
                // A folder frame: header strip in the folder's colour, a
                // darker body that its children are drawn on.
                painter.rect_filled(inner, corner, darken(bg, 0.45));
                let header = Rect::from_min_max(
                    inner.min,
                    pos2(
                        inner.right(),
                        (inner.top() + NestedOptions::default().header).min(inner.bottom()),
                    ),
                );
                painter.rect_filled(
                    header,
                    CornerRadius {
                        nw: corner.nw,
                        ne: corner.ne,
                        sw: 0,
                        se: 0,
                    },
                    bg,
                );
                painter.rect_stroke(
                    inner,
                    corner,
                    Stroke::new(1.0_f32, mix(bg, edge, 0.4)),
                    StrokeKind::Inside,
                );
                if labels {
                    paint_header_label(painter, &theme, header, child, base);
                }
                continue;
            }

            painter.rect_filled(inner, corner, bg);
            if !small {
                let stroke = if is_hot {
                    Stroke::new(2.0_f32, edge)
                } else {
                    Stroke::new(1.0_f32, mix(bg, edge, 0.4))
                };
                painter.rect_stroke(inner, corner, stroke, StrokeKind::Inside);
            }
            if labels {
                paint_tile_labels(painter, &theme, inner, child, base, bg, radius);
            }
        }

        // The selection on top of everything, so a nested one stays visible.
        if let Some(i) = selected {
            let inner = tiles[i].rect.shrink(TILE_INSET);
            painter.rect_stroke(
                inner,
                CornerRadius::same(radius),
                Stroke::new(2.5_f32, palette.accent),
                StrokeKind::Inside,
            );
        }
    }

    fn apply_map_outcome(&mut self, outcome: MapOutcome, ctx: &egui::Context) {
        if let Some(target) = outcome.menu_target {
            self.menu_target = target;
        }
        if let Some(select) = outcome.select {
            self.selection = select.and_then(|path| self.names_below_focus(&path));
        }
        if let Some(path) = outcome.zoom {
            if let Some(names) = self.names_below_focus(&path) {
                self.zoom_into(&names);
            }
        }
        if let Some(path) = outcome.open {
            if let Some(names) = self.names_below_focus(&path) {
                open_path(&self.path_for(&names));
            }
        }
        if let Some(key) = outcome.key {
            self.apply_map_key(key, ctx);
        }
        if let Some(action) = outcome.action {
            self.apply_action(action, ctx);
        }
    }

    fn apply_map_key(&mut self, key: MapKey, ctx: &egui::Context) {
        let selected_path = self.selection.as_ref().map(|names| self.path_for(names));
        match key {
            MapKey::Select(path) => {
                self.selection = self.names_below_focus(&path);
            }
            MapKey::Up => self.zoom_out(),
            MapKey::Top => {
                self.nav_stack.clear();
                self.selection = None;
                self.hovered = None;
            }
            MapKey::ZoomIn => {
                if let Some(names) = self.selection.clone() {
                    self.zoom_into(&names);
                }
            }
            MapKey::Escape => {
                if self.selection.is_some() {
                    self.selection = None;
                } else if !self.search.text.is_empty() {
                    self.search.text.clear();
                    self.search_edited();
                } else {
                    self.zoom_out();
                }
            }
            MapKey::Rename => {
                if let (Some(path), Some(node)) = (selected_path, self.selected_node()) {
                    let name = node.name.clone();
                    self.apply_action(
                        DeferredAction::StartRename {
                            path,
                            current_name: name,
                        },
                        ctx,
                    );
                }
            }
            MapKey::QuickLook => {
                if let Some(path) = selected_path {
                    quick_look(&path);
                }
            }
            MapKey::Trash => {
                if let Some(path) = selected_path {
                    self.do_trash(path, ctx);
                }
            }
        }
    }

    pub(super) fn apply_action(&mut self, action: DeferredAction, ctx: &egui::Context) {
        match action {
            DeferredAction::OpenFile(p) => open_path(&p),
            DeferredAction::RevealInFinder(p) => reveal_in_file_manager(&p),
            DeferredAction::CopyPath(s) => ctx.copy_text(s),
            DeferredAction::StartRename { path, current_name } => {
                self.rename_state = Some(RenameState {
                    is_dir: path.is_dir(),
                    path,
                    new_name: current_name,
                    error: None,
                    focus_pending: true,
                });
            }
            DeferredAction::MoveToTrash(p) => self.do_trash(p, ctx),
            DeferredAction::OpenTerminal(p) => open_terminal(&p),
            DeferredAction::QuickLook(p) => quick_look(&p),
            DeferredAction::ZoomIn(p) => {
                if let Some(names) = self.rel_names(&p) {
                    self.zoom_into(&names);
                }
            }
        }
    }
}

/// A key pressed on the map.
pub(super) enum MapKey {
    /// Select the tile at this child path below the focus.
    Select(Vec<usize>),
    Up,
    Top,
    ZoomIn,
    Escape,
    Rename,
    QuickLook,
    Trash,
}

/// What happened on the map this frame, applied once the UI pass is over.
#[derive(Default)]
pub(super) struct MapOutcome {
    /// Child path below the focus of the tile under the pointer.
    hovered: Option<Vec<usize>>,
    /// A click: select this tile, or (with `None`) nothing.
    select: Option<Option<Vec<usize>>>,
    zoom: Option<Vec<usize>>,
    open: Option<Vec<usize>>,
    key: Option<MapKey>,
    /// The tile right-clicked this frame, whose menu opens.
    menu_target: Option<Option<Vec<String>>>,
    action: Option<DeferredAction>,
    rescan: bool,
}

/// The map's keyboard: arrows move the selection, Return renames, Space
/// previews, Backspace goes up; with Cmd, Down zooms in, Up goes up,
/// Shift+Up goes to the top and Backspace moves to the Trash.
fn map_key(ui: &Ui, tiles: &[Tile], bounds: Rect, selected: Option<usize>) -> Option<MapKey> {
    use egui::{KeyboardShortcut as Ks, Modifiers as M};
    ui.input_mut(|i| {
        if i.consume_shortcut(&Ks::new(M::COMMAND | M::SHIFT, Key::ArrowUp)) {
            return Some(MapKey::Top);
        }
        if i.consume_shortcut(&Ks::new(M::COMMAND, Key::ArrowUp)) {
            return Some(MapKey::Up);
        }
        if i.consume_shortcut(&Ks::new(M::COMMAND, Key::ArrowDown)) {
            return Some(MapKey::ZoomIn);
        }
        if i.consume_shortcut(&Ks::new(M::COMMAND, Key::Backspace))
            || i.consume_shortcut(&Ks::new(M::COMMAND, Key::Delete))
        {
            return Some(MapKey::Trash);
        }
        if !i.modifiers.is_none() {
            return None;
        }
        for (key, direction) in [
            (Key::ArrowLeft, Direction::Left),
            (Key::ArrowRight, Direction::Right),
            (Key::ArrowUp, Direction::Up),
            (Key::ArrowDown, Direction::Down),
        ] {
            if i.key_pressed(key) {
                let next = match selected {
                    Some(index) => move_selection(tiles, bounds, index, direction),
                    None => Some(0),
                };
                return next.map(|n| MapKey::Select(tile_path(tiles, n)));
            }
        }
        if i.key_pressed(Key::Enter) {
            return Some(MapKey::Rename);
        }
        if i.key_pressed(Key::Space) {
            return Some(MapKey::QuickLook);
        }
        if i.key_pressed(Key::Backspace) || i.key_pressed(Key::Delete) {
            return Some(MapKey::Up);
        }
        if i.key_pressed(Key::Escape) {
            return Some(MapKey::Escape);
        }
        None
    })
}

/// A nested folder's header: name on the left, size on the right when it fits.
fn paint_header_label(
    painter: &egui::Painter,
    theme: &ThemeColors,
    header: Rect,
    node: &FileNode,
    base: Color32,
) {
    const PAD: f32 = 5.0;
    if header.width() < 30.0 || header.height() < 12.0 {
        return;
    }
    let (primary, secondary) = theme.label_colors(base);
    let font = FontId::proportional(11.5);
    let size = painter.layout_no_wrap(format_size(node.size), font.clone(), secondary);
    let room = header.width() - 2.0 * PAD;
    let show_size = room > size.size().x + 40.0;
    let name_w = if show_size {
        room - size.size().x - 8.0
    } else {
        room
    };
    let name = elided(painter, &node.name, font, primary, name_w);
    let y = header.center().y - name.size().y / 2.0;
    painter.galley(pos2(header.left() + PAD, y).round(), name, primary);
    if show_size {
        let x = header.right() - PAD - size.size().x;
        painter.galley(pos2(x, y).round(), size, secondary);
    }
}
