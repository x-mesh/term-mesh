import Foundation
import SwiftUI

enum ReviewBoardSettings {
    static let enabledKey = "reviewBoard.enabled"
    static let widthKey = "reviewBoard.width"
    static let isClosedKey = "reviewBoard.isClosed"
    static let selectedTaskIDKey = "reviewBoard.selectedTaskID"
    static let defaultWidth: CGFloat = 380
    static let minimumWidth: CGFloat = 320
    static let maximumWidth: CGFloat = 560

    static func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }

    static func loadWidth(defaults: UserDefaults = .standard) -> CGFloat {
        let stored = defaults.double(forKey: widthKey)
        guard stored > 0 else { return defaultWidth }
        return clampedWidth(CGFloat(stored))
    }

    static func saveWidth(_ width: CGFloat, defaults: UserDefaults = .standard) {
        defaults.set(Double(clampedWidth(width)), forKey: widthKey)
    }
}

extension Notification.Name {
    static let reviewBoardTaskSelected = Notification.Name("termMesh.reviewBoard.taskSelected")
}

enum ReviewBoardStatus: String, CaseIterable, Equatable, Sendable {
    case coordinatorOffline
    case memMeshUnavailable
    case suspectHost
    case fencedZombie
    case blocked
    case reviewReady
    case mergeFailed

    var title: String {
        switch self {
        case .coordinatorOffline: return "Coordinator Offline"
        case .memMeshUnavailable: return "mem-mesh Unavailable"
        case .suspectHost: return "Suspect Host"
        case .fencedZombie: return "Fenced Zombie"
        case .blocked: return "Blocked"
        case .reviewReady: return "Review Ready"
        case .mergeFailed: return "Merge Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .coordinatorOffline: return "antenna.radiowaves.left.and.right.slash"
        case .memMeshUnavailable: return "externaldrive.badge.xmark"
        case .suspectHost: return "exclamationmark.triangle"
        case .fencedZombie: return "lock.shield"
        case .blocked: return "hand.raised"
        case .reviewReady: return "checkmark.seal"
        case .mergeFailed: return "arrow.triangle.merge"
        }
    }

    var color: Color {
        switch self {
        case .coordinatorOffline, .memMeshUnavailable: return .secondary
        case .suspectHost, .blocked: return .orange
        case .fencedZombie, .mergeFailed: return .red
        case .reviewReady: return .green
        }
    }

    var accessibilityLabel: String {
        "\(title) state"
    }
}

struct ReviewBoardSnapshot: Equatable, Sendable {
    var tasks: [ReviewBoardTask]
    var panelRuns: [ReviewBoardPanelRun]
    var coordinatorOnline: Bool
    var memMeshAvailable: Bool
    var suspectHost: Bool
    var fencedZombie: Bool

    static let empty = ReviewBoardSnapshot(
        tasks: [],
        panelRuns: [],
        coordinatorOnline: false,
        memMeshAvailable: false,
        suspectHost: false,
        fencedZombie: false
    )
}

struct ReviewBoardTask: Identifiable, Equatable, Sendable {
    let id: String
    let teamName: String
    let title: String
    let status: String
    let assignee: String?
    let priority: Int
    let labels: [String]
    let dependsOn: [String]
    let blockedReason: String?
    let reviewSummary: String?
    let result: String?
    let resultPath: String?
    let worktreeBranch: String?
    let worktreeParent: String?
    let worktreeFinishMode: String?
    let worktreeRemoved: Bool?
    let isStale: Bool
    let staleSeconds: Int?
    let updatedAt: String?

    init(
        id: String,
        teamName: String,
        title: String,
        status: String,
        assignee: String? = nil,
        priority: Int = 2,
        labels: [String] = [],
        dependsOn: [String] = [],
        blockedReason: String? = nil,
        reviewSummary: String? = nil,
        result: String? = nil,
        resultPath: String? = nil,
        worktreeBranch: String? = nil,
        worktreeParent: String? = nil,
        worktreeFinishMode: String? = nil,
        worktreeRemoved: Bool? = nil,
        isStale: Bool = false,
        staleSeconds: Int? = nil,
        updatedAt: String? = nil
    ) {
        self.id = ReviewBoardText.safeIdentifier(id)
        self.teamName = ReviewBoardText.safeLabel(teamName)
        self.title = ReviewBoardText.safeLabel(title)
        self.status = status
        self.assignee = assignee.map(ReviewBoardText.safeLabel)
        self.priority = priority
        self.labels = labels.map(ReviewBoardText.safeLabel)
        self.dependsOn = dependsOn.map(ReviewBoardText.safeIdentifier)
        self.blockedReason = blockedReason.map { ReviewBoardText.safeBody($0) }
        self.reviewSummary = reviewSummary.map { ReviewBoardText.safeBody($0) }
        self.result = result.map { ReviewBoardText.safeBody($0) }
        self.resultPath = resultPath.flatMap(ReviewBoardText.safePathLabel)
        self.worktreeBranch = worktreeBranch.map(ReviewBoardText.safeLabel)
        self.worktreeParent = worktreeParent.map(ReviewBoardText.safeLabel)
        self.worktreeFinishMode = worktreeFinishMode.map(ReviewBoardText.safeLabel)
        self.worktreeRemoved = worktreeRemoved
        self.isStale = isStale
        self.staleSeconds = staleSeconds
        self.updatedAt = updatedAt
    }

    init?(dictionary: [String: Any]) {
        guard let id = dictionary["id"] as? String,
              let title = dictionary["title"] as? String else {
            return nil
        }
        self.init(
            id: id,
            teamName: dictionary["team_name"] as? String ?? "Unknown team",
            title: title,
            status: dictionary["status"] as? String ?? "queued",
            assignee: dictionary["assignee"] as? String,
            priority: dictionary["priority"] as? Int ?? 2,
            labels: dictionary["labels"] as? [String] ?? [],
            dependsOn: dictionary["depends_on"] as? [String] ?? [],
            blockedReason: dictionary["blocked_reason"] as? String,
            reviewSummary: dictionary["review_summary"] as? String,
            result: dictionary["result"] as? String,
            resultPath: dictionary["result_path"] as? String,
            worktreeBranch: dictionary["worktree_branch"] as? String,
            worktreeParent: dictionary["worktree_parent"] as? String,
            worktreeFinishMode: dictionary["worktree_finish_mode"] as? String,
            worktreeRemoved: dictionary["worktree_removed"] as? Bool,
            isStale: dictionary["is_stale"] as? Bool ?? false,
            staleSeconds: dictionary["stale_seconds"] as? Int,
            updatedAt: dictionary["updated_at"] as? String
        )
    }
}

struct ReviewBoardPanelRun: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let phase: String
    let isTerminal: Bool
    let tail: String?

    init?(dictionary: [String: Any]) {
        guard let run = dictionary["run"] as? String else { return nil }
        id = ReviewBoardText.safeIdentifier(run)
        title = ReviewBoardText.safeLabel(dictionary["title"] as? String ?? "Panel run")
        phase = ReviewBoardText.safeLabel(dictionary["phase"] as? String ?? "unknown")
        isTerminal = dictionary["terminal"] as? Bool ?? false
        tail = (dictionary["tail"] as? String).map { ReviewBoardText.safeBody($0) }
    }
}

struct ReviewBoardTaskDigest: Equatable, Sendable {
    let attemptLineage: String
    let aheadBehind: String
    let commitPush: String
    let platformChecks: String
    let pullRequestChecks: String
    let overlappingFiles: String
    let rejectionReason: String
    let mergeQueue: String

    static func make(for task: ReviewBoardTask, panelRuns: [ReviewBoardPanelRun]) -> ReviewBoardTaskDigest {
        let haystack = ([task.title, task.blockedReason, task.reviewSummary, task.result] + task.labels)
            .compactMap { $0 }
            .joined(separator: "\n")
        let lower = haystack.lowercased()
        let activeRun = panelRuns.first { !$0.isTerminal }
        let lastRun = panelRuns.first

        return ReviewBoardTaskDigest(
            attemptLineage: task.dependsOn.isEmpty
                ? "No predecessor task reported"
                : "Depends on \(task.dependsOn.joined(separator: ", "))",
            aheadBehind: firstLine(containingAny: ["ahead", "behind"], in: haystack) ?? "Ahead/behind not reported",
            commitPush: firstLine(containingAny: ["commit", "push"], in: haystack)
                ?? fallbackCommitPush(task),
            platformChecks: firstLine(containingAny: ["xcodebuild", "test", "platform", "macos"], in: haystack)
                ?? "Platform checks not reported",
            pullRequestChecks: firstLine(containingAny: ["pr", "check", "ci"], in: haystack)
                ?? "PR/check state not reported",
            overlappingFiles: firstLine(containingAny: ["overlap", "conflict"], in: haystack)
                ?? "No overlapping files reported",
            rejectionReason: task.blockedReason
                ?? firstLine(containingAny: ["reject", "rejected", "blocked"], in: haystack)
                ?? "No rejection reason reported",
            mergeQueue: activeRun.map { "Running: \($0.title) (\($0.phase))" }
                ?? lastRun.map { "Last run: \($0.title) (\($0.phase))" }
                ?? (lower.contains("merge") ? "Merge activity reported" : "No merge queue entry reported")
        )
    }

    private static func fallbackCommitPush(_ task: ReviewBoardTask) -> String {
        var parts: [String] = []
        if let branch = task.worktreeBranch {
            parts.append("branch \(branch)")
        }
        if let mode = task.worktreeFinishMode {
            parts.append("finish \(mode)")
        }
        if task.worktreeRemoved == true {
            parts.append("worktree removed")
        }
        if let resultPath = task.resultPath {
            parts.append("report \(resultPath)")
        }
        return parts.isEmpty ? "Commit/push not reported" : parts.joined(separator: ", ")
    }

    private static func firstLine(containingAny needles: [String], in text: String) -> String? {
        text.split(separator: "\n")
            .map(String.init)
            .first { line in
                let lower = line.lowercased()
                return needles.contains { lower.contains($0) }
            }
            .map { ReviewBoardText.safeBody($0) }
    }
}

enum ReviewBoardText {
    private static let uuidPattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
    private static let longHexPattern = #"\b[0-9a-fA-F]{24,}\b"#
    private static let tokenPattern = #"\b[A-Za-z0-9_-]{32,}\b"#

    static func safeIdentifier(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return trimmed }
        return String(trimmed.prefix(8))
    }

    static func safeLabel(_ value: String) -> String {
        safeBody(value, limit: 120)
    }

    static func safeBody(_ value: String, limit: Int = 240) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        text = replace(pattern: uuidPattern, in: text, with: "<uuid>")
        text = replace(pattern: longHexPattern, in: text, with: "<token>")
        text = replace(pattern: tokenPattern, in: text, with: "<token>")
        text = text
            .split(separator: " ")
            .map { token -> String in
                let raw = String(token)
                return safePathLikeToken(raw) ?? raw
            }
            .joined(separator: " ")
        if text.count > limit {
            return String(text.prefix(limit - 1)) + "…"
        }
        return text
    }

    static func safePathLabel(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return safePathLikeToken(trimmed) ?? safeLabel(trimmed)
    }

    private static func safePathLikeToken(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]{}\"'"))
        guard trimmed.hasPrefix("/") || trimmed.contains("/Users/") || trimmed.contains("/.gk/") else {
            return nil
        }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        guard !name.isEmpty else { return "…/" }
        return "…/\(name)"
    }

    private static func replace(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
