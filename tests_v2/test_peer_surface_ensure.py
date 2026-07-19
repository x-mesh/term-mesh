#!/usr/bin/env python3
"""Live daemon QA for deterministic surface.ensure.v1 reconciliation."""

from __future__ import annotations

import socket
import sys
import tempfile
import threading
import time
import uuid
from contextlib import closing
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import peer_client as pc
from peer_client import PeerClient, PeerClientError, TermMeshDaemon

pb = pc.pb


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PeerClientError(message)


def connect(daemon: TermMeshDaemon, name: str = "surface-ensure-e2e") -> PeerClient:
    client = PeerClient(str(daemon.peer_socket_path), display_name=name)
    client.connect()
    client.handshake()
    require(
        pc.SURFACE_ENSURE_CAPABILITY in client.host_capabilities,
        f"host omitted {pc.SURFACE_ENSURE_CAPABILITY}: {client.host_capabilities}",
    )
    return client


def ensure(client: PeerClient, key: str, cwd: str, args=None, request_id=None):
    return client.ensure_surface(
        key=key,
        cwd=cwd,
        executable="/bin/sh",
        args=args or ["-c", "while :; do sleep 60; done"],
        request_id=request_id,
    )


def main() -> int:
    fixture = Path(tempfile.mkdtemp(prefix="tm-runner-fixture-"))
    secret = "ENSURE_SECRET_MUST_NOT_APPEAR_7c0c0a"
    daemon = TermMeshDaemon()
    try:
        daemon.start()

        legacy = PeerClient(
            str(daemon.peer_socket_path),
            display_name="legacy-no-ensure-capability",
            capabilities=[pc.WORKSPACE_LIFECYCLE_CAPABILITY],
        )
        legacy.connect()
        legacy.handshake()
        legacy.ping(7)
        legacy.close()

        with closing(connect(daemon)) as client:
            first = ensure(client, "runner-sequential", str(fixture))
            require(first.result == pb.ENSURE_SURFACE_RESULT_CREATED, f"first ensure: {first}")
            require(first.pid > 0 and len(first.surface_id) == 16, f"invalid live identity: {first}")

            sequential = [ensure(client, "runner-sequential", str(fixture)) for _ in range(9)]
            require(
                all(r.result == pb.ENSURE_SURFACE_RESULT_REUSED for r in sequential),
                f"sequential ensure did not reuse: {sequential}",
            )
            require(
                {(r.surface_id, r.instance_id, r.generation, r.pid) for r in [first, *sequential]}
                == {(first.surface_id, first.instance_id, first.generation, first.pid)},
                "sequential identity changed",
            )

            duplicate_id = uuid.uuid4().bytes
            original = ensure(client, "runner-duplicate-id", str(fixture), request_id=duplicate_id)
            duplicate = ensure(
                client,
                "runner-duplicate-id-changed-payload",
                str(fixture),
                args=["-c", "while :; do sleep 59; done"],
                request_id=duplicate_id,
            )
            require(original.result == pb.ENSURE_SURFACE_RESULT_CREATED, f"duplicate setup: {original}")
            require(
                duplicate.error_code == pb.ENSURE_SURFACE_ERROR_CODE_DUPLICATE_REQUEST_ID,
                f"request_id reuse was not rejected: {duplicate}",
            )

            conflict = ensure(
                client,
                "runner-sequential",
                str(fixture),
                args=["-c", "while :; do sleep 59; done"],
            )
            require(conflict.result == pb.ENSURE_SURFACE_RESULT_SPEC_CONFLICT, f"conflict: {conflict}")
            require(conflict.surface_id == first.surface_id, "conflict lost stable surface id")

            missing_cwd = ensure(client, "runner-bad-cwd", str(fixture / "missing"))
            require(
                missing_cwd.error_code == pb.ENSURE_SURFACE_ERROR_CODE_CWD_NOT_FOUND,
                f"bad cwd taxonomy: {missing_cwd}",
            )
            missing_command = client.ensure_surface(
                key="runner-bad-command",
                cwd=str(fixture),
                executable=str(fixture / "missing-command"),
            )
            require(
                missing_command.error_code == pb.ENSURE_SURFACE_ERROR_CODE_COMMAND_NOT_FOUND,
                f"bad command taxonomy: {missing_command}",
            )
            exited = ensure(client, "runner-exited", str(fixture), args=["-c", "exit 42"])
            require(
                exited.error_code == pb.ENSURE_SURFACE_ERROR_CODE_COMMAND_EXITED and exited.exit_code == 42,
                f"immediate exit taxonomy: {exited}",
            )

            malformed = client.ensure_surface(
                key="runner-malformed",
                cwd="relative/path",
                executable="/bin/sh",
            )
            require(
                malformed.error_code == pb.ENSURE_SURFACE_ERROR_CODE_INVALID_REQUEST,
                f"malformed request taxonomy: {malformed}",
            )
            oversized = client.ensure_surface(
                key="runner-oversized",
                cwd=str(fixture),
                executable="/bin/sh",
                args=["x" * 65_537],
            )
            require(
                oversized.error_code == pb.ENSURE_SURFACE_ERROR_CODE_REQUEST_TOO_LARGE,
                f"oversized field taxonomy: {oversized}",
            )

            client.attach_surface(first.surface_id)
            client.detach_surface(first.surface_id)
            detached = ensure(client, "runner-sequential", str(fixture))
            require(detached.pid == first.pid, f"detach terminated or replaced process: {detached}")

        with closing(connect(daemon, "concurrent-pipeline")) as concurrent_client:
            concurrent = concurrent_client.ensure_same_surface_concurrently(
                20,
                key="runner-concurrent",
                cwd=str(fixture),
                executable="/bin/sh",
                args=["-c", "while :; do sleep 60; done"],
            )
        require(
            sum(r.result == pb.ENSURE_SURFACE_RESULT_CREATED for r in concurrent) == 1,
            f"concurrent ensure must create exactly once: {[r.result for r in concurrent]}",
        )
        require(
            len({(r.surface_id, r.instance_id, r.generation, r.pid) for r in concurrent}) == 1,
            "concurrent ensure produced duplicate processes",
        )

        conflict_barrier = threading.Barrier(2)

        def conflicting_spec(index: int):
            contender = connect(daemon, f"conflicting-spec-{index}")
            try:
                conflict_barrier.wait(timeout=5)
                return ensure(
                    contender,
                    "runner-concurrent-conflict",
                    str(fixture),
                    args=["-c", f"while :; do sleep {58 + index}; done"],
                )
            finally:
                contender.close()

        with ThreadPoolExecutor(max_workers=2) as pool:
            raced_conflict = list(pool.map(conflicting_spec, range(2)))
        require(
            sorted(r.result for r in raced_conflict)
            == sorted([pb.ENSURE_SURFACE_RESULT_CREATED, pb.ENSURE_SURFACE_RESULT_SPEC_CONFLICT]),
            f"concurrent conflicting specs did not resolve deterministically: {raced_conflict}",
        )
        require(
            raced_conflict[0].surface_id == raced_conflict[1].surface_id,
            "concurrent conflict produced different logical ids",
        )

        dropped = connect(daemon, "dropped-response")
        dropped.send_ensure_without_waiting(
            "runner-dropped-response",
            str(fixture),
            "/bin/sh",
            ["-c", "while :; do sleep 60; done", secret],
        )
        dropped.close()
        with closing(connect(daemon, "dropped-response-retry")) as retry:
            dropped_surface = None
            side_effect_deadline = time.monotonic() + 10.0
            while time.monotonic() < side_effect_deadline:
                dropped_surface = next(
                    (surface for surface in retry.list_surfaces() if surface.title == "runner-dropped-response"),
                    None,
                )
                if dropped_surface is not None:
                    break
                time.sleep(0.01)
            require(dropped_surface is not None, "dropped response request produced no observable surface")
            recovered = ensure(
                retry,
                "runner-dropped-response",
                str(fixture),
                args=["-c", "while :; do sleep 60; done", secret],
            )
            require(
                recovered.result == pb.ENSURE_SURFACE_RESULT_REUSED,
                f"dropped response retry did not reuse completed side effect: {recovered}",
            )
            require(
                recovered.surface_id == dropped_surface.surface_id,
                "dropped response retry changed logical surface identity",
            )

        before_restart = concurrent[0]
        daemon.restart()
        with closing(connect(daemon, "restart-generation")) as restarted:
            recreated = ensure(restarted, "runner-concurrent", str(fixture))
            require(recreated.result == pb.ENSURE_SURFACE_RESULT_RECREATED, f"restart: {recreated}")
            require(recreated.surface_id == before_restart.surface_id, "restart changed logical id")
            require(recreated.instance_id != before_restart.instance_id, "restart reused instance id")
            require(recreated.generation == before_restart.generation + 1, "generation did not increment")
            require(recreated.pid > 0, "restart did not create a live child")

        log_text = daemon.log_path.read_text(errors="replace")
        require(secret not in log_text, "raw ensure argument leaked into daemon log")

        for malformed_payload in (b"\xff",):
            raw = PeerClient(str(daemon.peer_socket_path), "malformed-frame")
            raw.connect()
            raw.send_malformed_frame(malformed_payload)
            raw.close()
        raw = PeerClient(str(daemon.peer_socket_path), "oversized-frame")
        raw.connect()
        raw.send_oversized_frame_header()
        raw.close()

        with closing(connect(daemon, "post-malformed-health")) as healthy:
            healthy.ping(12345)
    finally:
        daemon.cleanup()
        try:
            fixture.rmdir()
        except OSError:
            pass

    print("PASS: deterministic peer surface ensure QA")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (PeerClientError, socket.error) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
