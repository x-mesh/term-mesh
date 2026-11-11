#!/usr/bin/env python3
"""A peer viewer's attach-time Resize must not strip colors from the screen the
host re-sends. Regression for the resize snapshot being plain text (no SGR), so
every viewer connect/reconnect showed an uncolored screen.

Flow: the DEBUG loopback open starts the app's in-app peer server; a raw
PeerClient then attaches a host surface that printed colored markers and sends
three Resizes, each checked on the bytes after the last ESC[2J: rows only
(columns unchanged), columns and rows together, and rows again after the viewer
detaches and reconnects on a new PeerClient. The re-sent screen must still carry
the color SGR in effect at each marker.
"""
import re
import select
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError
from peer_client import PeerClient, PeerClientError, pb

SGR_RE = re.compile(rb"\x1b\[([0-9;:]*)m")


def _wait(predicate, timeout_s: float = 15.0, interval_s: float = 0.2) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def _collect_pty(peer: PeerClient, surface_id: bytes, duration_s: float,
                 stop_when=None) -> bytes:
    """Gather PtyData payloads for the surface for up to duration_s, or until
    stop_when(collected) is true."""
    collected = b""
    deadline = time.time() + duration_s
    while time.time() < deadline:
        if not peer._recv_buf:
            ready, _, _ = select.select([peer._sock], [], [], min(0.2, max(0.0, deadline - time.time())))
            if not ready:
                continue
        # Fixed budget: _recv_envelope consumes the header first, so a timeout
        # mid-frame would desync the stream.
        env = peer._recv_envelope(5.0)
        if env.WhichOneof("payload") != "pty_data":
            continue
        if env.pty_data.surface_id != surface_id:
            continue
        collected += env.pty_data.payload
        if stop_when is not None and stop_when(collected):
            break
    return collected


def _drain_quiet(peer: PeerClient, surface_id: bytes, quiet_s: float = 0.8,
                 max_s: float = 10.0) -> bytes:
    """Collect until no PtyData arrives for quiet_s."""
    collected = b""
    deadline = time.time() + max_s
    while time.time() < deadline:
        chunk = _collect_pty(peer, surface_id, quiet_s, stop_when=lambda b: True)
        if not chunk:
            break
        collected += chunk
    return collected


def _color_active_before(data: bytes, marker: bytes):
    """Follow SGR sequences up to the last occurrence of marker and report
    whether a foreground color is active there. Returns (active, context)."""
    pos = data.rfind(marker)
    if pos < 0:
        return False, b""
    active = False
    for m in SGR_RE.finditer(data[:pos]):
        params = m.group(1).decode("ascii", errors="replace")
        parts = params.split(";") if params else [""]
        i = 0
        while i < len(parts):
            p = parts[i]
            i += 1
            if ":" in p:
                if p.startswith("38:"):
                    active = True
                continue
            if p in ("", "0", "39"):
                active = False
            elif p in ("38", "48", "58"):
                if p == "38":
                    active = True
                mode = parts[i] if i < len(parts) else ""
                i += 4 if mode == "2" else 2 if mode == "5" else 0
            elif p.isdigit() and (30 <= int(p) <= 37 or 90 <= int(p) <= 97):
                active = True
    return active, data[max(0, pos - 60):pos]


RESIZE_CLEAR = b"\x1b[2J"


def _after_last_clear(data: bytes):
    """Bytes after the last ESC[2J, or None when the clear is absent. The resize
    path broadcasts ESC[2J ESC[H before re-sending the screen."""
    pos = data.rfind(RESIZE_CLEAR)
    if pos < 0:
        return None
    return data[pos + len(RESIZE_CLEAR):]


def _check_attach_colored(peer: PeerClient, surface_id: bytes, red: bytes, green: bytes):
    attach_bytes = _drain_quiet(peer, surface_id)
    for marker in (red, green):
        active, ctx = _color_active_before(attach_bytes, marker)
        if marker not in attach_bytes or not active:
            raise termmeshError(
                f"precondition failed: attach snapshot lacks colored {marker!r} "
                f"(context={ctx!r})"
            )


def _resize_and_check_colors(peer: PeerClient, host_key, surface_id: bytes,
                             red: bytes, green: bytes, step: str,
                             cols: int, rows: int):
    # A host pane with local focus ignores viewer sizes that do not claim
    # authority, so claim it like a viewer whose pane just gained focus.
    peer._send(resize=pb.Resize(
        surface_id=surface_id, cols=cols, rows=rows, claim_authority=True,
    ))

    def _both_after_clear(collected: bytes) -> bool:
        tail = _after_last_clear(collected)
        return tail is not None and red in tail and green in tail

    after = _collect_pty(peer, surface_id, 5.0, stop_when=_both_after_clear)

    with PeerClient(host_key) as probe:
        probe.connect()
        probe.handshake()
        now = [s for s in probe.list_surfaces() if s.surface_id == surface_id]
    if not now or (now[0].cols, now[0].rows) != (cols, rows):
        raise termmeshError(
            f"test is vacuous at step {step!r}: host size is not the requested size "
            f"(requested={cols}x{rows}, "
            f"actual={(now[0].cols, now[0].rows) if now else None})"
        )

    tail = _after_last_clear(after)
    if tail is None:
        raise termmeshError(
            f"step {step!r}: no ESC[2J resize snapshot within 5s; got {after[-200:]!r}"
        )
    for marker in (red, green):
        if marker not in tail:
            raise termmeshError(
                f"step {step!r}: {marker!r} missing after the resize clear: {tail[-200:]!r}"
            )
        active, ctx = _color_active_before(tail, marker)
        if not active:
            raise termmeshError(
                f"step {step!r}: expected a color SGR active before {marker!r} after "
                f"resize, got no color; preceding 60 bytes={ctx!r}"
            )


def main() -> int:
    token = uuid.uuid4().hex[:8]
    red = f"RZC_RED_{token}".encode()
    green = f"RZC_GREEN_{token}".encode()

    with termmesh() as c:
        # --- 1. bring up the in-app peer server via the loopback open
        status = c.peer_pane_status()
        if status.get("pane_sessions"):
            raise termmeshError(f"expected no pane sessions at baseline, got {status!r}")
        def _open_result():
            try:
                result = c.peer_pane_status().get("last_open_result")
            except termmeshError:
                return None
            return result if isinstance(result, dict) else None

        # The in-app peer server can still be starting right after launch, which
        # reports no_host_socket; each kick clears the previous result, so retry
        # that one error within the budget and fail on any other.
        open_deadline = time.time() + 60
        result = None
        while True:
            kicked = c.peer_open_remote_pane()
            if not kicked.get("started"):
                raise termmeshError(f"open_remote_pane did not start: {kicked!r}")
            if not _wait(lambda: _open_result() is not None,
                         timeout_s=max(0.0, open_deadline - time.time())):
                raise termmeshError(
                    f"open_remote_pane never reported a result (last={result!r})"
                )
            result = _open_result()
            if result.get("ok"):
                break
            if result.get("error") != "no_host_socket":
                raise termmeshError(f"open_remote_pane failed: {result!r}")
            if time.time() >= open_deadline:
                raise termmeshError(f"open_remote_pane failed: {result!r}")
        host_key = result["host_key"]
        c.close_surface(result["panel_id"])

        def _no_sessions():
            try:
                return not (c.peer_pane_status().get("pane_sessions") or [])
            except termmeshError:
                return False

        if not _wait(_no_sessions, timeout_s=15):
            raise termmeshError("loopback pane session did not close")

        # --- 2. host surface with colored markers
        host_sid = c.new_surface(panel_type="terminal")
        c.focus_surface(host_sid)
        peer = None
        attached = False
        surface_id = uuid.UUID(host_sid).bytes
        try:
            if not _wait(lambda: c.read_terminal_text(host_sid).strip() != "", timeout_s=10):
                raise termmeshError(f"surface {host_sid} shell prompt never rendered")
            c.send_surface(
                host_sid,
                f"clear; printf '\\033[31mRZC_%s_{token}\\033[0m\\n"
                f"\\033[1;32mRZC_%s_{token}\\033[0m\\n' RED GREEN\r",
            )

            def _markers_visible():
                text = c.read_terminal_text(host_sid)
                return red.decode() in text and green.decode() in text

            if not _wait(_markers_visible, timeout_s=10):
                raise termmeshError(
                    f"colored markers never rendered: {c.read_terminal_text(host_sid)[-300:]!r}"
                )

            # --- 3. attach through a raw peer client
            peer = PeerClient(host_key)
            peer.connect()
            peer.handshake()
            infos = [s for s in peer.list_surfaces() if s.surface_id == surface_id]
            if not infos:
                raise termmeshError(f"host surface {host_sid} not listed by the peer server")
            before_cols, before_rows = infos[0].cols, infos[0].rows
            peer.attach_surface(surface_id)
            attached = True

            # --- 4. attach snapshot is the precondition: markers arrive colored
            _check_attach_colored(peer, surface_id, red, green)

            # --- 5. resize steps; each requests a size different from the last
            _resize_and_check_colors(
                peer, host_key, surface_id, red, green, "rows-only",
                before_cols, max(2, before_rows - 4),
            )
            _resize_and_check_colors(
                peer, host_key, surface_id, red, green, "width",
                max(2, before_cols - 8), max(2, before_rows - 4),
            )

            # --- 6. same path on a fresh viewer connection
            try:
                peer.detach_surface(surface_id)
            finally:
                attached = False
                peer.close()
                peer = None
            peer = PeerClient(host_key)
            peer.connect()
            peer.handshake()
            peer.attach_surface(surface_id)
            attached = True
            _check_attach_colored(peer, surface_id, red, green)
            _resize_and_check_colors(
                peer, host_key, surface_id, red, green, "reconnect",
                before_cols, max(2, before_rows - 6),
            )
        finally:
            if peer is not None:
                try:
                    if attached:
                        peer.detach_surface(surface_id)
                finally:
                    peer.close()
            try:
                c.close_surface(host_sid)
            except termmeshError:
                pass

    print("PASS: peer resize snapshot preserves colors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
