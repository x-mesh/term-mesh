#if DEBUG
import Foundation

enum UpdateTestSupport {
    static func applyIfNeeded(to viewModel: UpdateViewModel) {
        let env = ProcessInfo.processInfo.environment
        guard (env["TERMMESH_UI_TEST_MODE"] ?? env["CMUX_UI_TEST_MODE"]) == "1" else { return }
        guard let state = (env["TERMMESH_UI_TEST_UPDATE_STATE"] ?? env["CMUX_UI_TEST_UPDATE_STATE"]) else { return }

        DispatchQueue.main.async {
            let version = (env["TERMMESH_UI_TEST_UPDATE_VERSION"] ?? env["CMUX_UI_TEST_UPDATE_VERSION"]) ?? "9.9.9"
            switch state {
            case "available":
                transition(to: .updateAvailable(
                    installed: "0.0.1",
                    latest: version,
                    install: {},
                    dismiss: { viewModel.state = .idle }
                ), on: viewModel)
            case "notFound":
                transition(to: .upToDate(dismiss: { viewModel.state = .idle }), on: viewModel)
            default:
                break
            }
        }
    }

    static func performMockFeedCheckIfNeeded(on viewModel: UpdateViewModel) -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard (env["TERMMESH_UI_TEST_TRIGGER_UPDATE_CHECK"] ?? env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"]) == "1" else { return false }
        guard let feedURLString = (env["TERMMESH_UI_TEST_FEED_URL"] ?? env["CMUX_UI_TEST_FEED_URL"]),
              let feedURL = URL(string: feedURLString) else { return false }

        UpdateLogStore.shared.append("ui test mock feed check: \(feedURLString)")
        UpdateTestURLProtocol.registerIfNeeded()
        DispatchQueue.main.async {
            viewModel.state = .checking
        }

        let version = (env["TERMMESH_UI_TEST_UPDATE_VERSION"] ?? env["CMUX_UI_TEST_UPDATE_VERSION"]) ?? "9.9.9"
        let task = URLSession.shared.dataTask(with: feedURL) { data, _, _ in
            let xml = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let hasItem = xml.contains("<item>")
            let applyState = {
                if hasItem {
                    viewModel.state = .updateAvailable(
                        installed: "0.0.1",
                        latest: version,
                        install: {},
                        dismiss: { viewModel.state = .idle }
                    )
                } else {
                    setUpToDate(on: viewModel)
                }
            }
            DispatchQueue.main.async {
                let delayMilliseconds = Int((env["TERMMESH_UI_TEST_MOCK_FEED_DELAY_MS"] ?? env["CMUX_UI_TEST_MOCK_FEED_DELAY_MS"]) ?? "") ?? 0
                if delayMilliseconds > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds)) {
                        applyState()
                    }
                } else {
                    applyState()
                }
            }
        }
        task.resume()
        return true
    }

    private static func transition(to state: UpdateState, on viewModel: UpdateViewModel) {
        viewModel.state = .checking
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if case .upToDate = state {
                setUpToDate(on: viewModel)
            } else {
                viewModel.state = state
            }
        }
    }

    /// Sets `.upToDate`, records the shown timestamp, and schedules the auto-fade
    /// with hidden timestamp recording after `noUpdateDisplayDuration`.
    private static func setUpToDate(on viewModel: UpdateViewModel) {
        recordUITestTimestamp(key: "noUpdateShownAt")
        viewModel.state = .upToDate(dismiss: { viewModel.state = .idle })
        let duration = UpdateTiming.noUpdateDisplayDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak viewModel] in
            guard let viewModel, case .upToDate = viewModel.state else { return }
            recordUITestTimestamp(key: "noUpdateHiddenAt")
            viewModel.state = .idle
        }
    }

    /// Writes a timestamp to the JSON file at TERMMESH_UI_TEST_TIMING_PATH.
    static func recordUITestTimestamp(key: String) {
        let env = ProcessInfo.processInfo.environment
        guard (env["TERMMESH_UI_TEST_MODE"] ?? env["CMUX_UI_TEST_MODE"]) == "1" else { return }
        guard let path = (env["TERMMESH_UI_TEST_TIMING_PATH"] ?? env["CMUX_UI_TEST_TIMING_PATH"]) else { return }

        let url = URL(fileURLWithPath: path)
        var payload: [String: Double] = [:]
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Double] {
            payload = object
        }
        payload[key] = Date().timeIntervalSince1970
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: url)
        }
    }
}
#endif
