import Foundation

/// Pure helpers for session topic tagging. Production tagging is local and
/// deterministic so background indexing never sends an unfocused transcript,
/// title, or working directory to a model. The legacy prompt/parser helpers
/// remain for compatibility tests and imported tag workflows.
public enum SessionTagger {
    /// One session handed to the tagger: enough to name a topic, no more.
    public struct Item: Equatable {
        public let id: String
        public let title: String
        public let snippet: String
        public let project: String?
        public init(id: String, title: String, snippet: String, project: String? = nil) {
            self.id = id
            self.title = title
            self.snippet = snippet
            self.project = project
        }
    }

    public static let systemPrompt = """
    You label work sessions with a short topic, like a folder name. For each session you are given an id, a title, sometimes the project it belongs to, and a snippet of the conversation. Reply with ONLY a JSON array, one object per session, in the same order: [{"id": "<the id>", "tag": "<topic>"}]. The tag is 1-2 words, title case, a concrete subject (examples: "Taxes", "Penumbra", "Infra", "Billing", "Website", "Hiring"). The tag must add information the user does not already have: do NOT use the project name as the tag, and do NOT just repeat the title. Pick the specific subject within that project. If nothing more specific than the project or title fits, use "General". No commentary, no code fences, no extra keys.
    """

    /// Build the user message for a batch. Snippets are capped so the prompt stays
    /// small even for a big batch. `knownTags` are topics already in use; passing
    /// them nudges the model to reuse an existing label for similar sessions instead
    /// of inventing a near-duplicate ("Operations" vs "Email Brief").
    public static func userPrompt(for items: [Item], knownTags: [String] = [], snippetCap: Int = 280) -> String {
        var lines: [String] = []
        if !knownTags.isEmpty {
            let vocabulary = knownTags.sorted().prefix(40).joined(separator: ", ")
            lines.append("Existing topics already in use (reuse one when it fits, otherwise make a new one): \(vocabulary)")
            lines.append("")
        }
        lines.append("Sessions to label:")
        for item in items {
            let snippet = item.snippet.count > snippetCap
                ? String(item.snippet.prefix(snippetCap))
                : item.snippet
            lines.append("- id: \(item.id)")
            lines.append("  title: \(sanitizeLine(item.title))")
            if let project = item.project, !project.isEmpty {
                lines.append("  project: \(sanitizeLine(project))")
            }
            if !snippet.isEmpty {
                lines.append("  snippet: \(sanitizeLine(snippet))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Parse the model's reply into id → tag. Tolerant of code fences and of leading
    /// or trailing prose around the JSON array.
    public static func parse(_ response: String) -> [String: String] {
        guard let data = jsonArrayData(in: response),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }
        var result: [String: String] = [:]
        for object in array {
            guard let id = (object["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty,
                  let rawTag = object["tag"] as? String else {
                continue
            }
            let tag = normalizeTag(rawTag)
            if !tag.isEmpty { result[id.lowercased()] = tag }
        }
        return result
    }

    /// Clean a model tag into a short, title-cased label.
    public static func normalizeTag(_ raw: String, wordLimit: Int = 2, charLimit: Int = 24) -> String {
        let stripped = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"'.,#"))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !stripped.isEmpty else { return "" }
        let words = stripped.split(separator: " ").prefix(wordLimit).map { word -> String in
            // Preserve short all-caps acronyms (HSA, IRA); title-case ordinary words.
            if word.count <= 3, word == word.uppercased() { return String(word) }
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }
        let joined = words.joined(separator: " ")
        return joined.count > charLimit ? String(joined.prefix(charLimit)).trimmingCharacters(in: .whitespaces) : joined
    }

    /// Produce a useful local topic from app-indexed metadata. Existing topic
    /// labels win when their words appear in the title, which avoids creating
    /// near-duplicates. Otherwise the first one or two informative title words
    /// are used, followed by a project-name fallback. Session snippets are not
    /// needed and never leave the indexing process.
    public static func localTag(
        for item: Item,
        knownTags: [String] = []
    ) -> String {
        let titleWords = words(in: item.title)
        let titleSet = Set(titleWords)
        let matchingKnown = knownTags.compactMap { raw -> (tag: String, score: Int)? in
            let tag = normalizeTag(raw)
            let tagWords = words(in: tag)
            guard !tag.isEmpty, !tagWords.isEmpty else { return nil }
            let score = Set(tagWords).intersection(titleSet).count
            return score > 0 ? (tag, score) : nil
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.tag.count != $1.tag.count { return $0.tag.count < $1.tag.count }
            return $0.tag < $1.tag
        }
        if let known = matchingKnown.first?.tag { return known }

        let informative = titleWords.filter { !localTagStopWords.contains($0) }
        let titleTag = normalizeTag(informative.prefix(2).joined(separator: " "))
        if !titleTag.isEmpty { return titleTag }

        if let project = item.project {
            let projectTag = normalizeTag(
                words(in: project)
                    .filter { !localTagStopWords.contains($0) }
                    .prefix(2)
                    .joined(separator: " ")
            )
            if !projectTag.isEmpty { return projectTag }
        }
        return "General"
    }

    // MARK: - Helpers

    private static func sanitizeLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let localTagStopWords: Set<String> = [
        "a", "an", "and", "the", "to", "for", "of", "on", "in", "with",
        "add", "build", "check", "create", "fix", "help", "implement",
        "investigate", "make", "new", "redo", "remove", "review", "update",
        "audit", "chat", "conversation", "session", "task", "work", "working"
    ]

    private static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Extract the first top-level JSON array substring from a noisy response.
    private static func jsonArrayData(in response: String) -> Data? {
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]"),
              start < end else {
            return nil
        }
        return String(response[start...end]).data(using: .utf8)
    }
}
