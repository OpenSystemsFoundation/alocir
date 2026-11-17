import Darwin
import Synchronization

/// `(device, inode)`: identifies a file or directory across paths.
struct FileID: Hashable, Sendable {
    var device: UInt64
    var inode: UInt64
}

/// One entry of a directory listing, as the scanner needs it.
struct DirectoryEntry {
    enum EntryType {
        case regular
        case directory
        case symlink
        /// Sockets, FIFOs, devices.
        case special
        /// Listed, but its attributes could not be read.
        case unreadable
    }

    var name: String
    var type: EntryType
    /// Allocated bytes. Only meaningful for `.regular`.
    var allocatedSize: UInt64
    var linkCount: UInt32
    var id: FileID
}

/// Reads a directory's entries with `getattrlistbulk`, which returns name,
/// type, link count, file id and allocated size for hundreds of entries per
/// system call, falling back to `readdir` + `fstatat` where the file system
/// does not support it.
///
/// The directory is opened by its full path and closed before this returns,
/// so no descriptor stays open while subdirectories are scanned.
struct DirectoryReader: ~Copyable {
    /// The directory's own `(device, inode)`, from `fstat` on the open
    /// descriptor (not from the parent's listing, which is wrong at mount
    /// points).
    let id: FileID
    private var fd: Int32

    /// Opens `path` as a directory without following a symlink. `nil` (with
    /// `errno` set) if it cannot be opened.
    init?(path: String) {
        self.init(opened: Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
    }

    /// Opens `name` inside the open directory `parent`, which skips looking
    /// up every component of the full path again. Same rules as `init(path:)`.
    init?(in parent: DirectoryHandle, name: String) {
        self.init(opened: openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
    }

    private init?(opened fd: Int32) {
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let saved = errno
            Darwin.close(fd)
            errno = saved
            return nil
        }
        self.fd = fd
        self.id = FileID(device: UInt64(UInt32(bitPattern: st.st_dev)), inode: st.st_ino)
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    /// A second descriptor for this directory, kept open so its
    /// subdirectories can be opened relative to it. `nil` if it can't be had.
    func handle(for scan: ScanState) -> DirectoryHandle? {
        DirectoryHandle(duplicating: fd, for: scan)
    }

    /// Calls `body` for every entry except `.` and `..`, then closes the
    /// directory. `forceFallback` skips `getattrlistbulk` (for tests).
    consuming func forEachEntry(forceFallback: Bool = false, _ body: (DirectoryEntry) -> Void) {
        if !forceFallback, readBulk(body) {
            return
        }
        readFallback(body)
    }

    // MARK: getattrlistbulk

    private static let bufferSize = 64 * 1024

    private static func bits<T: BinaryInteger>(_ value: T) -> attrgroup_t {
        attrgroup_t(truncatingIfNeeded: value)
    }

    /// Returns false if `getattrlistbulk` is unsupported here and nothing was
    /// read, so the caller should fall back.
    private func readBulk(_ body: (DirectoryEntry) -> Void) -> Bool {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Self.bits(ATTR_CMN_RETURNED_ATTRS) | Self.bits(ATTR_CMN_ERROR)
            | Self.bits(ATTR_CMN_NAME) | Self.bits(ATTR_CMN_DEVID)
            | Self.bits(ATTR_CMN_OBJTYPE) | Self.bits(ATTR_CMN_FILEID)
        request.fileattr = Self.bits(ATTR_FILE_LINKCOUNT) | Self.bits(ATTR_FILE_ALLOCSIZE)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var readAny = false
        while true {
            let count = getattrlistbulk(fd, &request, buffer, Self.bufferSize, 0)
            if count < 0 {
                let error = errno
                if !readAny && (error == ENOTSUP || error == EINVAL) {
                    return false
                }
                // Another error part-way through: keep what was read.
                return true
            }
            if count == 0 {
                return true
            }
            readAny = true
            var entry = buffer
            for _ in 0..<count {
                let length = entry.loadUnaligned(as: UInt32.self)
                Self.parse(entry, body)
                entry += Int(length)
            }
        }
    }

    /// Parses one packed `getattrlistbulk` record. Fields appear in a fixed
    /// order, only when their bit is set in the returned-attributes bitmap,
    /// each 4-byte aligned (so 8-byte fields need unaligned loads).
    private static func parse(_ record: UnsafeMutableRawPointer, _ body: (DirectoryEntry) -> Void) {
        var cursor = UnsafeRawPointer(record) + MemoryLayout<UInt32>.size
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr
        let file = returned.fileattr

        // ATTR_CMN_ERROR comes straight after the returned attributes.
        var error: UInt32 = 0
        if common & bits(ATTR_CMN_ERROR) != 0 {
            error = cursor.loadUnaligned(as: UInt32.self)
            cursor += MemoryLayout<UInt32>.size
        }
        var name = ""
        if common & bits(ATTR_CMN_NAME) != 0 {
            let offset = cursor.loadUnaligned(as: Int32.self)
            let length = cursor.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            let start = (cursor + Int(offset)).assumingMemoryBound(to: UInt8.self)
            // `length` includes the terminating NUL.
            let bytes = UnsafeBufferPointer(start: start, count: max(Int(length) - 1, 0))
            name = String(decoding: bytes, as: UTF8.self)
            cursor += MemoryLayout<attrreference_t>.size
        }
        guard !name.isEmpty else { return }
        var device: UInt64 = 0
        if common & bits(ATTR_CMN_DEVID) != 0 {
            device = UInt64(UInt32(bitPattern: cursor.loadUnaligned(as: Int32.self)))
            cursor += MemoryLayout<dev_t>.size
        }
        var objectType: UInt32?
        if common & bits(ATTR_CMN_OBJTYPE) != 0 {
            objectType = cursor.loadUnaligned(as: UInt32.self)
            cursor += MemoryLayout<fsobj_type_t>.size
        }
        var inode: UInt64 = 0
        if common & bits(ATTR_CMN_FILEID) != 0 {
            inode = cursor.loadUnaligned(as: UInt64.self)
            cursor += MemoryLayout<UInt64>.size
        }
        var linkCount: UInt32 = 1
        if file & bits(ATTR_FILE_LINKCOUNT) != 0 {
            linkCount = cursor.loadUnaligned(as: UInt32.self)
            cursor += MemoryLayout<UInt32>.size
        }
        var allocated: UInt64 = 0
        if file & bits(ATTR_FILE_ALLOCSIZE) != 0 {
            allocated = UInt64(clamping: cursor.loadUnaligned(as: Int64.self))
            cursor += MemoryLayout<off_t>.size
        }

        let type: DirectoryEntry.EntryType
        switch objectType {
        case UInt32(VDIR.rawValue): type = .directory
        case UInt32(VLNK.rawValue): type = .symlink
        case UInt32(VREG.rawValue): type = error == 0 ? .regular : .unreadable
        case nil: type = .unreadable
        default: type = error == 0 ? .special : .unreadable
        }
        body(DirectoryEntry(
            name: name, type: type, allocatedSize: allocated, linkCount: linkCount,
            id: FileID(device: device, inode: inode)))
    }

    // MARK: readdir fallback

    private consuming func readFallback(_ body: (DirectoryEntry) -> Void) {
        // fdopendir takes over the descriptor; closedir closes it.
        let fd = self.fd
        self.fd = -1
        guard let dir = fdopendir(fd) else {
            Darwin.close(fd)
            return
        }
        defer { closedir(dir) }
        rewinddir(dir)
        let dfd = dirfd(dir)
        while let item = readdir(dir) {
            let (name, nameIsEmpty) = withUnsafeBytes(of: &item.pointee.d_name) { raw -> (String, Bool) in
                let length = Int(item.pointee.d_namlen)
                let bytes = UnsafeBufferPointer(
                    start: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: length)
                return (String(decoding: bytes, as: UTF8.self), length == 0)
            }
            if nameIsEmpty || name == "." || name == ".." { continue }
            let dtype = item.pointee.d_type
            if dtype == UInt8(DT_LNK) { body(DirectoryEntry(name: name, type: .symlink, allocatedSize: 0, linkCount: 1, id: FileID(device: 0, inode: 0))); continue }
            var st = stat()
            guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                let type: DirectoryEntry.EntryType = dtype == UInt8(DT_DIR) ? .directory : .unreadable
                body(DirectoryEntry(name: name, type: type, allocatedSize: 0, linkCount: 1, id: FileID(device: 0, inode: 0)))
                continue
            }
            let id = FileID(device: UInt64(UInt32(bitPattern: st.st_dev)), inode: st.st_ino)
            let type: DirectoryEntry.EntryType
            switch st.st_mode & S_IFMT {
            case S_IFDIR: type = .directory
            case S_IFLNK: type = .symlink
            case S_IFREG: type = .regular
            default: type = .special
            }
            body(DirectoryEntry(
                name: name, type: type,
                allocatedSize: UInt64(clamping: st.st_blocks) &* 512,
                linkCount: UInt32(st.st_nlink), id: id))
        }
    }
}

/// An open directory that subdirectory jobs open themselves relative to.
/// Closed when the last job holding it lets go.
///
/// The number open at once is capped (`limit`): apps start with a soft limit
/// of 256 descriptors, and the rest of the app needs some. Past the cap,
/// subdirectories are opened by full path, which is slower but needs none.
final class DirectoryHandle: Sendable {
    let fd: Int32
    /// The scan this handle belongs to, which counts its open handles.
    private let scan: ScanState

    /// Handles open across every scan in the process.
    private static let open = Atomic<Int>(0)
    static let limit = 128

    init?(duplicating source: Int32, for scan: ScanState) {
        guard Self.open.wrappingAdd(1, ordering: .relaxed).newValue <= Self.limit else {
            Self.open.wrappingSubtract(1, ordering: .relaxed)
            return nil
        }
        let fd = fcntl(source, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else {
            Self.open.wrappingSubtract(1, ordering: .relaxed)
            return nil
        }
        self.fd = fd
        self.scan = scan
        scan.openHandles.wrappingAdd(1, ordering: .relaxed)
    }

    deinit {
        Darwin.close(fd)
        scan.openHandles.wrappingSubtract(1, ordering: .relaxed)
        Self.open.wrappingSubtract(1, ordering: .relaxed)
    }
}

/// `lstat` a path. `nil` if it cannot be read.
func lstatInfo(_ path: String) -> stat? {
    var st = stat()
    return lstat(path, &st) == 0 ? st : nil
}

/// Disk usage of a file per `lstat`: allocated blocks, as `du` counts them.
func diskUsage(_ st: stat) -> UInt64 {
    UInt64(clamping: st.st_blocks) &* 512
}

func fileID(_ st: stat) -> FileID {
    FileID(device: UInt64(UInt32(bitPattern: st.st_dev)), inode: st.st_ino)
}
