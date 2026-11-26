import Foundation
import GhosttyTerminal
import Observation

@Observable
final class TerminalSearch {
    enum Direction {
        case older
        case newer

        fileprivate var bindingAction: String {
            switch self {
            case .older: "navigate_search:next"
            case .newer: "navigate_search:previous"
            }
        }
    }

    private(set) var isPresented = false
    private(set) var query = ""
    private(set) var total: Int?
    private(set) var selected: Int?
    private(set) var showsNoResults = false
    private(set) var focusRequest = 0

    var isEditing = false {
        didSet {
            guard oldValue, !isEditing else { return }
            FindHistory.shared.fence()
        }
    }

    var hasMatches: Bool {
        (total ?? 0) > 0
    }

    private static let noResultsDelay: TimeInterval = 0.4
    private static let maximumQueryLength = 512

    @ObservationIgnored private let terminal: TerminalViewState
    @ObservationIgnored private var pacer = FindQueryPacer()
    @ObservationIgnored private var needle = ""
    @ObservationIgnored private var isSurfaceActive = true
    @ObservationIgnored private var delayGeneration = 0
    @ObservationIgnored private var noResultsGeneration = 0

    @ObservationIgnored private var pendingSelection: Direction?
    @ObservationIgnored private var wantsFieldFocus = false

    @ObservationIgnored private var reportedTotal: Int??
    @ObservationIgnored private var reportedSelected: Int??
    @ObservationIgnored private var isFlushScheduled = false

    init(terminal: TerminalViewState) {
        self.terminal = terminal
        terminal.onSearch = { [weak self] event in
            self?.surfaceDidReport(event)
        }
    }

    // MARK: - Presentation

    func present(needle: String? = nil) {
        if !isPresented {
            isPresented = true
        }
        if let needle = needle.map(Self.normalized), !needle.isEmpty {
            query = needle
            submit(selecting: .older)
        } else if query.isEmpty, let recent = FindHistory.shared.queries.first {
            query = recent
            submit(selecting: nil)
        } else if self.needle != query {
            submit(selecting: nil)
        }
        requestFieldFocus()
    }

    func takeFieldFocusRequest() -> Bool {
        defer { wantsFieldFocus = false }
        return wantsFieldFocus
    }

    private func requestFieldFocus() {
        wantsFieldFocus = true
        focusRequest += 1
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        isEditing = false
        wantsFieldFocus = false
        delayGeneration += 1
        pacer.reset()
        needle = ""
        clearResults()
        terminal.performBindingAction("end_search")
    }

    // MARK: - Query

    func edit(_ text: String) {
        let text = Self.normalized(text)
        guard text != query else { return }
        query = text
        switch pacer.edited(text, at: Self.now) {
        case .search:
            submit(selecting: .older)
        case .wait:
            scheduleDelayedSearch()
        case .idle:
            break
        }
    }

    func search(for text: String) {
        query = Self.normalized(text)
        submit(selecting: .older)
        requestFieldFocus()
    }

    func navigate(_ direction: Direction) {
        guard isPresented else {
            present()
            if isPresented, !needle.isEmpty {
                pendingSelection = direction
            }
            return
        }
        guard !needle.isEmpty, Self.isSameNeedle(needle, query) else {
            submit(selecting: direction)
            return
        }
        needle = query
        guard isSurfaceActive else { return }
        if hasMatches {
            pendingSelection = nil
            terminal.performBindingAction(direction.bindingAction)
        } else if total == nil {
            pendingSelection = direction
        }
    }

    func setSurfaceActive(_ isActive: Bool) {
        guard isActive != isSurfaceActive else { return }
        isSurfaceActive = isActive
        guard isPresented, !needle.isEmpty else { return }
        if isActive {
            startSearch()
        } else {
            clearResults()
            terminal.performBindingAction("search:")
        }
    }

    private func scheduleDelayedSearch() {
        delayGeneration += 1
        let generation = delayGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + FindQueryPacer.delay) { [weak self] in
            guard let self, generation == delayGeneration, isPresented else { return }
            if pacer.delayElapsed(query) == .search {
                submit(selecting: .older)
            }
        }
    }

    private func submit(selecting direction: Direction?) {
        delayGeneration += 1
        pacer.searched(query)
        needle = query
        FindHistory.shared.add(needle)
        clearResults()
        pendingSelection = needle.isEmpty ? nil : direction
        if isSurfaceActive {
            startSearch()
        }
    }

    private func startSearch() {
        terminal.performBindingAction("search:\(needle)")
    }

    private func clearResults() {
        noResultsGeneration += 1
        pendingSelection = nil
        reportedTotal = nil
        reportedSelected = nil
        if total != nil {
            total = nil
        }
        if selected != nil {
            selected = nil
        }
        if showsNoResults {
            showsNoResults = false
        }
    }

    private static var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func normalized(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let printable = line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String(printable).prefix(maximumQueryLength))
    }

    private static func isSameNeedle(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8) { asciiLowercased($0) == asciiLowercased($1) }
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (0x41 ... 0x5A).contains(byte) ? byte + 0x20 : byte
    }

    // MARK: - Selecting the first match

    private func requestPendingSelection() {
        guard let direction = pendingSelection, hasMatches, selected == nil else { return }
        pendingSelection = nil
        terminal.performBindingAction(direction.bindingAction)
    }

    // MARK: - What the surface reports

    private func surfaceDidReport(_ event: TerminalSearchEvent) {
        switch event {
        case let .started(needle):
            present(needle: needle)
        case .ended:
            dismiss()
        case let .total(total):
            reportedTotal = .some(total)
            scheduleFlush()
        case let .selected(selected):
            reportedSelected = .some(selected)
            scheduleFlush()
        }
    }

    private func scheduleFlush() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushReports()
        }
    }

    private func flushReports() {
        isFlushScheduled = false
        let newTotal = reportedTotal
        let newSelected = reportedSelected
        reportedTotal = nil
        reportedSelected = nil
        guard isPresented, isSurfaceActive, !needle.isEmpty else { return }
        if let newSelected {
            if newSelected != selected {
                selected = newSelected
            }
            if newSelected != nil {
                pendingSelection = nil
            }
        }
        if let newTotal {
            if newTotal != total {
                total = newTotal
            }
            updateNoResults()
        }
        requestPendingSelection()
    }

    private func updateNoResults() {
        noResultsGeneration += 1
        guard total == 0 else {
            if showsNoResults {
                showsNoResults = false
            }
            return
        }
        guard !showsNoResults else { return }
        let generation = noResultsGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noResultsDelay) { [weak self] in
            guard let self, generation == noResultsGeneration, total == 0 else { return }
            showsNoResults = true
        }
    }
}

struct FindQueryPacer {
    enum Step: Equatable {
        case search
        case wait
        case idle
    }

    static let delay: TimeInterval = 0.5
    static let staleAfter: TimeInterval = 3

    private enum State {
        case empty
        case delaying
        case activeShort
        case activeMedium
        case activeLong
    }

    private enum Length {
        case short
        case medium
        case long
    }

    private var state = State.empty
    private var lastEdit: TimeInterval?

    mutating func edited(_ query: String, at time: TimeInterval) -> Step {
        let isStale = lastEdit.map { time - $0 > Self.staleAfter } ?? false
        lastEdit = time
        guard !query.isEmpty else {
            let hadSearch = state != .empty
            state = .empty
            return hadSearch ? .search : .idle
        }
        let length = Self.length(of: query)
        switch state {
        case .empty:
            return length == .short ? startDelay() : activate(length)
        case .delaying:
            return length == .short ? .idle : activate(length)
        case .activeShort, .activeMedium:
            if length == .short, isStale {
                return startDelay()
            }
            if state == .activeMedium, length == .short {
                return .search
            }
            return activate(length)
        case .activeLong:
            return length == .short ? startDelay() : activate(length)
        }
    }

    mutating func delayElapsed(_ query: String) -> Step {
        guard state == .delaying, !query.isEmpty else { return .idle }
        return activate(Self.length(of: query))
    }

    mutating func searched(_ query: String) {
        state = query.isEmpty ? .empty : Self.state(for: Self.length(of: query))
    }

    mutating func reset() {
        state = .empty
        lastEdit = nil
    }

    private static func length(of query: String) -> Length {
        switch query.count {
        case ...2: .short
        case 3 ... 4: .medium
        default: .long
        }
    }

    private static func state(for length: Length) -> State {
        switch length {
        case .short: .activeShort
        case .medium: .activeMedium
        case .long: .activeLong
        }
    }

    private mutating func startDelay() -> Step {
        state = .delaying
        return .wait
    }

    private mutating func activate(_ length: Length) -> Step {
        state = Self.state(for: length)
        return .search
    }
}

struct FindHistoryList: Equatable {
    static let capacity = 10
    static let minimumLength = 3

    private(set) var queries: [String] = []
    private var canCoalesce = false

    mutating func add(_ query: String) {
        guard query.count >= Self.minimumLength else {
            fence()
            return
        }
        if canCoalesce, let last = queries.first {
            if query.hasPrefix(last) {
                queries.removeFirst()
            } else if last.hasPrefix(query) {
                return
            }
        }
        queries.removeAll { $0 == query }
        queries.insert(query, at: 0)
        if queries.count > Self.capacity {
            queries.removeLast(queries.count - Self.capacity)
        }
        canCoalesce = true
    }

    mutating func fence() {
        canCoalesce = false
    }

    mutating func removeAll() {
        queries = []
        canCoalesce = false
    }
}

@Observable
final class FindHistory {
    static let shared = FindHistory()

    private(set) var queries: [String] = []
    @ObservationIgnored private var list = FindHistoryList()

    private init() {}

    func add(_ query: String) {
        list.add(query)
        publish()
    }

    func fence() {
        list.fence()
    }

    func removeAll() {
        list.removeAll()
        publish()
    }

    private func publish() {
        guard queries != list.queries else { return }
        queries = list.queries
    }
}
