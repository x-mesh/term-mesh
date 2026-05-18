import Foundation

final class CliProfileStore {
    static let shared = CliProfileStore()

    private let queue = DispatchQueue(label: "com.termmesh.CliProfileStore", attributes: [])

    private var storeURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("term-mesh", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cli-profiles.json")
    }

    private var cache: [String: [CliProfile]]? = nil

    private init() {}

    func all() -> [String: [CliProfile]] {
        queue.sync { _load() }
    }

    func profiles(for cli: String) -> [CliProfile] {
        queue.sync { _load()[cli] ?? [] }
    }

    func save(_ profile: CliProfile, for cli: String) {
        queue.sync {
            var data = _load()
            var list = data[cli] ?? []
            if let idx = list.firstIndex(where: { $0.id == profile.id }) {
                list[idx] = profile
            } else {
                list.append(profile)
            }
            data[cli] = list
            _persist(data)
        }
    }

    func delete(_ profile: CliProfile, for cli: String) {
        queue.sync {
            var data = _load()
            data[cli] = (data[cli] ?? []).filter { $0.id != profile.id }
            _persist(data)
        }
    }

    // MARK: - Private

    private func _load() -> [String: [CliProfile]] {
        if let cached = cache { return cached }
        guard let bytes = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String: [CliProfile]].self, from: bytes)
        else { return [:] }
        cache = decoded
        return decoded
    }

    private func _persist(_ data: [String: [CliProfile]]) {
        cache = data
        guard let bytes = try? JSONEncoder().encode(data) else {
            NSLog("CliProfileStore: encode failed")
            return
        }
        try? bytes.write(to: storeURL, options: .atomic)
    }
}
