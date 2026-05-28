import Foundation
import os.log

/// term-mesh 번들에 포함된 Claude 슬래시 커맨드 파일을
/// 앱 시작 시 ~/.claude/commands/ 에 버전 기반으로 설치한다.
///
/// 설치 조건:
/// - 번들에 claude-commands/ 리소스 디렉토리가 존재
/// - 현재 앱 버전이 마지막 설치 시 버전보다 새로움
/// - 대상 파일이 없거나, "term-mesh-managed" 마커가 있는 파일만 덮어쓰기
///
/// 사용자가 직접 작성한 커맨드 파일(마커 없음)은 절대 건드리지 않는다.
enum ClaudeCommandInstaller {

    private static let logger = Logger(
        subsystem: "com.termmesh",
        category: "ClaudeCommandInstaller"
    )

    /// UserDefaults key: 마지막 설치 시 앱 버전
    private static let installedVersionKey = "termMeshClaudeCommandsInstalledVersion"

    /// UserDefaults key: managed-name 강제 마이그레이션 완료 표시.
    /// 동일 버전에서도 한 번은 무조건 실행되어 기존 사용자의 마커 없는 team.md /
    /// tm.md 등을 백업 후 term-mesh 버전으로 교체한다. 이후 launch부터는
    /// 일반 버전 게이트(installedVersionKey)로 돌아간다.
    private static let managedNameMigrationKey = "termMeshClaudeCommandsManagedNameBackupV1"

    /// term-mesh가 소유권을 주장하는 슬래시 커맨드 파일 이름.
    /// 이 목록에 있는 파일은 사용자 버전(마커 없음)이라도 백업 후 강제 덮어쓰기 한다.
    /// 다른 이름의 파일은 절대 건드리지 않는다.
    private static let managedCommandNames: Set<String> = [
        "tm.md",
        "team.md",
        "team-up.md",
        "tm-op.md",
        "tm-bench.md",
        "watch.md"
    ]

    /// 번들 내 커맨드 디렉토리 (claude-commands/)
    private static var bundleCommandsURL: URL? {
        Bundle.main.url(forResource: "claude-commands", withExtension: nil)
    }

    /// 번들 내 스킬 디렉토리 (claude-skills/)
    private static var bundleSkillsURL: URL? {
        Bundle.main.url(forResource: "claude-skills", withExtension: nil)
    }

    /// 대상: ~/.claude/commands/
    private static var targetURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/commands")
    }

    /// 대상: ~/.claude/skills/
    private static var targetSkillsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills")
    }

    /// 앱 시작 시 호출. 번들 버전이 더 새로우면 커맨드/스킬 파일을 설치한다.
    /// 에러는 조용히 실패 — 설치 실패가 앱 시작을 막아선 안 된다.
    static func installIfNeeded() {
        let current = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
        let installed = UserDefaults.standard.string(forKey: installedVersionKey) ?? ""
        let migrationDone = UserDefaults.standard.bool(forKey: managedNameMigrationKey)

        // 버전 게이트 OR 일회성 강제 마이그레이션 — 둘 중 하나라도 필요하면 install
        let needsVersionInstall = isNewer(current, than: installed)
        let needsMigration = !migrationDone
        guard needsVersionInstall || needsMigration else {
            logger.debug("Claude commands/skills already installed for version \(current, privacy: .public)")
            return
        }
        if needsMigration && !needsVersionInstall {
            logger.info("Running one-time managed-name backup migration for existing user")
        }

        if let src = bundleCommandsURL {
            do {
                try installCommands(from: src, to: targetURL)
                logger.info("Claude commands installed for version \(current, privacy: .public)")
            } catch {
                logger.error("Command install failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            logger.error("claude-commands bundle resource not found")
        }

        if let srcSkills = bundleSkillsURL {
            do {
                try installSkills(from: srcSkills, to: targetSkillsURL)
                logger.info("Claude skills installed for version \(current, privacy: .public)")
            } catch {
                logger.error("Skill install failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            logger.debug("claude-skills bundle resource not found (optional)")
        }

        UserDefaults.standard.set(current, forKey: installedVersionKey)
        UserDefaults.standard.set(true, forKey: managedNameMigrationKey)
    }

    // MARK: - Private

    private static func installCommands(from src: URL, to dst: URL) throws {
        let fm = FileManager.default

        // ~/.claude/commands/ 디렉토리 없으면 생성
        if !fm.fileExists(atPath: dst.path) {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        }

        let files = try fm.contentsOfDirectory(
            at: src, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" }

        for file in files {
            let dest = dst.appendingPathComponent(file.lastPathComponent)
            let name = file.lastPathComponent

            // 보존 정책:
            // (1) 마커가 있으면 → 이전 term-mesh 설치본 → 그냥 덮어쓰기
            // (2) 마커가 없고 이름이 managed 목록이면 → 사용자 버전/심볼릭/레거시 → 백업 후 덮어쓰기
            // (3) 마커가 없고 이름이 managed가 아니면 → 사용자 커스텀 → 건드리지 않음
            // existsAsSymlink 검사가 fileExists보다 견고 (broken symlink도 잡음)
            let existsRegular = fm.fileExists(atPath: dest.path)
            let existsAsSymlink = (try? fm.attributesOfItem(atPath: dest.path)[.type] as? FileAttributeType) == .typeSymbolicLink
            if existsRegular || existsAsSymlink {
                if !isManagedFile(at: dest) {
                    guard managedCommandNames.contains(name) else {
                        logger.debug("Skipping user-customized file: \(name, privacy: .public)")
                        continue
                    }
                    backupNonManagedFile(at: dest)
                }
            }

            // 번들 파일을 복사 (기존 managed 파일 덮어쓰기)
            // 임시 파일에 먼저 복사 후 rename으로 원자적 교체
            let tmp = dest.deletingLastPathComponent()
                .appendingPathComponent(".tmp-\(file.lastPathComponent)")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: file, to: tmp)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
            logger.debug("Installed: \(file.lastPathComponent, privacy: .public)")
        }
    }

    /// 사용자 버전 파일을 `<name>.bak-yyyyMMdd-HHmmss` 로 백업.
    /// 심볼릭 링크면 resolved content를 읽어 일반 파일로 백업한다 (원본 보존이 목적).
    /// 실패해도 install은 계속 진행 — 데이터 손실보다 명령 노출이 우선이지만,
    /// 백업 실패는 로그에 명확히 남긴다.
    private static func backupNonManagedFile(at url: URL) {
        let fm = FileManager.default
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = df.string(from: Date())
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).bak-\(suffix)")

        // 중복 방지: 같은 초에 두 번 호출되더라도 덮어쓰지 않음
        guard !fm.fileExists(atPath: backupURL.path) else {
            logger.debug("Backup already exists, skipping: \(backupURL.lastPathComponent, privacy: .public)")
            return
        }

        // 심볼릭/일반 모두에서 resolved 콘텐츠를 읽는다
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            do {
                try content.write(to: backupURL, atomically: true, encoding: .utf8)
                logger.info("Backed up \(url.lastPathComponent, privacy: .public) → \(backupURL.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Backup write failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        } else {
            // resolved 콘텐츠 못 읽음 (broken symlink 등) — 그래도 직접 copy 시도
            do {
                try fm.copyItem(at: url, to: backupURL)
                logger.info("Backed up (binary/symlink) \(url.lastPathComponent, privacy: .public) → \(backupURL.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Backup copy failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 파일 상단 5줄 이내에 "<!-- term-mesh-managed:" prefix 마커가 있는지 확인.
    /// 첫 줄은 슬래시 커맨드 picker의 description으로 쓰이는 human-readable heading이
    /// 차지하고, 마커는 line 2(또는 그 근처)로 옮긴다. hasPrefix를 사용해 부정 주석
    /// (NOT term-mesh-managed 등)에 의한 오탐을 방지한다.
    private static func isManagedFile(at url: URL) -> Bool {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let headLines = content.components(separatedBy: .newlines).prefix(5)
        return headLines.contains { $0.hasPrefix("<!-- term-mesh-managed:") }
    }

    /// SKILL.md는 YAML frontmatter가 먼저 오므로, marker는 frontmatter 바로 다음 줄에 삽입된다.
    /// 파일 상단 30줄 이내에 "<!-- term-mesh-managed:" 가 있는지 확인한다.
    private static func isManagedSkillFile(at url: URL) -> Bool {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let headLines = content.components(separatedBy: .newlines).prefix(30)
        return headLines.contains { $0.hasPrefix("<!-- term-mesh-managed:") }
    }

    /// 스킬 설치. 각 스킬은 claude-skills/<name>/SKILL.md 구조로 번들에 있다.
    /// 디렉토리 단위로 순회하며, 기존에 같은 이름의 스킬이 있으면 managed 마커가 있을 때만 덮어쓴다.
    private static func installSkills(from src: URL, to dst: URL) throws {
        let fm = FileManager.default

        if !fm.fileExists(atPath: dst.path) {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        }

        // 번들의 스킬 디렉토리 순회 (각각이 <name>/SKILL.md 구조)
        let skillDirs = try fm.contentsOfDirectory(
            at: src, includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        for skillDir in skillDirs {
            let skillName = skillDir.lastPathComponent
            let srcFile = skillDir.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: srcFile.path) else {
                logger.debug("Skill \(skillName, privacy: .public): SKILL.md not found, skipping")
                continue
            }

            let destDir = dst.appendingPathComponent(skillName)
            let destFile = destDir.appendingPathComponent("SKILL.md")

            if fm.fileExists(atPath: destFile.path) {
                if !isManagedSkillFile(at: destFile) {
                    logger.debug("Skipping user-customized skill: \(skillName, privacy: .public)")
                    continue
                }
            } else {
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            }

            // 원자적 교체: 임시 파일에 쓴 뒤 rename
            let tmp = destDir.appendingPathComponent(".tmp-SKILL.md")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: srcFile, to: tmp)
            try? fm.removeItem(at: destFile)
            try fm.moveItem(at: tmp, to: destFile)
            logger.debug("Installed skill: \(skillName, privacy: .public)")
        }
    }

    /// SemVer 비교: a가 b보다 새로우면 true
    private static func isNewer(_ a: String, than b: String) -> Bool {
        if b.isEmpty { return true }
        let toInts = { (s: String) in s.split(separator: ".").compactMap { Int($0) } }
        let av = toInts(a), bv = toInts(b)
        for i in 0..<max(av.count, bv.count) {
            let ai = i < av.count ? av[i] : 0
            let bi = i < bv.count ? bv[i] : 0
            if ai != bi { return ai > bi }
        }
        return false
    }
}
