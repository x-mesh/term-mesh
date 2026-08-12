#!/usr/bin/env python3
"""Unit coverage for the typed surface.terminate.v1 Python helper."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import peer_client as pc


class TerminateHelperTests(unittest.TestCase):
    def test_default_capability_and_fresh_request_id_per_call(self) -> None:
        client = pc.PeerClient("/tmp/not-used")
        self.assertIn(pc.SURFACE_TERMINATE_CAPABILITY, client.capabilities)
        sent = []

        def send(**payload):
            sent.append(payload["terminate_surface_request"])
            return len(sent)

        def receive(match, _timeout):
            request = sent[-1]
            response = pc.pb.TerminateSurfaceResponse(
                request_id=request.request_id,
                result=pc.pb.TERMINATE_SURFACE_RESULT_NOT_FOUND,
                surface_id=request.surface_id,
            )
            envelope = pc.pb.Envelope(
                seq=100 + len(sent),
                correlation_id=len(sent),
                terminate_surface_response=response,
            )
            self.assertTrue(match(envelope))
            return envelope

        client._send = send
        client._read_until = receive
        first = client.terminate_surface(b"s" * 16)
        second = client.terminate_surface(b"s" * 16)

        self.assertEqual(first.result, pc.pb.TERMINATE_SURFACE_RESULT_NOT_FOUND)
        self.assertEqual(first.surface_id, b"s" * 16)
        self.assertEqual(first.error_code, pc.pb.TERMINATE_SURFACE_ERROR_CODE_UNSPECIFIED)
        self.assertEqual(len(first.request_id), 16)
        self.assertNotEqual(first.request_id, second.request_id)

    def test_stable_error_fields_are_parsed(self) -> None:
        client = pc.PeerClient("/tmp/not-used")
        request_id = b"r" * 16
        client._send = lambda **_payload: 9
        client._read_until = lambda _match, _timeout: pc.pb.Envelope(
            seq=10,
            correlation_id=9,
            terminate_surface_response=pc.pb.TerminateSurfaceResponse(
                request_id=request_id,
                result=pc.pb.TERMINATE_SURFACE_RESULT_FAILED,
                surface_id=b"s" * 16,
                error=pc.pb.TerminateSurfaceError(
                    code=pc.pb.TERMINATE_SURFACE_ERROR_CODE_INTERNAL,
                    stage="terminate",
                    safe_context="surface termination failed",
                ),
            ),
        )

        outcome = client.terminate_surface(b"s" * 16, request_id=request_id)
        self.assertEqual(outcome.request_id, request_id)
        self.assertEqual(outcome.error_code, pc.pb.TERMINATE_SURFACE_ERROR_CODE_INTERNAL)
        self.assertEqual(outcome.error_stage, "terminate")
        self.assertEqual(outcome.error_context, "surface termination failed")


if __name__ == "__main__":
    unittest.main()
