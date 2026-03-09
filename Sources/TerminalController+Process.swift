import AppKit
import Foundation

extension TerminalController {
    // MARK: - Process Ancestry Check

    /// Get the peer PID of a connected Unix domain socket using LOCAL_PEERPID.
    nonisolated func getPeerPid(_ socket: Int32) -> pid_t? {
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize)
        if result != 0 || pid <= 0 {
            return nil
        }
        return pid
    }

    /// Check if the peer has the same UID as this process using LOCAL_PEERCRED.
    /// This works even after the peer has disconnected (unlike LOCAL_PEERPID).
    func peerHasSameUID(_ socket: Int32) -> Bool {
        var cred = xucred()
        var credLen = socklen_t(MemoryLayout<xucred>.size)
        let result = getsockopt(socket, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLen)
        guard result == 0 else { return false }
        return cred.cr_uid == getuid()
    }

    /// Check if `pid` is a descendant of this process by walking the process tree.
    func isDescendant(_ pid: pid_t) -> Bool {
        var current = pid
        // Walk up to 128 levels to avoid infinite loops from kernel bugs
        for _ in 0..<128 {
            if current == myPid {
                return true
            }
            if current <= 1 {
                return false
            }
            let parent = parentPid(of: current)
            if parent == current || parent < 0 {
                return false
            }
            current = parent
        }
        return false
    }

    /// Get the parent PID of a process using sysctl.
    func parentPid(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            return -1
        }
        return info.kp_eproc.e_ppid
    }

    func start(tabManager: TabManager, socketPath: String, accessMode: SocketControlMode) {
        self.tabManager = tabManager
        self.accessMode = accessMode

        if isRunning {
            if self.socketPath == socketPath && acceptLoopAlive {
                self.accessMode = accessMode
                applySocketPermissions()
                return
            }
            stop()
        }

        self.socketPath = socketPath

        // Remove existing socket file
        unlink(socketPath)

        // Create socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            print("TerminalController: Failed to create socket")
            return
        }

        // Bind to path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strcpy(pathBuf, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult >= 0 else {
            print("TerminalController: Failed to bind socket")
            close(serverSocket)
            return
        }

        applySocketPermissions()

        // Listen
        guard listen(serverSocket, 5) >= 0 else {
            print("TerminalController: Failed to listen on socket")
            close(serverSocket)
            return
        }

        isRunning = true
        print("TerminalController: Listening on \(socketPath)")

        // Wire batched port scanner results back to workspace state.
        PortScanner.shared.onPortsUpdated = { [weak self] workspaceId, panelId, ports in
            MainActor.assumeIsolated {
                guard let self, let tabManager = self.tabManager else { return }
                guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
                let validSurfaceIds = Set(workspace.panels.keys)
                guard validSurfaceIds.contains(panelId) else { return }
                let nextPorts = Array(Set(ports)).sorted()
                let currentPorts = workspace.surfaceListeningPorts[panelId] ?? []
                guard currentPorts != nextPorts else { return }
                if nextPorts.isEmpty {
                    workspace.surfaceListeningPorts.removeValue(forKey: panelId)
                } else {
                    workspace.surfaceListeningPorts[panelId] = nextPorts
                }
                workspace.recomputeListeningPorts()
            }
        }

        // Accept connections in background thread
        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
        }
    }

    nonisolated func stop() {
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        unlink(socketPath)
    }

    func applySocketPermissions() {
        let permissions = mode_t(accessMode.socketFilePermissions)
        if chmod(socketPath, permissions) != 0 {
            print("TerminalController: Failed to set socket permissions to \(String(permissions, radix: 8)) for \(socketPath)")
        }
    }

    func writeSocketResponse(_ response: String, to socket: Int32) {
        let payload = response + "\n"
        payload.withCString { ptr in
            _ = write(socket, ptr, strlen(ptr))
        }
    }

    func passwordAuthRequiredResponse(for command: String) -> String {
        let message = "Authentication required. Send auth <password> first."
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return "ERROR: Authentication required — send auth <password> first"
        }
        let id = dict["id"]
        return v2Error(id: id, code: "auth_required", message: message)
    }

    func passwordLoginV1ResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        let lowered = command.lowercased()
        guard lowered == "auth" || lowered.hasPrefix("auth ") else {
            return nil
        }
        guard SocketControlPasswordStore.hasConfiguredPassword() else {
            return "ERROR: Password mode is enabled but no socket password is configured in Settings."
        }

        let provided: String
        if lowered == "auth" {
            provided = ""
        } else {
            provided = String(command.dropFirst(5))
        }
        guard !provided.isEmpty else {
            return "ERROR: Missing password. Usage: auth <password>"
        }
        guard SocketControlPasswordStore.verify(password: provided) else {
            return "ERROR: Invalid password"
        }
        authenticated = true
        return "OK: Authenticated"
    }

    func passwordLoginV2ResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }
        let id = dict["id"]
        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard method == "auth.login" else {
            return nil
        }

        guard let params = dict["params"] as? [String: Any],
              let provided = params["password"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "auth.login requires params.password")
        }

        guard SocketControlPasswordStore.hasConfiguredPassword() else {
            return v2Error(
                id: id,
                code: "auth_unconfigured",
                message: "Password mode is enabled but no socket password is configured in Settings."
            )
        }

        guard SocketControlPasswordStore.verify(password: provided) else {
            return v2Error(id: id, code: "auth_failed", message: "Invalid password")
        }
        authenticated = true
        return v2Ok(id: id, result: ["authenticated": true])
    }

    func authResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        guard accessMode.requiresPasswordAuth else {
            return nil
        }
        if let v2Response = passwordLoginV2ResponseIfNeeded(for: command, authenticated: &authenticated) {
            return v2Response
        }
        if let v1Response = passwordLoginV1ResponseIfNeeded(for: command, authenticated: &authenticated) {
            return v1Response
        }
        if !authenticated {
            return passwordAuthRequiredResponse(for: command)
        }
        return nil
    }

    nonisolated func acceptLoop() {
        acceptLoopAlive = true
        defer {
            acceptLoopAlive = false
            isRunning = false
        }

        var consecutiveFailures = 0
        while isRunning {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverSocket, sockaddrPtr, &clientAddrLen)
                }
            }

            guard clientSocket >= 0 else {
                if isRunning {
                    consecutiveFailures += 1
                    print("TerminalController: Accept failed (\(consecutiveFailures) consecutive)")
                    if consecutiveFailures >= 50 {
                        print("TerminalController: Too many consecutive accept failures, exiting accept loop")
                        break
                    }
                    usleep(10_000) // 10ms backoff
                }
                continue
            }

            consecutiveFailures = 0

            // Capture peer PID immediately — before the client can disconnect.
            // ncat --send-only closes the connection right after writing, so by
            // the time a new thread starts the peer may already be gone.
            let peerPid = getPeerPid(clientSocket)

            // Handle client in new thread
            Thread.detachNewThread { [weak self] in
                self?.handleClient(clientSocket, peerPid: peerPid)
            }
        }
    }

}
