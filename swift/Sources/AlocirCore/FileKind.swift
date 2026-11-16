/// The category a file is coloured by. Computed once by the scanner from the
/// name's extension and stored in the node, so painting never touches strings.
public enum FileKind: UInt8, Sendable, CaseIterable {
    case directory
    case other
    case image
    case video
    case audio
    case document
    case archive
    case code
    case application
    case system
}
