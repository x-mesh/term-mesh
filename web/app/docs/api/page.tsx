import type { Metadata } from "next";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";

export const metadata: Metadata = {
  title: "API Reference",
  description:
    "term-mesh CLI and Unix socket API reference. Workspace management, split panes, input control, notifications, sidebar metadata (status, progress, logs), environment variables, and detection methods.",
};

function Cmd({
  name,
  desc,
  cli,
  socket,
}: {
  name: string;
  desc: string;
  cli: string;
  socket: string;
}) {
  return (
    <div className="mb-6">
      <h4>{name}</h4>
      <p>{desc}</p>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
        <CodeBlock title="CLI" lang="bash">{cli}</CodeBlock>
        <CodeBlock title="Socket" lang="json">{socket}</CodeBlock>
      </div>
    </div>
  );
}

export default function ApiPage() {
  return (
    <>
      <h1>API Reference</h1>
      <p>
        term-mesh provides both a CLI tool and a Unix socket for programmatic
        control. Every command is available through both interfaces.
      </p>

      <h2>Socket</h2>
      <table>
        <thead>
          <tr>
            <th>Build</th>
            <th>Path</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>Release</td>
            <td>
              <code>/tmp/term-mesh.sock</code>
            </td>
          </tr>
          <tr>
            <td>Debug</td>
            <td>
              <code>/tmp/term-mesh-debug.sock</code>
            </td>
          </tr>
          <tr>
            <td>Tagged debug build</td>
            <td>
              <code>/tmp/term-mesh-debug-&lt;tag&gt;.sock</code>
            </td>
          </tr>
        </tbody>
      </table>
      <p>
        Override with the <code>CMUX_SOCKET_PATH</code> environment variable.
        Send one newline-terminated JSON request per call:
      </p>
      <CodeBlock lang="json">{`{"id":"req-1","method":"workspace.list","params":{}}
// Response:
{"id":"req-1","ok":true,"result":{"workspaces":[...]}}`}</CodeBlock>
      <Callout>
        JSON socket requests must use <code>method</code> and{" "}
        <code>params</code>. Legacy v1 JSON payloads such as{" "}
        <code>{`{"command":"..."}`}</code> are not supported.
      </Callout>

      <h2>Access modes</h2>
      <table>
        <thead>
          <tr>
            <th>Mode</th>
            <th>Description</th>
            <th>How to enable</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>
              <strong>Off</strong>
            </td>
            <td>Socket disabled</td>
            <td>Settings UI or <code>CMUX_SOCKET_MODE=off</code></td>
          </tr>
          <tr>
            <td>
              <strong>term-mesh processes only</strong>
            </td>
            <td>
              Only processes spawned inside term-mesh terminals can connect.
            </td>
            <td>Default mode in Settings UI</td>
          </tr>
          <tr>
            <td>
              <strong>allowAll</strong>
            </td>
            <td>Allow any local process to connect (no ancestry check).</td>
            <td>
              Environment override only: <code>CMUX_SOCKET_MODE=allowAll</code>
            </td>
          </tr>
        </tbody>
      </table>
      <Callout type="warn">
        On shared machines, use <strong>Off</strong> or{" "}
        <strong>term-mesh processes only</strong>.
      </Callout>

      <h2>CLI options</h2>
      <table>
        <thead>
          <tr>
            <th>Flag</th>
            <th>Description</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>
              <code>--socket PATH</code>
            </td>
            <td>Custom socket path</td>
          </tr>
          <tr>
            <td>
              <code>--json</code>
            </td>
            <td>Output in JSON format</td>
          </tr>
          <tr>
            <td>
              <code>--window ID</code>
            </td>
            <td>Target a specific window</td>
          </tr>
          <tr>
            <td>
              <code>--workspace ID</code>
            </td>
            <td>Target a specific workspace</td>
          </tr>
          <tr>
            <td>
              <code>--surface ID</code>
            </td>
            <td>Target a specific surface</td>
          </tr>
          <tr>
            <td>
              <code>--id-format refs|uuids|both</code>
            </td>
            <td>Control identifier format in JSON output</td>
          </tr>
        </tbody>
      </table>

      <h2>Workspace commands</h2>

      <Cmd
        name="list-workspaces"
        desc="List all open workspaces."
        cli={`term-mesh list-workspaces
term-mesh list-workspaces --json`}
        socket={`{"id":"ws-list","method":"workspace.list","params":{}}`}
      />
      <Cmd
        name="new-workspace"
        desc="Create a new workspace."
        cli={`term-mesh new-workspace`}
        socket={`{"id":"ws-new","method":"workspace.create","params":{}}`}
      />
      <Cmd
        name="select-workspace"
        desc="Switch to a specific workspace."
        cli={`term-mesh select-workspace --workspace <id>`}
        socket={`{"id":"ws-select","method":"workspace.select","params":{"workspace_id":"<id>"}}`}
      />
      <Cmd
        name="current-workspace"
        desc="Get the currently active workspace."
        cli={`term-mesh current-workspace
term-mesh current-workspace --json`}
        socket={`{"id":"ws-current","method":"workspace.current","params":{}}`}
      />
      <Cmd
        name="close-workspace"
        desc="Close a workspace."
        cli={`term-mesh close-workspace --workspace <id>`}
        socket={`{"id":"ws-close","method":"workspace.close","params":{"workspace_id":"<id>"}}`}
      />

      <h2>Split commands</h2>

      <Cmd
        name="new-split"
        desc="Create a new split pane. Directions: left, right, up, down."
        cli={`term-mesh new-split right
term-mesh new-split down`}
        socket={`{"id":"split-new","method":"surface.split","params":{"direction":"right"}}`}
      />
      <Cmd
        name="list-surfaces"
        desc="List all surfaces in the current workspace."
        cli={`term-mesh list-surfaces
term-mesh list-surfaces --json`}
        socket={`{"id":"surface-list","method":"surface.list","params":{}}`}
      />
      <Cmd
        name="focus-surface"
        desc="Focus a specific surface."
        cli={`term-mesh focus-surface --surface <id>`}
        socket={`{"id":"surface-focus","method":"surface.focus","params":{"surface_id":"<id>"}}`}
      />

      <h2>Input commands</h2>

      <Cmd
        name="send"
        desc="Send text input to the focused terminal."
        cli={`term-mesh send "echo hello"
term-mesh send "ls -la\\n"`}
        socket={`{"id":"send-text","method":"surface.send_text","params":{"text":"echo hello\\n"}}`}
      />
      <Cmd
        name="send-key"
        desc="Send a key press. Keys: enter, tab, escape, backspace, delete, up, down, left, right."
        cli={`term-mesh send-key enter`}
        socket={`{"id":"send-key","method":"surface.send_key","params":{"key":"enter"}}`}
      />
      <Cmd
        name="send-surface"
        desc="Send text to a specific surface."
        cli={`term-mesh send-surface --surface <id> "command"`}
        socket={`{"id":"send-surface","method":"surface.send_text","params":{"surface_id":"<id>","text":"command"}}`}
      />
      <Cmd
        name="send-key-surface"
        desc="Send a key press to a specific surface."
        cli={`term-mesh send-key-surface --surface <id> enter`}
        socket={`{"id":"send-key-surface","method":"surface.send_key","params":{"surface_id":"<id>","key":"enter"}}`}
      />

      <h2>Notification commands</h2>

      <Cmd
        name="notify"
        desc="Send a notification."
        cli={`term-mesh notify --title "Title" --body "Body"
term-mesh notify --title "T" --subtitle "S" --body "B"`}
        socket={`{"id":"notify","method":"notification.create","params":{"title":"Title","subtitle":"S","body":"Body"}}`}
      />
      <Cmd
        name="list-notifications"
        desc="List all notifications."
        cli={`term-mesh list-notifications
term-mesh list-notifications --json`}
        socket={`{"id":"notif-list","method":"notification.list","params":{}}`}
      />
      <Cmd
        name="clear-notifications"
        desc="Clear all notifications."
        cli={`term-mesh clear-notifications`}
        socket={`{"id":"notif-clear","method":"notification.clear","params":{}}`}
      />

      <h2>Sidebar metadata commands</h2>
      <p>
        Set status pills, progress bars, and log entries in the sidebar for any
        workspace. Useful for build scripts, CI integrations, and AI coding
        agents that want to surface state at a glance.
      </p>

      <Cmd
        name="set-status"
        desc="Set a sidebar status pill. Use a unique key so different tools can manage their own entries."
        cli={`term-mesh set-status build "compiling" --icon hammer --color "#ff9500"
term-mesh set-status deploy "v1.2.3" --workspace workspace:2`}
        socket={`set_status build compiling --icon=hammer --color=#ff9500 --tab=<workspace-uuid>`}
      />
      <Cmd
        name="clear-status"
        desc="Remove a sidebar status entry by key."
        cli={`term-mesh clear-status build`}
        socket={`clear_status build --tab=<workspace-uuid>`}
      />
      <Cmd
        name="list-status"
        desc="List all sidebar status entries for a workspace."
        cli={`term-mesh list-status`}
        socket={`list_status --tab=<workspace-uuid>`}
      />
      <Cmd
        name="set-progress"
        desc="Set a progress bar in the sidebar (0.0 to 1.0)."
        cli={`term-mesh set-progress 0.5 --label "Building..."
term-mesh set-progress 1.0 --label "Done"`}
        socket={`set_progress 0.5 --label=Building... --tab=<workspace-uuid>`}
      />
      <Cmd
        name="clear-progress"
        desc="Clear the sidebar progress bar."
        cli={`term-mesh clear-progress`}
        socket={`clear_progress --tab=<workspace-uuid>`}
      />
      <Cmd
        name="log"
        desc="Append a log entry to the sidebar. Levels: info, progress, success, warning, error."
        cli={`term-mesh log "Build started"
term-mesh log --level error --source build "Compilation failed"
term-mesh log --level success -- "All 42 tests passed"`}
        socket={`log --level=error --source=build --tab=<workspace-uuid> -- Compilation failed`}
      />
      <Cmd
        name="clear-log"
        desc="Clear all sidebar log entries."
        cli={`term-mesh clear-log`}
        socket={`clear_log --tab=<workspace-uuid>`}
      />
      <Cmd
        name="list-log"
        desc="List sidebar log entries."
        cli={`term-mesh list-log
term-mesh list-log --limit 5`}
        socket={`list_log --limit=5 --tab=<workspace-uuid>`}
      />
      <Cmd
        name="sidebar-state"
        desc="Dump all sidebar metadata (cwd, git branch, ports, status, progress, logs)."
        cli={`term-mesh sidebar-state
term-mesh sidebar-state --workspace workspace:2`}
        socket={`sidebar_state --tab=<workspace-uuid>`}
      />

      <h2>Utility commands</h2>

      <Cmd
        name="ping"
        desc="Check if term-mesh is running and responsive."
        cli={`term-mesh ping`}
        socket={`{"id":"ping","method":"system.ping","params":{}}
// Response: {"id":"ping","ok":true,"result":{"pong":true}}`}
      />
      <Cmd
        name="capabilities"
        desc="List available socket methods and current access mode."
        cli={`term-mesh capabilities
term-mesh capabilities --json`}
        socket={`{"id":"caps","method":"system.capabilities","params":{}}`}
      />
      <Cmd
        name="identify"
        desc="Show focused window/workspace/pane/surface context."
        cli={`term-mesh identify
term-mesh identify --json`}
        socket={`{"id":"identify","method":"system.identify","params":{}}`}
      />

      <h2>Environment variables</h2>
      <table>
        <thead>
          <tr>
            <th>Variable</th>
            <th>Description</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>
              <code>CMUX_SOCKET_PATH</code>
            </td>
            <td>Override the socket path used by CLI and integrations</td>
          </tr>
          <tr>
            <td>
              <code>CMUX_SOCKET_ENABLE</code>
            </td>
            <td>
              Force-enable/disable socket (<code>1</code>/<code>0</code>,{" "}
              <code>true</code>/<code>false</code>, <code>on</code>/
              <code>off</code>)
            </td>
          </tr>
          <tr>
            <td>
              <code>CMUX_SOCKET_MODE</code>
            </td>
            <td>
              Override access mode (<code>term-meshOnly</code>,{" "}
              <code>allowAll</code>, <code>off</code>). Also accepts{" "}
              <code>term-mesh-only</code>/<code>term-mesh_only</code> and{" "}
              <code>allow-all</code>/<code>allow_all</code>
            </td>
          </tr>
          <tr>
            <td>
              <code>CMUX_WORKSPACE_ID</code>
            </td>
            <td>Auto-set: current workspace ID</td>
          </tr>
          <tr>
            <td>
              <code>CMUX_SURFACE_ID</code>
            </td>
            <td>Auto-set: current surface ID</td>
          </tr>
          <tr>
            <td>
              <code>TERM_PROGRAM</code>
            </td>
            <td>
              Set to <code>ghostty</code>
            </td>
          </tr>
          <tr>
            <td>
              <code>TERM</code>
            </td>
            <td>
              Set to <code>xterm-ghostty</code>
            </td>
          </tr>
        </tbody>
      </table>
      <Callout>
        Legacy <code>CMUX_SOCKET_MODE</code> values <code>full</code> and{" "}
        <code>notifications</code> are still accepted for compatibility.
      </Callout>

      <h2>Detecting term-mesh</h2>
      <CodeBlock title="bash" lang="bash">{`# Prefer explicit socket path if set
SOCK="\${CMUX_SOCKET_PATH:-/tmp/term-mesh.sock}"
[ -S "$SOCK" ] && echo "Socket available"

# Check for the CLI
command -v term-mesh &>/dev/null && echo "term-mesh available"

# In term-mesh-managed terminals these are auto-set
[ -n "\${CMUX_WORKSPACE_ID:-}" ] && [ -n "\${CMUX_SURFACE_ID:-}" ] && echo "Inside term-mesh surface"

# Distinguish from regular Ghostty
[ "$TERM_PROGRAM" = "ghostty" ] && [ -n "\${CMUX_WORKSPACE_ID:-}" ] && echo "In term-mesh"`}</CodeBlock>

      <h2>Examples</h2>

      <h3>Python client</h3>
      <CodeBlock title="python" lang="python">{`import json
import os
import socket

SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/term-mesh.sock")

def rpc(method, params=None, req_id=1):
    payload = {"id": req_id, "method": method, "params": params or {}}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(payload).encode("utf-8") + b"\\n")
        return json.loads(sock.recv(65536).decode("utf-8"))

# List workspaces
print(rpc("workspace.list", req_id="ws"))

# Send notification
print(rpc(
    "notification.create",
    {"title": "Hello", "body": "From Python!"},
    req_id="notify"
))`}</CodeBlock>

      <h3>Shell script</h3>
      <CodeBlock title="bash" lang="bash">{`#!/bin/bash
SOCK="\${CMUX_SOCKET_PATH:-/tmp/term-mesh.sock}"

term-mesh_cmd() {
    printf "%s\\n" "$1" | nc -U "$SOCK"
}

term-mesh_cmd '{"id":"ws","method":"workspace.list","params":{}}'
term-mesh_cmd '{"id":"notify","method":"notification.create","params":{"title":"Done","body":"Task complete"}}'`}</CodeBlock>

      <h3>Build script with notification</h3>
      <CodeBlock title="bash" lang="bash">{`#!/bin/bash
npm run build
if [ $? -eq 0 ]; then
    term-mesh notify --title "✓ Build Success" --body "Ready to deploy"
else
    term-mesh notify --title "✗ Build Failed" --body "Check the logs"
fi`}</CodeBlock>
    </>
  );
}
