import SwiftUI
import AppKit
import Foundation
import Darwin
import Combine
import UniformTypeIdentifiers
import PDFKit
import AVFoundation

// MARK: - Config schema (mirrors ~/.mlxlm/config.json)

struct PilotConfig: Codable {
    let version: Int
    let control: ControlConfig
    let server: ServerConfig
    let models: [String: ModelConfig]
    let memory: MemoryConfig?
}

/// Persistent cross-conversation memory. Off if `memory` block is absent.
struct MemoryConfig: Codable {
    let enabled: Bool?
    let auto_extract: Bool?
    let max_tokens_injected: Int?
    let default_retention_days: Int?
    let max_entries: Int?
    let max_entries_per_turn: Int?
    let min_seconds_between_extractions: Double?
}

struct ControlConfig: Codable {
    let models_dir: String
    let default_model: String
    let logs_dir: String
    let venv_python: String
    let auto_start_models: [String]?
    let log_retention_days: Int?
}

struct ServerConfig: Codable {
    let host: String
    let port: Int
}

struct ModelConfig: Codable {
    let engine: String
    let port: Int?
    let max_context_tokens: Int?
    let kv_bits: Int?
    let kv_quant_scheme: String?
    let trust_remote_code: Bool?
    let modalities: [String]?
    let tool_calling: Bool?
    let request_defaults: RequestDefaults?
    let notes: String?
}

struct RequestDefaults: Codable {
    let max_tokens: Int?
    let temperature: Double?
    let top_p: Double?
    let top_k: Int?
    let min_p: Double?
    let repetition_penalty: Double?
    let presence_penalty: Double?
}

// MARK: - Attachment

struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let kind: Kind
    let displayName: String

    enum Kind: Equatable {
        case image(Data)                       // PNG bytes
        case video(Data, mimeType: String)     // raw bytes + mime
        case pdfPages([Data])                  // each page as PNG bytes
        case text(String)                      // plain-text payload (inline into user message)
    }

    var requiresModality: String {
        switch kind {
        case .image:    return "image"
        case .video:    return "video"
        case .pdfPages: return "image"   // PDF is rendered to images
        case .text:     return "text"    // every model declares "text"
        }
    }

    var summary: String {
        switch kind {
        case .image(let d):
            return "image · \(byteString(d.count))"
        case .video(let d, _):
            return "video · \(byteString(d.count))"
        case .pdfPages(let pages):
            let total = pages.reduce(0) { $0 + $1.count }
            return "pdf · \(pages.count) page\(pages.count == 1 ? "" : "s") · \(byteString(total))"
        case .text(let s):
            return "text · \(s.count) chars"
        }
    }

    private func byteString(_ n: Int) -> String {
        if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
        if n >= 1024      { return "\(n / 1024) KB" }
        return "\(n) B"
    }
}

// MARK: - Chat message

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let role: String       // "user" | "assistant" | "system"
    let content: String
    // Attachments are send-time only — raw bytes are never persisted to the
    // conversation store. On reload, attachmentSummaries gives us a breadcrumb
    // like "image · 240 KB" to show in place of the missing binary.
    let attachmentSummaries: [String]
    let model: String?
    let timestamp: Date

    // Transient — not persisted. Populated when a user attaches something in
    // the current session; reloading from disk leaves this empty.
    var attachments: [Attachment] = []

    init(role: String, content: String, attachments: [Attachment] = [], model: String?, timestamp: Date) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.attachments = attachments
        self.attachmentSummaries = attachments.map { $0.summary }
        self.model = model
        self.timestamp = timestamp
    }

    // Codable: skip the live `attachments` field, persist only summaries.
    private enum CodingKeys: String, CodingKey {
        case id, role, content, attachmentSummaries, model, timestamp
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.role == rhs.role && lhs.content == rhs.content &&
        lhs.model == rhs.model && lhs.timestamp == rhs.timestamp
    }
}

// MARK: - Conversation (persisted)

struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
    var archived: Bool
    /// Per-conversation system prompt. Persisted alongside the messages
    /// so it survives reload and switching between threads.
    var systemPrompt: String = ""
    /// Pinned conversations sort to the top of the sidebar regardless
    /// of updatedAt. Toggled via the row context menu.
    var pinned: Bool = false

    init(id: UUID = UUID(), title: String = "New Chat",
         createdAt: Date = Date(), updatedAt: Date = Date(),
         messages: [ChatMessage] = [], archived: Bool = false,
         systemPrompt: String = "", pinned: Bool = false) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.archived = archived
        self.systemPrompt = systemPrompt
        self.pinned = pinned
    }

    // Custom Codable to keep backward compat with old files that don't
    // have systemPrompt / pinned.
    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, messages, archived, systemPrompt, pinned
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.messages = try c.decode([ChatMessage].self, forKey: .messages)
        self.archived = (try? c.decode(Bool.self, forKey: .archived)) ?? false
        self.systemPrompt = (try? c.decode(String.self, forKey: .systemPrompt)) ?? ""
        self.pinned = (try? c.decode(Bool.self, forKey: .pinned)) ?? false
    }

    /// Derive a sidebar title from the first user message (or a placeholder).
    static func deriveTitle(from messages: [ChatMessage]) -> String {
        for m in messages where m.role == "user" {
            let t = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            let snippet = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
            return String(snippet.prefix(48))
        }
        return "New Chat"
    }
}

// MARK: - Engine state

enum EngineState: String {
    case stopped, booting, ready, stopping, crashed
}

final class EngineHandle: ObservableObject, Identifiable {
    let id = UUID()
    let model: String
    let engine: String
    let port: Int
    let process: Process
    let logFileHandle: FileHandle
    let startedAt: Date
    @Published var state: EngineState = .booting
    @Published var ramMB: Int? = nil
    @Published var cpuPercent: Double? = nil
    @Published var lastHealthOK: Bool = false
    @Published var lastReadyAt: Date? = nil

    var pid: Int32 { process.processIdentifier }

    init(model: String, engine: String, port: Int, process: Process, logFileHandle: FileHandle) {
        self.model = model
        self.engine = engine
        self.port = port
        self.process = process
        self.logFileHandle = logFileHandle
        self.startedAt = Date()
    }

    deinit {
        try? logFileHandle.close()
    }
}

// MARK: - Memory entry + store

/// One persistent cross-conversation memory. Lives on disk at
/// ~/.mlxlm/memory/<id>.md as Markdown with YAML frontmatter, indexed in
/// ~/.mlxlm/memory/INDEX.json for O(1) directory listing without parsing
/// every file.
struct MemoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var body: String
    /// "fact" | "preference" | "decision" | "task" | "reference" | "manual".
    /// "manual" is reserved for /remember entries; the extractor uses the
    /// other five.
    var type: String
    var pinned: Bool
    /// Days from createdAt before maintenance prunes this entry. nil =
    /// fall back to memory.default_retention_days. -1 = never expire
    /// (functionally identical to pinned but doesn't sort to top).
    var ttlDays: Int?
    let createdAt: Date
    var lastUsedAt: Date?
    /// Origin breadcrumb so users can trace memory back to where it came
    /// from. nil for /remember entries (sourceConversation is current
    /// conversation but not stamped on the entry).
    var sourceConversationID: UUID?
    var sourceModel: String?

    init(id: UUID = UUID(), title: String, body: String, type: String = "fact",
         pinned: Bool = false, ttlDays: Int? = nil,
         createdAt: Date = Date(), lastUsedAt: Date? = nil,
         sourceConversationID: UUID? = nil, sourceModel: String? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.type = type
        self.pinned = pinned
        self.ttlDays = ttlDays
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.sourceConversationID = sourceConversationID
        self.sourceModel = sourceModel
    }

    /// Conservative char-based token estimate, matching the router. Used
    /// when budgeting how many memories to inject per request.
    var estimatedTokens: Int {
        max(1, (title.count + body.count) / 3)
    }

    /// Human display formatted as a single line for the system-prompt
    /// injection block: "[type · title] body".
    var injectionLine: String {
        let prefix = "[\(type) · \(title)]"
        return body.isEmpty ? prefix : "\(prefix) \(body)"
    }
}

/// Disk-backed persistent memory store. Single instance lives on
/// PilotController. All disk I/O is synchronous on the calling thread —
/// callers must hop to a background queue if they want to avoid blocking
/// the main thread (the store itself is small enough that it's fine on
/// main for typical workloads).
final class MemoryStore {
    private let dir: String
    private let indexPath: String
    private(set) var entries: [MemoryEntry] = []
    private let fm = FileManager.default
    /// Last error message from a disk op; nil = healthy. PilotController
    /// reads this after each call and surfaces to the UI's MemoryPanel.
    private(set) var lastError: String?

    init(dir: String) {
        self.dir = dir
        self.indexPath = (dir as NSString).appendingPathComponent("INDEX.json")
        ensureDirExists()
        load()
    }

    private func ensureDirExists() {
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    /// Re-read INDEX.json from disk. The per-entry .md bodies are loaded
    /// alongside; if a body file is missing the entry is dropped from the
    /// in-memory list (and a stale-index warning is printed).
    func load() {
        guard let data = fm.contents(atPath: indexPath) else {
            entries = []
            return
        }
        do {
            let decoded = try JSONDecoder.iso8601.decode([MemoryEntry].self, from: data)
            // Hydrate body from .md if INDEX.json was written without it
            // (older format), but normally body lives directly in the JSON.
            entries = decoded
            lastError = nil
        } catch {
            let msg = "INDEX.json parse failed: \(error.localizedDescription)"
            print("memory: \(msg)")
            entries = []
            lastError = msg
        }
    }

    /// Atomic save: write INDEX.json (canonical store), and a parallel
    /// .md file per entry for human grepping. The .md is best-effort and
    /// not load-bearing.
    func save() {
        ensureDirExists()
        do {
            let enc = JSONEncoder.iso8601Pretty
            let data = try enc.encode(entries)
            let tmp = indexPath + ".tmp"
            try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
            _ = try? fm.replaceItemAt(URL(fileURLWithPath: indexPath),
                                      withItemAt: URL(fileURLWithPath: tmp))
            // Best-effort .md mirror (one file per entry, named by id).
            for e in entries {
                let p = (dir as NSString).appendingPathComponent("\(e.id.uuidString).md")
                let frontmatter = """
                ---
                id: \(e.id.uuidString)
                title: \(e.title.replacingOccurrences(of: "\n", with: " "))
                type: \(e.type)
                pinned: \(e.pinned)
                ttl_days: \(e.ttlDays.map { "\($0)" } ?? "null")
                created: \(ISO8601DateFormatter().string(from: e.createdAt))
                source_conversation: \(e.sourceConversationID?.uuidString ?? "")
                source_model: \(e.sourceModel ?? "")
                ---
                """
                let body = "\(frontmatter)\n\n\(e.body)\n"
                try? body.write(toFile: p, atomically: true, encoding: .utf8)
            }
            lastError = nil
        } catch {
            let msg = "save failed: \(error.localizedDescription)"
            print("memory: \(msg)")
            lastError = msg
        }
    }

    /// Insert or update by id. Replaces matching id, otherwise appends.
    func upsert(_ entry: MemoryEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        save()
    }

    /// Delete by id. Also removes the parallel .md file. No-op if absent.
    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        let p = (dir as NSString).appendingPathComponent("\(id.uuidString).md")
        try? fm.removeItem(atPath: p)
        save()
    }

    /// Fuzzy delete: returns count of removed entries whose title contains
    /// `pattern` (case-insensitive). Used by /forget.
    @discardableResult
    func deleteMatching(_ pattern: String) -> Int {
        let needle = pattern.lowercased()
        let matched = entries.filter { $0.title.lowercased().contains(needle) }
        for e in matched { delete(id: e.id) }
        return matched.count
    }

    /// Build the injection block for the system prompt. Selects pinned
    /// first, then most-recently-used, then most-recent-created, until
    /// `maxTokens` is hit. Returns ("", []) if the store is empty or the
    /// selection is empty.
    func selectForInjection(maxTokens: Int) -> (block: String, used: [MemoryEntry]) {
        guard !entries.isEmpty, maxTokens > 0 else { return ("", []) }
        let sorted = entries.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            let aL = a.lastUsedAt ?? a.createdAt
            let bL = b.lastUsedAt ?? b.createdAt
            return aL > bL
        }
        var used: [MemoryEntry] = []
        var spent = 0
        for e in sorted {
            let cost = e.estimatedTokens
            if spent + cost > maxTokens { continue }
            used.append(e)
            spent += cost
        }
        if used.isEmpty { return ("", []) }
        var block = "=== Persistent memory (from prior conversations) ===\n"
        for e in used {
            block += "- \(e.injectionLine)\n"
        }
        block += "=== End memory ==="
        return (block, used)
    }

    /// Mark entries as just-used so they sort higher next time. Called
    /// after a successful injection.
    func markUsed(_ ids: [UUID]) {
        let now = Date()
        var changed = false
        for i in entries.indices {
            if ids.contains(entries[i].id) {
                entries[i].lastUsedAt = now
                changed = true
            }
        }
        if changed { save() }
    }
}

// JSONEncoder/JSONDecoder helpers for ISO8601 dates so MemoryEntry's
// createdAt round-trips cleanly through INDEX.json. Use a custom decoder
// strategy that accepts both fractional-second and integer-second variants
// (Python's datetime.isoformat() emits fractional; Swift's
// ISO8601DateFormatter without .withFractionalSeconds only accepts
// integer seconds — so a hand-edited or python-seeded INDEX.json would
// otherwise refuse to parse).
fileprivate extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = withFrac.date(from: str) ?? plain.date(from: str) {
                return date
            }
            // Last resort: try interpreting as a plain RFC-3339 fragment by
            // appending Z if missing.
            let normalized = str.hasSuffix("Z") ? str : str + "Z"
            if let date = withFrac.date(from: normalized) ?? plain.date(from: normalized) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Unparseable date: \(str)")
        }
        return d
    }
}

fileprivate extension JSONEncoder {
    static var iso8601Pretty: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

// MARK: - PilotController

final class PilotController: ObservableObject {
    static let shared = PilotController()

    @Published var config: PilotConfig?
    @Published var configError: String?

    /// App-wide chat lane. Single source of truth for outgoing model alias.
    /// "qwen35" → routes to Qwen3.6-35B-A3B-4bit (primary).
    /// "deep"   → routes to Qwen3.6-27B-8bit (slow reasoning).
    /// Bound to the input dropdown and updated by right-panel Start so a
    /// user who starts 27B from the right panel automatically chats with
    /// 27B — no silent revert to qwen35 on subsequent sends.
    /// Default on launch is qwen35 (deterministic primary).
    @Published var selectedChatAlias: String = "qwen35"
    /// Engines keyed by model name. Multiple may be loaded simultaneously.
    @Published var engines: [String: EngineHandle] = [:]
    /// Models the router spawned directly (not us). Populated by pollTick's
    /// per-configured-model /health probe. Key is model name, value is port.
    /// Presence = listening. These show up in the menu with an "(ext)" tag
    /// so the user can see router-managed backends too.
    @Published var externalBackends: [String: Int] = [:]
    /// Router's enforced input-token cap, fetched from /health. Single
    /// source of truth for the UI — nil until the first successful poll.
    @Published var routerMaxInputTokens: Int? = nil
    /// System prompt bound to the ACTIVE conversation. Loaded on
    /// selectConversation, saved back on syncActiveConversation and
    /// sendChat. Persists across app restarts via the conversation file.
    @Published var activeSystemPrompt: String = ""
    /// Rolling send history for ⌘↑ / ⌘↓ recall. Session-only (not
    /// persisted) — just a quick way to re-run a prompt you just sent.
    /// Capped at 50 entries.
    @Published var sentHistory: [String] = []
    private let sentHistoryCap = 50
    /// Chat font size multiplier. 1.0 = default. Adjustable via ⌘+ and ⌘-.
    /// Persisted to UserDefaults.
    @Published var chatFontScale: Double = UserDefaults.standard.object(forKey: "mlxpilot.chatFontScale") as? Double ?? 1.0
    /// When true, chat bubble text is drag-selectable (SwiftUI .textSelection).
    /// Default OFF: enabling it inserts NSTextField-backed SelectionOverlay
    /// per Text view, whose AppKit constraint invalidation hangs the main
    /// thread on long messages. Toggle on only when you need to grab a
    /// sub-range out of a bubble; off otherwise.
    @Published var chatTextSelectionEnabled: Bool = UserDefaults.standard.object(forKey: "mlxpilot.chatTextSelectionEnabled") as? Bool ?? false {
        didSet { UserDefaults.standard.set(chatTextSelectionEnabled, forKey: "mlxpilot.chatTextSelectionEnabled") }
    }
    /// Current in-flight streaming chat request. Set by sendChat(),
    /// cleared on completion or cancel. Used by stopGeneration().
    var currentChatTask: URLSessionDataTask?
    var currentChatSession: URLSession?
    /// Streaming throttle state: coalesce per-token deltas into 30ms
    /// batches to eliminate SwiftUI flicker on fast models.
    @Published var streamPendingDelta: String = ""
    @Published var streamFlushScheduled: Bool = false
    @Published var streamTokenCount: Int = 0
    /// Set when the last response stopped because it hit max_tokens —
    /// surfaces a "Continue" button that asks the model to keep going.
    @Published var lastResponseHitMaxTokens: Bool = false

    // MARK: Persistent memory state
    /// Disk-backed cross-conversation memory store. Initialized lazily on
    /// first access so a corrupt INDEX.json can never crash app launch.
    private(set) lazy var memoryStore: MemoryStore = MemoryStore(
        dir: NSHomeDirectory() + "/.mlxlm/memory")
    /// Mirrors memoryStore.entries for SwiftUI observation. Re-published
    /// whenever the store is mutated through PilotController helpers.
    @Published var memoryEntries: [MemoryEntry] = []
    /// IDs of memories that were injected into the most recent send.
    /// Surfaces the "🧠 N memories loaded" chip in the chat header.
    @Published var lastInjectedMemoryIDs: [UUID] = []
    @Published var lastInjectedMemoryTokens: Int = 0
    /// Throttle: don't run the extractor more than once every N seconds.
    private var lastExtractorRunAt: Date = .distantPast
    /// Status text for the right-panel Memory section ("idle" / "extracting…" / etc.).
    @Published var memoryStatus: String = "idle"
    /// Last user-surfaced memory error (disk read/write failure, malformed
    /// model output etc.). Cleared when a successful op runs. nil = healthy.
    @Published var memoryLastError: String? = nil

    /// Flush the pending stream buffer into the last chat message. Called
    /// from the 30ms-delayed asyncAfter and on onDone/onError.
    func flushStreamBuffer() {
        streamFlushScheduled = false
        let delta = streamPendingDelta
        streamPendingDelta = ""
        if delta.isEmpty { return }
        if let i = chatMessages.indices.last {
            let msg = chatMessages[i]
            let updated = ChatMessage(
                role: msg.role,
                content: msg.content + delta,
                attachments: msg.attachments,
                model: msg.model,
                timestamp: msg.timestamp
            )
            chatMessages[i] = updated
        }
    }

    // MARK: Memory helpers (UI surface; storage lives in MemoryStore)

    /// Whether the memory subsystem is enabled by config. False if the
    /// `memory` block is absent or memory.enabled == false.
    var memoryEnabled: Bool {
        config?.memory?.enabled ?? false
    }
    var memoryAutoExtract: Bool {
        memoryEnabled && (config?.memory?.auto_extract ?? true)
    }
    var memoryMaxTokensInjected: Int {
        config?.memory?.max_tokens_injected ?? 5000
    }
    var memoryMaxEntriesPerTurn: Int {
        config?.memory?.max_entries_per_turn ?? 3
    }
    var memoryMaxEntries: Int {
        config?.memory?.max_entries ?? 500
    }
    var memoryMinSecondsBetweenExtractions: Double {
        config?.memory?.min_seconds_between_extractions ?? 4.0
    }
    var memoryDefaultRetentionDays: Int {
        config?.memory?.default_retention_days ?? 90
    }

    /// Pull current entries from the store into the @Published mirror.
    /// Call after any mutation that bypasses the helper methods.
    func memoryRefresh() {
        memoryStore.load()
        mirrorMemoryStore()
    }

    /// Internal mirror sync after store mutation. Called from every memory*
    /// helper so the panel always sees fresh entries + errors.
    private func mirrorMemoryStore() {
        memoryEntries = memoryStore.entries
        memoryLastError = memoryStore.lastError
    }

    /// Append a manually-authored memory. Used by /remember and the
    /// right-panel "Add" form. Returns the new entry's id.
    @discardableResult
    func memoryAddManual(title: String, body: String,
                         type: String = "manual",
                         pinned: Bool = false,
                         ttlDays: Int? = nil) -> UUID {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = MemoryEntry(
            title: trimmedTitle.isEmpty ? "(untitled)" : trimmedTitle,
            body: trimmedBody,
            type: type,
            pinned: pinned,
            ttlDays: ttlDays,
            sourceConversationID: activeConversationID,
            sourceModel: chatEngine()?.model
        )
        memoryStore.upsert(entry)
        mirrorMemoryStore()
        enforceMaxEntries()
        return entry.id
    }

    /// Delete by id. Updates @Published mirror.
    func memoryDelete(id: UUID) {
        memoryStore.delete(id: id)
        mirrorMemoryStore()
    }

    /// Delete entries whose title matches a fuzzy substring (used by
    /// /forget). Returns the count removed.
    @discardableResult
    func memoryDeleteMatching(_ pattern: String) -> Int {
        let n = memoryStore.deleteMatching(pattern)
        mirrorMemoryStore()
        return n
    }

    /// Toggle the pinned flag on an entry. Pinned entries are loaded
    /// first into context and survive TTL pruning.
    func memoryTogglePin(id: UUID) {
        if let idx = memoryStore.entries.firstIndex(where: { $0.id == id }) {
            var e = memoryStore.entries[idx]
            e.pinned.toggle()
            memoryStore.upsert(e)
            mirrorMemoryStore()
        }
    }

    /// Replace an entry's title/body in-place. Used by inline edit.
    func memoryUpdate(id: UUID, title: String, body: String, type: String?) {
        if let idx = memoryStore.entries.firstIndex(where: { $0.id == id }) {
            var e = memoryStore.entries[idx]
            e.title = title
            e.body = body
            if let t = type { e.type = t }
            memoryStore.upsert(e)
            mirrorMemoryStore()
        }
    }

    /// Wipe everything. Confirmed at the UI layer.
    func memoryClearAll() {
        for e in memoryStore.entries {
            memoryStore.delete(id: e.id)
        }
        memoryEntries = []
    }

    /// Cap total entries: when over `memoryMaxEntries`, drop oldest
    /// non-pinned entries until under the cap. Called after each insert.
    private func enforceMaxEntries() {
        let cap = memoryMaxEntries
        guard memoryStore.entries.count > cap else { return }
        let removable = memoryStore.entries
            .filter { !$0.pinned }
            .sorted { ($0.lastUsedAt ?? $0.createdAt) < ($1.lastUsedAt ?? $1.createdAt) }
        let toRemove = memoryStore.entries.count - cap
        for e in removable.prefix(toRemove) {
            memoryStore.delete(id: e.id)
        }
        mirrorMemoryStore()
    }

    /// Build a system-prompt prefix from the memory store. Returns the
    /// memory block (or empty string) and updates `lastInjectedMemoryIDs`
    /// + `lastInjectedMemoryTokens` for the header chip.
    func buildMemoryInjection() -> String {
        guard memoryEnabled else {
            lastInjectedMemoryIDs = []
            lastInjectedMemoryTokens = 0
            return ""
        }
        let (block, used) = memoryStore.selectForInjection(maxTokens: memoryMaxTokensInjected)
        if used.isEmpty {
            lastInjectedMemoryIDs = []
            lastInjectedMemoryTokens = 0
            return ""
        }
        memoryStore.markUsed(used.map { $0.id })
        mirrorMemoryStore()
        lastInjectedMemoryIDs = used.map { $0.id }
        lastInjectedMemoryTokens = used.reduce(0) { $0 + $1.estimatedTokens }
        return block
    }

    /// Run the autonomous extractor against the most recent (user, assistant)
    /// turn pair. Sends a side request to the currently-loaded model and
    /// parses any returned JSON memory entries. Best-effort: failures log
    /// and never propagate to the chat.
    func memoryExtractFromLastTurn() {
        guard memoryAutoExtract else { return }
        // Throttle.
        if Date().timeIntervalSince(lastExtractorRunAt) < memoryMinSecondsBetweenExtractions {
            return
        }
        // Need both sides of the turn.
        guard chatMessages.count >= 2 else { return }
        let lastAssistant = chatMessages.last { $0.role == "assistant" }
        let lastUser = chatMessages.last { $0.role == "user" }
        guard let a = lastAssistant, let u = lastUser, !a.content.isEmpty else { return }
        lastExtractorRunAt = Date()
        memoryStatus = "extracting…"

        let existingTitles = memoryStore.entries.map { $0.title }
        let existingList = existingTitles.isEmpty
            ? "(none)"
            : existingTitles.prefix(80).map { "- \($0)" }.joined(separator: "\n")

        // Cap turn excerpts so the extractor itself stays cheap.
        let userExcerpt = String(u.content.prefix(2400))
        let assistantExcerpt = String(a.content.prefix(2400))

        let prompt = """
        You are a memory-extraction assistant. Read the recent exchange below \
        and identify NEW information worth remembering across future conversations: \
        user facts, preferences, decisions, ongoing tasks, important reference material.

        Existing memory titles (DO NOT duplicate these — output [] if everything \
        worth remembering is already covered):
        \(existingList)

        Recent USER message:
        \(userExcerpt)

        Recent ASSISTANT response:
        \(assistantExcerpt)

        Output ONLY a JSON array. Each element must be an object with:
          "title":     string, max 80 chars, descriptive
          "body":      string, max 800 chars, the actual memory content
          "type":      one of "fact" | "preference" | "decision" | "task" | "reference"
          "ttl_days":  integer, 30 for tasks, 90 for facts/preferences/references, \
        180 for decisions
          "pinned":    boolean, true ONLY if it's a strong persistent preference
        Limit: at most \(memoryMaxEntriesPerTurn) entries this turn. Skip pleasantries, \
        ephemeral chat, or anything readily found by re-searching the conversation. \
        If nothing new is worth remembering, output exactly: []

        JSON:
        """

        // Always go through the router so alias resolution works whether
        // the GUI launched the model or it's an externally-managed engine.
        // The router on :8000 takes "default" → resolves to whichever
        // chat model is loaded.
        let modelAlias = "default"
        let payload: [String: Any] = [
            "model": modelAlias,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
            "max_tokens": 1200,
            "temperature": 0.2,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            memoryStatus = "idle"
            return
        }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!,
                             timeoutInterval: 60.0)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let modelName = chatEngine()?.model ?? modelAlias

        let convID = activeConversationID
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.memoryStatus = "idle" }
                if let err = err {
                    self.appendMemoryLog("extractor error: \(err.localizedDescription)")
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let message = first["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    self.appendMemoryLog("extractor: malformed response (no content)")
                    return
                }
                let parsed = Self.parseMemoryArray(content)
                if parsed.isEmpty {
                    self.appendMemoryLog("extractor: 0 new memories")
                    return
                }
                var added = 0
                for item in parsed.prefix(self.memoryMaxEntriesPerTurn) {
                    let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
                    if title.isEmpty || body.isEmpty { continue }
                    // Dedupe: skip if exact title already exists.
                    if self.memoryStore.entries.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                        continue
                    }
                    let entry = MemoryEntry(
                        title: String(title.prefix(80)),
                        body: String(body.prefix(800)),
                        type: item.type,
                        pinned: item.pinned,
                        ttlDays: item.ttlDays,
                        sourceConversationID: convID,
                        sourceModel: modelName
                    )
                    self.memoryStore.upsert(entry)
                    added += 1
                }
                self.memoryEntries = self.memoryStore.entries
                self.enforceMaxEntries()
                self.appendMemoryLog("extractor: added \(added) memor\(added == 1 ? "y" : "ies")")
            }
        }.resume()
    }

    /// Append a single line to ~/.mlxlm/logs/memory.log so the user (and
    /// maintenance) can audit what the extractor decided to do. Best-effort.
    private func appendMemoryLog(_ line: String) {
        let dir = NSHomeDirectory() + "/.mlxlm/logs"
        let path = dir + "/memory.log"
        let stamp = ISO8601DateFormatter().string(from: Date())
        let row = "[\(stamp)] \(line)\n"
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        if let data = row.data(using: .utf8) {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    /// Parse the extractor's response into typed entries. Tolerant of
    /// fluff before/after the JSON array (some models prepend ```json).
    private struct ExtractedMemory {
        var title: String
        var body: String
        var type: String
        var ttlDays: Int?
        var pinned: Bool
    }
    private static func parseMemoryArray(_ raw: String) -> [ExtractedMemory] {
        // Locate the first '[' and last ']' to slice out the array even
        // if the model wrapped it in ```json fences or commentary.
        guard let open = raw.firstIndex(of: "["),
              let close = raw.lastIndex(of: "]"), open <= close else {
            return []
        }
        let slice = String(raw[open...close])
        guard let data = slice.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var out: [ExtractedMemory] = []
        let allowedTypes: Set<String> = ["fact", "preference", "decision", "task", "reference"]
        for item in arr {
            let title = (item["title"] as? String) ?? ""
            let body  = (item["body"]  as? String) ?? ""
            var type  = (item["type"]  as? String) ?? "fact"
            if !allowedTypes.contains(type) { type = "fact" }
            let ttl: Int?
            if let i = item["ttl_days"] as? Int { ttl = i }
            else if let s = item["ttl_days"] as? String, let i = Int(s) { ttl = i }
            else { ttl = nil }
            let pinned = (item["pinned"] as? Bool) ?? false
            out.append(ExtractedMemory(title: title, body: body, type: type,
                                       ttlDays: ttl, pinned: pinned))
        }
        return out
    }

    /// Token usage totals from the router's /usage endpoint. Polled every
    /// 10s from pollTick. Keys: total_tokens, input_tokens, output_tokens,
    /// requests (lifetime) and today_* (resets at date rollover on the
    /// router side). Per-model breakdown kept in perModelUsage.
    @Published var usageTotal: Int = 0
    @Published var usageInput: Int = 0
    @Published var usageOutput: Int = 0
    @Published var usageRequests: Int = 0
    @Published var usageTodayTotal: Int = 0
    @Published var usageTodayRequests: Int = 0
    @Published var perModelUsage: [String: Int] = [:]  // model name -> total_tokens
    @Published var lastActionStatus: String = "—"

    // Chat state
    @Published var chatMessages: [ChatMessage] = []
    @Published var chatInProgress: Bool = false
    @Published var chatTargetModel: String? = nil  // user override; nil = use any ready

    // Conversation persistence. `conversations` is the full list (sorted newest
    // first, excluding archived by default). `activeConversationID` identifies
    // which one the editor pane is currently showing; its messages live in
    // `chatMessages` and are kept in sync on every mutation.
    @Published var conversations: [Conversation] = []
    @Published var activeConversationID: UUID? = nil
    /// Free-form search query for the sidebar. Matches title + message bodies
    /// case-insensitively. Empty string means "show everything".
    @Published var conversationSearchQuery: String = ""

    // Folder state
    @Published var logsFolderSize: String = "—"
    @Published var logsFileCount: Int = 0

    private var pollTimer: Timer?
    private var usedPorts: Set<Int> = []
    private let usedPortsLock = NSLock()
    private var handleSubs: [String: AnyCancellable] = [:]
    private let configPath = NSHomeDirectory() + "/.mlxlm/config.json"
    private static let supportedConfigVersion = 6

    init() {
        loadConfig()
        refreshFolderSizes()
        startPollTimer()
        loadConversations()
        // Hydrate the @Published memory mirror from disk on launch.
        mirrorMemoryStore()
        if let toStart = config?.control.auto_start_models, !toStart.isEmpty {
            DispatchQueue.main.async { [weak self] in
                for model in toStart { self?.startModel(model) }
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: Config

    func loadConfig() {
        guard let data = FileManager.default.contents(atPath: configPath) else {
            self.configError = "config not found at \(configPath)"
            self.config = nil
            return
        }
        do {
            let decoded = try JSONDecoder().decode(PilotConfig.self, from: data)
            guard decoded.version == Self.supportedConfigVersion else {
                self.config = nil
                self.configError = "config schema version \(decoded.version) not supported (need \(Self.supportedConfigVersion))"
                return
            }
            self.config = decoded
            self.configError = nil
        } catch {
            self.config = nil
            self.configError = "config parse failed: \(error.localizedDescription)"
        }
    }

    var availableModels: [String] {
        config?.models.keys.sorted() ?? []
    }
    var defaultModel: String? { config?.control.default_model }

    /// All engines currently in booting/ready state.
    var liveEngines: [EngineHandle] {
        engines.values.filter { $0.state == .booting || $0.state == .ready }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Returns the engine the user has targeted for chat, or the first ready engine.
    func chatEngine() -> EngineHandle? {
        if let target = chatTargetModel,
           let h = engines[target],
           h.state == .ready {
            return h
        }
        return engines.values.first(where: { $0.state == .ready })
    }

    // MARK: Lifecycle (multi-model: each engine gets its own port)

    func startModel(_ model: String) {
        guard let cfg = config else {
            lastActionStatus = "no config loaded"
            return
        }
        guard cfg.models[model] != nil else {
            lastActionStatus = "model not in config: \(model)"
            return
        }
        // Bind chat lane to whichever model the user is starting. This
        // closes the previous bug where right-panel Start of 27B left the
        // chat dropdown on "qwen35", and the next message routed to 35B,
        // evicting the freshly-started 27B. Right-panel Start IS now the
        // canonical way to switch lanes; the dropdown reflects it.
        if model.contains("Qwen3.6-27B-8bit") {
            selectedChatAlias = "deep"
        } else if model.contains("Qwen3.6-35B-A3B-4bit") {
            selectedChatAlias = "qwen35"
        }
        // Already running?
        if let h = engines[model], h.state == .booting || h.state == .ready {
            lastActionStatus = "\(model) already \(h.state.rawValue)"
            return
        }
        // Clean up any prior stopped/crashed entry first.
        if engines[model] != nil {
            engines.removeValue(forKey: model)
            handleSubs.removeValue(forKey: model)
        }
        actuallyStartEngine(model: model)
    }

    func ejectModel(_ model: String) {
        guard let h = engines[model] else { return }
        // Eject of 27B snaps the chat lane back to qwen35 so the next
        // message does NOT silently relaunch 27B via lazy-load. The 27B
        // lane is manual-only; it must stay off after eject until the
        // user explicitly picks `deep` from the dropdown again.
        if model.contains("Qwen3.6-27B-8bit") && selectedChatAlias == "deep" {
            selectedChatAlias = "qwen35"
        }
        if h.state == .stopped || h.state == .crashed {
            engines.removeValue(forKey: model)
            handleSubs.removeValue(forKey: model)
            return
        }
        h.state = .stopping
        lastActionStatus = "stopping \(model)"
        h.process.terminate()
        // terminationHandler completes cleanup.
    }

    /// Kill any process listening on `port` via `lsof -ti :PORT | xargs kill`.
    /// Used for router-owned backends the GUI doesn't own a Process handle for.
    /// Runs off-main so an unresponsive lsof/kill can't freeze the UI.
    func ejectByPort(_ port: Int, model: String) {
        DispatchQueue.main.async { [weak self] in
            self?.externalBackends.removeValue(forKey: model)
            // Same rule as ejectModel: ejecting 27B snaps the chat lane
            // back to qwen35 so the next send does not silently relaunch
            // 27B through router lazy-load.
            if model.contains("Qwen3.6-27B-8bit") && self?.selectedChatAlias == "deep" {
                self?.selectedChatAlias = "qwen35"
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let cmd = "pids=$(/usr/sbin/lsof -ti :\(port)); if [ -n \"$pids\" ]; then kill $pids; sleep 1; kill -9 $pids 2>/dev/null; fi"
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", cmd]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            do { try task.run(); task.waitUntilExit() } catch { /* swallow */ }
        }
    }

    func restartModel(_ model: String) {
        // Capture port preference: restart should reuse same logic.
        ejectModel(model)
        // Defer the start; terminationHandler doesn't auto-chain in multi-model.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.startModel(model)
        }
    }

    func stopAll() {
        for (m, h) in engines where h.state == .booting || h.state == .ready {
            ejectModel(m)
        }
        // Also kill any router-owned backends currently listening.
        for (name, port) in externalBackends {
            ejectByPort(port, model: name)
        }
    }

    private func allocPort(startingAt base: Int) -> Int {
        usedPortsLock.lock()
        defer { usedPortsLock.unlock() }
        var p = base
        while usedPorts.contains(p) || isPortBound(p) {
            p += 1
            if p > base + 100 { break }
        }
        usedPorts.insert(p)
        return p
    }

    private func releasePort(_ port: Int) {
        usedPortsLock.lock()
        usedPorts.remove(port)
        usedPortsLock.unlock()
    }

    private func isPortBound(_ port: Int) -> Bool {
        // Quick TCP probe — reuse the URLSession check.
        let sem = DispatchSemaphore(value: 0)
        var bound = false
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 0.3)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let r = resp as? HTTPURLResponse, r.statusCode > 0 { bound = true }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 0.4)
        return bound
    }

    private func actuallyStartEngine(model: String) {
        guard let cfg = config, let modelCfg = cfg.models[model] else { return }

        let modelPath = (cfg.control.models_dir as NSString).appendingPathComponent(model)
        let port: Int
        if let fixed = modelCfg.port {
            // If something is already listening on the fixed port (orphan from a
            // previous app run, or another process), don't try to spawn — adopt
            // the existing one and warn. Bind would crash the new server otherwise.
            if isPortBound(fixed) {
                lastActionStatus = "\(model): port \(fixed) already in use — leaving existing server alone"
                return
            }
            usedPortsLock.lock()
            usedPorts.insert(fixed)
            usedPortsLock.unlock()
            port = fixed
        } else {
            port = allocPort(startingAt: cfg.server.port)
        }

        var args: [String] = [
            "-m", "\(modelCfg.engine).server",
            "--model", modelPath,
            "--host", cfg.server.host,
            "--port", String(port)
        ]
        if modelCfg.engine == "mlx_vlm" {
            if let bits = modelCfg.kv_bits {
                args.append("--kv-bits"); args.append(String(bits))
            }
            if let scheme = modelCfg.kv_quant_scheme {
                args.append("--kv-quant-scheme"); args.append(scheme)
            }
            if let maxCtx = modelCfg.max_context_tokens {
                args.append("--max-kv-size"); args.append(String(maxCtx))
            }
        } else if modelCfg.engine == "mlx_lm" {
            if let rd = modelCfg.request_defaults {
                if let t = rd.temperature  { args.append("--temp"); args.append(String(t)) }
                if let p = rd.top_p        { args.append("--top-p"); args.append(String(p)) }
                if let k = rd.top_k        { args.append("--top-k"); args.append(String(k)) }
                if let mt = rd.max_tokens  { args.append("--max-tokens"); args.append(String(mt)) }
            }
        }
        if modelCfg.trust_remote_code == true {
            args.append("--trust-remote-code")
        }

        // Per-model log file. Sanitize the model name to keep the filename safe.
        let safeName = model.replacingOccurrences(of: "/", with: "_")
        let logPath = (cfg.control.logs_dir as NSString).appendingPathComponent("server.\(safeName).log")
        let fm = FileManager.default
        if !fm.fileExists(atPath: cfg.control.logs_dir) {
            do {
                try fm.createDirectory(atPath: cfg.control.logs_dir, withIntermediateDirectories: true)
            } catch {
                lastActionStatus = "could not create logs dir \(cfg.control.logs_dir): \(error.localizedDescription)"
                releasePort(port)
                return
            }
        }
        if !fm.fileExists(atPath: logPath) {
            fm.createFile(atPath: logPath, contents: nil)
        }
        guard let logHandle = FileHandle(forWritingAtPath: logPath) else {
            lastActionStatus = "could not open \(logPath)"
            releasePort(port)
            return
        }
        do {
            try logHandle.seekToEnd()
            let marker = "\n=== \(Date()) — MLX Pilot starting \(modelCfg.engine) for \(model) on :\(port) ===\n"
            if let d = marker.data(using: .utf8) { logHandle.write(d) }
        } catch {
            try? logHandle.close()
            releasePort(port)
            lastActionStatus = "log seek failed: \(error.localizedDescription)"
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cfg.control.venv_python)
        proc.arguments = args
        proc.standardOutput = logHandle
        proc.standardError = logHandle

        let handle = EngineHandle(model: model, engine: modelCfg.engine, port: port,
                                  process: proc, logFileHandle: logHandle)

        proc.terminationHandler = { [weak self, weak handle] terminated in
            DispatchQueue.main.async {
                guard let self else { return }
                let exitCode = terminated.terminationStatus
                let reason = terminated.terminationReason
                // Three termination categories:
                //   1. GUI-initiated eject (handle was set to .stopping first)
                //   2. SIGTERM from the router's auto-swap eviction (signal 15)
                //   3. Anything else — real crash
                // Cases 1 and 2 are clean stops, not crashes. The router uses
                // SIGTERM to evict before launching a new model; that's a
                // routine swap and should not surface as a crash in the UI.
                let guiInitiated = (handle?.state == .stopping)
                let routerEvicted = (reason == .uncaughtSignal && exitCode == 15)
                let cleanStop = guiInitiated || routerEvicted
                handle?.lastHealthOK = false
                handle?.state = cleanStop ? .stopped : .crashed
                try? handle?.logFileHandle.close()
                if let p = handle?.port { self.releasePort(p) }

                let modelName = handle?.model ?? "?"
                if guiInitiated {
                    self.lastActionStatus = "\(modelName) stopped (exit \(exitCode))"
                } else if routerEvicted {
                    self.lastActionStatus = "\(modelName) evicted by router auto-swap"
                } else {
                    self.lastActionStatus = "\(modelName) crashed (exit \(exitCode)) — see logs"
                }
            }
        }

        do {
            try proc.run()
            engines[model] = handle
            // Forward this handle's @Published changes through the controller's
            // objectWillChange so SwiftUI views observing PilotController redraw
            // when engine state / RAM / CPU updates.
            handleSubs[model] = handle.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
            lastActionStatus = "started \(model) on :\(port) (PID \(proc.processIdentifier))"
        } catch {
            try? logHandle.close()
            releasePort(port)
            lastActionStatus = "Process.run failed: \(error.localizedDescription)"
        }
    }

    // MARK: Polling

    // Dedicated URLSession for health polling with hard 5s timeouts at BOTH
    // request and resource levels. URLSession.shared inherits a 60s default
    // for timeoutIntervalForResource which is useless for a health poll.
    private lazy var healthSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = 5.0
        cfg.timeoutIntervalForResource = 5.0
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    // Inflight guards: prevent stacking when a backend is slow or wedged.
    // A new tick for the same engine is skipped until the previous poll
    // (or ps probe) completes. Without this, a 2s timer + a slow backend
    // produces an unbounded queue of URLSession tasks and /bin/ps forks,
    // which is exactly the 99% CPU spin we hit on 2026-04-13.
    private var healthInflight: Set<String> = []
    private var psInflight: Set<String> = []
    private let inflightLock = NSLock()

    private func startPollTimer() {
        // 5s interval (was 2s) to match the 5s request timeout budget, so a
        // single slow poll cannot cause the next tick to overlap with it.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.pollTick()
        }
    }

    private var pollCounter = 0
    private var externalProbeInflight: Set<String> = []
    /// Consecutive probe failures per model. Debounces transient timeouts
    /// so a slow /health (common when the backend is mid-inference under
    /// heavy streaming load) doesn't clear the model from the display.
    /// We require N consecutive failures before removing.
    private var externalProbeFailCount: [String: Int] = [:]
    private let externalProbeFailThreshold = 3  // 3 * 5s = 15s before hiding
    private func pollTick() {
        for h in engines.values where h.state == .booting || h.state == .ready {
            pollEngine(h)
        }
        // Probe every configured model port that we don't already own. Any
        // 200 /health means the router (or someone else) has that model
        // listening — we surface it in the UI as an external backend.
        // One single lsof call for ALL configured model ports, not one
        // per model. Was 4 lsof subprocess spawns per 5s (~340ms CPU);
        // now it's one spawn (~86ms) regardless of model count.
        probeAllExternalBackends()
        pollCounter += 1
        if pollCounter % 5 == 0 {
            refreshFolderSizes()
        }
        if pollCounter % 2 == 0 {
            pollUsage()
            pollRouterHealth()
        }
        // Repaint the menu bar icon after every poll so the green-vs-gray
        // state stays in sync with the current loaded-model count.
        DispatchQueue.main.async {
            (NSApp.delegate as? AppDelegate)?.refreshStatusBarIcon()
        }
    }

    private var usageInflight = false
    func pollUsage() {
        if usageInflight { return }
        usageInflight = true
        guard let url = URL(string: "http://127.0.0.1:8000/usage") else {
            usageInflight = false
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 2.0)
        req.httpMethod = "GET"
        healthSession.dataTask(with: req) { [weak self] data, resp, _ in
            defer { DispatchQueue.main.async { self?.usageInflight = false } }
            guard let self else { return }
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            let total = (obj["total_tokens"] as? Int) ?? 0
            let input = (obj["input_tokens"] as? Int) ?? 0
            let output = (obj["output_tokens"] as? Int) ?? 0
            let requests = (obj["requests"] as? Int) ?? 0
            var todayTotal = 0
            var todayRequests = 0
            if let today = obj["today"] as? [String: Any] {
                todayTotal = (today["total_tokens"] as? Int) ?? 0
                todayRequests = (today["requests"] as? Int) ?? 0
            }
            var perModel: [String: Int] = [:]
            if let pm = obj["per_model"] as? [String: [String: Any]] {
                for (name, stats) in pm {
                    perModel[name] = (stats["total_tokens"] as? Int) ?? 0
                }
            }
            DispatchQueue.main.async {
                self.usageTotal = total
                self.usageInput = input
                self.usageOutput = output
                self.usageRequests = requests
                self.usageTodayTotal = todayTotal
                self.usageTodayRequests = todayRequests
                self.perModelUsage = perModel
            }
        }.resume()
    }

    private var routerHealthInflight = false
    func pollRouterHealth() {
        if routerHealthInflight { return }
        routerHealthInflight = true
        guard let url = URL(string: "http://127.0.0.1:8000/health") else {
            routerHealthInflight = false
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 2.0)
        req.httpMethod = "GET"
        healthSession.dataTask(with: req) { [weak self] data, resp, _ in
            defer { DispatchQueue.main.async { self?.routerHealthInflight = false } }
            guard let self else { return }
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            let maxIn = obj["max_input_tokens"] as? Int
            DispatchQueue.main.async {
                self.routerMaxInputTokens = maxIn
            }
        }.resume()
    }

    private var externalProbeAllInflight = false
    /// Native Darwin TCP-connect probe (no subprocess). For each eligible
    /// model, try a non-blocking connect to 127.0.0.1:port with a 200ms
    /// timeout. If connect succeeds OR errors with ECONNRESET/EISCONN we
    /// consider the port listening. Replaced the previous lsof subprocess
    /// which was ~86ms per tick; this is ~2ms for 4 ports.
    private func probeAllExternalBackends() {
        guard let cfg = config else { return }
        inflightLock.lock()
        if externalProbeAllInflight { inflightLock.unlock(); return }
        externalProbeAllInflight = true
        inflightLock.unlock()

        var targets: [(String, Int)] = []
        for (modelName, modelCfg) in cfg.models {
            if let h = engines[modelName],
               h.state == .ready || h.state == .booting || h.state == .stopping {
                continue
            }
            guard let port = modelCfg.port else { continue }
            targets.append((modelName, port))
        }
        if targets.isEmpty {
            inflightLock.lock()
            externalProbeAllInflight = false
            inflightLock.unlock()
            return
        }

        DispatchQueue.global(qos: .background).async { [weak self] in
            defer {
                self?.inflightLock.lock()
                self?.externalProbeAllInflight = false
                self?.inflightLock.unlock()
            }
            var listeningPorts = Set<Int>()
            for (_, port) in targets {
                if Self.tcpPortOpen(host: "127.0.0.1", port: port, timeoutMs: 200) {
                    listeningPorts.insert(port)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for (model, port) in targets {
                    if listeningPorts.contains(port) {
                        self.externalBackends[model] = port
                        self.externalProbeFailCount[model] = 0
                    } else {
                        let next = (self.externalProbeFailCount[model] ?? 0) + 1
                        self.externalProbeFailCount[model] = next
                        if next >= self.externalProbeFailThreshold {
                            self.externalBackends.removeValue(forKey: model)
                        }
                    }
                }
            }
        }
    }

    /// Non-blocking TCP connect to check if `port` is listening on `host`.
    /// Returns true if a socket can connect (or would block but poll says
    /// writable with no SO_ERROR). Much cheaper than shelling out to lsof.
    private static func tcpPortOpen(host: String, port: Int, timeoutMs: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        if sock < 0 { return false }
        defer { close(sock) }
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            return false
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(sock, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        if errno != EINPROGRESS { return false }

        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let rc = poll(&pfd, 1, Int32(timeoutMs))
        if rc <= 0 { return false }

        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &len)
        return soError == 0
    }

    private func probeExternalBackend(model: String, port: Int) {
        inflightLock.lock()
        let busy = externalProbeInflight.contains(model)
        if !busy { externalProbeInflight.insert(model) }
        inflightLock.unlock()
        if busy { return }
        // TCP listen check via `lsof -ti :PORT -sTCP:LISTEN`. This confirms
        // the port is held by any process regardless of whether HTTP is
        // responsive. Previously we did HTTP GET /health, but mlx backends
        // under heavy inference load block their event loop and /health
        // can hang indefinitely — which is exactly when we most need the
        // display to correctly show "loaded". TCP socket state is owned by
        // the kernel and is always immediately queryable.
        DispatchQueue.global(qos: .background).async { [weak self] in
            defer {
                self?.inflightLock.lock()
                self?.externalProbeInflight.remove(model)
                self?.inflightLock.unlock()
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            var ok = false
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let s = String(data: data, encoding: .utf8) ?? ""
                ok = !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } catch { ok = false }
            DispatchQueue.main.async {
                guard let self else { return }
                if ok {
                    self.externalBackends[model] = port
                    self.externalProbeFailCount[model] = 0
                } else {
                    let next = (self.externalProbeFailCount[model] ?? 0) + 1
                    self.externalProbeFailCount[model] = next
                    if next >= self.externalProbeFailThreshold {
                        self.externalBackends.removeValue(forKey: model)
                    }
                }
            }
        }
    }

    private func pollEngine(_ h: EngineHandle) {
        // Always poll the local loopback. cfg.server.host may be "0.0.0.0" which is
        // valid as a bind address but not as a connect target.
        let engineKey = h.model
        inflightLock.lock()
        let healthBusy = healthInflight.contains(engineKey)
        if !healthBusy { healthInflight.insert(engineKey) }
        inflightLock.unlock()

        if !healthBusy, let url = URL(string: "http://127.0.0.1:\(h.port)/health") {
            var req = URLRequest(url: url, timeoutInterval: 5.0)
            req.httpMethod = "GET"
            healthSession.dataTask(with: req) { [weak self, weak h] _, resp, _ in
                DispatchQueue.main.async {
                    let ok = (resp as? HTTPURLResponse)?.statusCode == 200
                    h?.lastHealthOK = ok
                    if ok && h?.state == .booting {
                        h?.state = .ready
                        h?.lastReadyAt = Date()
                    }
                }
                self?.inflightLock.lock()
                self?.healthInflight.remove(engineKey)
                self?.inflightLock.unlock()
            }.resume()
        }
        // /bin/ps probe for RAM/CPU — also guarded by inflight set.
        // Without this, a stuck ps (rare but possible under heavy load)
        // would allow new ps processes to stack every 5s until fd exhaustion.
        inflightLock.lock()
        let psBusy = psInflight.contains(engineKey)
        if !psBusy { psInflight.insert(engineKey) }
        inflightLock.unlock()
        if psBusy { return }

        DispatchQueue.global(qos: .background).async { [weak self, weak h] in
            defer {
                self?.inflightLock.lock()
                self?.psInflight.remove(engineKey)
                self?.inflightLock.unlock()
            }
            guard let h = h else { return }
            let pid = h.pid
            guard pid > 0 else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["-o", "rss=,%cpu=", "-p", String(pid)]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            do { try task.run() } catch { return }
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let s = String(data: data, encoding: .utf8) else { return }
            let parts = s.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard parts.count >= 2,
                  let kb = Int(parts[0]),
                  let cpu = Double(parts[1]) else { return }
            DispatchQueue.main.async {
                h.ramMB = kb / 1024
                h.cpuPercent = cpu
            }
        }
    }

    // MARK: Folder management

    // HuggingFace cache is where mlx-vlm / mlx-lm actually put downloaded
    // model blobs and xet content. Show that folder when the user picks
    // "Open Cache Folder".
    var cacheDir: String { NSHomeDirectory() + "/.cache/huggingface" }
    var logsDir: String { config?.control.logs_dir ?? (NSHomeDirectory() + "/.mlxlm/logs") }
    var modelsDir: String { config?.control.models_dir ?? (NSHomeDirectory() + "/.mlxlm/models") }

    func openCacheFolder() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: cacheDir) {
            do {
                try fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
            } catch {
                lastActionStatus = "could not create cache folder: \(error.localizedDescription)"
                return
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: cacheDir))
    }

    /// Clear the HuggingFace cache subdirs that accumulate model blobs and
    /// in-flight downloads. Preserves auth tokens (`token`, `stored_tokens`).
    ///
    /// Why this is dispatched off the main thread even though the target
    /// directory is usually tiny: prior to 2026-04-14, this ran inline on the
    /// menu's main-thread action selector. User reported that clicking
    /// "Clear Cache" in the menu bar reliably shut the app down. Root cause
    /// was never positively identified (the HF cache is ~20 KB and empty in
    /// practice), but the symptom reproduced. Moving all I/O to a background
    /// queue, catching every error, and only touching `@Published` state from
    /// the main queue eliminates every class of main-thread-I/O kill.
    ///
    /// Defensive additions:
    ///   1. `DispatchQueue.global(qos: .userInitiated)` for the file I/O
    ///   2. Explicit `do/catch` around every `removeItem` call
    ///   3. Skip any file currently held open by a running mlx_lm /
    ///      mlx_vlm / router process (checked via `lsof -c Python`), so we
    ///      never rip weights out from under an active backend
    ///   4. Main-queue dispatch for both the progress and the final
    ///      `lastActionStatus` update (SwiftUI `@Published` mutation must be
    ///      on the main actor)
    func clearCacheFolder() {
        // Shell out to ~/.mlxlm/maintenance.py --apply in a fully detached
        // subprocess. Same pattern as clearLogs — keeps AppKit out of the
        // file-work code path, the prior inline version correlated with
        // the menu bar status item vanishing.
        let py = NSHomeDirectory() + "/.mlxlm/venv/bin/python"
        let script = NSHomeDirectory() + "/.mlxlm/maintenance.py"
        let logOut = self.logsDir + "/clear_cache.stdout.log"
        // Truncate the log first so the user sees only the output from
        // THIS click — otherwise old runs accumulate and it's confusing.
        if let emptyData = "".data(using: .utf8) {
            try? emptyData.write(to: URL(fileURLWithPath: logOut))
        }
        let cmd = "nohup \(quote(py)) \(quote(script)) --apply --quiet >> \(quote(logOut)) 2>&1 &"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", cmd]
        do { try task.run() } catch { /* swallow */ }
        // Delayed folder-size refresh so the user sees cache panel update.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.refreshFolderSizes()
        }
    }

    /// Shell-quote a path for safe interpolation into a `/bin/sh -c` string.
    private func quote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Returns the set of absolute file paths currently held open by any
    /// Python process — a safe superset of what the running mlx_lm and
    /// mlx_vlm backends are reading. Used by `clearCacheFolder` to avoid
    /// unlinking files a live model is mmap'ing.
    private static func filesOpenByMLXProcesses() -> Set<String> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-c", "Python", "-Fn"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return [] }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return [] }
        var paths = Set<String>()
        for line in out.split(separator: "\n") {
            if line.hasPrefix("n/") {
                paths.insert(String(line.dropFirst()))
            }
        }
        return paths
    }

    func refreshFolderSizes() {
        let ldir = logsDir
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let lSize = self.folderSize(ldir)
            let lCount = self.logFileCount(ldir)
            DispatchQueue.main.async {
                self.logsFolderSize = lSize
                self.logsFileCount = lCount
            }
        }
    }

    private func folderSize(_ path: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "—" }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        task.arguments = ["-sh", path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return "?" }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8) else { return "?" }
        return s.split(separator: "\t").first.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? "?"
    }

    private func logFileCount(_ path: String) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return 0 }
        return entries.filter { $0.hasSuffix(".log") }.count
    }

    func openLogsFolder() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logsDir) {
            try? fm.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: logsDir))
    }

    func openModelsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: modelsDir))
    }

    func clearLogs() {
        // Same bulletproof pattern as clearCacheFolder: shell out to a
        // detached /bin/sh subprocess so the app process never touches
        // the filesystem or mutates @Published state on the menu-action
        // codepath. The prior inline FileHandle truncate + refreshFolderSizes
        // path correlated with the menu bar icon vanishing on click.
        let dir = self.logsDir
        let cmd = "for f in \(quote(dir))/*.log; do : > \"$f\" 2>/dev/null; done &"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", cmd]
        do { try task.run() } catch { /* swallow */ }
        // Refresh folder sizes after the menu action has fully returned to
        // AppKit (asyncAfter runs on a fresh runloop tick, not inside the
        // menu-action callstack). Gives the user visible confirmation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshFolderSizes()
        }
    }

    func openConfigFile() {
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    // MARK: Chat

    /// "Clear" now means "start a new conversation", which is what users
    /// actually want — the old chat survives in the sidebar.
    /// Clear current conversation's messages (keep the conversation row).
    /// Misleadingly named historically — for a NEW conversation call
    /// newConversation() directly or use Cmd+N.
    func clearChat() {
        clearActiveMessages()
    }

    /// Append a chat message and persist the active conversation in one step.
    /// All sendChat callsites should go through this instead of mutating
    /// `chatMessages` directly, so the on-disk store never drifts from RAM.
    func appendChatMessage(_ msg: ChatMessage) {
        chatMessages.append(msg)
        syncActiveConversation()
    }

    // MARK: Conversation persistence
    //
    // Conversations are stored one-file-per-thread at
    //   ~/.mlxlm/conversations/<uuid>.json
    // The format is simply a JSON-encoded `Conversation`. Deleting a file is
    // a hard delete; setting `archived = true` is a soft delete (hidden from
    // the sidebar by default but kept on disk for recovery).

    var conversationsDir: String { NSHomeDirectory() + "/.mlxlm/conversations" }

    /// Conversations visible in the sidebar: non-archived, optionally filtered
    /// by `conversationSearchQuery`. Matching is case-insensitive and checks
    /// the title plus the content of every message in the thread.
    var visibleConversations: [Conversation] {
        let q = conversationSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = q.isEmpty
            ? conversations.filter { !$0.archived }
            : conversations
        let filtered: [Conversation]
        if q.isEmpty {
            filtered = base
        } else {
            let needle = q.lowercased()
            filtered = base.filter { conv in
                if conv.title.lowercased().contains(needle) { return true }
                for m in conv.messages {
                    if m.content.lowercased().contains(needle) { return true }
                }
                return false
            }
        }
        // Pinned first, then by updatedAt. Preserves search filtering.
        return filtered.sorted { (a, b) in
            if a.pinned != b.pinned { return a.pinned }
            return a.updatedAt > b.updatedAt
        }
    }

    /// Toggle the pinned flag on a conversation and persist.
    func togglePin(_ id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].pinned.toggle()
        conversations[idx].updatedAt = Date()
        saveConversation(conversations[idx])
        // Force re-sort via @Published mutation.
        conversations = conversations
    }


    /// Return a short snippet around the first match of `query` in the
    /// conversation's messages, for display below the sidebar row title.
    /// Returns nil if no body match (title-only match, show nothing extra).
    func matchSnippet(for conv: Conversation, query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        for m in conv.messages {
            let lower = m.content.lowercased()
            if let r = lower.range(of: q) {
                let contextStart = m.content.index(r.lowerBound, offsetBy: -30, limitedBy: m.content.startIndex) ?? m.content.startIndex
                let contextEnd = m.content.index(r.upperBound, offsetBy: 30, limitedBy: m.content.endIndex) ?? m.content.endIndex
                var snippet = String(m.content[contextStart..<contextEnd])
                snippet = snippet.replacingOccurrences(of: "\n", with: " ")
                if contextStart > m.content.startIndex { snippet = "…" + snippet }
                if contextEnd < m.content.endIndex { snippet = snippet + "…" }
                return snippet
            }
        }
        return nil
    }

    private func ensureConversationsDir() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: conversationsDir) {
            try? fm.createDirectory(atPath: conversationsDir,
                                    withIntermediateDirectories: true)
        }
    }

    private func conversationPath(_ id: UUID) -> String {
        (conversationsDir as NSString).appendingPathComponent("\(id.uuidString).json")
    }

    private static let convEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let convDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Load every conversation from disk into memory and surface it in the
    /// sidebar. Safe to call repeatedly — it rebuilds the in-memory list.
    func loadConversations() {
        ensureConversationsDir()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: conversationsDir) else {
            self.conversations = []
            return
        }
        var loaded: [Conversation] = []
        for name in entries where name.hasSuffix(".json") {
            let path = (conversationsDir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: path) else { continue }
            do {
                let c = try Self.convDecoder.decode(Conversation.self, from: data)
                loaded.append(c)
            } catch {
                // Log and skip; one corrupt file shouldn't break the list.
                print("conversation decode failed for \(name): \(error)")
            }
        }
        // Newest first.
        loaded.sort { $0.updatedAt > $1.updatedAt }
        self.conversations = loaded

        // Pick a sane active conversation: the newest non-archived one, or
        // a fresh conversation if nothing is on disk yet.
        if let first = loaded.first(where: { !$0.archived }) {
            activeConversationID = first.id
            chatMessages = first.messages
        } else if loaded.isEmpty {
            newConversation()
        } else {
            activeConversationID = nil
            chatMessages = []
        }
    }

    /// Write a conversation to disk. Called from `syncActiveConversation`
    /// after every chat mutation, and from delete/archive operations.
    private func saveConversation(_ conv: Conversation) {
        ensureConversationsDir()
        do {
            let data = try Self.convEncoder.encode(conv)
            try data.write(to: URL(fileURLWithPath: conversationPath(conv.id)),
                           options: .atomic)
        } catch {
            lastActionStatus = "save failed: \(error.localizedDescription)"
        }
    }

    /// Pull the latest `chatMessages` into the active conversation, update
    /// its title/timestamp, write to disk, and refresh the sidebar ordering.
    func syncActiveConversation() {
        guard let id = activeConversationID,
              let idx = conversations.firstIndex(where: { $0.id == id }) else {
            return
        }
        var conv = conversations[idx]
        conv.messages = chatMessages
        conv.systemPrompt = activeSystemPrompt
        conv.updatedAt = Date()
        // Auto-title from first user message if still generic.
        if conv.title == "New Chat" || conv.title.isEmpty {
            conv.title = Conversation.deriveTitle(from: chatMessages)
        }
        conversations[idx] = conv
        // Re-sort so freshly-updated chat floats to top.
        conversations.sort { $0.updatedAt > $1.updatedAt }
        saveConversation(conv)
    }

    /// Start a brand new conversation and make it the active one. The old
    /// active conversation is already on disk (sync runs on every mutation),
    /// so nothing is lost.
    func newConversation() {
        let conv = Conversation()
        conversations.insert(conv, at: 0)
        activeConversationID = conv.id
        chatMessages = []
        activeSystemPrompt = ""
        saveConversation(conv)
    }

    /// Switch the chat editor to an existing conversation. Its messages
    /// replace `chatMessages`. Does not write to disk — no mutation yet.
    func selectConversation(_ id: UUID) {
        guard let conv = conversations.first(where: { $0.id == id }) else { return }
        activeConversationID = conv.id
        chatMessages = conv.messages
        activeSystemPrompt = conv.systemPrompt
    }

    /// Hard delete: remove file and drop from in-memory list. If the deleted
    /// one was active, switch to the next newest or create a blank one.
    func deleteConversation(_ id: UUID) {
        try? FileManager.default.removeItem(atPath: conversationPath(id))
        conversations.removeAll { $0.id == id }
        if activeConversationID == id {
            if let first = conversations.first(where: { !$0.archived }) {
                selectConversation(first.id)
            } else {
                newConversation()
            }
        }
    }

    /// Path to the templates dir. Each .md file in this dir is a
    /// reusable prompt. Filename (without .md) becomes the template name.
    var templatesDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".mlxlm/templates")
    }

    /// List available templates: [(name, first 60 chars as preview)].
    /// Scanned fresh on each call — templates are rare, cost is trivial.
    func listTemplates() -> [(name: String, preview: String, body: String)] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: templatesDir) {
            try? fm.createDirectory(atPath: templatesDir, withIntermediateDirectories: true)
            // Seed with a couple of starter templates so the picker isn't empty.
            let starters: [(String, String)] = [
                ("summarize", "Summarize the following in 3-5 bullet points:\n\n"),
                ("explain-code", "Explain what this code does in plain English:\n\n"),
                ("refactor", "Refactor this for clarity. Keep behavior identical:\n\n"),
            ]
            for (name, body) in starters {
                let p = (templatesDir as NSString).appendingPathComponent("\(name).md")
                try? body.write(toFile: p, atomically: true, encoding: .utf8)
            }
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: templatesDir) else { return [] }
        var out: [(String, String, String)] = []
        for name in entries where name.hasSuffix(".md") {
            let p = (templatesDir as NSString).appendingPathComponent(name)
            guard let body = try? String(contentsOfFile: p, encoding: .utf8) else { continue }
            let bare = (name as NSString).deletingPathExtension
            let preview = String(body.replacingOccurrences(of: "\n", with: " ").prefix(60))
            out.append((bare, preview, body))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Rename a conversation manually (overrides auto-title).
    func renameConversation(_ id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].title = String(trimmed.prefix(120))
        conversations[idx].updatedAt = Date()
        saveConversation(conversations[idx])
    }

    /// Send a "please continue" follow-up to extend a response that
    /// was truncated at max_tokens. Pulls the last assistant message's
    /// model so the follow-up stays on the same backend.
    func continueResponse() {
        guard !chatInProgress else { return }
        guard lastResponseHitMaxTokens else { return }
        lastResponseHitMaxTokens = false
        var o = ChatOverrides()
        o.systemPrompt = activeSystemPrompt
        sendChat("Please continue from exactly where you left off.", overrides: o)
    }

    /// Adjust the chat font scale. Clamped to [0.75, 2.0]. Persists.
    func adjustChatFontScale(by delta: Double) {
        let next = max(0.75, min(2.0, chatFontScale + delta))
        chatFontScale = next
        UserDefaults.standard.set(next, forKey: "mlxpilot.chatFontScale")
    }

    /// Delete a single message from the active conversation.
    func deleteMessage(_ id: UUID) {
        guard !chatInProgress else { return }
        chatMessages.removeAll { $0.id == id }
        syncActiveConversation()
    }

    /// Wipe all messages in the active conversation but keep the
    /// conversation row itself (title, system prompt, pinned state,
    /// archived flag). Useful for "fresh start" without losing the
    /// thread's identity.
    func clearActiveMessages() {
        guard !chatInProgress else { return }
        chatMessages = []
        syncActiveConversation()
    }

    /// Retry: remove the last error/system message and re-send the most
    /// recent user message with its original attachments. Used by the
    /// "retry" link on error system messages.
    func retryLastFailed() {
        guard !chatInProgress else { return }
        while let last = chatMessages.last, last.role == "system" {
            chatMessages.removeLast()
        }
        guard let lastUser = chatMessages.lastIndex(where: { $0.role == "user" }) else { return }
        let userMsg = chatMessages[lastUser]
        chatMessages.remove(at: lastUser)
        syncActiveConversation()
        var o = ChatOverrides()
        o.attachments = userMsg.attachments
        sendChat(userMsg.content, overrides: o)
    }

    /// Resubmit: strip trailing non-user messages (assistant placeholders
    /// from a hang/kill, system errors, partial replies) and re-send the
    /// most recent user message verbatim. Used by the header "Resubmit"
    /// button so the user doesn't have to retype after a crash.
    func resubmitLast() {
        guard !chatInProgress else { return }
        while let last = chatMessages.last, last.role != "user" {
            chatMessages.removeLast()
        }
        guard let lastUser = chatMessages.lastIndex(where: { $0.role == "user" }) else { return }
        let userMsg = chatMessages[lastUser]
        chatMessages.remove(at: lastUser)
        syncActiveConversation()
        var o = ChatOverrides()
        o.attachments = userMsg.attachments
        sendChat(userMsg.content, overrides: o)
    }

    /// Export a conversation to a user-chosen .md file via NSSavePanel.
    /// Runs on main. Writes headers per message with role + timestamp +
    /// model, preserves content verbatim (markdown from the model is
    /// already markdown). Attachments become "[attachment: …]" stubs.
    func exportConversation(_ id: UUID) {
        guard let conv = conversations.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (conv.title.isEmpty ? "conversation" : conv.title) + ".md"
        panel.title = "Export Conversation"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            let df = ISO8601DateFormatter()
            var out = "# \(conv.title)\n\n"
            out += "_Exported \(df.string(from: Date()))_\n\n---\n\n"
            for m in conv.messages {
                let role: String = {
                    switch m.role {
                    case "user": return "You"
                    case "assistant": return "Assistant"
                    case "system": return "System"
                    default: return m.role.capitalized
                    }
                }()
                let ts = df.string(from: m.timestamp)
                let model = m.model.map { " · \($0)" } ?? ""
                out += "## \(role)\(model)\n_\(ts)_\n\n\(m.content)\n"
                if !m.attachmentSummaries.isEmpty {
                    out += "\n"
                    for a in m.attachmentSummaries { out += "- [attachment: \(a)]\n" }
                }
                out += "\n---\n\n"
            }
            try? out.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Soft delete: flag as archived so it hides from the sidebar, but leave
    /// the file on disk in case the user wants to recover it.
    func archiveConversation(_ id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].archived = true
        conversations[idx].updatedAt = Date()
        saveConversation(conversations[idx])
        if activeConversationID == id {
            if let first = conversations.first(where: { !$0.archived }) {
                selectConversation(first.id)
            } else {
                newConversation()
            }
        }
    }

    struct ChatOverrides {
        var systemPrompt: String = ""
        var temperature: Double? = nil
        var topP: Double? = nil
        var topK: Int? = nil
        var maxTokens: Int? = nil
        var thinkingEnabled: Bool = true
        var attachments: [Attachment] = []
        /// If set, bypass the GUI-owned chat engine and route this message
        /// through the router at :8000 with the given alias (e.g. "coder",
        /// "vision"). Triggers router-side hot-swap if the alias isn't
        /// currently loaded. One-shot — cleared by caller after send.
        var routeThroughRouterAlias: String? = nil
    }

    /// Check if `text` starts with a slash command. If so, handle it
    /// (fetch URL / search web) and return:
    ///   - nil         → not a slash command, caller proceeds normally
    ///   - Optional(nil) → recognized as slash, handled async,
    ///                     caller should NOT re-send the raw text
    ///   - Optional(String) → recognized, rewritten text to re-send
    /// We use nested Optional so we can distinguish "not a command" from
    /// "command processed, awaiting async network, caller returns".
    func handleSlashCommand(_ text: String, overrides: ChatOverrides) -> String??  {
        // /help — list every slash command in one place.
        if text == "/help" || text == "/?" {
            let help = """
            Slash commands:
              /fetch <url>         download a web page and ask the model about it
              /search <query>      DuckDuckGo top 5 results inlined as context
              /remember <text>     save a memory (flags: --pin, --ttl <days>, --title <t>)
              /forget <pattern>    delete memories whose title contains <pattern>
              /memory              preview what memories would inject on the next send
              /help                this list

            Tips:
              ↩  send · ⇧↩  newline · ⌘+ / ⌘-  font · ⌘↑/⌘↓  recall sent history
              ⌘⇧V  paste image from clipboard · drag files anywhere on the chat pane
            """
            appendChatMessage(ChatMessage(role: "system", content: help,
                model: nil, timestamp: Date()))
            return .some(nil)
        }
        // Memory: /remember <text>  /forget <pattern>  /memory
        if text.hasPrefix("/remember") {
            let raw = String(text.dropFirst("/remember".count))
                .trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else {
                appendChatMessage(ChatMessage(role: "system",
                    content: "usage: /remember <text>  (optional flags: --pin, --ttl <days>, --title <title>)",
                    model: nil, timestamp: Date()))
                return .some(nil)
            }
            // Parse trailing flags off the back of `raw`.
            var pinned = false
            var ttl: Int? = nil
            var titleOverride: String? = nil
            var bodyText = raw
            // Tokenize once and pull off recognised --flag pairs.
            var tokens = bodyText.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            var consumed = Set<Int>()
            var i = 0
            while i < tokens.count {
                if tokens[i] == "--pin" {
                    pinned = true
                    consumed.insert(i)
                } else if tokens[i] == "--ttl", i + 1 < tokens.count, let v = Int(tokens[i + 1]) {
                    ttl = v
                    consumed.insert(i); consumed.insert(i + 1)
                    i += 1
                } else if tokens[i] == "--title", i + 1 < tokens.count {
                    titleOverride = tokens[i + 1]
                    consumed.insert(i); consumed.insert(i + 1)
                    i += 1
                }
                i += 1
            }
            tokens = tokens.enumerated().compactMap { consumed.contains($0.offset) ? nil : $0.element }
            bodyText = tokens.joined(separator: " ")
            let title = titleOverride ?? String(bodyText.prefix(60))
            let id = memoryAddManual(title: title, body: bodyText, type: "manual",
                                     pinned: pinned, ttlDays: ttl)
            let pinStr = pinned ? " · pinned" : ""
            let ttlStr = ttl.map { " · ttl \($0)d" } ?? ""
            appendChatMessage(ChatMessage(role: "system",
                content: "remembered: \"\(title)\"\(pinStr)\(ttlStr)  (id: \(id.uuidString.prefix(8)))",
                model: nil, timestamp: Date()))
            return .some(nil)
        }
        if text.hasPrefix("/forget") {
            let pattern = String(text.dropFirst("/forget".count))
                .trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty else {
                appendChatMessage(ChatMessage(role: "system",
                    content: "usage: /forget <text fragment from a memory's title>",
                    model: nil, timestamp: Date()))
                return .some(nil)
            }
            let n = memoryDeleteMatching(pattern)
            appendChatMessage(ChatMessage(role: "system",
                content: n == 0 ? "no memories matched \"\(pattern)\""
                                 : "forgot \(n) memor\(n == 1 ? "y" : "ies") matching \"\(pattern)\"",
                model: nil, timestamp: Date()))
            return .some(nil)
        }
        if text == "/memory" || text.hasPrefix("/memory ") {
            let count = memoryStore.entries.count
            if count == 0 {
                appendChatMessage(ChatMessage(role: "system",
                    content: "memory is empty.\n• /remember <text> — save explicitly\n• autonomous extractor: \(memoryAutoExtract ? "on" : "off")",
                    model: nil, timestamp: Date()))
                return .some(nil)
            }
            // Preview what would be injected on the next send.
            let (block, used) = memoryStore.selectForInjection(maxTokens: memoryMaxTokensInjected)
            let header = "memory: \(count) entries on disk · \(used.count) would inject (~\(used.reduce(0) { $0 + $1.estimatedTokens }) tok)\n"
            let body = block.isEmpty ? "(nothing fits the current token budget)" : block
            appendChatMessage(ChatMessage(role: "system",
                content: header + body, model: nil, timestamp: Date()))
            return .some(nil)
        }
        if text.hasPrefix("/fetch ") {
            let url = String(text.dropFirst("/fetch ".count)).trimmingCharacters(in: .whitespaces)
            guard let u = URL(string: url), u.scheme == "http" || u.scheme == "https" else {
                appendChatMessage(ChatMessage(role: "system",
                    content: "usage: /fetch <http(s)://url>", model: nil, timestamp: Date()))
                return .some(nil)
            }
            appendChatMessage(ChatMessage(role: "system",
                content: "fetching \(url)…", model: nil, timestamp: Date()))
            URLSession.shared.dataTask(with: u) { [weak self] data, resp, err in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let err = err {
                        self.appendChatMessage(ChatMessage(role: "system",
                            content: "/fetch error: \(err.localizedDescription)",
                            model: nil, timestamp: Date()))
                        return
                    }
                    guard let data = data,
                          let body = String(data: data, encoding: .utf8) else {
                        self.appendChatMessage(ChatMessage(role: "system",
                            content: "/fetch: non-text or empty response",
                            model: nil, timestamp: Date()))
                        return
                    }
                    let plain = Self.stripHTML(body)
                    let capped = plain.count > 20000 ? String(plain.prefix(20000)) + "\n…[truncated]" : plain
                    let wrapped = "<fetched url=\"\(url)\">\n\(capped)\n</fetched>\n\nPlease summarize / answer based on the above."
                    self.sendChat(wrapped, overrides: overrides)
                }
            }.resume()
            return .some(nil)
        }
        if text.hasPrefix("/search ") {
            let query = String(text.dropFirst("/search ".count)).trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else {
                appendChatMessage(ChatMessage(role: "system",
                    content: "usage: /search <query>", model: nil, timestamp: Date()))
                return .some(nil)
            }
            // DuckDuckGo HTML endpoint — zero install, zero API key.
            // Parses the HTML result page for anchor links and snippets.
            // If DDG changes their markup this will break; fallback is
            // to /fetch a URL manually or switch to ddgr.
            let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            guard let u = URL(string: "https://html.duckduckgo.com/html/?q=\(q)") else {
                appendChatMessage(ChatMessage(role: "system",
                    content: "/search: bad query", model: nil, timestamp: Date()))
                return .some(nil)
            }
            var req = URLRequest(url: u, timeoutInterval: 15.0)
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
            appendChatMessage(ChatMessage(role: "system",
                content: "searching: \(query)…", model: nil, timestamp: Date()))
            URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let err = err {
                        self.appendChatMessage(ChatMessage(role: "system",
                            content: "/search error: \(err.localizedDescription)",
                            model: nil, timestamp: Date()))
                        return
                    }
                    guard let data = data,
                          let html = String(data: data, encoding: .utf8) else {
                        self.appendChatMessage(ChatMessage(role: "system",
                            content: "/search: empty response", model: nil, timestamp: Date()))
                        return
                    }
                    let results = Self.parseDuckDuckGoHTML(html, max: 5)
                    if results.isEmpty {
                        self.appendChatMessage(ChatMessage(role: "system",
                            content: "/search: no results (DDG markup may have changed)",
                            model: nil, timestamp: Date()))
                        return
                    }
                    var lines: [String] = []
                    for (i, r) in results.enumerated() {
                        lines.append("[\(i+1)] \(r.title) — \(r.url)\n    \(r.snippet)")
                    }
                    let wrapped = "<search query=\"\(query)\">\n" + lines.joined(separator: "\n") +
                                  "\n</search>\n\nPlease answer based on these search results."
                    self.sendChat(wrapped, overrides: overrides)
                }
            }.resume()
            return .some(nil)
        }
        return nil
    }

    /// Parse DuckDuckGo HTML result page for (title, url, snippet) tuples.
    /// Uses two regexes over the full body to extract anchor-class result
    /// links and their snippet blocks, then pairs them in document order.
    private static func parseDuckDuckGoHTML(_ html: String, max: Int) -> [(title: String, url: String, snippet: String)] {
        let linkPattern = "<a[^>]+class=\"[^\"]*result__a[^\"]*\"[^>]+href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>"
        let snippetPattern = "<a[^>]+class=\"[^\"]*result__snippet[^\"]*\"[^>]*>([\\s\\S]*?)</a>"
        var links: [(String, String)] = []
        var snippets: [String] = []
        let ns = html as NSString
        if let re = try? NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive]) {
            let range = NSRange(location: 0, length: ns.length)
            re.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
                guard let m = match, m.numberOfRanges >= 3 else { return }
                var url = ns.substring(with: m.range(at: 1))
                let title = Self.stripHTML(ns.substring(with: m.range(at: 2)))
                // DDG wraps real URLs in /l/?uddg=<encoded>&rut=...
                // Decode the uddg param back to the real URL.
                if url.hasPrefix("//duckduckgo.com/l/") || url.hasPrefix("/l/") {
                    if let r = url.range(of: "uddg=") {
                        var tail = String(url[r.upperBound...])
                        if let amp = tail.firstIndex(of: "&") { tail = String(tail[..<amp]) }
                        if let dec = tail.removingPercentEncoding { url = dec }
                    }
                }
                if url.hasPrefix("//") { url = "https:" + url }
                links.append((title, url))
            }
        }
        if let re = try? NSRegularExpression(pattern: snippetPattern, options: [.caseInsensitive]) {
            let range = NSRange(location: 0, length: ns.length)
            re.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
                guard let m = match, m.numberOfRanges >= 2 else { return }
                snippets.append(Self.stripHTML(ns.substring(with: m.range(at: 1))))
            }
        }
        var out: [(title: String, url: String, snippet: String)] = []
        for i in 0..<min(links.count, max) {
            let snip = i < snippets.count ? snippets[i] : ""
            out.append((title: links[i].0, url: links[i].1, snippet: snip))
        }
        return out
    }

    private static func stripHTML(_ html: String) -> String {
        var s = html
        // Remove scripts and styles entirely
        s = s.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>",
                                    with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>",
                                    with: "", options: .regularExpression)
        // Strip tags
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode common entities
        let entities: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
        ]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        // Collapse whitespace
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func sendChat(_ userText: String, systemPrompt: String, attachments: [Attachment]) {
        var overrides = ChatOverrides()
        overrides.systemPrompt = systemPrompt
        overrides.attachments = attachments
        sendChat(userText, overrides: overrides)
    }

    func sendChat(_ userText: String, overrides: ChatOverrides = ChatOverrides()) {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSystem = overrides.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !overrides.attachments.isEmpty else { return }
        // Slash-command preprocessing: /fetch and /search fetch internet
        // content and then continue the normal chat with the result baked
        // into the user message. The model itself never touches the net.
        if let rewritten = handleSlashCommand(trimmed, overrides: overrides) {
            if let rewritten = rewritten {
                var o = overrides
                o.systemPrompt = trimmedSystem
                sendChat(rewritten, overrides: o)
            }
            return
        }
        guard let cfg = config else { return }

        // Two routing modes:
        //  - routerMode: override alias set → POST directly to the router
        //    at :8000, let it resolve the alias and hot-swap as needed.
        //    Used by the per-message model picker.
        //  - direct mode: no override → POST to the current GUI-owned
        //    engine's backend port (existing behavior).
        let routerMode = overrides.routeThroughRouterAlias != nil
        let routerAlias = overrides.routeThroughRouterAlias ?? ""
        let engineHandle: EngineHandle? = routerMode ? nil : chatEngine()
        if !routerMode && engineHandle == nil {
            appendChatMessage(ChatMessage(role: "system", content: "No model is ready. Start one in the right panel first, or pick a model from the dropdown.", model: nil, timestamp: Date()))
            return
        }
        let displayModelName = routerMode ? routerAlias : (engineHandle?.model ?? "")
        let targetURLString = routerMode
            ? "http://127.0.0.1:8000/v1/chat/completions"
            : "http://127.0.0.1:\(engineHandle!.port)/v1/chat/completions"

        // In direct mode, validate attachment modalities against what
        // the current engine actually supports. In router mode we skip
        // this — the router will 404/error if the alias can't handle it.
        if !routerMode, let h = engineHandle, let modelCfg = cfg.models[h.model] {
            let modelModalities = Set(modelCfg.modalities ?? [])
            let needed = Set(overrides.attachments.map { $0.requiresModality })
            let missing = needed.subtracting(modelModalities)
            if !missing.isEmpty {
                appendChatMessage(ChatMessage(
                    role: "system",
                    content: "\(h.model) doesn't support: \(missing.sorted().joined(separator: ", ")). Eject and start a model that supports it.",
                    model: h.model, timestamp: Date()))
                return
            }
        }
        let modelCfg: ModelConfig? = routerMode ? nil : cfg.models[engineHandle!.model]

        // Append user message immediately (with attachments if any).
        let userMsg = ChatMessage(role: "user", content: trimmed, attachments: overrides.attachments,
                                  model: nil, timestamp: Date())
        appendChatMessage(userMsg)
        chatInProgress = true

        // Push to send history (dedupe consecutive, cap length).
        if !trimmed.isEmpty && sentHistory.last != trimmed {
            sentHistory.append(trimmed)
            if sentHistory.count > sentHistoryCap {
                sentHistory.removeFirst(sentHistory.count - sentHistoryCap)
            }
        }

        // Build the request message list. The Qwen3.6 family supports
        // chat_template_kwargs.enable_thinking (off by default for the
        // qwen35 alias, on for thinker/deep/thinker27).
        let effectiveModelName = displayModelName
        let isQwenThinker = effectiveModelName.contains("Qwen3.6")
            || routerAlias == "qwen35" || routerAlias == "thinker"
            || routerAlias == "deep"   || routerAlias == "thinker27"
            || routerAlias == "qwen27"
        // Build the system message: persistent memory block (if any) +
        // user's per-conversation system prompt. Memory block is empty
        // when memory.enabled = false or the store is empty.
        let memoryBlock = buildMemoryInjection()
        let systemContent: String
        if memoryBlock.isEmpty {
            systemContent = trimmedSystem
        } else if trimmedSystem.isEmpty {
            systemContent = memoryBlock
        } else {
            systemContent = "\(trimmedSystem)\n\n\(memoryBlock)"
        }
        var messages: [[String: Any]] = []
        if !systemContent.isEmpty {
            messages.append(["role": "system", "content": systemContent])
        }
        // Prior history as plain text (we don't re-send historical images).
        for m in chatMessages.dropLast() where m.role == "user" || m.role == "assistant" {
            messages.append(["role": m.role, "content": m.content])
        }
        // Current user turn — multipart if attachments present, plain text otherwise.
        if !overrides.attachments.isEmpty {
            var parts: [[String: Any]] = []
            if !trimmed.isEmpty {
                parts.append(["type": "text", "text": trimmed])
            }
            for att in overrides.attachments {
                switch att.kind {
                case .image(let data):
                    let b64 = data.base64EncodedString()
                    parts.append(["type": "image_url",
                                  "image_url": ["url": "data:image/png;base64,\(b64)"]])
                case .video(let data, let mime):
                    let b64 = data.base64EncodedString()
                    parts.append(["type": "video_url",
                                  "video_url": ["url": "data:\(mime);base64,\(b64)"]])
                case .pdfPages(let pages):
                    for page in pages {
                        let b64 = page.base64EncodedString()
                        parts.append(["type": "image_url",
                                      "image_url": ["url": "data:image/png;base64,\(b64)"]])
                    }
                case .text(let body):
                    // Inline the text as a labeled block in the prompt so
                    // the model knows it's an attached file / folder / doc.
                    let block = "<attached name=\"\(att.displayName)\">\n\(body)\n</attached>"
                    parts.append(["type": "text", "text": block])
                }
            }
            messages.append(["role": "user", "content": parts])
        } else {
            messages.append(["role": "user", "content": trimmed])
        }

        // Payload "model" field: in direct mode, the full on-disk path
        // (what mlx_lm/mlx_vlm backend expects). In router mode, the
        // alias — the router will resolve it and rewrite the field.
        let modelField: String
        if routerMode {
            modelField = routerAlias
        } else if let h = engineHandle {
            modelField = (cfg.control.models_dir as NSString).appendingPathComponent(h.model)
        } else {
            modelField = ""
        }
        var payload: [String: Any] = [
            "model": modelField,
            "messages": messages,
            "stream": false
        ]
        // Apply user overrides first; then fall back to model card defaults; then absolute defaults.
        let rd = modelCfg?.request_defaults
        payload["temperature"]        = overrides.temperature ?? rd?.temperature ?? 1.0
        payload["top_p"]              = overrides.topP        ?? rd?.top_p       ?? 0.95
        payload["top_k"]              = overrides.topK        ?? rd?.top_k       ?? 64
        payload["max_tokens"]         = overrides.maxTokens   ?? rd?.max_tokens  ?? 4096
        if let mp = rd?.min_p              { payload["min_p"] = mp }
        if let rp = rd?.repetition_penalty { payload["repetition_penalty"] = rp }
        if let pp = rd?.presence_penalty   { payload["presence_penalty"] = pp }

        // Qwen3.6 thinking control via chat_template_kwargs.
        if isQwenThinker && !overrides.thinkingEnabled {
            payload["chat_template_kwargs"] = ["enable_thinking": false]
        }

        // Streaming: we set stream:true and consume SSE chunks via a
        // URLSessionDataDelegate. Each delta appends to the last assistant
        // message's content. When the stream ends, we sync the conversation
        // to disk once (not per-chunk — avoids disk thrash).
        payload["stream"] = true
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: targetURLString) else {
            chatInProgress = false
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 600.0)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = body

        let respondingModel = displayModelName
        // Placeholder assistant message — we'll mutate its content as
        // chunks arrive. Empty string until the first delta lands.
        let placeholder = ChatMessage(role: "assistant", content: "",
                                       model: respondingModel, timestamp: Date())
        chatMessages.append(placeholder)

        // Streaming throttle state: tokens are buffered in `streamPendingDelta`
        // and flushed to the UI at most every 30ms. Prevents SwiftUI flicker
        // on fast models (qwen35 turbo) without slowing anything down.
        streamPendingDelta = ""
        streamFlushScheduled = false
        streamTokenCount = 0
        lastResponseHitMaxTokens = false
        let delegate = ChatStreamDelegate(
            onChunk: { [weak self] delta in
                guard let self else { return }
                self.streamPendingDelta += delta
                self.streamTokenCount += 1
                // #5: auto-save every 100 tokens so a crash loses at most
                // 100 tokens of a long streaming response, not the whole reply.
                if self.streamTokenCount % 100 == 0 {
                    self.flushStreamBuffer()
                    self.syncActiveConversation()
                    return
                }
                if !self.streamFlushScheduled {
                    self.streamFlushScheduled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.030) { [weak self] in
                        self?.flushStreamBuffer()
                    }
                }
            },
            onDone: { [weak self] finishReason in
                guard let self else { return }
                self.flushStreamBuffer()
                // Surface Continue button if the backend said finish_reason=length.
                if finishReason == "length" {
                    self.lastResponseHitMaxTokens = true
                }
                if let i = self.chatMessages.indices.last,
                   self.chatMessages[i].content.isEmpty {
                    // Empty body — replace with a placeholder so the UI
                    // doesn't show an empty bubble.
                    var m = self.chatMessages[i]
                    m = ChatMessage(role: m.role, content: "(empty response)",
                                    attachments: m.attachments,
                                    model: m.model, timestamp: m.timestamp)
                    self.chatMessages[i] = m
                }
                self.chatInProgress = false
                self.currentChatTask = nil
                self.syncActiveConversation()
                // Fire the autonomous memory extractor on the just-completed
                // turn. Async + best-effort — never blocks the chat loop.
                DispatchQueue.main.async { [weak self] in
                    self?.memoryExtractFromLastTurn()
                }
            },
            onError: { [weak self] errStr in
                guard let self else { return }
                self.flushStreamBuffer()
                // If we already streamed partial content, keep it and
                // append an [error] suffix. Otherwise replace the
                // placeholder with a system error message.
                if let i = self.chatMessages.indices.last {
                    let m = self.chatMessages[i]
                    if m.content.isEmpty {
                        self.chatMessages[i] = ChatMessage(
                            role: "system",
                            content: "error: \(errStr)",
                            attachments: m.attachments,
                            model: m.model, timestamp: m.timestamp
                        )
                    } else {
                        self.chatMessages[i] = ChatMessage(
                            role: m.role,
                            content: m.content + "\n\n[error: \(errStr)]",
                            attachments: m.attachments,
                            model: m.model, timestamp: m.timestamp
                        )
                    }
                }
                self.chatInProgress = false
                self.currentChatTask = nil
                self.syncActiveConversation()
            }
        )
        let session = URLSession(configuration: .default, delegate: delegate,
                                 delegateQueue: OperationQueue.main)
        let task = session.dataTask(with: req)
        currentChatSession = session
        currentChatTask = task
        task.resume()
    }

    /// Cancels the in-flight chat task if any. Delegate's didComplete
    /// handler flips chatInProgress off and syncs the partial.
    func stopGeneration() {
        currentChatTask?.cancel()
        currentChatTask = nil
        // The delegate's onError path will finalize the UI state since
        // cancel() produces a didCompleteWithError with code .cancelled.
    }

    /// Replace a user message's content and resend. Removes the message
    /// and everything after it (assistant replies, further turns), then
    /// calls sendChat with the new text and the original attachments.
    /// Attachments survive only within the current session — reloaded
    /// conversations have empty attachments and edit still works for
    /// text-only messages.
    func editAndResend(messageID: UUID, newContent: String) {
        guard !chatInProgress else { return }
        guard let idx = chatMessages.firstIndex(where: { $0.id == messageID }) else { return }
        guard chatMessages[idx].role == "user" else { return }
        let original = chatMessages[idx]
        chatMessages.removeSubrange(idx..<chatMessages.count)
        syncActiveConversation()
        var o = ChatOverrides()
        o.attachments = original.attachments
        sendChat(newContent, overrides: o)
    }

    /// Drop the last assistant message and resend the previous user
    /// message with the same attachments (if still in memory). Only
    /// works while the session is live — reloaded conversations lose
    /// raw attachment bytes.
    func regenerateLast() {
        guard !chatInProgress else { return }
        // Find the last assistant message, then the preceding user message.
        guard let lastAssistant = chatMessages.lastIndex(where: { $0.role == "assistant" }) else {
            return
        }
        // Remove the assistant + any trailing system noise after it.
        chatMessages.removeSubrange(lastAssistant..<chatMessages.count)
        // Find the user message to resend.
        guard let lastUser = chatMessages.lastIndex(where: { $0.role == "user" }) else {
            return
        }
        let userMsg = chatMessages[lastUser]
        // Remove the old user message too — sendChat will re-append it.
        chatMessages.remove(at: lastUser)
        syncActiveConversation()
        var o = ChatOverrides()
        o.attachments = userMsg.attachments
        sendChat(userMsg.content, overrides: o)
    }
}

/// Simple SSE parser for mlx_lm/mlx_vlm streaming chat completions.
/// Buffers bytes, splits on \n, extracts `data: {...}` lines, decodes
/// `choices[0].delta.content`, and calls onChunk per content delta.
/// Calls onDone on clean end (`data: [DONE]` or stream close) and
/// onError if the URLSession reports a non-cancel failure.
final class ChatStreamDelegate: NSObject, URLSessionDataDelegate {
    let onChunk: (String) -> Void
    let onDone: (String?) -> Void
    let onError: (String) -> Void
    private var buffer = Data()
    private var ended = false

    init(onChunk: @escaping (String) -> Void,
         onDone: @escaping (String?) -> Void,
         onError: @escaping (String) -> Void) {
        self.onChunk = onChunk
        self.onDone = onDone
        self.onError = onError
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        buffer.append(data)
        processBuffer()
    }

    private func processBuffer() {
        while let nlIdx = buffer.firstIndex(of: 0x0A) {  // '\n'
            let line = buffer.subdata(in: buffer.startIndex..<nlIdx)
            buffer.removeSubrange(buffer.startIndex...nlIdx)
            guard let s = String(data: line, encoding: .utf8) else { continue }
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                ended = true
                continue
            }
            guard let pdata = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any]
            else { continue }
            if let choices = obj["choices"] as? [[String: Any]],
               let first = choices.first {
                // Prefer delta.content (streaming); fall back to message.content.
                if let delta = first["delta"] as? [String: Any],
                   let c = delta["content"] as? String, !c.isEmpty {
                    onChunk(c)
                } else if let msg = first["message"] as? [String: Any],
                          let c = msg["content"] as? String, !c.isEmpty {
                    onChunk(c)
                }
                if let reason = first["finish_reason"] as? String, !reason.isEmpty {
                    lastFinishReason = reason
                }
            }
        }
    }

    /// Set to `.length` when we observe finish_reason=length in any SSE
    /// choice. The controller reads this in onDone to decide whether to
    /// surface a "Continue" button.
    var lastFinishReason: String?

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // Drain any remaining buffered bytes.
        processBuffer()
        defer { session.invalidateAndCancel() }
        if let err = error as NSError? {
            if err.code == NSURLErrorCancelled {
                onDone(lastFinishReason)
                return
            }
            onError(err.localizedDescription)
            return
        }
        onDone(lastFinishReason)
    }
}

// MARK: - AppDelegate (status bar + menu + lazy NSWindow)

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem?
    var menu: NSMenu?
    var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Force-instantiate the controller so loadConfig + auto_start_models fire on launch.
        _ = PilotController.shared

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "airplane", accessibilityDescription: "MLX Pilot")
            // NOT a template: we want to tint the icon green when loaded.
            image?.isTemplate = false
            button.image = image
            button.contentTintColor = NSColor.secondaryLabelColor
        }
        let m = NSMenu()
        m.delegate = self
        m.autoenablesItems = false
        item.menu = m
        self.statusItem = item
        self.menu = m

        // Paint the icon tint based on model-loaded state. Runs on the
        // 5s pollTick cadence from PilotController (which calls
        // AppDelegate.refreshStatusBarIcon() at the end of each tick).
        refreshStatusBarIcon()
    }

    /// Tint the menu bar airplane green if any model is loaded (GUI-owned
    /// or router-owned), otherwise fall back to secondary-label gray.
    /// Called every poll tick.
    func refreshStatusBarIcon() {
        guard let button = statusItem?.button else { return }
        let pilot = PilotController.shared
        let hasGUI = pilot.liveEngines.contains(where: { $0.state == .ready })
        let hasRouter = !pilot.externalBackends.isEmpty
        let anyLoaded = hasGUI || hasRouter
        button.contentTintColor = anyLoaded
            ? NSColor.systemGreen
            : NSColor.secondaryLabelColor
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let pilot = PilotController.shared
        menu.removeAllItems()

        add(menu, title: "Open Window", action: #selector(openMainWindow))
        menu.addItem(.separator())

        // Live engines header — merges GUI-spawned engines with router-owned
        // external backends so the user sees everything actually loaded.
        let live = pilot.liveEngines
        // External backends show for models where the GUI doesn't own a
        // currently-live engine. A crashed GUI entry does not shadow a
        // live router-owned backend.
        let external = pilot.externalBackends
            .filter { (name, _) in
                guard let h = pilot.engines[name] else { return true }
                return !(h.state == .ready || h.state == .booting || h.state == .stopping)
            }
            .sorted { $0.key < $1.key }
        let totalLoaded = live.count + external.count
        if totalLoaded == 0 {
            addDisabled(menu, "No engines running")
        } else {
            addDisabled(menu, "Loaded models (\(totalLoaded)):")
            for h in live {
                let dot: String
                switch h.state {
                case .ready: dot = "●"
                case .booting: dot = "◐"
                case .stopping: dot = "◑"
                case .crashed: dot = "✕"
                default: dot = "○"
                }
                let ramTxt = h.ramMB.map { "\($0) MB" } ?? "—"
                addDisabled(menu, "  \(dot) \(h.model)  ·  :\(h.port)  ·  \(ramTxt)")
            }
            for (name, port) in external {
                addDisabled(menu, "  ● \(name)  ·  :\(port)  ·  (router)")
            }
        }
        if let err = pilot.configError {
            addDisabled(menu, "⚠︎ \(err)")
        }
        menu.addItem(.separator())

        // Start submenu — every model
        let startItem = NSMenuItem(title: "Start ▸", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for model in pilot.availableModels {
            let isDefault = model == pilot.defaultModel
            let h = pilot.engines[model]
            let prefix: String
            switch h?.state {
            case .ready:    prefix = "● "
            case .booting:  prefix = "◐ "
            case .stopping: prefix = "◑ "
            case .crashed:  prefix = "✕ "
            default:        prefix = "○ "
            }
            let title = "\(prefix)\(model)\(isDefault ? "  (default)" : "")"
            let mi = NSMenuItem(title: title, action: #selector(startModel(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = model
            sub.addItem(mi)
        }
        startItem.submenu = sub
        menu.addItem(startItem)

        // Eject submenu — GUI-owned engines AND router-owned backends.
        let ejectItem = NSMenuItem(title: "Eject ▸", action: nil, keyEquivalent: "")
        let ejectSub = NSMenu()
        if live.isEmpty && external.isEmpty {
            let mi = NSMenuItem(title: "(none loaded)", action: nil, keyEquivalent: "")
            mi.isEnabled = false
            ejectSub.addItem(mi)
        } else {
            for h in live {
                let mi = NSMenuItem(title: "\(h.model) (:\(h.port))",
                                    action: #selector(ejectModelByName(_:)),
                                    keyEquivalent: "")
                mi.target = self
                mi.representedObject = h.model
                ejectSub.addItem(mi)
            }
            for (name, port) in external {
                let mi = NSMenuItem(title: "\(name) (:\(port))  [router]",
                                    action: #selector(ejectExternalByPort(_:)),
                                    keyEquivalent: "")
                mi.target = self
                mi.representedObject = ["model": name, "port": port] as NSDictionary
                ejectSub.addItem(mi)
            }
            let separator = NSMenuItem.separator()
            ejectSub.addItem(separator)
            let allMI = NSMenuItem(title: "Eject All", action: #selector(ejectAll), keyEquivalent: "")
            allMI.target = self
            ejectSub.addItem(allMI)
        }
        ejectItem.submenu = ejectSub
        menu.addItem(ejectItem)

        menu.addItem(.separator())

        add(menu, title: "Open Models Folder", action: #selector(openModelsFolder))
        add(menu, title: "Open Cache Folder", action: #selector(openCacheFolder))
        add(menu, title: "Clear Cache",       action: #selector(clearCache))
        add(menu, title: "Open Logs Folder", action: #selector(openLogsFolder))
        add(menu, title: "Open Config", action: #selector(openConfigFile))
        menu.addItem(.separator())

        add(menu, title: "Clear Logs", action: #selector(clearLogs))
        add(menu, title: "Reload Config", action: #selector(reloadConfig))
        if pilot.lastActionStatus != "—" {
            addDisabled(menu, "  \(pilot.lastActionStatus)")
        }
        menu.addItem(.separator())

        add(menu, title: "Quit", action: #selector(quit))
    }

    @discardableResult
    private func add(_ menu: NSMenu, title: String, action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        menu.addItem(mi)
        return mi
    }

    private func addDisabled(_ menu: NSMenu, _ title: String) {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        menu.addItem(mi)
    }

    @objc func openMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MLX Pilot"
            window.identifier = NSUserInterfaceItemIdentifier("main")
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: ContentView()
                .frame(minWidth: 1020, minHeight: 620))
            window.delegate = self
            window.minSize = NSSize(width: 1020, height: 620)
            mainWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === mainWindow else { return }
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    @objc func startModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String else { return }
        PilotController.shared.startModel(model)
    }
    @objc func ejectModelByName(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String else { return }
        PilotController.shared.ejectModel(model)
    }
    @objc func ejectExternalByPort(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? NSDictionary,
              let name = dict["model"] as? String,
              let port = dict["port"] as? Int else { return }
        PilotController.shared.ejectByPort(port, model: name)
    }
    @objc func ejectAll()         { PilotController.shared.stopAll() }
    @objc func openModelsFolder() { PilotController.shared.openModelsFolder() }
    @objc func openCacheFolder()  { PilotController.shared.openCacheFolder() }
    @objc func clearCache()       { PilotController.shared.clearCacheFolder() }
    @objc func openLogsFolder()   { PilotController.shared.openLogsFolder() }
    @objc func openConfigFile()   { PilotController.shared.openConfigFile() }
    @objc func clearLogs()        { PilotController.shared.clearLogs() }
    @objc func reloadConfig()     { PilotController.shared.loadConfig() }
    @objc func quit()             { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        // Best-effort: tell every spawned mlx server to exit so they don't orphan
        // onto their ports. We can't wait for them — terminate is synchronous.
        for h in PilotController.shared.engines.values {
            if h.process.isRunning { h.process.terminate() }
        }
    }
}

// MARK: - SwiftUI App entry

@main
struct MLXPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - Main window: three-region NavigationSplitView

struct ContentView: View {
    @ObservedObject var pilot = PilotController.shared
    @State private var selectedSidebarItem: SidebarItem = .chat

    enum SidebarItem: String, Hashable, CaseIterable {
        case chat = "Chat"
        case projects = "Projects"
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedSidebarItem)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } content: {
            CenterPaneView()
                .navigationSplitViewColumnWidth(min: 420, ideal: 560)
        } detail: {
            RightPanelView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
        }
        .navigationTitle("MLX Pilot")
    }
}

// MARK: - Left sidebar (scaffold)

struct SidebarView: View {
    @Binding var selection: ContentView.SidebarItem
    @ObservedObject var pilot = PilotController.shared
    @State private var showingRenameAlert = false
    @State private var renameTargetID: UUID? = nil
    @State private var renameDraft = ""
    @State private var deleteTargetID: UUID? = nil
    @State private var showingDeleteConfirm = false
    @FocusState private var searchFocused: Bool

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // New Chat button + search field pinned to the top of the sidebar.
            HStack(spacing: 6) {
                Button {
                    pilot.newConversation()
                    selection = .chat
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("n", modifiers: .command)
                .help("Start a new conversation (⌘N)")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.caption)
                TextField("Search conversations  (⌘F)", text: $pilot.conversationSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($searchFocused)
                    .onSubmit {
                        // Enter in the search field does nothing — keep focus.
                    }
                if !pilot.conversationSearchQuery.isEmpty {
                    Button {
                        pilot.conversationSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
            .background(
                // Cmd+F focuses the search field from anywhere in the
                // sidebar. Invisible button that carries the shortcut.
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.gray.opacity(0.12))
            .cornerRadius(6)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            List(selection: $selection) {
                Section("Conversations") {
                    let visible = pilot.visibleConversations
                    if visible.isEmpty {
                        if pilot.conversationSearchQuery.isEmpty {
                            Text("no conversations yet")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            Text("no matches for \"\(pilot.conversationSearchQuery)\"")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    ForEach(visible) { conv in
                        ConversationRow(
                            conversation: conv,
                            isActive: conv.id == pilot.activeConversationID,
                            matchSnippet: pilot.matchSnippet(for: conv, query: pilot.conversationSearchQuery)
                        )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                pilot.selectConversation(conv.id)
                                selection = .chat
                            }
                            .contextMenu {
                                Button(conv.pinned ? "Unpin" : "Pin") {
                                    pilot.togglePin(conv.id)
                                }
                                Button("Rename…") {
                                    renameTargetID = conv.id
                                    renameDraft = conv.title
                                    showingRenameAlert = true
                                }
                                Button("Export to .md") {
                                    pilot.exportConversation(conv.id)
                                }
                                Button("Archive") {
                                    pilot.archiveConversation(conv.id)
                                }
                                Button("Delete", role: .destructive) {
                                    deleteTargetID = conv.id
                                    showingDeleteConfirm = true
                                }
                            }
                    }
                }
                Section("Projects") {
                    Label("Projects", systemImage: "folder")
                        .tag(ContentView.SidebarItem.projects)
                    Text("(coming later)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Section("Loaded engines") {
                    let routerOnly = pilot.externalBackends
                        .filter { pilot.engines[$0.key] == nil }
                        .sorted { $0.key < $1.key }
                    if pilot.liveEngines.isEmpty && routerOnly.isEmpty {
                        Text("none")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    ForEach(pilot.liveEngines, id: \.id) { h in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(stateColor(h.state))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(h.model)
                                    .font(.caption.bold())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(":\(h.port)  \(h.state.rawValue)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    ForEach(routerOnly, id: \.key) { name, port in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.green)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name)
                                    .font(.caption.bold())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(":\(port)  router")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .alert("Rename conversation", isPresented: $showingRenameAlert, actions: {
            TextField("Title", text: $renameDraft)
            Button("Save") {
                if let id = renameTargetID {
                    pilot.renameConversation(id, to: renameDraft)
                }
                renameTargetID = nil
                renameDraft = ""
            }
            Button("Cancel", role: .cancel) {
                renameTargetID = nil
                renameDraft = ""
            }
        })
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = deleteTargetID {
                    pilot.deleteConversation(id)
                }
                deleteTargetID = nil
            }
            Button("Cancel", role: .cancel) {
                deleteTargetID = nil
            }
        } message: {
            Text("This cannot be undone. Use Archive instead to hide without deleting.")
        }
    }

    private func stateColor(_ s: EngineState) -> Color {
        switch s {
        case .ready: return .green
        case .booting: return .orange
        case .stopping: return .yellow
        case .crashed: return .red
        case .stopped: return .gray
        }
    }
}

// Sidebar row for a single persisted conversation. Highlights when active.
// Shows title, relative update time, message count, last model used, and
// (if a search is active) a snippet of the first matching text in body.
struct ConversationRow: View {
    let conversation: Conversation
    let isActive: Bool
    let matchSnippet: String?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var lastModel: String? {
        for m in conversation.messages.reversed() where m.model != nil {
            return m.model
        }
        return nil
    }

    private var shortModel: String? {
        guard let m = lastModel else { return nil }
        // Trim a long model name for the sidebar row.
        let lower = m.lowercased()
        if lower.contains("qwen3.6-27b") { return "deep" }
        if lower.contains("qwen3.6")     { return "qwen36" }
        return String(m.prefix(16))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: conversation.archived
                  ? "archivebox"
                  : (isActive ? "bubble.left.fill" : "bubble.left"))
                .foregroundColor(isActive ? .accentColor : .secondary)
                .font(.caption)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if conversation.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    Text(conversation.title.isEmpty ? "Untitled" : conversation.title)
                        .font(.caption.bold())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 4) {
                    Text(Self.relativeFormatter.localizedString(for: conversation.updatedAt, relativeTo: Date()))
                    Text("·")
                    Text("\(conversation.messages.count) msg")
                    if let m = shortModel {
                        Text("·")
                        Text(m)
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                if let snip = matchSnippet {
                    Text(snip)
                        .font(.caption2)
                        .italic()
                        .foregroundColor(.accentColor)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Center pane (working chat with image drop + editable system prompt)

struct CenterPaneView: View {
    @ObservedObject var pilot = PilotController.shared
    @State private var inputText: String = ""
    // Local state mirrors pilot.activeSystemPrompt for TextField binding.
    // Kept in sync via .onAppear and .onChange below so per-conversation
    // system prompts load correctly when switching threads.
    @State private var systemPrompt: String = ""
    @State private var attachments: [Attachment] = []
    @State private var dropTargeted: Bool = false
    @State private var systemPromptExpanded: Bool = false
    /// One-shot model override for the next send. Empty string = use
    /// whichever model the current chatEngine() returns. Reset to ""
    /// after the send goes out.
    // overrideModelAlias removed — chat lane now lives on PilotController.selectedChatAlias.
    // Dropdown binds to pilot.selectedChatAlias directly; right-panel Start updates it.
    @State private var historyCursor: Int = -1  // -1 = not navigating
    @FocusState private var inputFocused: Bool

    // Lightweight caps so attachments don't blow up the request payload.
    private static let maxImageEdge: CGFloat = 1568
    private static let maxPDFPages = 20
    private static let pdfRenderScale: CGFloat = 2.0   // ~144 DPI
    private static let maxVideoBytes = 50 * 1024 * 1024

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("Chat").font(.title2).bold()
                Spacer()
                if let h = pilot.chatEngine() {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("→ \(h.model)  :\(h.port)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if pilot.liveEngines.isEmpty {
                    Text("no model running — start one in the right panel")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("model still booting…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                contextChip
                Button("Resubmit") { pilot.resubmitLast() }
                    .controlSize(.small)
                    .disabled(pilot.chatInProgress
                              || !pilot.chatMessages.contains(where: { $0.role == "user" }))
                    .help("Re-send the last user message. Strips any trailing assistant placeholder or system error first — useful after a hang or kill.")
                Button("Clear") { pilot.clearChat() }
                    .controlSize(.small)
                    .disabled(pilot.chatMessages.isEmpty)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 6)

            // Memory chip: shows what was injected on the last send. Empty
            // when memory is off, store is empty, or nothing fit the budget.
            if pilot.memoryEnabled && !pilot.lastInjectedMemoryIDs.isEmpty {
                HStack(spacing: 6) {
                    Text("🧠 \(pilot.lastInjectedMemoryIDs.count) memor\(pilot.lastInjectedMemoryIDs.count == 1 ? "y" : "ies") loaded · ~\(pilot.lastInjectedMemoryTokens) tok")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if pilot.memoryStatus != "idle" {
                        Text("· \(pilot.memoryStatus)")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if pilot.chatMessages.isEmpty {
                            Text("Type a message below to chat with the running model. Drop an image (or screenshot) onto the input area to send it. Open the system prompt section to set a custom voice.")
                                .font(.callout)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 16)
                        }
                        ForEach(pilot.chatMessages) { msg in
                            ChatBubble(message: msg)
                                .id(msg.id)
                        }
                        if pilot.chatInProgress {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("generating…")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 6)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: pilot.chatMessages.count) { _ in
                    if let last = pilot.chatMessages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                // Auto-scroll during streaming: streamTokenCount ticks on
                // every delta from the SSE delegate. Scrolling to .bottom
                // without animation avoids jank on fast models.
                .onChange(of: pilot.streamTokenCount) { _ in
                    if let last = pilot.chatMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            // System prompt (collapsible)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        systemPromptExpanded.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: systemPromptExpanded ? "chevron.down" : "chevron.right")
                            Text("System prompt")
                                .font(.caption.bold())
                            if !systemPrompt.isEmpty && !systemPromptExpanded {
                                Text("(\(systemPrompt.count) chars)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    if systemPromptExpanded && !systemPrompt.isEmpty {
                        Button("Clear") { systemPrompt = "" }
                            .controlSize(.mini)
                    }
                }
                if systemPromptExpanded {
                    TextField("Describe how the assistant should respond. Empty = use the model's default voice.",
                              text: $systemPrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .font(.caption)
                        .onChange(of: systemPrompt) { newValue in
                            // Write-through to the controller so it persists
                            // on the next syncActiveConversation call.
                            pilot.activeSystemPrompt = newValue
                        }
                }
            }
            .onAppear {
                systemPrompt = pilot.activeSystemPrompt
            }
            .onChange(of: pilot.activeConversationID) { _ in
                // Reload local state when user switches conversations.
                systemPrompt = pilot.activeSystemPrompt
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // Attachment chips
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { att in
                            AttachmentChip(attachment: att) {
                                attachments.removeAll { $0.id == att.id }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }

            // Continue banner — appears when the last response hit
            // max_tokens so the user can one-click ask the model to
            // keep going without manually typing "please continue".
            if pilot.lastResponseHitMaxTokens && !pilot.chatInProgress {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle")
                        .foregroundColor(.orange)
                    Text("Response was cut off at max_tokens")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Continue") { pilot.continueResponse() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    Button {
                        pilot.lastResponseHitMaxTokens = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(8)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(6)
                .padding(.horizontal, 12)
                .padding(.top, 4)
            }

            // Input area (drop target)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Type a message…  (↩ to send · ⇧↩ for newline · drop files/folders to attach)",
                              text: $inputText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...6)
                        .onSubmit { sendIfReady() }
                    // Prompt template picker. Click → pick a template,
                    // body is prepended to the input text. Templates are
                    // stored at ~/.mlxlm/templates/*.md (seeded with
                    // summarize/explain-code/refactor on first launch).
                    Menu {
                        Section("Slash commands") {
                            Button("/fetch <url>  —  download + inline a web page") {
                                inputText = "/fetch "
                            }
                            Button("/search <query>  —  DuckDuckGo top 5 as context") {
                                inputText = "/search "
                            }
                            Button("/remember <text>  —  save explicit memory") {
                                inputText = "/remember "
                            }
                            Button("/forget <pattern>  —  delete memories by title") {
                                inputText = "/forget "
                            }
                            Button("/memory  —  show what would be injected next send") {
                                inputText = "/memory"
                            }
                            Button("/help  —  list all commands and shortcuts") {
                                inputText = "/help"
                            }
                        }
                        Section("Prompt templates") {
                            let templates = pilot.listTemplates()
                            if templates.isEmpty {
                                Text("(no templates)")
                            } else {
                                ForEach(Array(templates.enumerated()), id: \.offset) { _, t in
                                    Button(t.name) {
                                        if inputText.isEmpty {
                                            inputText = t.body
                                        } else {
                                            inputText = t.body + "\n" + inputText
                                        }
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Open templates folder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: pilot.templatesDir))
                        }
                    } label: {
                        Image(systemName: "square.stack.3d.up")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 30)
                    .help("Insert a slash command or template")
                    // Two-lane chat picker. Bound to pilot.selectedChatAlias
                    // so right-panel Start, dropdown selection, and chat
                    // sends all share one source of truth. "auto" was
                    // removed — it caused ambiguity with right-panel
                    // Start. Selection is sticky across sends and across
                    // new chats; only changes when the user changes it
                    // (or when right-panel Start auto-binds the lane).
                    Picker("", selection: $pilot.selectedChatAlias) {
                        Text("qwen35 (35B primary)").tag("qwen35")
                        Text("deep (27B reasoning)").tag("deep")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .help("Override model for the next message (auto = current engine)")
                    if pilot.chatInProgress {
                        Button("Stop") { pilot.stopGeneration() }
                            .keyboardShortcut(".", modifiers: .command)
                            .foregroundColor(.red)
                    } else {
                        Button("Send") { sendIfReady() }
                            .keyboardShortcut(.return, modifiers: [])
                            .disabled(
                                inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
                            )
                    }
                }
                HStack {
                    Text(pilot.lastActionStatus)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text("~\(estimatedTokens()) tok")
                        .font(.caption2)
                        .foregroundColor({
                            let cap = pilot.routerMaxInputTokens ?? 60000
                            let warn = Int(Double(cap) * 0.9)
                            if estimatedTokens() > cap { return .red }
                            if estimatedTokens() > warn { return .orange }
                            return .secondary
                        }())
                        .help({
                            if let cap = pilot.routerMaxInputTokens {
                                return "Estimated input tokens (router trims at \(cap / 1000)K)"
                            }
                            return "Estimated input tokens (router cap unknown)"
                        }())
                }
            }
            .padding(12)
            .background(dropTargeted ? Color.blue.opacity(0.08) : Color.clear)
            .onDrop(of: [UTType.image, UTType.movie, UTType.pdf, UTType.audio, UTType.fileURL], isTargeted: $dropTargeted) { providers in
                handleDrop(providers)
            }
            // Hidden Cmd+E shortcut: ejects whichever model is currently
            // handling chat (GUI-owned first, else first router-owned).
            .background(
                Button("") {
                    if let h = pilot.chatEngine() {
                        pilot.ejectModel(h.model)
                    } else if let first = pilot.externalBackends.first {
                        pilot.ejectByPort(first.value, model: first.key)
                    }
                }
                .keyboardShortcut("e", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
            )
            // Cmd+Shift+V: paste an image from the clipboard as an
            // attachment. Uses Shift to avoid hijacking normal Cmd+V
            // text paste inside the focused TextField.
            .background(
                Button("") { pasteFromClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .opacity(0)
                    .frame(width: 0, height: 0)
            )
            // ⌘↑ / ⌘↓ recall previous / next sent message from history.
            // Cursor -1 = not navigating (at the live draft). 0..N-1 =
            // walking through sentHistory from the most recent backward.
            .background(
                HStack {
                    Button("") { recallHistory(direction: -1) }
                        .keyboardShortcut(.upArrow, modifiers: .command)
                    Button("") { recallHistory(direction: 1) }
                        .keyboardShortcut(.downArrow, modifiers: .command)
                }
                .opacity(0)
                .frame(width: 0, height: 0)
            )
            // ⌘+ / ⌘- chat font zoom, ⌘0 reset, ⇧⌘E export current.
            .background(
                HStack {
                    Button("") { pilot.adjustChatFontScale(by: 0.1) }
                        .keyboardShortcut("=", modifiers: .command)   // Cmd+= (aka Cmd++)
                    Button("") { pilot.adjustChatFontScale(by: -0.1) }
                        .keyboardShortcut("-", modifiers: .command)
                    Button("") { pilot.chatFontScale = 1.0
                                 UserDefaults.standard.set(1.0, forKey: "mlxpilot.chatFontScale") }
                        .keyboardShortcut("0", modifiers: .command)
                    Button("") {
                        if let id = pilot.activeConversationID {
                            pilot.exportConversation(id)
                        }
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                }
                .opacity(0)
                .frame(width: 0, height: 0)
            )
        }
        // Pane-wide drop target: drop a screenshot / image / pdf / video
        // anywhere on the chat pane (not just the input area) and it
        // attaches. Input area still has its own onDrop for the blue-glow
        // affordance; both call the same handler.
        .onDrop(of: [UTType.image, UTType.movie, UTType.pdf, UTType.audio, UTType.fileURL],
                isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    /// Estimated tokens that the next send will use, including conversation
    /// history, the per-conversation system prompt, the input draft, and
    /// any memory injection. Matches the router's `len // 3` heuristic.
    private var estimatedNextRequestTokens: Int {
        let historyChars = pilot.chatMessages.reduce(0) { $0 + $1.content.count }
        let systemChars = systemPrompt.count
        let draftChars = inputText.count
        let memoryChars = pilot.lastInjectedMemoryTokens * 3   // rough — memory token count is precomputed
        return max(0, (historyChars + systemChars + draftChars + memoryChars) / 3)
    }

    /// Header chip showing "context: X / cap" where cap is whatever the
    /// router currently advertises in /health. Color shifts amber > 75%,
    /// red > 90% so you see the wall coming.
    @ViewBuilder
    private var contextChip: some View {
        let cap = pilot.routerMaxInputTokens ?? 0
        let used = estimatedNextRequestTokens
        let pct = cap > 0 ? Double(used) / Double(cap) : 0
        let color: Color = {
            if cap == 0 { return .secondary }
            if pct >= 0.90 { return .red }
            if pct >= 0.75 { return .orange }
            return .secondary
        }()
        let usedStr = formatK(used)
        let capStr = cap > 0 ? formatK(cap) : "?"
        Text("ctx: \(usedStr) / \(capStr)")
            .font(.caption)
            .foregroundColor(color)
            .help(cap > 0
                  ? "Estimated tokens for the next send (history + system + draft + memory) vs the router's enforced input cap. Router silently trims oldest messages once you exceed the cap."
                  : "Router cap unknown — /health probe hasn't returned yet.")
    }

    /// Compact "12.3K" formatting for the context chip.
    private func formatK(_ n: Int) -> String {
        if n >= 1000 {
            let v = Double(n) / 1000.0
            return String(format: v >= 10 ? "%.0fK" : "%.1fK", v)
        }
        return "\(n)"
    }

    /// Walk backward (older) or forward (newer) through sentHistory.
    /// Direction -1 = older, +1 = newer. Wraps at the ends gracefully.
    private func recallHistory(direction: Int) {
        let hist = pilot.sentHistory
        guard !hist.isEmpty else { return }
        if historyCursor == -1 {
            historyCursor = direction < 0 ? hist.count - 1 : 0
        } else {
            historyCursor = max(0, min(hist.count - 1, historyCursor + direction))
        }
        inputText = hist[historyCursor]
    }

    /// Cmd+Shift+V — attach an image from the clipboard. Supports raw
    /// screenshot data, image files, and file URLs pointing to images.
    /// If nothing image-like is on the clipboard, posts a status msg.
    private func pasteFromClipboard() {
        let pb = NSPasteboard.general
        if let img = NSImage(pasteboard: pb),
           let png = nsImageToScaledPNG(img, maxEdge: Self.maxImageEdge) {
            attachments.append(Attachment(kind: .image(png), displayName: "pasted image"))
            return
        }
        if let fileURLs = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            for u in fileURLs { ingestFileURL(u) }
            return
        }
        postStatus("no image on clipboard (⇧⌘V pastes images — ⌘V still pastes text)")
    }

    /// Single source of truth for the outgoing router alias.
    /// Only `deep` reaches the 27B lane; everything else (auto, qwen35,
    /// any prior conversation label, any resident backend, any past
    /// selection) is routed to qwen35. Conversation history, sidebar
    /// labels, lastModel, loaded engines, externalBackends, and assistant
    /// labels MUST NOT influence routing — they are display-only.
    private func resolveOutgoingAlias() -> String {
        let a = pilot.selectedChatAlias
        return (a == "deep") ? "deep" : "qwen35"
    }

    private func sendIfReady() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && attachments.isEmpty { return }
        var o = PilotController.ChatOverrides()
        o.systemPrompt = systemPrompt
        o.attachments = attachments
        o.routeThroughRouterAlias = resolveOutgoingAlias()  // always route via router; it lazy-loads
        pilot.sendChat(text, overrides: o)
        inputText = ""
        attachments = []
        historyCursor = -1       // reset history navigation
        // pilot.selectedChatAlias is intentionally STICKY across sends,
        // across new chats, and across conversation switches. It only
        // changes when (a) the user changes the dropdown or (b) the
        // right-panel Start binds the lane to whichever model is being
        // started. No one-shot reset.
    }

    /// Rough char-to-token estimator matching router.py's len/3 heuristic.
    /// Counts current input text + any text-kind attachments + a flat
    /// per-image / per-pdf / per-video estimate so the user gets a sense
    /// of their prompt size before sending. Router trims anything over
    /// ~16K input tokens.
    private func estimatedTokens() -> Int {
        var chars = inputText.count
        for a in attachments {
            switch a.kind {
            case .text(let s): chars += s.count
            case .image: chars += 1200 * 3     // vision tokens vary; ~1200 as a rough flag
            case .pdfPages(let p): chars += 1200 * 3 * p.count
            case .video: chars += 3000 * 3
            }
        }
        // Add prior conversation history so the preview reflects what will actually be sent.
        for m in pilot.chatMessages where m.role == "user" || m.role == "assistant" {
            chars += m.content.count
        }
        return max(0, chars / 3)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            // Prefer file URL since it lets us route by UTType.
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    if let error = error {
                        DispatchQueue.main.async {
                            self.postStatus("drop failed: \(error.localizedDescription)")
                        }
                        return
                    }
                    var url: URL?
                    if let u = item as? URL { url = u }
                    if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                    guard let url else {
                        DispatchQueue.main.async {
                            self.postStatus("drop failed: could not extract a file URL from the dragged item")
                        }
                        return
                    }
                    self.ingestFileURL(url)
                }
                handled = true
                continue
            }
            // Pasted/dragged in-memory images (no file URL).
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { obj, error in
                    if let error = error {
                        DispatchQueue.main.async {
                            self.postStatus("image drop failed: \(error.localizedDescription)")
                        }
                        return
                    }
                    guard let img = obj as? NSImage else {
                        DispatchQueue.main.async {
                            self.postStatus("image drop failed: not a recognised image format")
                        }
                        return
                    }
                    guard let png = nsImageToScaledPNG(img, maxEdge: Self.maxImageEdge) else {
                        DispatchQueue.main.async {
                            self.postStatus("image drop failed: could not convert to PNG (try saving the image to disk and dragging the file)")
                        }
                        return
                    }
                    DispatchQueue.main.async {
                        self.attachments.append(Attachment(kind: .image(png), displayName: "image"))
                    }
                }
                handled = true
            }
        }
        return handled
    }

    private func ingestFileURL(_ url: URL) {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)

        if let type, type.conforms(to: .image) || ["png","jpg","jpeg","heic","gif","webp","bmp","tiff"].contains(ext) {
            guard let img = NSImage(contentsOf: url),
                  let png = nsImageToScaledPNG(img, maxEdge: Self.maxImageEdge) else {
                postStatus("could not read image \(name)")
                return
            }
            DispatchQueue.main.async {
                self.attachments.append(Attachment(kind: .image(png), displayName: name))
            }
            return
        }

        if let type, type.conforms(to: .pdf) || ext == "pdf" {
            guard let pdf = PDFDocument(url: url) else {
                postStatus("could not read pdf \(name)")
                return
            }
            let pages = rasterizePDF(pdf, maxPages: Self.maxPDFPages, scale: Self.pdfRenderScale)
            if pages.isEmpty {
                postStatus("pdf has no renderable pages: \(name)")
                return
            }
            if pdf.pageCount > Self.maxPDFPages {
                postStatus("\(name): truncated to first \(Self.maxPDFPages) pages")
            }
            DispatchQueue.main.async {
                self.attachments.append(Attachment(kind: .pdfPages(pages), displayName: name))
            }
            return
        }

        if let type, type.conforms(to: .movie) || type.conforms(to: .video) || ["mp4","mov","m4v","webm","avi","mkv"].contains(ext) {
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                if data.count > Self.maxVideoBytes {
                    let sizeMB = Double(data.count) / 1_048_576
                    let capMB = Self.maxVideoBytes / 1_048_576
                    postStatus("\(name): video too large (\(String(format: "%.1f", sizeMB)) MB, cap \(capMB) MB)")
                    return
                }
                let mime = videoMime(for: ext)
                DispatchQueue.main.async {
                    self.attachments.append(Attachment(kind: .video(data, mimeType: mime), displayName: name))
                }
            } catch {
                postStatus("could not read video \(name): \(error.localizedDescription)")
            }
            return
        }

        if let type, type.conforms(to: .audio) || ["mp3","wav","m4a","flac","aac","ogg"].contains(ext) {
            postStatus("audio files aren't supported — your local models can't hear. Transcribe externally and paste the text instead.")
            return
        }

        // Directory: walk recursively, concatenate text-ish files with headers,
        // cap at Self.maxFolderChars total. No recursion into hidden dirs.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            DispatchQueue.global(qos: .userInitiated).async {
                let text = Self.ingestFolder(url, cap: Self.maxFolderChars)
                DispatchQueue.main.async {
                    if text.isEmpty {
                        self.postStatus("folder \(name): no text files found")
                        return
                    }
                    self.attachments.append(Attachment(kind: .text(text), displayName: name + "/"))
                }
            }
            return
        }

        // Office docs + RTF + HTML: shell out to /usr/bin/textutil (macOS
        // built-in) to extract plain text. Works for .docx, .rtf, .html,
        // .webarchive. Does NOT work for .xlsx / .pptx — those need a
        // different tool and are skipped.
        if ["docx", "rtf", "rtfd", "html", "htm", "webarchive", "odt"].contains(ext) {
            DispatchQueue.global(qos: .userInitiated).async {
                let text = Self.extractViaTextutil(url: url)
                DispatchQueue.main.async {
                    if text.isEmpty {
                        self.postStatus("\(name): textutil produced no text")
                        return
                    }
                    let capped = text.count > Self.maxTextChars
                        ? String(text.prefix(Self.maxTextChars)) + "\n…[truncated]"
                        : text
                    self.attachments.append(Attachment(kind: .text(capped), displayName: name))
                }
            }
            return
        }
        if ["xlsx", "pptx"].contains(ext) {
            postStatus("\(name): .xlsx/.pptx extraction not supported — export to .csv or .txt first")
            return
        }

        // Text-like files: read UTF-8, cap, attach as .text. Broad allow-list
        // based on extension OR utf8 content sniff for unknown extensions.
        let textExts: Set<String> = [
            "txt", "md", "markdown", "rst",
            "py", "swift", "js", "ts", "tsx", "jsx", "rb", "go", "rs", "java",
            "c", "cc", "cpp", "h", "hpp", "m", "mm", "cs",
            "sh", "bash", "zsh", "fish",
            "json", "yaml", "yml", "toml", "ini", "cfg", "env",
            "xml", "svg", "css", "scss", "sass", "less",
            "sql", "graphql", "proto",
            "log", "csv", "tsv",
        ]
        if textExts.contains(ext) {
            do {
                let raw = try String(contentsOf: url, encoding: .utf8)
                let capped = raw.count > Self.maxTextChars
                    ? String(raw.prefix(Self.maxTextChars)) + "\n…[truncated]"
                    : raw
                DispatchQueue.main.async {
                    self.attachments.append(Attachment(kind: .text(capped), displayName: name))
                }
            } catch {
                postStatus("could not read \(name): \(error.localizedDescription)")
            }
            return
        }

        // Unknown extension — try reading as UTF-8. If it parses and looks
        // like text, attach as text. Otherwise reject.
        if let raw = try? String(contentsOf: url, encoding: .utf8), !raw.isEmpty {
            let capped = raw.count > Self.maxTextChars
                ? String(raw.prefix(Self.maxTextChars)) + "\n…[truncated]"
                : raw
            DispatchQueue.main.async {
                self.attachments.append(Attachment(kind: .text(capped), displayName: name))
            }
            return
        }

        postStatus("unsupported file type: \(name)")
    }

    /// Max characters per single text attachment (~6K tokens at 3 chars/token).
    private static let maxTextChars = 32_000
    /// Max total characters aggregated across an entire folder.
    private static let maxFolderChars = 64_000

    /// Walk `dir` recursively, concatenate the contents of text-ish files
    /// with headers. Skip hidden dirs (leading dot), common build/dep
    /// dirs, and anything bigger than 200 KB per file. Returns the
    /// concatenated text, truncated at `cap` chars.
    private static func ingestFolder(_ dir: URL, cap: Int) -> String {
        let textExts: Set<String> = [
            "txt", "md", "markdown", "rst",
            "py", "swift", "js", "ts", "tsx", "jsx", "rb", "go", "rs", "java",
            "c", "cc", "cpp", "h", "hpp", "m", "mm", "cs",
            "sh", "bash", "zsh", "fish",
            "json", "yaml", "yml", "toml", "ini", "cfg", "env",
            "xml", "css", "scss", "sql", "graphql", "proto",
        ]
        let skipDirs: Set<String> = [
            ".git", ".svn", ".hg", "node_modules", ".venv", "venv", "__pycache__",
            ".build", "build", "dist", "target", ".next", ".cache", "DerivedData",
        ]
        var out = ""
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsPackageDescendants]) else { return "" }
        while let any = en.nextObject() {
            guard let url = any as? URL else { continue }
            if out.count >= cap { break }
            let name = url.lastPathComponent
            if name.hasPrefix(".") || skipDirs.contains(name) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    en.skipDescendants()
                }
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard textExts.contains(ext) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 200_000 { continue }
            guard let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let rel = url.path.replacingOccurrences(of: dir.path + "/", with: "")
            out += "=== \(rel) ===\n\(body)\n\n"
        }
        if out.count > cap {
            out = String(out.prefix(cap)) + "\n…[truncated at \(cap) chars]"
        }
        return out
    }

    /// Convert a .docx / .rtf / .html via `/usr/bin/textutil -convert txt -stdout`.
    private static func extractViaTextutil(url: URL) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        task.arguments = ["-convert", "txt", "-stdout", url.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private func postStatus(_ msg: String) {
        DispatchQueue.main.async {
            PilotController.shared.lastActionStatus = msg
        }
    }

    private func videoMime(for ext: String) -> String {
        switch ext {
        case "mp4", "m4v": return "video/mp4"
        case "mov":        return "video/quicktime"
        case "webm":       return "video/webm"
        case "avi":        return "video/x-msvideo"
        case "mkv":        return "video/x-matroska"
        default:           return "video/mp4"
        }
    }
}

// MARK: - Attachment chip

struct AttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    /// For text attachments, produce a short preview of the first line
    /// of content so the chip shows what you're actually attaching.
    private var textPreview: String? {
        if case let .text(body) = attachment.kind {
            let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
            return String(firstLine.prefix(40))
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            iconView
                .frame(width: 36, height: 36)
                .background(Color.secondary.opacity(0.10))
                .cornerRadius(4)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .font(.caption2.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.summary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if let preview = textPreview {
                    Text(preview)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(6)
        .background(Color.blue.opacity(0.06))
        .cornerRadius(6)
    }

    @ViewBuilder
    private var iconView: some View {
        switch attachment.kind {
        case .image(let data):
            if let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            } else {
                Image(systemName: "photo")
            }
        case .video:
            Image(systemName: "film")
                .font(.title3)
                .foregroundColor(.secondary)
        case .pdfPages(let pages):
            if let first = pages.first, let img = NSImage(data: first) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            } else {
                Image(systemName: "doc.text")
            }
        case .text:
            Image(systemName: "doc.plaintext")
                .font(.title3)
                .foregroundColor(.secondary)
        }
    }
}

private func nsImageToPNG(_ image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { return nil }
    return png
}

/// Downscale an NSImage so its longest edge is at most `maxEdge`, then encode PNG.
private func nsImageToScaledPNG(_ image: NSImage, maxEdge: CGFloat) -> Data? {
    let size = image.size
    let longest = max(size.width, size.height)
    guard longest > 0 else { return nil }
    let scale = longest > maxEdge ? maxEdge / longest : 1.0
    let target = NSSize(width: floor(size.width * scale), height: floor(size.height * scale))

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    guard let rep else { return nsImageToPNG(image) }
    rep.size = target
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: target),
               from: NSRect(origin: .zero, size: size),
               operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

/// Rasterize PDF pages to PNG bytes. Caps page count and renders at the given scale.
private func rasterizePDF(_ doc: PDFDocument, maxPages: Int, scale: CGFloat) -> [Data] {
    let count = min(doc.pageCount, maxPages)
    var out: [Data] = []
    out.reserveCapacity(count)
    for i in 0..<count {
        guard let page = doc.page(at: i) else { continue }
        let bounds = page.bounds(for: .mediaBox)
        let target = NSSize(width: floor(bounds.width * scale),
                            height: floor(bounds.height * scale))
        guard target.width > 0, target.height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { continue }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            continue
        }
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext
        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(origin: .zero, size: target))
        cg.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: cg)
        NSGraphicsContext.restoreGraphicsState()
        if let png = rep.representation(using: .png, properties: [:]) {
            out.append(png)
        }
    }
    return out
}

/// Code block with its own Copy button so the user can grab the code
/// without manually dragging a selection. Text inside is still selectable.
struct CodeBlockView: View {
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer()
                Button(copied ? "copied" : "copy") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.08))
        .cornerRadius(4)
    }
}

/// Lightweight Markdown renderer for chat output. Splits `text` into
/// logical blocks (fenced code, headers, bullet lists, paragraphs) and
/// renders each with SwiftUI-native styling. Inline formatting inside each
/// block (bold, italic, code spans) is rendered via
/// `AttributedString(markdown:)` which is built into Foundation on
/// macOS 12+. We deliberately don't pull in a heavyweight markdown
/// dependency — this covers what MLX backends actually emit.
struct MarkdownContent: View {
    let text: String
    // Observe so flipping the chat-text-selection toggle re-renders bubbles.
    @ObservedObject private var pilot = PilotController.shared

    private enum Block {
        case header(Int, String)
        case bullet(String)
        case numbered(String, String)
        case code(String)
        case paragraph(String)
    }

    /// A prose segment is one or more consecutive non-code blocks merged
    /// into a single AttributedString so native SwiftUI text selection
    /// (.textSelection(.enabled)) can drag across them as a continuous
    /// range. Code segments are separate because they live in their own
    /// bordered copy-button view.
    private enum Segment {
        case prose(AttributedString)
        case code(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(segments().enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .prose(let attr):
                    // Selection-on path needs .fixedSize for AppKit to get a
                    // concrete hit-testable text region; without it the click
                    // never lands on the text and drag-select silently no-ops.
                    // Selection-off path skips both modifiers — that's the
                    // fast path that the default-off toggle protects.
                    if pilot.chatTextSelectionEnabled {
                        Text(attr)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(attr)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .code(let c):
                    CodeBlockView(code: c)
                }
            }
        }
    }

    private func segments() -> [Segment] {
        let blocks = parse()
        var out: [Segment] = []
        var proseAccum = AttributedString("")
        func flushProse() {
            if !proseAccum.characters.isEmpty {
                out.append(.prose(proseAccum))
                proseAccum = AttributedString("")
            }
        }
        for block in blocks {
            switch block {
            case .code(let c):
                flushProse()
                out.append(.code(c))
            case .header(let level, let t):
                if !proseAccum.characters.isEmpty {
                    proseAccum += AttributedString("\n\n")
                }
                var header = inline(t)
                // SwiftUI Font via AttributeContainer is Sendable-clean,
                // unlike NSFont which trips a strict-concurrency warning.
                let font: Font
                switch level {
                case 1: font = .title2.bold()
                case 2: font = .title3.bold()
                case 3: font = .headline
                default: font = .subheadline.bold()
                }
                var container = AttributeContainer()
                container.font = font
                header.mergeAttributes(container)
                proseAccum += header
            case .bullet(let t):
                if !proseAccum.characters.isEmpty {
                    proseAccum += AttributedString("\n")
                }
                proseAccum += AttributedString("•  ")
                proseAccum += inline(t)
            case .numbered(let marker, let t):
                if !proseAccum.characters.isEmpty {
                    proseAccum += AttributedString("\n")
                }
                proseAccum += AttributedString("\(marker)  ")
                proseAccum += inline(t)
            case .paragraph(let t):
                if !proseAccum.characters.isEmpty {
                    proseAccum += AttributedString("\n\n")
                }
                proseAccum += inline(t)
            }
        }
        flushProse()
        return out
    }

    private func parse() -> [Block] {
        var out: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var paragraphBuf: [String] = []
        func flushParagraph() {
            if !paragraphBuf.isEmpty {
                out.append(.paragraph(paragraphBuf.joined(separator: " ")))
                paragraphBuf.removeAll()
            }
        }
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph()
                i += 1
                var buf: [String] = []
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    buf.append(lines[i])
                    i += 1
                }
                out.append(.code(buf.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }
            if let headerMatch = trimmed.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                flushParagraph()
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let titleText = String(trimmed[headerMatch.upperBound...])
                out.append(.header(level, titleText))
                i += 1
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                out.append(.bullet(String(trimmed.dropFirst(2))))
                i += 1
                continue
            }
            if let match = trimmed.range(of: "^\\d+\\.\\s+", options: .regularExpression) {
                flushParagraph()
                let marker = String(trimmed[..<match.upperBound]).trimmingCharacters(in: .whitespaces)
                let body = String(trimmed[match.upperBound...])
                out.append(.numbered(marker, body))
                i += 1
                continue
            }
            paragraphBuf.append(trimmed)
            i += 1
        }
        flushParagraph()
        return out
    }

    private func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    @State private var copied = false
    @State private var isEditing = false
    @State private var editDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption2.bold())
                    .foregroundColor(roleColor)
                if let m = message.model {
                    Text(m)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                actionButtonsRow
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(message.attachments) { att in
                    AttachmentPreview(attachment: att)
                }
                // When a conversation is reloaded from disk the raw bytes are
                // gone, but we kept breadcrumbs so the user can see that an
                // image / pdf / video was there historically.
                if message.attachments.isEmpty && !message.attachmentSummaries.isEmpty {
                    ForEach(Array(message.attachmentSummaries.enumerated()), id: \.offset) { _, summary in
                        HStack(spacing: 4) {
                            Image(systemName: "paperclip")
                                .font(.caption2)
                            Text(summary)
                                .font(.caption2)
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.gray.opacity(0.15))
                        .cornerRadius(4)
                    }
                }
                if isEditing && message.role == "user" {
                    VStack(alignment: .trailing, spacing: 4) {
                        TextEditor(text: $editDraft)
                            .font(.system(.body))
                            .frame(minHeight: 80)
                            .padding(4)
                            .background(Color.white.opacity(0.3))
                            .cornerRadius(4)
                        HStack(spacing: 6) {
                            Button("Cancel") {
                                isEditing = false
                                editDraft = ""
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button("Save & Resend") {
                                let newText = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !newText.isEmpty else { return }
                                isEditing = false
                                PilotController.shared.editAndResend(
                                    messageID: message.id,
                                    newContent: newText
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                } else if !message.content.isEmpty {
                    if isStreamingBubble {
                        // Streaming path: plain Text, no .fixedSize (ScrollView
                        // already proposes infinite vertical). Selection gated
                        // on the same chatTextSelectionEnabled toggle as the
                        // finished-bubble markdown path; default off because
                        // .textSelection(.enabled) on a fast-growing string
                        // re-runs AppKit layout per tick and saturates the
                        // main thread.
                        if PilotController.shared.chatTextSelectionEnabled {
                            Text(message.content)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(.system(size: 13 * PilotController.shared.chatFontScale))
                        } else {
                            Text(message.content)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(.system(size: 13 * PilotController.shared.chatFontScale))
                        }
                    } else {
                        MarkdownContent(text: message.content)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .environment(\.font, .system(size: 13 * PilotController.shared.chatFontScale))
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bgColor)
            .cornerRadius(8)
            // Bottom mirror of the action buttons so users on long replies
            // don't have to scroll back up to find copy / regenerate / delete.
            HStack(spacing: 6) {
                Spacer()
                actionButtonsRow
            }
        }
    }

    /// Action buttons (retry / edit / regenerate / copy / delete) — rendered
    /// at both the top header row and a mirrored bottom row of every bubble.
    /// Conditions match the original top-row logic: most buttons hide while
    /// chatInProgress is true; "copy" is always available.
    @ViewBuilder
    private var actionButtonsRow: some View {
        if message.role == "system" && !PilotController.shared.chatInProgress
            && (message.content.contains("error") || message.content.contains("503")) {
            Button("retry") {
                PilotController.shared.retryLastFailed()
            }
            .buttonStyle(.borderless)
            .font(.caption2)
            .foregroundColor(.orange)
        }
        if message.role == "user" && !PilotController.shared.chatInProgress && !isEditing {
            Button("edit") {
                editDraft = message.content
                isEditing = true
            }
            .buttonStyle(.borderless)
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        if message.role == "assistant" && !PilotController.shared.chatInProgress {
            Button("regenerate") {
                PilotController.shared.regenerateLast()
            }
            .buttonStyle(.borderless)
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        Button(copied ? "copied" : "copy") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(message.content, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
        .buttonStyle(.borderless)
        .font(.caption2)
        .foregroundColor(.secondary)
        if !PilotController.shared.chatInProgress {
            Button("delete") {
                PilotController.shared.deleteMessage(message.id)
            }
            .buttonStyle(.borderless)
            .font(.caption2)
            .foregroundColor(.red.opacity(0.7))
        }
    }

    private var isStreamingBubble: Bool {
        let pilot = PilotController.shared
        return pilot.chatInProgress
            && message.role == "assistant"
            && pilot.chatMessages.last?.id == message.id
    }

    private var label: String {
        switch message.role {
        case "user":      return "You"
        case "assistant": return "Assistant"
        case "system":    return "System"
        default:          return message.role
        }
    }
    private var roleColor: Color {
        switch message.role {
        case "user":      return .blue
        case "assistant": return .green
        case "system":    return .orange
        default:          return .secondary
        }
    }
    private var bgColor: Color {
        switch message.role {
        case "user":      return Color.blue.opacity(0.10)
        case "assistant": return Color.green.opacity(0.10)
        case "system":    return Color.orange.opacity(0.10)
        default:          return Color.gray.opacity(0.10)
        }
    }
}

// MARK: - Right panel

struct RightPanelView: View {
    @ObservedObject var pilot = PilotController.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let err = pilot.configError {
                    Text("Config error: \(err)")
                        .foregroundColor(.red)
                        .font(.caption)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08))
                        .cornerRadius(6)
                }

                sectionHeader("Models  (\(pilot.liveEngines.count + pilot.externalBackends.filter { pilot.engines[$0.key] == nil }.count) loaded)")
                if let cfg = pilot.config {
                    VStack(spacing: 8) {
                        ForEach(pilot.availableModels, id: \.self) { name in
                            ModelRow(name: name, cfg: cfg)
                        }
                    }
                }

                Divider()
                sectionHeader("Usage")
                UsagePanel()

                Divider()
                sectionHeader("Logs")
                LogsPanel()

                Divider()
                sectionHeader("Memory  (\(pilot.memoryEntries.count))")
                MemoryPanel()

                Divider()
                sectionHeader("Shortcuts")
                ShortcutsPanel()

                Divider()
                sectionHeader("Config")
                ConfigPanel()
            }
            .padding(16)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Model row

struct UsagePanel: View {
    @ObservedObject var pilot = PilotController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tokens").font(.caption.bold())
                Spacer()
                Button("Refresh") { pilot.pollUsage() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
            HStack {
                Text("Today").font(.caption.bold())
                Spacer()
                Text("\(pilot.usageTodayRequests) req · \(fmt(pilot.usageTodayTotal)) tok")
                    .font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Text("Lifetime").font(.caption.bold())
                Spacer()
                Text("\(pilot.usageRequests) req · \(fmt(pilot.usageTotal)) tok")
                    .font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Text("in / out").font(.caption2)
                Spacer()
                Text("\(fmt(pilot.usageInput)) / \(fmt(pilot.usageOutput))")
                    .font(.caption2).foregroundColor(.secondary)
            }
            // Per-model bucket — filtered to models currently configured.
            // Lifetime totals for ex-models are still on disk in usage.jsonl
            // but are hidden here so the panel matches the live model set.
            let knownModels = Set(pilot.config?.models.keys ?? Dictionary<String, ModelConfig>().keys)
            let visibleUsage = pilot.perModelUsage.filter { knownModels.contains($0.key) }
            if !visibleUsage.isEmpty {
                Divider()
                ForEach(visibleUsage.sorted(by: { $0.value > $1.value }), id: \.key) { name, total in
                    HStack {
                        Text(shortName(name)).font(.caption2)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(fmt(total)).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }

    private func fmt(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func shortName(_ s: String) -> String {
        // Strip common prefixes for display
        let parts = s.split(separator: "-")
        if parts.count > 2 { return parts.prefix(2).joined(separator: "-") }
        return s
    }
}

struct ModelRow: View {
    let name: String
    let cfg: PilotConfig
    @ObservedObject var pilot = PilotController.shared

    var body: some View {
        let modelCfg = cfg.models[name]
        let h = pilot.engines[name]
        // A crashed or stopped GUI-owned entry should NOT hide a live
        // router-owned backend — treat the GUI entry as effectively gone
        // for display purposes when state is .crashed or .stopped.
        let guiActive = (h != nil) && (h!.state == .ready || h!.state == .booting || h!.state == .stopping)
        let externalPort = guiActive ? nil : pilot.externalBackends[name]
        let isExternal = externalPort != nil
        let state: EngineState = guiActive ? (h?.state ?? .stopped) : (isExternal ? .ready : (h?.state ?? .stopped))
        let isDefault = name == cfg.control.default_model
        let isRunning = state == .ready || state == .booting

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor(state))
                    .frame(width: 9, height: 9)
                Text(name)
                    .font(.system(.caption, design: .monospaced).bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isDefault {
                    Text("default")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18))
                        .cornerRadius(3)
                }
                Spacer()
                Text(stateLabel(state).uppercased())
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(stateColor(state).opacity(0.20))
                    .foregroundColor(stateColor(state))
                    .cornerRadius(3)
            }

            HStack(spacing: 6) {
                Text(modelCfg?.engine ?? "?")
                if isRunning, let port = h?.port ?? externalPort {
                    Text("·")
                    Text(":\(port)")
                }
                if let pid = h?.pid, isRunning {
                    Text("·")
                    Text("PID \(pid)")
                }
                if let ram = h?.ramMB {
                    Text("·")
                    Text("\(ram) MB")
                }
                if let cpu = h?.cpuPercent {
                    Text("·")
                    Text(String(format: "%.0f%%", cpu))
                }
                if isExternal {
                    Text("·")
                    Text("ROUTER").foregroundColor(.blue)
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)

            if let m = modelCfg {
                let modalities = (m.modalities ?? []).joined(separator: "·")
                let ctxTokens: Int? = isExternal ? (pilot.routerMaxInputTokens ?? m.max_context_tokens) : m.max_context_tokens
                let ctx = ctxTokens.map { "\($0 / 1000)K" } ?? "?"
                Text("\(modalities)  ·  \(ctx) ctx")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 4) {
                if isExternal, let port = externalPort {
                    Button("Eject") { pilot.ejectByPort(port, model: name) }
                    Text("router").font(.caption2).foregroundColor(.blue)
                } else if isRunning {
                    Button("Eject")   { pilot.ejectModel(name) }
                    Button("Restart") { pilot.restartModel(name) }
                } else {
                    Button("Start")   { pilot.startModel(name) }
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }

    private func stateColor(_ s: EngineState) -> Color {
        switch s {
        case .ready:    return .green
        case .booting:  return .orange
        case .stopping: return .yellow
        case .crashed:  return .red
        case .stopped:  return .gray
        }
    }

    private func stateLabel(_ s: EngineState) -> String {
        switch s {
        case .stopped:  return "stopped"
        case .booting:  return "booting"
        case .ready:    return "ready"
        case .stopping: return "stopping"
        case .crashed:  return "crashed"
        }
    }
}

// MARK: - Attachment preview (in chat bubble)

struct AttachmentPreview: View {
    let attachment: Attachment

    var body: some View {
        switch attachment.kind {
        case .image(let data):
            if let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 320, maxHeight: 320)
                    .cornerRadius(6)
            }
        case .video:
            HStack(spacing: 6) {
                Image(systemName: "film.fill").foregroundColor(.secondary)
                Text(attachment.displayName).font(.caption)
                Text(attachment.summary).font(.caption2).foregroundColor(.secondary)
            }
            .padding(6)
            .background(Color.secondary.opacity(0.10))
            .cornerRadius(4)
        case .pdfPages(let pages):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.fill").foregroundColor(.secondary)
                    Text(attachment.displayName).font(.caption.bold())
                    Text(attachment.summary).font(.caption2).foregroundColor(.secondary)
                }
                if let first = pages.first, let img = NSImage(data: first) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 240, maxHeight: 320)
                        .cornerRadius(4)
                }
            }
        case .text(let body):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.plaintext.fill").foregroundColor(.secondary)
                    Text(attachment.displayName).font(.caption.bold())
                    Text(attachment.summary).font(.caption2).foregroundColor(.secondary)
                }
                Text(body.prefix(400).replacingOccurrences(of: "\t", with: "  "))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(6)
                    .truncationMode(.tail)
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.05))
                    .cornerRadius(3)
            }
        }
    }
}

// MARK: - Logs panel

/// Quick-reference panel listing the app's keyboard shortcuts.
/// Static content, no state, no polling. Zero cost.
struct ShortcutsPanel: View {
    private let items: [(String, String)] = [
        ("⌘N",        "New chat"),
        ("⌘E",        "Eject current model"),
        ("⇧⌘E",       "Export current conversation"),
        ("⌘F",        "Focus sidebar search"),
        ("⌘.",        "Stop generation"),
        ("⌘↑ / ⌘↓",   "Recall sent history"),
        ("⌘+ / ⌘-",   "Chat font zoom"),
        ("⌘0",        "Reset font zoom"),
        ("⇧⌘V",       "Paste image from clipboard"),
        ("↩",         "Send message"),
        ("⇧↩",        "Newline in message"),
        ("⎋",         "Clear sidebar search"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.0) { key, desc in
                HStack {
                    Text(key)
                        .font(.system(.caption, design: .monospaced).bold())
                        .frame(width: 42, alignment: .leading)
                        .foregroundColor(.primary)
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
}

struct LogsPanel: View {
    @ObservedObject var pilot = PilotController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pilot.logsDir)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Size: \(pilot.logsFolderSize) · \(pilot.logsFileCount) file\(pilot.logsFileCount == 1 ? "" : "s")")
                .font(.caption)
            HStack(spacing: 4) {
                Button("Open") { pilot.openLogsFolder() }
                Button("Clear") { pilot.clearLogs() }
                Button("Refresh") { pilot.refreshFolderSizes() }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
}

// MARK: - Memory panel

/// Right-panel browser for the persistent memory store. Lists every
/// MemoryEntry, supports inline view/edit/delete, pin toggle, "Add new"
/// form, search filter, and an enable/disable toggle that flips
/// memory.enabled in config.json.
struct MemoryPanel: View {
    @ObservedObject var pilot = PilotController.shared
    @State private var search: String = ""
    @State private var showingAddSheet = false
    @State private var newTitle: String = ""
    @State private var newBody: String = ""
    @State private var newType: String = "manual"
    @State private var newPinned: Bool = false
    @State private var expandedID: UUID? = nil
    @State private var editingID: UUID? = nil
    @State private var editTitle: String = ""
    @State private var editBody: String = ""
    @State private var confirmClear: Bool = false

    private let typeOptions = ["manual", "fact", "preference", "decision", "task", "reference"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status row
            HStack(spacing: 6) {
                Circle()
                    .fill(pilot.memoryEnabled ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(pilot.memoryEnabled
                     ? (pilot.memoryAutoExtract ? "auto-extract on" : "manual-only")
                     : "disabled in config")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(pilot.memoryStatus)
                    .font(.caption2)
                    .foregroundColor(pilot.memoryStatus == "idle" ? .secondary : .accentColor)
            }
            // Surface disk-level errors (parse failure, save failure) so the
            // user knows when memory updates aren't being persisted.
            if let err = pilot.memoryLastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption2)
                    Text(err)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                TextField("filter…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("Add a new memory manually")
                Button {
                    pilot.memoryRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("Re-read memory from disk")
                Menu {
                    Button("Open memory folder") {
                        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.mlxlm/memory")
                        NSWorkspace.shared.open(url)
                    }
                    Button("Tail memory.log") {
                        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.mlxlm/logs/memory.log")
                        NSWorkspace.shared.open(url)
                    }
                    Divider()
                    Button("Clear ALL memory") {
                        confirmClear = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .controlSize(.small)
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            }
            // Entry list
            if filteredEntries.isEmpty {
                Text(search.isEmpty
                     ? "no memories yet — chat normally and the model will record what it considers worth remembering, or use /remember <text>"
                     : "no memories match \"\(search)\"")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 4) {
                    ForEach(filteredEntries) { entry in
                        memoryRow(entry)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .sheet(isPresented: $showingAddSheet) { addSheet }
        .alert("Clear ALL memory?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) { }
            Button("Delete all", role: .destructive) { pilot.memoryClearAll() }
        } message: {
            Text("Removes every memory entry from disk. This cannot be undone.")
        }
    }

    private var filteredEntries: [MemoryEntry] {
        let entries = pilot.memoryEntries
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = needle.isEmpty
            ? entries
            : entries.filter {
                $0.title.lowercased().contains(needle)
                || $0.body.lowercased().contains(needle)
                || $0.type.lowercased().contains(needle)
            }
        return filtered.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            let aL = a.lastUsedAt ?? a.createdAt
            let bL = b.lastUsedAt ?? b.createdAt
            return aL > bL
        }
    }

    @ViewBuilder
    private func memoryRow(_ entry: MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    pilot.memoryTogglePin(id: entry.id)
                } label: {
                    Image(systemName: entry.pinned ? "pin.fill" : "pin")
                        .foregroundColor(entry.pinned ? .accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(entry.pinned ? "Pinned (loaded first, never auto-pruned)" : "Pin")

                Text(entry.title)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("· \(entry.type)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    if expandedID == entry.id {
                        expandedID = nil
                        editingID = nil
                    } else {
                        expandedID = entry.id
                    }
                } label: {
                    Image(systemName: expandedID == entry.id ? "chevron.down" : "chevron.right")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                Button {
                    pilot.memoryDelete(id: entry.id)
                    if expandedID == entry.id { expandedID = nil; editingID = nil }
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
            if expandedID == entry.id {
                if editingID == entry.id {
                    TextField("title", text: $editTitle)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    TextEditor(text: $editBody)
                        .font(.caption)
                        .frame(minHeight: 80)
                        .padding(4)
                        .background(Color.white.opacity(0.4))
                        .cornerRadius(4)
                    HStack(spacing: 6) {
                        Spacer()
                        Button("Cancel") {
                            editingID = nil
                        }
                        .controlSize(.small)
                        Button("Save") {
                            pilot.memoryUpdate(id: entry.id, title: editTitle, body: editBody, type: nil)
                            editingID = nil
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Text(entry.body)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text("created \(shortDate(entry.createdAt))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if let lu = entry.lastUsedAt {
                            Text("· used \(shortDate(lu))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if let ttl = entry.ttlDays {
                            Text("· ttl \(ttl)d")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("edit") {
                            editTitle = entry.title
                            editBody = entry.body
                            editingID = entry.id
                        }
                        .controlSize(.mini)
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(expandedID == entry.id ? Color.gray.opacity(0.08) : Color.clear)
        .cornerRadius(3)
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add memory")
                .font(.headline)
            TextField("title", text: $newTitle)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $newBody)
                .font(.body)
                .frame(minHeight: 120)
                .padding(4)
                .background(Color.white.opacity(0.5))
                .cornerRadius(4)
            HStack {
                Picker("type", selection: $newType) {
                    ForEach(typeOptions, id: \.self) { Text($0) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180)
                Toggle("pinned", isOn: $newPinned)
                    .toggleStyle(.checkbox)
                Spacer()
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    resetAddForm()
                    showingAddSheet = false
                }
                Button("Save") {
                    pilot.memoryAddManual(title: newTitle, body: newBody, type: newType, pinned: newPinned)
                    resetAddForm()
                    showingAddSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty
                          || newBody.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func resetAddForm() {
        newTitle = ""
        newBody = ""
        newType = "manual"
        newPinned = false
    }

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

// MARK: - Config panel

struct ConfigPanel: View {
    @ObservedObject var pilot = PilotController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("~/.mlxlm/config.json")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                HStack(spacing: 4) {
                    Button("Open") { pilot.openConfigFile() }
                    Button("Reload") { pilot.loadConfig() }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $pilot.chatTextSelectionEnabled) {
                    Text("Drag-select chat text")
                        .font(.caption)
                }
                .controlSize(.small)
                .toggleStyle(.checkbox)
                Text("On = highlight + ⌘C to copy a sub-range. Can hang the app on very long replies. Off = use the per-bubble Copy button.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
}
