import AppKit

/// Clicking a checkbox glyph ticks it; every other click is an ordinary click. Also owns block
/// mode: Esc steps out of the text and selects the block the caret was in, ↑/↓ walk between
/// blocks, Enter drops back into one. A text view has no idea what a block is, so the selection
/// is drawn here rather than being a text selection.
final class MarkdownTextView: NSTextView {
    var onPress: (() -> Void)?

    /// The selected block's paragraph range, or nil while editing. Nil is the normal state.
    private var selectedBlock: NSRange?

    /// A press on a list marker that may become a reorder drag: which item, and where the press
    /// landed. A tap (no movement) keeps the old behaviour — tick a todo, drop a caret after a
    /// bullet; moving past the threshold moves the whole line instead.
    private struct Grab {
        var line: NSRange
        var index: Int
        var glyph: ListGlyph
        var start: NSPoint
    }

    /// Where a dragged item would land: the list line under the cursor, and which edge of it.
    private struct Drop {
        var line: NSRange
        var before: Bool
    }

    private var grab: Grab?
    private var drop: Drop?
    private var dragging = false

    private static let blockHighlight = NSColor.black.withAlphaComponent(0.07)  // a light grey wash
    private static let dropIndicator = NSColor.controlAccentColor

    // MARK: - Block mode

    /// Esc from editing selects the caret's block; Esc again, a click or typing leaves the mode.
    /// `doCommand(by:)` rather than the delegate hook, so block mode sees keys before the
    /// markdown rules do — in this mode ↑/↓ and Enter mean something else entirely.
    override func doCommand(by selector: Selector) {
        guard !handleBlockCommand(selector) else { return }
        super.doCommand(by: selector)
    }

    private func handleBlockCommand(_ selector: Selector) -> Bool {
        let ns = string as NSString
        guard let block = selectedBlock else {
            guard selector == #selector(cancelOperation(_:)) else { return false }
            selectBlock(Blocks.range(in: ns, at: selectedRange().location))
            return true
        }
        switch selector {
        case #selector(moveUp(_:)), #selector(moveDown(_:)):
            let delta = selector == #selector(moveUp(_:)) ? -1 : 1
            if let next = Blocks.step(from: block, by: delta, in: ns) { selectBlock(next) }
        case #selector(insertNewline(_:)):
            editBlock(at: Blocks.contentEnd(block, in: ns))
        case #selector(deleteBackward(_:)), #selector(deleteForward(_:)):
            deleteBlock(block)
        case #selector(cancelOperation(_:)):
            editBlock(at: selectedRange().location)
        default: break  // every other key is inert while a block is selected
        }
        return true
    }

    /// Canc removes the selected block and stays in block mode, selecting the one above — or
    /// whatever slides up into its place, when it was the first. Deleting is a block gesture, so
    /// it shouldn't drop you back into the text. Through shouldChangeText, so ⌘Z brings it back.
    private func deleteBlock(_ block: NSRange) {
        guard let ts = textStorage else { return }
        let ns = string as NSString
        // Measured before the text moves: the block above keeps its location whatever happens
        // below it, and when there is no block above, what follows slides up to the start.
        let landing = Blocks.step(from: block, by: -1, in: ns)?.location ?? 0
        var range = block
        // The last block has no newline of its own, so it takes the one that separates it from the
        // block above — otherwise deleting it would leave an empty block behind.
        if range.location + range.length == ns.length, range.location > 0 {
            range = NSRange(location: range.location - 1, length: range.length + 1)
        }
        guard range.length > 0, shouldChangeText(in: range, replacementString: "") else { return }
        ts.deleteCharacters(in: range)
        didChangeText()
        selectBlock(Blocks.range(in: string as NSString, at: landing))
    }

    private func selectBlock(_ range: NSRange) {
        selectedBlock = range
        scrollRangeToVisible(range)
        insertionPointColor = .clear  // the block is the selection now; a caret would be a second one
        needsDisplay = true
    }

    /// Back to editing, caret at `location`. Safe to call when no block is selected.
    func editBlock(at location: Int) {
        selectedBlock = nil
        insertionPointColor = MarkdownStyle.textColor
        setSelectedRange(NSRange(location: min(location, (string as NSString).length), length: 0))
        needsDisplay = true
    }

    /// Typing with a block selected drops into it and appends, rather than doing nothing.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let block = selectedBlock {
            editBlock(at: Blocks.contentEnd(block, in: self.string as NSString))
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let rect = selectedBlock.flatMap(blockRect) {
            Self.blockHighlight.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        // The item being dragged wears the same wash; a line marks where it will land.
        if dragging, let grab, let rect = blockRect(grab.line) {
            Self.blockHighlight.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        if dragging, let drop, let rect = blockRect(drop.line) {
            Self.dropIndicator.setFill()
            let y = drop.before ? rect.minY : rect.maxY - 2
            NSBezierPath(rect: NSRect(x: 4, y: y, width: bounds.width - 8, height: 2)).fill()
        }
        super.draw(dirtyRect)
    }

    /// The selected block's wash: as tall as its lines (paragraph spacing excluded, so the gap
    /// between blocks stays a gap) and as wide as the note.
    private func blockRect(_ block: NSRange) -> NSRect? {
        guard let lm = layoutManager else { return nil }
        let ns = string as NSString
        let safe = NSIntersectionRange(block, NSRange(location: 0, length: ns.length))
        var box = NSRect.zero
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(forCharacterRange: safe, actualCharacterRange: nil)) {
            _, used, _, _, _ in
            box = box.isEmpty ? used : box.union(used)
        }
        if box.isEmpty { box = lm.extraLineFragmentUsedRect }  // the document's final empty block
        guard box.height > 0 else { return nil }
        let origin = textContainerOrigin
        return NSRect(x: 2, y: box.minY + origin.y - 2, width: bounds.width - 4, height: box.height + 4)
    }

    // MARK: - Checkboxes and reordering

    override func mouseDown(with event: NSEvent) {
        onPress?()
        editBlock(at: selectedRange().location)  // a click is always editing
        let point = convert(event.locationInWindow, from: nil)
        let i = characterIndexForInsertion(at: point)
        guard let ts = textStorage else { return }
        // A press on a list marker may become a reorder drag, so it owns the whole gesture: we
        // don't hand it to NSTextView, which would start a text selection under it. A tap is
        // resolved in mouseUp. Only list items are grabbable — reordering is their gesture alone.
        if let (index, glyph) = glyphHit(near: i, in: ts) {
            grab = Grab(line: Blocks.range(in: ts.string as NSString, at: index), index: index,
                glyph: glyph, start: point)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab else { super.mouseDragged(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        if !dragging {
            let dx = point.x - grab.start.x
            let dy = point.y - grab.start.y
            guard dx * dx + dy * dy >= 16 else { return }  // ~4pt: below this it's still a tap
            dragging = true
        }
        // Hovering the item itself is not a destination: no line, and a drop here is a no-op.
        let slot = dropSlot(at: point)
        drop = slot?.line.location == grab.line.location ? nil : slot
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            grab = nil
            drop = nil
            dragging = false
            needsDisplay = true
        }
        guard let grab else { return }
        guard dragging, let drop else {
            // A tap, not a drag: tick the todo, or just drop the caret after a bullet.
            if grab.glyph == .bullet {
                editBlock(at: grab.index + ListGlyph.width)
            } else {
                toggleCheckbox(at: grab.index, glyph: grab.glyph)
            }
            return
        }
        moveBlock(from: grab.line, to: drop)
    }

    /// Drop any in-flight reorder drag — the view is being reused for another note under it.
    func cancelReorder() {
        grab = nil
        drop = nil
        dragging = false
        needsDisplay = true
    }

    // The marker attachment can resolve to either side of the insertion point.
    private func glyphHit(near i: Int, in ts: NSTextStorage) -> (Int, ListGlyph)? {
        for cand in [i, i - 1] where cand >= 0 && cand < ts.length {
            if let glyph = ListGlyph.at(ts, cand) { return (cand, glyph) }
        }
        return nil
    }

    /// Where a dragged item would land: the list line under `point`, and the nearer edge. nil
    /// when the cursor is not over a list item, so a note can't drop one into a paragraph.
    private func dropSlot(at point: NSPoint) -> Drop? {
        guard let ts = textStorage else { return nil }
        let ns = ts.string as NSString
        guard ns.length > 0 else { return nil }
        let i = min(max(0, characterIndexForInsertion(at: point)), ns.length)
        let line = Blocks.range(in: ns, at: i)
        guard ListGlyph.at(ts, line.location) != nil else { return nil }
        let rect = blockRect(line) ?? .zero
        return Drop(line: line, before: point.y < rect.midY)
    }

    /// Move a whole line to a new slot. Rebuilds the buffer from reordered blocks in one
    /// replacement, so the change is a single undo and the save fires once.
    private func moveBlock(from source: NSRange, to drop: Drop) {
        guard let ts = textStorage else { return }
        let ranges = lineRanges(in: ts.string as NSString)
        guard
            let from = ranges.firstIndex(where: { $0.location == source.location }),
            let to = ranges.firstIndex(where: { $0.location == drop.line.location }),
            let order = Blocks.reorder(count: ranges.count, from: from, to: to, before: drop.before)
        else { return }

        let lines = MarkdownDocument.lines(ts)
        let rebuilt = MarkdownDocument.join(
            lines, order: order, trailingNewline: (ts.string as NSString).hasSuffix("\n"))
        let full = NSRange(location: 0, length: ts.length)
        guard shouldChangeText(in: full, replacementString: rebuilt.string) else { return }
        ts.replaceCharacters(in: full, with: rebuilt)
        didChangeText()
        let caret = order.prefix(while: { $0 != from }).reduce(0) { $0 + lines[$1].length + 1 }
        setSelectedRange(NSRange(location: min(caret, (string as NSString).length), length: 0))
    }

    private func lineRanges(in ns: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var loc = 0
        while loc < ns.length {
            let r = ns.lineRange(for: NSRange(location: loc, length: 0))
            out.append(r)
            loc = r.location + r.length
        }
        return out.isEmpty ? [NSRange(location: 0, length: 0)] : out
    }

    private func toggleCheckbox(at i: Int, glyph: ListGlyph) {
        guard let ts = textStorage else { return }
        let becomingDone = glyph == .todoOpen
        let replacement = (becomingDone ? ListGlyph.todoDone : .todoOpen)
            .symbol(attributes: MarkdownStyle.base)
        let box = NSRange(location: i, length: 1)
        // shouldChangeText/didChangeText registers the undo *and* posts the change notification.
        guard shouldChangeText(in: box, replacementString: replacement.string) else { return }
        ts.replaceCharacters(in: box, with: replacement)
        didChangeText()

        // Strike / un-strike the item's content to match the new state.
        let ns = ts.string as NSString
        let line = ns.lineRange(for: NSRange(location: i, length: 0))
        let contentLen = line.length - ListGlyph.width - (ns.substring(with: line).hasSuffix("\n") ? 1 : 0)
        guard contentLen > 0 else { return }
        let range = NSRange(location: line.location + ListGlyph.width, length: contentLen)
        if becomingDone {
            MarkdownDocument.strikeThrough(ts, range)
        } else {
            ts.removeAttribute(.strikethroughStyle, range: range)
            ts.addAttribute(.foregroundColor, value: MarkdownStyle.textColor, range: range)
        }
    }

    // ⌘B / ⌘I reach here through the responder chain from the invisible Edit menu (the text view
    // is first responder). Target-nil menu items find these on whatever text view is focused.
    @objc func toggleBold(_ sender: Any?) { MarkdownInput.toggle(.bold, self) }
    @objc func toggleItalic(_ sender: Any?) { MarkdownInput.toggle(.italic, self) }
}
