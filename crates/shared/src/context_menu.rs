use eframe::egui;
use std::cell::RefCell;
use std::path::{Path, PathBuf};

pub enum DeferredAction {
    OpenFile(PathBuf),
    RevealInFinder(PathBuf),
    CopyPath(String),
    StartRename { path: PathBuf, current_name: String },
    MoveToTrash(PathBuf),
    OpenTerminal(PathBuf),
    QuickLook(PathBuf),
    ZoomIn(PathBuf),
}

pub fn build_context_menu(
    ui: &mut egui::Ui,
    deferred: &RefCell<Option<DeferredAction>>,
    item_path: &Path,
    item_name: &str,
    is_dir: bool,
) {
    ui.set_min_width(190.0);

    // Header: which item this menu is for.
    ui.add_space(2.0);
    ui.horizontal(|ui| {
        ui.add_space(4.0);
        ui.label(
            egui::RichText::new(crate::text::truncate_end(item_name, 32))
                .small()
                .weak(),
        );
    });
    ui.separator();

    if is_dir && ui.button("Zoom In").clicked() {
        *deferred.borrow_mut() = Some(DeferredAction::ZoomIn(item_path.to_path_buf()));
        ui.close_menu();
    }

    if ui.button("Open").clicked() {
        *deferred.borrow_mut() = Some(DeferredAction::OpenFile(item_path.to_path_buf()));
        ui.close_menu();
    }

    if cfg!(target_os = "macos") && ui.button("Quick Look").clicked() {
        *deferred.borrow_mut() = Some(DeferredAction::QuickLook(item_path.to_path_buf()));
        ui.close_menu();
    }

    let reveal_label = if cfg!(target_os = "macos") {
        "Reveal in Finder"
    } else if cfg!(target_os = "windows") {
        "Show in Explorer"
    } else {
        "Show in File Manager"
    };
    if ui.button(reveal_label).clicked() {
        *deferred.borrow_mut() = Some(DeferredAction::RevealInFinder(item_path.to_path_buf()));
        ui.close_menu();
    }

    // Hidden in Mac App Store builds: launching Terminal does not work from the sandbox.
    if !cfg!(feature = "app-store") && is_dir && ui.button("Open Terminal Here").clicked() {
        *deferred.borrow_mut() = Some(DeferredAction::OpenTerminal(item_path.to_path_buf()));
        ui.close_menu();
    }

    ui.separator();

    if ui.button("Copy Path").clicked() {
        *deferred.borrow_mut() = Some(DeferredAction::CopyPath(
            item_path.to_string_lossy().to_string(),
        ));
        ui.close_menu();
    }

    if ui.button("Rename\u{2026}").clicked() {
        *deferred.borrow_mut() = Some(DeferredAction::StartRename {
            path: item_path.to_path_buf(),
            current_name: item_name.to_string(),
        });
        ui.close_menu();
    }

    ui.separator();

    // The theme's error colour is chosen to be readable on its menu background.
    let danger = ui.visuals().error_fg_color;
    if ui
        .button(egui::RichText::new("Move to Trash").color(danger))
        .clicked()
    {
        *deferred.borrow_mut() = Some(DeferredAction::MoveToTrash(item_path.to_path_buf()));
        ui.close_menu();
    }
}
