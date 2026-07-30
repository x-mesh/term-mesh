import Foundation

/// What auto pilot is allowed to do without a person watching.
///
/// The whole feature rests on one property: everything it does has to be
/// undoable by one person in one command. Three limits together buy that, and
/// none of them is sufficient alone.
///
///   1. **A ceiling branch.** Auto merges stop at `develop`. `main` is never
///      reached automatically, so cutting a release stays a human decision no
///      matter how many tasks pile up below it.
///   2. **No push.** Merges stay in the local repository. Undoing one is then
///      `git reset`, not a conversation with everyone who already pulled.
///   3. **An undo point.** The ceiling's SHA is recorded *before* the merge,
///      so putting it back does not depend on reading reflog correctly under
///      pressure.
///
/// The policy is the single place that says yes. Anything it does not say yes
/// to falls through to the human review path that already exists — auto pilot
/// never has a second, looser route to a merge.
struct AutoPilotPolicy: Equatable {
    static let enabledKey = "autoPilot.enabled"
    static let ceilingBranchKey = "autoPilot.ceilingBranch"
    static let maxAutoMergesKey = "autoPilot.maxAutoMergesPerSession"

    /// Off until someone turns it on, per window, every launch decision
    /// explicit. A merge loop that starts itself is the one thing nobody asked
    /// for.
    var isEnabled: Bool

    /// The furthest branch an automatic merge may land on. A task whose merge
    /// target is anything else is handed back to a person — the policy does not
    /// try to guess an equivalent branch.
    var ceilingBranch: String

    /// Never a merge target, whatever the ceiling is set to. This exists
    /// because `ceilingBranch` is user-editable: someone typing `main` into
    /// the field should not thereby arm automatic merges into it.
    var protectedBranches: Set<String>

    /// A budget, so a misconfigured board cannot merge fifty tasks while
    /// nobody is looking. Counts merges, not attempts.
    var maxAutoMerges: Int

    static let defaultCeiling = "develop"
    static let defaultProtectedBranches: Set<String> = ["main", "master", "trunk"]

    static let `default` = AutoPilotPolicy(
        isEnabled: false,
        ceilingBranch: defaultCeiling,
        protectedBranches: defaultProtectedBranches,
        maxAutoMerges: 10
    )

    static func load(from defaults: UserDefaults = .standard) -> AutoPilotPolicy {
        let ceiling = defaults.string(forKey: ceilingBranchKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let budget = defaults.object(forKey: maxAutoMergesKey) as? Int
        return AutoPilotPolicy(
            isEnabled: defaults.bool(forKey: enabledKey),
            ceilingBranch: (ceiling?.isEmpty == false) ? ceiling! : defaultCeiling,
            protectedBranches: defaultProtectedBranches,
            maxAutoMerges: budget.map { max(0, $0) } ?? AutoPilotPolicy.default.maxAutoMerges
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: Self.enabledKey)
        defaults.set(ceilingBranch, forKey: Self.ceilingBranchKey)
        defaults.set(maxAutoMerges, forKey: Self.maxAutoMergesKey)
    }
}

/// Proof that the code being merged actually built and passed its tests.
///
/// `passed` alone is not proof. A check that passed against an earlier commit
/// says nothing about the one about to be merged, and that is exactly the case
/// auto pilot would otherwise wave through: an agent runs its VERIFY command,
/// pushes one more fix, and reports done. So the head the check ran against is
/// part of the evidence, and the policy compares it.
struct AutoPilotCheckEvidence: Equatable {
    let command: String
    let passed: Bool
    /// The commit the check actually ran against.
    let headSHA: String
    let recordedAtMS: Int64

    init(command: String, passed: Bool, headSHA: String, recordedAtMS: Int64) {
        self.command = command
        self.passed = passed
        self.headSHA = headSHA
        self.recordedAtMS = recordedAtMS
    }
}

/// One task, as auto pilot sees it at the moment it decides.
struct AutoPilotCandidate: Equatable {
    let taskID: String
    /// Where the merge would land. Not inferred — read from the task's
    /// recorded parent, because inferring it is how a merge ends up somewhere
    /// nobody expected.
    let targetBranch: String
    /// The commit that would be merged.
    let headSHA: String
    let checkEvidence: AutoPilotCheckEvidence?
    /// Whether the merge would leave this machine.
    let wouldPush: Bool
    /// Automatic merges already performed this session.
    let autoMergesSoFar: Int
}

/// Yes, or why not. The reason is shown to a person, so it says what to do
/// about it rather than naming the rule that fired.
enum AutoPilotDecision: Equatable {
    case proceed
    case handToHuman(String)

    var isProceed: Bool {
        if case .proceed = self { return true }
        return false
    }

    var reason: String? {
        if case .handToHuman(let reason) = self { return reason }
        return nil
    }
}

extension AutoPilotPolicy {
    /// The single yes. Checks run cheapest-and-most-absolute first, so the
    /// reason a person sees is the most fundamental one rather than whichever
    /// happened to be tested last.
    func evaluate(_ candidate: AutoPilotCandidate) -> AutoPilotDecision {
        guard isEnabled else {
            return .handToHuman("Auto pilot is off.")
        }

        let target = candidate.targetBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return .handToHuman("This task does not record where it would merge to.")
        }

        // Protected first: a ceiling misconfigured to `main` must not arm
        // automatic merges into it, so this check cannot be the one that
        // consults `ceilingBranch`.
        if Self.defaultProtectedBranches.contains(target) || protectedBranches.contains(target) {
            return .handToHuman("\(target) is never merged automatically.")
        }

        guard target == ceilingBranch else {
            return .handToHuman(
                "Auto pilot merges into \(ceilingBranch); this task targets \(target)."
            )
        }

        guard !candidate.wouldPush else {
            return .handToHuman("Auto pilot does not push — this merge would leave the machine.")
        }

        guard candidate.autoMergesSoFar < maxAutoMerges else {
            return .handToHuman(
                "Auto pilot has merged \(candidate.autoMergesSoFar) times this session (limit \(maxAutoMerges))."
            )
        }

        guard let evidence = candidate.checkEvidence else {
            return .handToHuman("Nothing has verified this task's build or tests.")
        }
        guard evidence.passed else {
            return .handToHuman("The last check failed: \(evidence.command)")
        }
        // The narrow case the whole evidence type exists for.
        guard evidence.headSHA == candidate.headSHA else {
            return .handToHuman(
                "The check ran against \(Self.short(evidence.headSHA)), "
                    + "but \(Self.short(candidate.headSHA)) would be merged."
            )
        }

        return .proceed
    }

    private static func short(_ sha: String) -> String {
        String(sha.prefix(8))
    }
}

/// Where a branch stood before auto pilot moved it.
///
/// Recorded before the merge, not after — a merge that fails halfway is
/// exactly when this is needed, and by then there is no ceiling SHA left to
/// read.
struct AutoPilotUndoPoint: Equatable, Codable {
    let branch: String
    let sha: String
    /// The target branch tip immediately after the automatic merge. Existing
    /// journal entries decode this as nil and therefore fail closed on undo.
    let mergedSHA: String?
    let taskID: String
    let repositoryPath: String
    let recordedAtMS: Int64

    init(
        branch: String,
        sha: String,
        mergedSHA: String? = nil,
        taskID: String,
        repositoryPath: String,
        recordedAtMS: Int64
    ) {
        self.branch = branch
        self.sha = sha
        self.mergedSHA = mergedSHA
        self.taskID = taskID
        self.repositoryPath = repositoryPath
        self.recordedAtMS = recordedAtMS
    }

    /// What a person runs to put the branch back. Spelled out rather than
    /// performed, because undoing someone's merge is their call to make.
    var restoreCommand: String {
        "git -C \(AutoPilotUndoPoint.quote(repositoryPath)) update-ref refs/heads/\(branch) \(sha)"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A newest-first, bounded list on disk.
///
/// On disk rather than in memory because the thing most worth reading back is
/// what happened just before something went wrong, and a crashed app remembers
/// nothing.
final class AutoPilotJournal<Entry: Codable & Equatable> {
    private let url: URL
    private let queue = DispatchQueue(label: "com.termmesh.autopilot.journal")
    private let limit: Int

    init(url: URL, limit: Int = 50) {
        self.url = url
        self.limit = limit
    }

    convenience init(teamName: String, kind: String, limit: Int = 50) {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".term-mesh/autopilot", isDirectory: true)
        self.init(url: base.appendingPathComponent("\(teamName)-\(kind).json"), limit: limit)
    }

    func record(_ entry: Entry) {
        queue.sync {
            var all = loadUnsafe()
            all.insert(entry, at: 0)
            if all.count > limit { all = Array(all.prefix(limit)) }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            guard let data = try? JSONEncoder().encode(all) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func entries() -> [Entry] {
        queue.sync { loadUnsafe() }
    }

    private func loadUnsafe() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}

/// Where a branch stood before auto pilot moved it — recorded before the
/// merge, not after. A merge that fails halfway is exactly when this is
/// needed, and by then there is no ceiling SHA left to read.
typealias AutoPilotUndoLog = AutoPilotJournal<AutoPilotUndoPoint>

extension AutoPilotJournal where Entry == AutoPilotUndoPoint {
    convenience init(teamName: String) {
        self.init(teamName: teamName, kind: "undo")
    }

    func points() -> [AutoPilotUndoPoint] { entries() }

    func latest(forTask taskID: String) -> AutoPilotUndoPoint? {
        entries().first { $0.taskID == taskID }
    }
}
