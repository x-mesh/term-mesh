#!/usr/bin/env python3
"""Python client for the term-mesh peer-federation wire protocol.

Speaks the length-prefixed protobuf `Envelope` framing defined in
`daemon/term-meshd/src/peer/framing.rs` (LE u32 byte length + protobuf
payload) and drives the handshake documented in
`daemon/term-meshd/src/peer/connection.rs` / `docs/peer-federation-protocol.md`:

    Hello -> host Hello -> AuthChallenge -> Auth(ssh-passthrough) -> AuthResult -> Ready

This is NOT the `tests_v2/termmesh.py` app-socket family (JSON-line protocol
over `TERMMESH_SOCKET`, driving the macOS app). It speaks the separate peer
wire protocol (protobuf over `TERMMESH_PEER_SOCKET`), which a bare
`term-meshd` process serves on its own -- no app required, hence usable for
pure-daemon e2e on a dev machine.

Generated protobuf bindings live in `tests_v2/peer_pb2/peer_pb2.py`.
Regenerate after any `proto/peer/v1/peer.proto` change with:

    ./tests_v2/peer_pb2/generate.sh

(see that script for why it pins a specific protoc release).
"""

from __future__ import annotations

import os
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).parent / "peer_pb2"))
import peer_pb2 as pb  # noqa: E402  (generated bindings; see module docstring)


PROTOCOL_VERSION = "1.0.0"
MAX_FRAME_BYTES = 16 * 1024 * 1024
AUTH_METHOD = "ssh-passthrough"
WORKSPACE_LIFECYCLE_CAPABILITY = "workspace.lifecycle.v1"

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DAEMON_BINARY = REPO_ROOT / "daemon" / "target" / "release" / "term-meshd"


class PeerClientError(Exception):
    """Raised for peer wire-protocol failures: timeout, decode, handshake rejection."""


@dataclass
class WorkspaceInfo:
    """One `Workspace` roster entry, as returned by `PeerClient.list_workspaces`."""

    id: bytes
    title: str
    is_default: bool
    pane_count: int

    @property
    def id_hex(self) -> str:
        return self.id.hex()


def _count_panes(layout: "pb.WorkspaceLayout") -> int:
    """Recursively count leaf panes in a `WorkspaceLayout` tree."""
    kind = layout.WhichOneof("node")
    if kind == "pane":
        return 1
    if kind == "split":
        return _count_panes(layout.split.first) + _count_panes(layout.split.second)
    return 0


class PeerClient:
    """One handshake-driven connection to a term-meshd peer-federation host."""

    def __init__(self, socket_path: str, display_name: str = "peer-e2e-test"):
        self.socket_path = str(socket_path)
        self.display_name = display_name
        self._sock: Optional[socket.socket] = None
        self._recv_buf = b""
        self._seq = 0
        self.host_capabilities: List[str] = []
        self.session_id: bytes = b""
        # Envelopes observed while waiting for something else -- pushes
        # (WorkspaceUpdate) mostly. Recorded so a fire-and-forget RPC's side
        # effect (e.g. the WorkspaceRemoved push) can be asserted even
        # though nothing paired it to a reply via correlation_id.
        self.workspace_removed_ids: List[bytes] = []

    # ---- connection lifecycle ------------------------------------------------

    def connect(self, timeout_s: float = 10.0) -> None:
        deadline = time.time() + timeout_s
        while not os.path.exists(self.socket_path):
            if time.time() >= deadline:
                raise PeerClientError(f"peer socket not found at {self.socket_path}")
            time.sleep(0.05)
        last_err: Optional[OSError] = None
        while time.time() < deadline:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                sock.connect(self.socket_path)
                self._sock = sock
                return
            except OSError as e:
                last_err = e
                sock.close()
                time.sleep(0.05)
        raise PeerClientError(f"failed to connect to {self.socket_path}: {last_err}")

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            finally:
                self._sock = None

    def __enter__(self) -> "PeerClient":
        self.connect()
        return self

    def __exit__(self, *exc) -> bool:
        self.close()
        return False

    # ---- framing --------------------------------------------------------------

    def _next_seq(self) -> int:
        self._seq += 1
        return self._seq

    def _send(self, **payload_kwargs) -> int:
        if self._sock is None:
            raise PeerClientError("not connected")
        seq = self._next_seq()
        env = pb.Envelope(seq=seq, **payload_kwargs)
        data = env.SerializeToString()
        if len(data) > MAX_FRAME_BYTES:
            raise PeerClientError(f"outgoing frame too large: {len(data)}")
        self._sock.sendall(struct.pack("<I", len(data)) + data)
        return seq

    def _recv_exact(self, n: int, deadline: float) -> bytes:
        while len(self._recv_buf) < n:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise PeerClientError(f"timed out waiting for {n} bytes (have {len(self._recv_buf)})")
            self._sock.settimeout(remaining)
            try:
                chunk = self._sock.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                raise PeerClientError("peer connection closed")
            self._recv_buf += chunk
        out, self._recv_buf = self._recv_buf[:n], self._recv_buf[n:]
        return out

    def _recv_envelope(self, timeout_s: float) -> "pb.Envelope":
        deadline = time.time() + timeout_s
        header = self._recv_exact(4, deadline)
        (length,) = struct.unpack("<I", header)
        if length > MAX_FRAME_BYTES:
            raise PeerClientError(f"incoming frame length {length} exceeds {MAX_FRAME_BYTES}")
        payload = self._recv_exact(length, deadline)
        env = pb.Envelope()
        env.ParseFromString(payload)
        return env

    def _record_push(self, env: "pb.Envelope") -> None:
        if env.WhichOneof("payload") != "workspace_update":
            return
        update = env.workspace_update
        if update.WhichOneof("kind") == "workspace_removed":
            self.workspace_removed_ids.append(update.workspace_removed.workspace_id)

    def _read_until(self, match: Callable[["pb.Envelope"], bool], timeout_s: float) -> "pb.Envelope":
        """Read envelopes until one satisfies `match`. Every envelope seen
        along the way (pushes included) is recorded via `_record_push`
        before being discarded, so a caller waiting on a *later* reply
        still observes an earlier broadcast (e.g. WorkspaceRemoved) that
        the single-connection FIFO ordering guarantees arrives first."""
        deadline = time.time() + timeout_s
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise PeerClientError("timed out waiting for expected envelope")
            env = self._recv_envelope(remaining)
            self._record_push(env)
            if match(env):
                return env

    # ---- handshake --------------------------------------------------------------

    def handshake(self, timeout_s: float = 10.0) -> None:
        """Hello -> host Hello -> AuthChallenge -> Auth -> AuthResult -> Ready."""
        self._send(
            hello=pb.Hello(
                protocol_version=PROTOCOL_VERSION,
                peer_id=uuid.uuid4().bytes,
                display_name=self.display_name,
                capabilities=[WORKSPACE_LIFECYCLE_CAPABILITY],
                app_version="peer-e2e-test",
            )
        )

        host_hello_env = self._read_until(lambda e: e.WhichOneof("payload") == "hello", timeout_s)
        self.host_capabilities = list(host_hello_env.hello.capabilities)

        self._read_until(lambda e: e.WhichOneof("payload") == "auth_challenge", timeout_s)

        self._send(auth=pb.Auth(method=AUTH_METHOD, token_id=b"", signature=b""))
        result_env = self._read_until(lambda e: e.WhichOneof("payload") == "auth_result", timeout_s)
        result = result_env.auth_result
        if not result.accepted:
            raise PeerClientError(f"auth rejected: {result.reason}")
        self.session_id = result.session_id

    # ---- workspace lifecycle RPCs --------------------------------------------

    def list_workspaces(self, timeout_s: float = 10.0) -> List[WorkspaceInfo]:
        seq = self._send(list_workspaces=pb.ListWorkspaces())
        env = self._read_until(
            lambda e: e.correlation_id == seq and e.WhichOneof("payload") == "workspace_list",
            timeout_s,
        )
        out = []
        for ws in env.workspace_list.workspaces:
            pane_count = _count_panes(ws.layout) if ws.HasField("layout") else 0
            out.append(
                WorkspaceInfo(id=ws.workspace_id, title=ws.title, is_default=ws.is_default, pane_count=pane_count)
            )
        return out

    def create_workspace(self, title: str, timeout_s: float = 10.0) -> bytes:
        """Paired RPC: the reply's correlation_id echoes this request's seq."""
        seq = self._send(create_workspace_request=pb.CreateWorkspaceRequest(title=title))
        env = self._read_until(
            lambda e: e.correlation_id == seq and e.WhichOneof("payload") == "create_workspace_response",
            timeout_s,
        )
        resp = env.create_workspace_response
        if not resp.accepted:
            raise PeerClientError(f"CreateWorkspaceRequest({title!r}) refused: {resp.reason}")
        return resp.workspace_id

    def rename_workspace(self, workspace_id: bytes, title: str) -> None:
        """Fire-and-forget by protocol design -- no paired reply. Callers
        that need a synchronization point should follow with
        `list_workspaces()` on this same connection: the host's
        `reader_loop` processes envelopes strictly in arrival order per
        connection, so the rename is guaranteed applied before that
        reply is even read off the wire."""
        self._send(rename_workspace_request=pb.RenameWorkspaceRequest(workspace_id=workspace_id, title=title))

    def delete_workspace(self, workspace_id: bytes) -> None:
        """Fire-and-forget; same per-connection ordering guarantee as
        `rename_workspace`. The host also broadcasts a WorkspaceRemoved
        push to this connection (it registers itself as a broadcast
        target at Ready) strictly before any later reply on this same
        connection, so `list_workspaces()` right after this call is
        enough to observe both effects -- see `_read_until`."""
        self._send(delete_workspace_request=pb.DeleteWorkspaceRequest(workspace_id=workspace_id))

    def ping(self, nonce: int = 1, timeout_s: float = 5.0) -> None:
        self._send(ping=pb.Ping(nonce=nonce))
        self._read_until(lambda e: e.WhichOneof("payload") == "pong" and e.pong.nonce == nonce, timeout_s)


class TermMeshDaemon:
    """Spawns an isolated `term-meshd` process for peer-federation e2e tests.

    Isolation, so this never collides with or disrupts a real running
    term-meshd instance on the same machine:
      - `HOME` override -> `peer-workspaces.json` persists under
        `<home>/Library/Application Support/term-meshd/` (`dirs::data_local_dir()`
        resolves via `$HOME` on macOS/unix -- verified against the vendored
        `dirs-sys` 0.5.0 source; see `daemon/term-meshd/src/peer/persist.rs`).
      - `TERMMESH_PEER_SOCKET` -> isolated peer-protocol socket (opt-in;
        unset means no peer server at all).
      - `TERMMESH_DAEMON_UNIX_PATH` -> isolated main app-protocol socket.
        The production default lives under `dirs::runtime_dir()`/`$TMPDIR`,
        NOT gated by `HOME`, and `socket::serve` unlinks any pre-existing
        file at that path on boot -- without this override a real running
        daemon's socket file would be removed out from under it.
      - `TERM_MESH_HTTP_DISABLED=1` -> the dashboard HTTP server otherwise
        binds a fixed `127.0.0.1:9876`, which a real running daemon may
        already hold.

    Socket paths are placed under a short-prefix `/tmp/...` directory
    rather than the caller's working directory or a scratch path, because
    macOS's `sockaddr_un` has a ~104-byte `sun_path` limit and a nested
    scratch/tempdir path can exceed it.
    """

    def __init__(
        self,
        binary_path: Optional[Path] = None,
        workdir: Optional[Path] = None,
        extra_env: Optional[Dict[str, str]] = None,
    ):
        self.binary_path = Path(binary_path) if binary_path else DEFAULT_DAEMON_BINARY
        if not self.binary_path.exists():
            raise PeerClientError(
                f"term-meshd binary not found at {self.binary_path}; "
                "build it first: cd daemon && cargo build --release"
            )
        self._owns_workdir = workdir is None
        self.workdir = Path(workdir) if workdir else Path(tempfile.mkdtemp(prefix="tm-peer-e2e-"))
        self.home_dir = self.workdir / "home"
        self.home_dir.mkdir(parents=True, exist_ok=True)
        self._sock_dir = Path(tempfile.mkdtemp(prefix="tm-peer-e2e-sock-", dir="/tmp"))
        self.peer_socket_path = self._sock_dir / "peer.sock"
        self.daemon_socket_path = self._sock_dir / "daemon.sock"
        self.log_path = self.workdir / "term-meshd.log"
        self.extra_env = dict(extra_env or {})
        self.proc: Optional[subprocess.Popen] = None
        self._log_file = None

    @property
    def workspaces_path(self) -> Path:
        """Where this instance's `peer-workspaces.json` lives, for tests
        that want to assert on the persisted file directly."""
        return self.home_dir / "Library" / "Application Support" / "term-meshd" / "peer-workspaces.json"

    def _env(self) -> Dict[str, str]:
        env = dict(os.environ)
        env["HOME"] = str(self.home_dir)
        env["TERMMESH_PEER_SOCKET"] = str(self.peer_socket_path)
        env["TERMMESH_DAEMON_UNIX_PATH"] = str(self.daemon_socket_path)
        env["TERM_MESH_HTTP_DISABLED"] = "1"
        env.update(self.extra_env)
        return env

    def start(self, timeout_s: float = 15.0) -> None:
        if self.proc is not None:
            raise PeerClientError("daemon already started")
        self._log_file = open(self.log_path, "a")
        self.proc = subprocess.Popen(
            [str(self.binary_path)],
            env=self._env(),
            stdout=self._log_file,
            stderr=subprocess.STDOUT,
        )
        deadline = time.time() + timeout_s
        while not self.peer_socket_path.exists():
            if self.proc.poll() is not None:
                raise PeerClientError(
                    f"term-meshd exited early (code={self.proc.returncode}); see {self.log_path}"
                )
            if time.time() >= deadline:
                raise PeerClientError(
                    f"peer socket {self.peer_socket_path} did not appear within {timeout_s}s; see {self.log_path}"
                )
            time.sleep(0.05)

    def stop(self, timeout_s: float = 5.0) -> None:
        if self.proc is None:
            return
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=timeout_s)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5.0)
        self.proc = None
        if self._log_file is not None:
            self._log_file.close()
            self._log_file = None

    def restart(self, timeout_s: float = 15.0) -> None:
        """Stop then start again with the SAME home/socket paths, so
        persisted state (`peer-workspaces.json`) survives -- this is the
        primitive the restart-persistence scenario is built on."""
        self.stop()
        self.start(timeout_s=timeout_s)

    def cleanup(self) -> None:
        self.stop()
        shutil.rmtree(self._sock_dir, ignore_errors=True)
        if self._owns_workdir:
            shutil.rmtree(self.workdir, ignore_errors=True)

    def __enter__(self) -> "TermMeshDaemon":
        self.start()
        return self

    def __exit__(self, *exc) -> bool:
        self.cleanup()
        return False
