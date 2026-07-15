#!/usr/bin/env python3
"""P3 capability plumbing: `Hello.capabilities` was declared in the proto
schema (`proto/peer/v1/peer.proto` Evolution rule 3) but no implementation
actually populated or read it -- all four Hello-generation sites (Rust host,
Rust CLI client, Swift host, Swift client) sent an empty list, and nothing
parsed the field on receipt either. This closes that gap: every generation
site now advertises this build's real capability set
(`ptydata.coalesce.v1`, `replay.ring.v1`), and every receiving side parses
and stores the other side's list behind a `has(_:)`/`hasClientCapability(_:)`
/`hasHostCapability(_:)`/`has_capability(_:)` query API -- a hook future wire
changes (P8's compression/native-TCP negotiation and later) can gate on. No
current code branches on a capability yet; this is plumbing only.

Covers, via `debug.peer.capabilities_probe` (DEBUG-only):
  1. This build's self-advertised list (`self_advertised`) contains both
     initial capability strings -- proof that Hello generation is wired,
     without needing a live 2-node peer session.
  2. As a bonus (best-effort, may be absent): `round_trip_*` booleans from
     a real, throwaway PeerServer + PeerSession handshake completed
     entirely within the app process -- when present, these prove the full
     generate -> wire -> parse -> store -> query path for the Swift host
     and Swift client in one shot. Asserted only when the probe reports
     them; their absence is not a failure (see note below).

Deliberately NOT covered here (documented limitation, not an oversight):
  - The Rust host/CLI receiving side and adversarial-input safety (empty,
    unknown strings, a 5000-entry list, invalid-UTF8 bytes) are covered by
    Rust unit/integration tests instead
    (`daemon/peer-proto/src/lib.rs`, `daemon/term-meshd/src/peer/framing.rs`,
    `daemon/term-meshd/src/peer/server.rs`'s `integration_tests` module) --
    there is no live 2-node (let alone cross-language) peer session in this
    VM test environment, so a genuine Rust<->Swift wire round trip can't be
    exercised from here. The Swift-side equivalent of that same round-trip
    coverage (both directions, plus adversarial input) lives in
    `swift/PeerProto/Tests/PeerProtoTests/PeerServerTests.swift`, which has
    `@testable` access this app-level probe does not.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError

EXPECTED_CAPABILITIES = ["ptydata.coalesce.v1", "replay.ring.v1", "workspace.lifecycle.v1"]


def main() -> int:
    with termmesh() as c:
        probe = c.capabilities_probe()
        if probe.get("ok") is not True:
            raise termmeshError(f"capabilities_probe returned ok!=True: {probe!r}")

        # 1. Self-advertisement: the core, always-present guarantee.
        advertised = probe.get("self_advertised")
        if not isinstance(advertised, list):
            raise termmeshError(f"capabilities_probe missing/invalid self_advertised: {probe!r}")
        missing = [cap for cap in EXPECTED_CAPABILITIES if cap not in advertised]
        if missing:
            raise termmeshError(
                f"self_advertised is missing expected capabilities {missing!r} "
                f"-- Hello generation is not wired to the real capability set. "
                f"full self_advertised={advertised!r}"
            )

        # 2. Best-effort round-trip bonus: assert only what the probe
        #    actually attempted. Absence (throwaway loopback couldn't be
        #    set up) is tolerated, not treated as failure.
        if "round_trip_ptydata_coalesce_v1" in probe:
            if probe["round_trip_ptydata_coalesce_v1"] is not True:
                raise termmeshError(
                    f"round-trip handshake completed but the client did not "
                    f"see the host advertise {EXPECTED_CAPABILITIES[0]!r}: {probe!r}"
                )
            if probe.get("round_trip_replay_ring_v1") is not True:
                raise termmeshError(
                    f"round-trip handshake completed but the client did not "
                    f"see the host advertise {EXPECTED_CAPABILITIES[1]!r}: {probe!r}"
                )
            if probe.get("round_trip_unknown_capability") is not False:
                raise termmeshError(
                    f"round-trip handshake reported the host advertising a "
                    f"capability it was never given -- has(_:) is not "
                    f"correctly scoped to what was actually received: {probe!r}"
                )

    print(
        "PASS: P3 capability plumbing -- self-advertised Hello.capabilities "
        "includes the initial set (ptydata.coalesce.v1, replay.ring.v1), and "
        "a real in-process handshake round trip (when available) confirms "
        "the client correctly parses and queries the host's advertised list"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
