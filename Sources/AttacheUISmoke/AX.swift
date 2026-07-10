import AppKit
import ApplicationServices

/// Thin wrapper over the AXUIElement C API. The harness drives controls through
/// accessibility actions (AXPress, value setting) rather than synthetic pointer
/// events, so it does not depend on window key status or hit-testing.
struct AXElement {
    let raw: AXUIElement

    init(_ raw: AXUIElement) { self.raw = raw }

    static func application(pid: pid_t) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid))
    }

    static var processIsTrusted: Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Attributes

    private func copyAttribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    func string(_ name: String) -> String {
        copyAttribute(name) as? String ?? ""
    }

    var role: String { string(kAXRoleAttribute) }
    var subrole: String { string(kAXSubroleAttribute) }
    var title: String { string(kAXTitleAttribute) }
    var axDescription: String { string(kAXDescriptionAttribute) }
    var help: String { string(kAXHelpAttribute) }
    var identifier: String { string("AXIdentifier") }
    var placeholder: String { string("AXPlaceholderValue") }

    var stringValue: String {
        guard let value = copyAttribute(kAXValueAttribute) else { return "" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    var doubleValue: Double? {
        (copyAttribute(kAXValueAttribute) as? NSNumber)?.doubleValue
    }

    var isEnabled: Bool {
        (copyAttribute(kAXEnabledAttribute) as? Bool) ?? true
    }

    var children: [AXElement] {
        guard let value = copyAttribute(kAXChildrenAttribute),
              let array = value as? [AXUIElement] else { return [] }
        return array.map(AXElement.init)
    }

    var windows: [AXElement] {
        guard let value = copyAttribute(kAXWindowsAttribute),
              let array = value as? [AXUIElement] else { return [] }
        return array.map(AXElement.init)
    }

    var actionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(raw, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    var frame: CGRect? {
        guard let positionValue = copyAttribute(kAXPositionAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = copyAttribute(kAXSizeAttribute),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Everything a human-readable matcher could go by, joined for matching.
    var matchText: String {
        [title, axDescription, help, placeholder, stringValue, identifier]
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    func matches(_ query: String) -> Bool {
        matchText.localizedCaseInsensitiveContains(query)
    }

    func matchesExactly(_ query: String) -> Bool {
        [title, axDescription, help, placeholder, stringValue, identifier]
            .contains(query)
    }

    /// One-line description used in failure messages and tree dumps.
    var summary: String {
        var parts = [role]
        if !subrole.isEmpty { parts.append("(\(subrole))") }
        if !title.isEmpty { parts.append("title=\"\(title)\"") }
        if !axDescription.isEmpty { parts.append("label=\"\(axDescription)\"") }
        if !help.isEmpty { parts.append("help=\"\(help)\"") }
        if !placeholder.isEmpty { parts.append("placeholder=\"\(placeholder)\"") }
        let value = stringValue
        if !value.isEmpty { parts.append("value=\"\(value.prefix(60))\"") }
        if let frame { parts.append("frame=\(NSStringFromRect(frame))") }
        return parts.joined(separator: " ")
    }

    // MARK: Actions

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(raw, action as CFString) == .success
    }

    func press() -> Bool { perform(kAXPressAction) }

    func setValue(_ text: String) -> Bool {
        AXUIElementSetAttributeValue(raw, kAXValueAttribute as CFString, text as CFTypeRef) == .success
    }

    func setValue(_ number: Double) -> Bool {
        AXUIElementSetAttributeValue(raw, kAXValueAttribute as CFString, NSNumber(value: number)) == .success
    }

    func setSelected(_ selected: Bool) -> Bool {
        AXUIElementSetAttributeValue(raw, kAXSelectedAttribute as CFString, selected as CFTypeRef) == .success
    }

    func setFocused() -> Bool {
        AXUIElementSetAttributeValue(raw, kAXFocusedAttribute as CFString, true as CFTypeRef) == .success
    }

    func setSize(_ requestedSize: CGSize) -> Bool {
        var size = requestedSize
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(raw, kAXSizeAttribute as CFString, value) == .success
    }

    func raiseWindow() {
        perform("AXRaise")
    }

    // MARK: Tree walking

    /// Breadth-first search over the subtree, capped so a runaway tree cannot
    /// hang the harness. Returns elements in discovery order.
    func descendants(where predicate: (AXElement) -> Bool,
                     nodeBudget: Int = 8000,
                     collectLimit: Int = 64) -> [AXElement] {
        var found: [AXElement] = []
        var queue: [AXElement] = [self]
        var visited = 0
        while !queue.isEmpty, visited < nodeBudget, found.count < collectLimit {
            let element = queue.removeFirst()
            visited += 1
            if predicate(element) { found.append(element) }
            queue.append(contentsOf: element.children)
        }
        return found
    }

    func firstDescendant(role: String? = nil, containing query: String) -> AXElement? {
        descendants(where: { element in
            if let role, element.role != role { return false }
            return element.matches(query)
        }, collectLimit: 1).first
    }

    func firstDescendant(role: String? = nil, exactly query: String) -> AXElement? {
        descendants(where: { element in
            if let role, element.role != role { return false }
            return element.matchesExactly(query)
        }, collectLimit: 1).first
    }

    /// Indented dump of the subtree for failure diagnostics. Depth-limited so a
    /// failure message stays readable.
    func treeDump(maxDepth: Int = 9, maxLines: Int = 160) -> String {
        var lines: [String] = []
        func walk(_ element: AXElement, depth: Int) {
            guard lines.count < maxLines, depth <= maxDepth else { return }
            let indent = String(repeating: "  ", count: depth)
            lines.append(indent + element.summary)
            for child in element.children {
                walk(child, depth: depth + 1)
            }
        }
        walk(self, depth: 0)
        if lines.count >= maxLines { lines.append("… (truncated)") }
        return lines.joined(separator: "\n")
    }
}
