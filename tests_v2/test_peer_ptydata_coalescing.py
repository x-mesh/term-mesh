#!/usr/bin/env python3
"""P7 PtyData coalescing: `pumpByteStream` used to turn every PTY tap chunk
into its own `PtyData` Envelope + framed write() syscall 1:1 -- Ghostty's tap
can fire "thousands of times per second" (`PtyTapHub.broadcast`), so a hot
output burst (large `cat`, `yes`, a busy build) meant a syscall storm with no
batching at all.

The fix (`PtyDataCoalescer`, swift/PeerProto/Sources/PeerProto/PeerServer.swift)
is leading-edge coalescing: the first chunk after an idle period is sent
unbuffered immediately (so an isolated keystroke echo gets zero added
latency), which arms a short (6ms default) collection window; chunks that
arrive while the window is armed are merged into one payload and flushed at
the window's end or at a 64KB byte cap, whichever comes first.

`pumpByteStream`'s owning `PeerServerSession` actor is package-internal to
PeerProto, and there is no live 2-node peer session in this test environment
regardless -- so, mirroring `debug.peer.demux_probe`'s approach for
`PeerSessionDemux`, this drives the exact same production `PtyDataCoalescer`
type directly via the DEBUG `debug.peer.coalesce_probe` socket command, with
synthetic chunks at controlled, generously-spaced intervals rather than real
PTY output (avoiding any screen-scrape / echo-race timing dependency --
there is no shell or terminal rendering involved in this probe at all).

Covers:
  1. burst    -- 5 chunks ~1ms apart (all inside the 6ms window) must merge
                 into fewer sends than chunks submitted.
  2. isolated -- 3 chunks ~30ms apart (each well outside the window) must
                 NOT merge -- one send per chunk, proving the leading-edge
                 design doesn't over-eagerly batch unrelated writes.
  3. capped   -- 12x 8KB chunks back-to-back (~96KB, over the 64KB cap
                 within a single window) must force an early flush -- more
                 than one send, and no single send anywhere near the full
                 96KB total (the cap actually bounds growth).
  4. Every scenario's total bytes sent must equal chunks_submitted x
     chunk_size exactly -- coalescing must never lose or duplicate bytes,
     only regroup them. Each scenario's probe run ends by calling
     `flushRemaining()` (the same call `pumpByteStream` makes when its
     byte stream ends -- natural finish, cancellation, or pane/session
     teardown), so an equal byte count also demonstrates that whatever was
     still buffered at "stream end" was correctly flushed rather than
     silently dropped -- the concern the P7 proposal's audit flagged
     (in-flight coalesced bytes lost on pane close).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


def _scenario(probe: dict, name: str) -> dict:
    s = probe.get(name)
    if not isinstance(s, dict):
        raise termmeshError(f"coalesce_probe missing/invalid {name!r} scenario: {probe!r}")
    for key in ("chunks_submitted", "frames_sent", "bytes_total", "max_frame_bytes"):
        if key not in s:
            raise termmeshError(f"{name} scenario missing {key!r}: {s!r}")
    return s


def main() -> int:
    with termmesh() as c:
        probe = c.coalesce_probe()
        if probe.get("ok") is not True:
            raise termmeshError(f"coalesce_probe returned ok!=True: {probe!r}")

        # --- 1. burst: rapid chunks inside the window must merge.
        burst = _scenario(probe, "burst")
        if burst["chunks_submitted"] != 5:
            raise termmeshError(f"burst scenario chunk count changed unexpectedly: {burst!r}")
        if burst["bytes_total"] != 5 * 100:
            raise termmeshError(
                f"burst scenario lost or duplicated bytes: expected {5*100}, "
                f"got {burst['bytes_total']} (full={burst!r})"
            )
        if not (burst["frames_sent"] < burst["chunks_submitted"]):
            raise termmeshError(
                f"burst chunks 1ms apart (well inside the 6ms window) should "
                f"coalesce into fewer sends than chunks submitted -- got "
                f"frames_sent={burst['frames_sent']} >= chunks_submitted="
                f"{burst['chunks_submitted']} (full={burst!r})"
            )

        # --- 2. isolated: chunks far apart must NOT merge -- one send each.
        isolated = _scenario(probe, "isolated")
        if isolated["chunks_submitted"] != 3:
            raise termmeshError(f"isolated scenario chunk count changed unexpectedly: {isolated!r}")
        if isolated["bytes_total"] != 3 * 50:
            raise termmeshError(
                f"isolated scenario lost or duplicated bytes: expected {3*50}, "
                f"got {isolated['bytes_total']} (full={isolated!r})"
            )
        if isolated["frames_sent"] != isolated["chunks_submitted"]:
            raise termmeshError(
                f"isolated chunks 30ms apart (well outside the 6ms window) "
                f"should NOT coalesce -- expected frames_sent== "
                f"chunks_submitted=={isolated['chunks_submitted']}, got "
                f"frames_sent={isolated['frames_sent']} (full={isolated!r}). "
                f"leading-edge design should send each in isolation with no "
                f"added delay, not batch unrelated writes together."
            )

        # --- 3. capped: enough back-to-back bytes to cross the 64KB cap
        #        within one window must force an early flush.
        capped = _scenario(probe, "capped")
        if capped["chunks_submitted"] != 12:
            raise termmeshError(f"capped scenario chunk count changed unexpectedly: {capped!r}")
        expected_total = 12 * 8192
        if capped["bytes_total"] != expected_total:
            raise termmeshError(
                f"capped scenario lost or duplicated bytes: expected "
                f"{expected_total}, got {capped['bytes_total']} (full={capped!r})"
            )
        if not (capped["frames_sent"] < capped["chunks_submitted"]):
            raise termmeshError(
                f"capped scenario should still coalesce (frames_sent < "
                f"chunks_submitted) despite the forced cap flush -- got "
                f"frames_sent={capped['frames_sent']} (full={capped!r})"
            )
        if capped["frames_sent"] < 2:
            raise termmeshError(
                f"capped scenario's ~96KB burst must force at least one "
                f"cap-triggered flush in addition to the leading send -- "
                f"expected frames_sent>=2, got {capped['frames_sent']} "
                f"(full={capped!r})"
            )
        # Generous bound: the cap is checked after appending a chunk, so a
        # capped frame can exceed the 64KB (65536) cap by up to one chunk's
        # worth (8192) in the worst case -- see PeerServer.swift's cap-check
        # comment. What matters here is that the cap actually bounds growth
        # (nowhere near the full ~96KB total), not an exact byte boundary.
        if capped["max_frame_bytes"] > 80000:
            raise termmeshError(
                f"capped scenario produced a frame far larger than the 64KB "
                f"cap should allow -- the byte cap is not bounding growth. "
                f"max_frame_bytes={capped['max_frame_bytes']} (full={capped!r})"
            )
        if capped["max_frame_bytes"] >= capped["bytes_total"]:
            raise termmeshError(
                f"capped scenario's largest frame contains the ENTIRE "
                f"~96KB burst -- the byte cap never actually triggered a "
                f"split. (full={capped!r})"
            )

    print(
        "PASS: PtyDataCoalescer merges rapid bursts into fewer sends, leaves "
        "isolated writes unmerged with no added delay, bounds growth at the "
        "64KB cap, and never loses or duplicates bytes across any scenario"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
