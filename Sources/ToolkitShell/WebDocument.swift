#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// One document, one window. The page in the window holds the live model and
/// posts its JSON after every edit, so the document always has the bytes to
/// write without asking the page and waiting.
///
/// Subclass to add imports the page cannot read itself (override `read`,
/// then call `deliver(text:name:imported:)`) or to refine `isImport`.
open class WebDocument: NSDocument {
    public static let jsonType = UTType.json.identifier

    /// Text read from disk that the page has not been given yet.
    public private(set) var pendingText: String?
    public private(set) var pendingName: String?
    /// The model as the page last reported it.
    private var latestJSON: String?
    /// An import (XMI, Project XML, CSV…) comes in as a new document: it is never written back over.
    private var cameFromImport = false
    private var modelName: String = ShellConfig.current.untitledName

    open override class var autosavesInPlace: Bool { false }
    open override class var readableTypes: [String] { [jsonType] + ShellConfig.current.importedTypes }
    open override class var writableTypes: [String] { [jsonType] }
    open override class func isNativeType(_ type: String) -> Bool { type == jsonType }

    public var editor: EditorWindowController? { windowControllers.first as? EditorWindowController }

    open override func makeWindowControllers() {
        addWindowController(EditorWindowController())
    }

    // MARK: Reading

    open override func read(from data: Data, ofType typeName: String) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let name = fileURL?.lastPathComponent
        deliver(text: text, name: name, imported: isImport(text: text, name: name))
    }

    /// Hand text to the page (now, or as soon as the page is up). `imported`
    /// marks a file in a foreign format: the page converts it, and the result
    /// becomes an untitled, unsaved document rather than that file.
    public func deliver(text: String, name: String?, imported: Bool) {
        pendingText = text
        pendingName = name
        cameFromImport = imported
        // Revert: the window already exists, so hand the text over now.
        editor?.deliverPendingText()
    }

    /// Whether a file is something other than the app's own JSON. Default: it looks like XML.
    open func isImport(text: String, name: String?) -> Bool { Self.looksLikeXML(text) }

    public static func looksLikeXML(_ text: String) -> Bool {
        text.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" }).hasPrefix("<")
    }

    /// The page took the text. An imported model becomes an unsaved, untitled document.
    public func didDeliverPendingText() {
        pendingText = nil
        pendingName = nil
        guard cameFromImport else { return }
        cameFromImport = false
        fileURL = nil
        fileType = Self.jsonType
        updateChangeCount(.changeDone)
    }

    // MARK: Changes from the page

    public func pageDidChange(json: String, dirty: Bool, name: String) {
        latestJSON = json
        modelName = name
        if dirty { updateChangeCount(.changeDone) }
    }

    // MARK: Writing

    open override func data(ofType typeName: String) throws -> Data {
        guard let json = latestJSON else {
            let noun = ShellConfig.current.documentNoun
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The \(noun) has not finished loading yet. Try again in a moment."])
        }
        return Data(json.utf8)
    }

    open override func prepareSavePanel(_ panel: NSSavePanel) -> Bool {
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Self.fileName(forModelNamed: modelName)
        return true
    }

    /// "Vehicle model" → "vehicle-model.sysml.json", the name the web app gives its downloads.
    public static func fileName(forModelNamed name: String, suffix: String = ShellConfig.current.fileSuffix) -> String {
        let slug = name.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return (slug.isEmpty ? "untitled" : slug) + suffix
    }

    open override func save(to url: URL, ofType typeName: String, for operation: NSDocument.SaveOperationType,
                            completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: operation) { [weak self] error in
            if error == nil, operation != .autosaveElsewhereOperation {
                self?.editor?.documentWasSaved(as: url.lastPathComponent)
            }
            completionHandler(error)
        }
    }
}
#endif
