//
//  AgentToolbox.swift
//  MagicPlus
//

import AppKit
import Foundation

/// What the agent is allowed to do, as a closed list of narrow, typed tools.
///
/// Deliberately not a shell. A model handed `run_command` can do anything, which means nobody can
/// say what it can do — and "what can the AI do to my machine" has to be answerable by reading one
/// list. Every tool here is either read-only or reversible; the destructive tier (delete, quit)
/// does not exist yet, and when it does it will confirm in the chat before running.
///
/// Nothing here is new capability. Files come from Spotlight, notes go to the shelf, volume goes
/// through the audio service, windows through the window lister — the agent is a language interface
/// over what the app already does.
@MainActor
final class AgentToolbox {
    private let shelf: ShelfStore
    private let clipboard: ClipboardService

    init(shelf: ShelfStore, clipboard: ClipboardService) {
        self.shelf = shelf
        self.clipboard = clipboard
    }

    // MARK: - The catalogue

    /// A schema helper: an object with these properties, requiring the listed names.
    private nonisolated static func schema(
        _ properties: [String: JSONValue],
        required: [String] = []
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string))
        ])
    }

    private nonisolated static func property(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    nonisolated static let specs: [ToolSpec] = [
        ToolSpec(
            name: "search_files",
            description: "Search the user's files with Spotlight, newest first. Returns names and "
                + "paths. Give a query, a kind, or both — to list every PDF, pass kind alone and "
                + "leave query out. If nothing matches by name, it retries as a content search.",
            parameters: schema([
                "query": property("string", "Part of a file name. Omit to list everything of a kind."),
                "kind": property("string", "pdf, image, audio, video, folder or any."),
                "limit": property("number", "Maximum results, default 10.")
            ])
        ),
        ToolSpec(
            name: "read_file",
            description: "Read what is in a file: text and code directly, PDFs as their text, and "
                + "pictures and screenshots through text recognition. Only inside the user's home "
                + "folder. Use it before answering anything about a file's contents.",
            parameters: schema([
                "path": property("string", "Absolute path, as returned by search_files.")
            ], required: ["path"])
        ),
        ToolSpec(
            name: "open_item",
            description: "Open a file or folder by absolute path, in its default application.",
            parameters: schema([
                "path": property("string", "Absolute path, as returned by search_files.")
            ], required: ["path"])
        ),
        ToolSpec(
            name: "reveal_in_finder",
            description: "Show a file or folder in the Finder, selected.",
            parameters: schema([
                "path": property("string", "Absolute path, as returned by search_files.")
            ], required: ["path"])
        ),
        ToolSpec(
            name: "open_app",
            description: "Launch an installed application by name.",
            parameters: schema([
                "name": property("string", "The application's name, e.g. Safari.")
            ], required: ["name"])
        ),
        ToolSpec(
            name: "write_note",
            description: "Save a text note. It lands on the user's shelf as a .txt file.",
            parameters: schema([
                "text": property("string", "The note's content."),
                "title": property("string", "Optional file name, without extension.")
            ], required: ["text"])
        ),
        ToolSpec(
            name: "set_volume",
            description: "Set the system output volume.",
            parameters: schema([
                "percent": property("number", "0 to 100.")
            ], required: ["percent"])
        ),
        ToolSpec(
            name: "system_status",
            description: "Read the battery level, free disk space and what is currently playing.",
            parameters: schema([:])
        ),
        ToolSpec(
            name: "list_windows",
            description: "List the windows currently open, with their applications and titles.",
            parameters: schema([:])
        ),
        ToolSpec(
            name: "focus_window",
            description: "Bring a window to the front, found by its title or its application's name.",
            parameters: schema([
                "query": property("string", "Part of the window title or application name.")
            ], required: ["query"])
        ),
        ToolSpec(
            name: "search_clipboard",
            description: "Search the user's clipboard history for text entries containing a phrase.",
            parameters: schema([
                "query": property("string", "What to look for."),
                "limit": property("number", "Maximum results, default 5.")
            ], required: ["query"])
        )
    ]

    // MARK: - Running one

    /// Runs a tool and describes the outcome — to the model, so it can carry on, and honestly, so
    /// it cannot claim something happened that did not.
    func run(_ call: ToolCallRequest) async -> String {
        switch call.name {
        case "search_files": await searchFiles(call.arguments)
        case "read_file": await readFile(call.arguments)
        case "open_item": openItem(call.arguments)
        case "reveal_in_finder": revealInFinder(call.arguments)
        case "open_app": openApp(call.arguments)
        case "write_note": writeNote(call.arguments)
        case "set_volume": setVolume(call.arguments)
        case "system_status": systemStatus()
        case "list_windows": listWindows()
        case "focus_window": focusWindow(call.arguments)
        case "search_clipboard": searchClipboard(call.arguments)
        default: "Unknown tool: \(call.name)"
        }
    }

    /// A step line for the chat, in the user's language, present tense — what is being done.
    nonisolated static func stepTitle(for call: ToolCallRequest) -> String {
        switch call.name {
        case "search_files":
            String(localized: "Searching files for “\(call.arguments["query"]?.stringValue ?? "")”",
                   comment: "Agent step")
        case "read_file":
            String(localized: "Reading \(shortName(of: call.arguments["path"]?.stringValue))",
                   comment: "Agent step")
        case "open_item":
            String(localized: "Opening \(shortName(of: call.arguments["path"]?.stringValue))",
                   comment: "Agent step")
        case "reveal_in_finder":
            String(localized: "Showing \(shortName(of: call.arguments["path"]?.stringValue)) in Finder",
                   comment: "Agent step")
        case "open_app":
            String(localized: "Launching \(call.arguments["name"]?.stringValue ?? "")",
                   comment: "Agent step")
        case "write_note":
            String(localized: "Writing a note", comment: "Agent step")
        case "set_volume":
            String(localized: "Setting the volume", comment: "Agent step")
        case "system_status":
            String(localized: "Reading the system status", comment: "Agent step")
        case "list_windows":
            String(localized: "Listing open windows", comment: "Agent step")
        case "focus_window":
            String(localized: "Focusing “\(call.arguments["query"]?.stringValue ?? "")”",
                   comment: "Agent step")
        case "search_clipboard":
            String(localized: "Searching the clipboard history", comment: "Agent step")
        default:
            call.name
        }
    }

    private nonisolated static func shortName(of path: String?) -> String {
        guard let path, !path.isEmpty else { return "…" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Files

    private func searchFiles(_ arguments: JSONValue) async -> String {
        let query = arguments["query"]?.stringValue ?? ""
        let kind = arguments["kind"]?.stringValue ?? "any"
        let limit = Int(arguments["limit"]?.numberValue ?? 10).clamped(1...25)

        // A name *or* a kind is enough. Requiring both is what made "do I have any PDFs?"
        // impossible to ask: there is no name in that question, and a model told to supply one
        // anyway sends an empty string or invents "*.pdf" — measured, on six models out of seven.
        guard !query.isEmpty || kind.lowercased() != "any" else {
            return "search_files needs either a query or a kind."
        }

        var results = await SpotlightSearch.run(
            query.isEmpty ? .everything : .name(query), kind: kind, limit: limit
        )
        // A name miss is usually a phrasing miss; the content index knows what the name does not.
        if results.isEmpty, !query.isEmpty {
            results = await SpotlightSearch.run(.content(query), kind: kind, limit: limit)
        }
        guard !results.isEmpty else {
            return query.isEmpty ? "No \(kind) files found." : "No files match “\(query)”."
        }
        return results
            .map { "\(URL(fileURLWithPath: $0).lastPathComponent) — \($0)" }
            .joined(separator: "\n")
    }

    private func readFile(_ arguments: JSONValue) async -> String {
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
            return "read_file needs a path."
        }
        return await AgentFileReader.read(path: path, home: NSHomeDirectory())
    }

    private func openItem(_ arguments: JSONValue) -> String {
        guard let path = existingPath(in: arguments) else { return "That path does not exist." }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        return "Opened \(path)."
    }

    private func revealInFinder(_ arguments: JSONValue) -> String {
        guard let path = existingPath(in: arguments) else { return "That path does not exist." }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        return "Revealed \(path) in the Finder."
    }

    /// The path argument, only if something is actually there — the model retries a wrong path
    /// better than it explains a silent no-op.
    private func existingPath(in arguments: JSONValue) -> String? {
        guard let path = arguments["path"]?.stringValue,
              FileManager.default.fileExists(atPath: path)
        else { return nil }
        return path
    }

    // MARK: - Applications and windows

    private func openApp(_ arguments: JSONValue) -> String {
        guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
            return "open_app needs a name."
        }
        let apps = AppLauncher.installedApps()
        guard let app = apps.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            ?? apps.first(where: { $0.name.localizedCaseInsensitiveContains(name) })
        else { return "No installed application is called “\(name)”." }
        AppLauncher.launch(app)
        return "Launched \(app.name)."
    }

    private func listWindows() -> String {
        let windows = WindowLister.switchableWindows()
        guard !windows.isEmpty else { return "No windows are open." }
        return windows
            .map { "\($0.applicationName): \($0.title.isEmpty ? "(untitled)" : $0.title)" }
            .joined(separator: "\n")
    }

    private func focusWindow(_ arguments: JSONValue) -> String {
        guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
            return "focus_window needs a query."
        }
        let windows = WindowLister.switchableWindows()
        guard let window = windows.first(where: { $0.title.localizedCaseInsensitiveContains(query) })
            ?? windows.first(where: { $0.applicationName.localizedCaseInsensitiveContains(query) })
        else { return "No open window matches “\(query)”." }
        WindowLister.focus(window)
        return "Focused \(window.applicationName): \(window.title)."
    }

    // MARK: - Notes, volume, status, clipboard

    private func writeNote(_ arguments: JSONValue) -> String {
        guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
            return "write_note needs text."
        }
        let directory = AppSupportDirectory.url().appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let name: String
        if let title = arguments["title"]?.stringValue, !title.isEmpty {
            // A title becomes a file name, so the characters a file name cannot hold go.
            name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            name = "Note \(formatter.string(from: Date()))"
        }
        let url = directory.appendingPathComponent("\(name).txt")

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            shelf.add([url])
            return "Saved the note as “\(name).txt” and put it on the shelf."
        } catch {
            return "Could not save the note: \(error.localizedDescription)"
        }
    }

    private func setVolume(_ arguments: JSONValue) -> String {
        guard let percent = arguments["percent"]?.numberValue else {
            return "set_volume needs a percent."
        }
        let level = (percent / 100).clampedToUnitRange
        SystemAudio.setOutputVolume(level)
        return "Volume set to \(Int(level * 100))%."
    }

    private func systemStatus() -> String {
        var lines: [String] = []

        let battery = SystemStatus.battery()
        if battery.isPresent {
            lines.append("Battery: \(battery.percentage)%\(battery.isCharging ? ", charging" : "")")
        } else {
            lines.append("On mains power, no battery.")
        }

        if let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ]), let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage {
            let formatter = ByteCountFormatter()
            lines.append("Disk: \(formatter.string(fromByteCount: free)) free of \(formatter.string(fromByteCount: Int64(total)))")
        }

        if let playing = MediaController.nowPlaying() {
            lines.append("Playing: \(playing.title)\(playing.artist.isEmpty ? "" : " — \(playing.artist)")")
        }
        return lines.joined(separator: "\n")
    }

    private func searchClipboard(_ arguments: JSONValue) -> String {
        guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
            return "search_clipboard needs a query."
        }
        let limit = Int(arguments["limit"]?.numberValue ?? 5).clamped(1...10)

        let matches = clipboard.items.compactMap { item -> String? in
            guard case .text(let text) = item.content,
                  text.localizedCaseInsensitiveContains(query)
            else { return nil }
            return String(text.prefix(300))
        }
        guard !matches.isEmpty else { return "Nothing in the clipboard history contains “\(query)”." }
        return matches.prefix(limit).joined(separator: "\n---\n")
    }
}

// MARK: - Spotlight

/// One `mdfind` run, off the main thread.
///
/// `mdfind` rather than `NSMetadataQuery` for the same reason the app already prefers small
/// subprocesses: it is one call with one answer, needs no run-loop choreography, and the query
/// language is identical because it is the same index underneath.
nonisolated enum SpotlightSearch {
    enum Mode {
        case name(String)
        case content(String)
        /// Everything of the given kind, which is what "do I have any PDFs?" actually asks.
        case everything
    }

    /// How many paths to consider before sorting. `mdfind` returns them in index order, which is no
    /// order at all to a person; sorting means asking the file system about each one, so the set
    /// that gets sorted is bounded.
    private static let sortingPool = 200

    static func run(_ mode: Mode, kind: String, limit: Int) async -> [String] {
        let query = query(for: mode, kind: kind)
        let lines = await Task.detached(priority: .utility) { () -> [String] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-onlyin", NSHomeDirectory(), query]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let paths = String(data: data, encoding: .utf8)?
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty } ?? []

            // Newest first. "Find my most recent PDF" is the common question, and an index-ordered
            // list answers it wrongly while looking like it answered it.
            return paths
                .prefix(Self.sortingPool)
                .map { path -> (String, Date) in
                    let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate])
                        as? Date
                    return (path, modified ?? .distantPast)
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }.value
        return Array(lines.prefix(limit))
    }

    /// The Spotlight predicate. Internal so the tests can pin it down without an index.
    static func query(for mode: Mode, kind: String) -> String {
        let type = contentType(for: kind)
        let match: String
        switch mode {
        case .name(let text): match = "kMDItemFSName == \"*\(sanitized(text))*\"cd"
        case .content(let text): match = "kMDItemTextContent == \"\(sanitized(text))*\"cd"
        case .everything:
            // A kind on its own is the whole predicate. Without one there is nothing to ask for,
            // and `search_files` refuses before it gets here.
            return type.map { "kMDItemContentTypeTree == \"\($0)\"" } ?? ""
        }
        guard let type else { return match }
        return "\(match) && kMDItemContentTypeTree == \"\(type)\""
    }

    private static func contentType(for kind: String) -> String? {
        switch kind.lowercased() {
        case "pdf": "com.adobe.pdf"
        case "image": "public.image"
        case "audio": "public.audio"
        case "video": "public.movie"
        case "folder": "public.folder"
        default: nil
        }
    }

    /// Quotes and backslashes would end the predicate string early — a model-supplied query is
    /// data, never syntax.
    private static func sanitized(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
    }
}

private extension Int {
    func clamped(_ range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
