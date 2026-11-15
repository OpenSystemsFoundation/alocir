//! What `SpaceSnifferApp` draws: the scanning screen, the toolbar, the
//! treemap, the status bar and the rename dialog.

use super::{RenameState, SpaceSnifferApp};
use crate::ui::{centered_block, icon_button, primary_button, stat};

use alocir_shared::context_menu::{build_context_menu, DeferredAction};
use alocir_shared::file_ops::{open_path, open_terminal, reveal_in_file_manager};
use alocir_shared::glyphs;
use alocir_shared::scanner::{format_size, FileNode};
use alocir_shared::text::{format_count, format_duration, truncate_end, truncate_start};
use alocir_shared::theme::{darken, mix, ThemeColors};
use alocir_shared::treemap::{layout_visible, TILE_INSET};
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

/// What happened in the treemap this frame, applied once the UI pass is over.
#[derive(Default)]
struct TreemapOutcome {
    clicked_dir: Option<usize>,
    hovered: Option<usize>,
    action: Option<DeferredAction>,
    rescan: bool,
}

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

impl SpaceSnifferApp {
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
        let theme = scheme.theme();
        let palette = scheme.palette();

        let mut go_up = false;
        let mut rescan = false;
        let mut crumb_click: Option<usize> = None;

        // Keyboard and mouse shortcuts, unless a dialog or menu owns the input.
        let rescan_shortcut = egui::KeyboardShortcut::new(egui::Modifiers::COMMAND, Key::R);
        let dialog_open = self.rename_state.is_some() || self.settings.open;
        if !dialog_open && !ctx.is_context_menu_open() {
            ctx.input_mut(|i| {
                go_up = i.key_pressed(Key::Backspace)
                    || i.key_pressed(Key::Escape)
                    || i.pointer.button_pressed(egui::PointerButton::Extra1);
                rescan = i.consume_shortcut(&rescan_shortcut) || i.key_pressed(Key::F5);
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
                    if icon_button(ui, true, glyphs::NEW_SCAN, "New scan (opens a new window)")
                        .clicked()
                    {
                        super::spawn_new_instance();
                    }
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
                        let mut names: Vec<&str> = Vec::with_capacity(self.nav_stack.len());
                        if let Some(root) = &self.root {
                            let mut node = root;
                            for &idx in &self.nav_stack {
                                let Some(child) = node.children.get(idx) else {
                                    break;
                                };
                                node = child;
                                names.push(&node.name);
                            }
                        }
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
        let current_dir = self.current_dir_path();

        egui::TopBottomPanel::bottom("status")
            .frame(panel_frame(12, 4))
            .show(ctx, |ui| {
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
                        let hovered = self.current_node().and_then(|node| {
                            let child = node.children.get(self.hovered?)?;
                            Some((child, node.size))
                        });
                        let text = if let Some((message, _)) = &self.notice {
                            RichText::new(format!("{}  {message}", glyphs::WARNING))
                                .color(palette.danger)
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
                            RichText::new(truncate_start(&current_dir.to_string_lossy(), max_chars))
                                .weak()
                        };
                        ui.add(egui::Label::new(text.small()).truncate());
                    });
                });
            });

        let this = &*self;
        let mut outcome = egui::CentralPanel::default()
            .frame(Frame::new().fill(palette.canvas).inner_margin(3.0))
            .show(ctx, |ui| {
                let mut outcome = TreemapOutcome::default();
                let Some(node) = this.current_node() else {
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

                let bounds = ui.available_rect_before_wrap();
                // Only tiles big enough to draw; nothing below is done for the rest.
                let layout = layout_visible(&node.children, bounds);
                if layout.is_empty() {
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

                let deferred: RefCell<Option<DeferredAction>> = RefCell::new(None);
                let parent_size = node.size;
                // The tile under the pointer, or the one whose menu is open.
                let mut highlighted: Option<usize> = None;

                // Pass 1: allocate rects, clicks, tooltips, context menus.
                // Tooltip and menu contents are only built when shown.
                for (i, item) in layout.iter().enumerate() {
                    let inner = item.rect.shrink(TILE_INSET);
                    let child = &node.children[item.index];

                    let response = ui.allocate_rect(inner, Sense::click());
                    if response.clicked() && child.is_dir {
                        outcome.clicked_dir = Some(item.index);
                    }
                    if response.hovered() {
                        highlighted = Some(i);
                        outcome.hovered = Some(item.index);
                    }
                    let response = if child.is_dir {
                        response.on_hover_cursor(egui::CursorIcon::PointingHand)
                    } else {
                        response
                    };
                    let response =
                        response.on_hover_ui_at_pointer(|ui| tile_tooltip(ui, child, parent_size));
                    let menu = response.context_menu(|ui| {
                        let item_path = current_dir.join(&child.name);
                        build_context_menu(ui, &deferred, &item_path, &child.name, child.is_dir);
                    });
                    if menu.is_some() {
                        highlighted = Some(i);
                    }
                }

                // Pass 2: paint
                let painter = ui.painter();
                let radius = palette.radius.min(3);
                for (i, item) in layout.iter().enumerate() {
                    let inner = item.rect.shrink(TILE_INSET);
                    let child = &node.children[item.index];
                    let hot = highlighted == Some(i);
                    let base = theme.color_for_node(&child.name, child.is_dir);
                    let bg = if hot { theme.hover_color(base) } else { base };
                    let edge = if child.is_dir {
                        theme.dir_border
                    } else {
                        theme.file_border
                    };

                    // Slivers stay square so they do not turn into dots.
                    let small = inner.width().min(inner.height()) < 8.0;
                    let corner = CornerRadius::same(if small { 0 } else { radius });
                    painter.rect_filled(inner, corner, bg);
                    if !small {
                        let stroke = if hot {
                            Stroke::new(2.0_f32, edge)
                        } else {
                            Stroke::new(1.0_f32, mix(bg, edge, 0.4))
                        };
                        painter.rect_stroke(inner, corner, stroke, StrokeKind::Inside);
                    }
                    paint_tile_labels(painter, &theme, inner, child, base, bg, radius);
                }

                outcome.action = deferred.into_inner();
                outcome
            })
            .inner;

        // Apply what happened, now that nothing borrows the tree.
        self.hovered = outcome.hovered;
        if rescan || outcome.rescan {
            self.scan_started = Instant::now();
            self.hovered = None;
            self.trigger_rescan(ctx);
            return;
        }
        if let Some(depth) = crumb_click {
            self.nav_stack.truncate(depth);
            self.hovered = None;
        } else if go_up {
            if self.nav_stack.pop().is_some() {
                self.hovered = None;
            }
        } else if let Some(idx) = outcome.clicked_dir {
            self.nav_stack.push(idx);
            self.hovered = None;
        }

        if let Some(action) = outcome.action.take() {
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
            }
        }
    }
}
