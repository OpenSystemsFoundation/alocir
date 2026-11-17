import AlocirCore
import SwiftUI

/// The right-click menu for a tile. Every item also has a menu-bar command.
struct FileMenuItems: View {
    let session: Session
    let node: FileNode

    var body: some View {
        if node.isDirectory, node !== session.tree?.focus {
            Button("Zoom In", systemImage: "arrow.down.right.and.arrow.up.left") {
                session.zoom(into: node, fromRect: nil)
            }
            Divider()
        }
        Button("Open", systemImage: "arrow.up.forward.app") { session.openItem(node) }
        Button("Show in Finder", systemImage: "folder") { session.revealInFinder(node) }
        Button("Quick Look", systemImage: "eye") { session.quickLook(node) }
        Divider()
        Button("Copy Path", systemImage: "doc.on.doc") { session.copyPath(node) }
        Button("Rename…", systemImage: "pencil") { session.renaming = node }
            .disabled(node === session.tree?.root)
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) { session.moveToTrash(node) }
            .disabled(node === session.tree?.root)
    }
}

/// Rename sheet: the name is selected without its extension; a name that
/// exists is refused unless only the case differs.
struct RenameSheet: View {
    let session: Session
    let node: FileNode
    @State private var name = ""
    @State private var selection: TextSelection?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename “\(node.name)”")
                .font(.headline)
            TextField("Name", text: $name, selection: $selection)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
                .onSubmit(commit)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .onAppear {
            name = node.name
            // Select the name without its extension, as Finder does.
            if !node.isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex {
                selection = TextSelection(range: name.startIndex..<dot)
            } else {
                selection = TextSelection(range: name.startIndex..<name.endIndex)
            }
        }
    }

    private func commit() {
        do {
            try session.rename(node, to: name)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
