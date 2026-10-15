import AppKit

/// Any app window readable through the Accessibility API. AXDocument names the focused
/// document and follows Preview's active tab; AXTitle is the fuzzy fallback and follows the
/// Settings pane. Non-final: BrowserContainer and TerminalContainer refine the identity.
///
/// Never fails: an app whose AX tree is empty — an Electron window before it has been poked,
/// or one that exposes nothing at all — binds at app level rather than returning nil, so
/// "Add note here" still works and the note is found again if a window identity appears later
/// (a coarser note is always reachable from a finer container through `load`).
class GenericAppContainer: Container {
    let bundleID: String
    let pid: pid_t

    /// The focused window's identity: AXDocument (a stable file path) when the app exposes one,
    /// else its sanitized AXTitle. nil when the AX tree is empty; the note then binds to the app.
    let ident: String?

    /// Pids already asked to build their AX tree. The request is async and idempotent, and a
    /// window that stays empty would otherwise re-poke every 0.4s poll for nothing.
    private static var poked: Set<pid_t> = []

    init(app: NSRunningApplication) {
        self.bundleID = app.bundleIdentifier ?? app.localizedName ?? "app"
        self.pid = app.processIdentifier
        if let id = GenericAppContainer.readIdent(pid: pid) {
            self.ident = id
        } else {
            // Electron builds its tree lazily; ask once and let the next poll see it.
            if GenericAppContainer.poked.insert(pid).inserted {
                AXWindows.enableAccessibility(pid: pid)
            }
            self.ident = nil
        }
    }

    /// AXDocument first (stable across close/reopen), then a sanitized title. nil if neither.
    private static func readIdent(pid: pid_t) -> String? {
        guard let win = AXWindows.focusedWindow(pid: pid) else { return nil }
        if let doc = AXWindows.string(win, kAXDocumentAttribute), !doc.isEmpty { return doc }
        guard let title = AXWindows.string(win, kAXTitleAttribute), !title.isEmpty else {
            return nil
        }
        let clean = Container.sanitizeTitle(title)
        return clean.isEmpty ? nil : clean
    }

    override var path: [String] { ident.map { [bundleID, $0] } ?? [bundleID] }

    override func note(at level: Int) throws -> Note? {
        let currentKey = key(at: level)
        // Before stable tab keys, the mutable title was part of the key. Migrate on first read;
        // writing the new key before deleting the old one makes an interrupted migration harmless.
        let legacyKey = Container.key(path: path, level: level)
        return try AppNotes.load(key: currentKey, migrating: legacyKey)
    }
    override func write(_ note: Note, at level: Int) throws {
        try AppNotes.save(key: key(at: level), note: note)
    }

    /// A focused app window is already on top, so nothing covers the note — `covering` stays
    /// empty and the caller's occlusion test collapses to false on its own.
    ///
    /// Bounds come from the window server, not AX: an AX read is a synchronous round-trip
    /// into the app's main thread, which is busy servicing the event loop during a drag, so
    /// the note trailed and stuttered. CGWindowList is fresh every frame — same source that
    /// keeps Finder tracking smooth. AX stays as the fallback for windows the list can't see.
    override func frame() -> Frame? {
        if let rect = WindowServer.frontWindowBounds(pid: pid) { return Frame(bounds: rect) }
        return AXWindows.focusedBounds(pid: pid).map { Frame(bounds: $0) }
    }
}
