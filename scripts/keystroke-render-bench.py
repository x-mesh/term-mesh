#!/usr/bin/env python3
"""keystroke-render-bench.py — time a keystroke from injection to render.

`tm-agent peer bench --mode rtt` stops at the PtyData frame, so it never sees
the relay binary, the app's frame pumps, Ghostty, or the renderer — which is
most of what a person actually waits for. This measures the whole way to the
screen, by the only route that works identically for a native pane and a
relayed one: inject over the control socket, then poll the rendered text until
the token shows up.

The poll is a socket round trip, so it is also the resolution limit. It is
measured separately and reported, because it lands on both sides of the A/B
equally and inflating both by the same constant is fine, while pretending it
is not there is not.

  ./scripts/keystroke-render-bench.py --surface 4 --iterations 60
  ./scripts/keystroke-render-bench.py --surface 4 --compare 7 --json

Give it two surfaces (`--surface` native, `--compare` relayed, or the reverse)
and it reports both plus the delta.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import time
import uuid

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests_v2"))

from termmesh import termmesh, termmeshError  # noqa: E402


def percentile(values, p):
    """Nearest-rank percentile — no interpolation, so every number reported is
    a sample that actually happened."""
    if not values:
        return float("nan")
    ordered = sorted(values)
    k = max(0, min(len(ordered) - 1, int(round(p / 100.0 * len(ordered) + 0.5)) - 1))
    return ordered[k]


def summarize(name, samples, dropped=0):
    return {
        "name": name,
        "n": len(samples),
        "dropped": dropped,
        "min": min(samples) if samples else float("nan"),
        "p50": percentile(samples, 50),
        "p95": percentile(samples, 95),
        "p99": percentile(samples, 99),
        "max": max(samples) if samples else float("nan"),
        "mean": statistics.fmean(samples) if samples else float("nan"),
    }


def measure_poll_floor(tm, surface, iterations=20):
    """Cost of one read with nothing to find — the resolution floor."""
    samples = []
    for _ in range(iterations):
        t0 = time.perf_counter()
        tm.read_terminal_text(surface)
        samples.append((time.perf_counter() - t0) * 1000.0)
    return samples


def clear_line(tm, surface):
    """Ctrl-U. Typing accumulates on the shell's line, and a token that is
    still on screen from the previous round would be 'found' instantly."""
    tm.send_surface(surface, "\x15")


def measure_surface(tm, surface, iterations, timeout_s, settle_s, key_mode=None):
    samples = []
    dropped = 0

    clear_line(tm, surface)
    time.sleep(settle_s)

    for _ in range(iterations):
        token = uuid.uuid4().hex[:8]

        # Drain whatever is on the line, and confirm it is gone before timing:
        # starting the clock while the previous token is still rendered would
        # measure nothing at all.
        clear_line(tm, surface)
        deadline = time.perf_counter() + timeout_s
        while time.perf_counter() < deadline:
            if token not in tm.read_terminal_text(surface):
                break

        t0 = time.perf_counter()
        if key_mode:
            tm.send_key_surface(surface, key_mode)
        else:
            tm.send_surface(surface, token)

        found = False
        deadline = t0 + timeout_s
        while time.perf_counter() < deadline:
            if token in tm.read_terminal_text(surface):
                found = True
                break
        t1 = time.perf_counter()

        if found:
            samples.append((t1 - t0) * 1000.0)
        else:
            dropped += 1
        time.sleep(settle_s)

    clear_line(tm, surface)
    return samples, dropped


def print_row(s):
    print(
        f"  {s['name']:<22} n={s['n']:<4} "
        f"min={s['min']:7.1f}  p50={s['p50']:7.1f}  p95={s['p95']:7.1f}  "
        f"p99={s['p99']:7.1f}  max={s['max']:8.1f}   (ms)"
        + (f"   dropped={s['dropped']}" if s["dropped"] else "")
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--surface", required=True, help="surface ref/index to measure")
    ap.add_argument("--compare", help="second surface, measured the same way")
    ap.add_argument("--label", default="A", help="label for --surface")
    ap.add_argument("--compare-label", default="B", help="label for --compare")
    ap.add_argument("--iterations", type=int, default=50)
    ap.add_argument("--timeout", type=float, default=5.0, help="give up on one sample after N s")
    ap.add_argument("--settle", type=float, default=0.05, help="idle between samples, seconds")
    ap.add_argument("--socket", help="control socket path")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    tm = termmesh(socket_path=args.socket)
    tm.connect()

    floor = measure_poll_floor(tm, args.surface)
    floor_summary = summarize("poll floor (read only)", floor)

    a_samples, a_dropped = measure_surface(tm, args.surface, args.iterations, args.timeout, args.settle)
    result = {"poll_floor": floor_summary, "a": summarize(args.label, a_samples, a_dropped)}

    if args.compare:
        b_samples, b_dropped = measure_surface(tm, args.compare, args.iterations, args.timeout, args.settle)
        result["b"] = summarize(args.compare_label, b_samples, b_dropped)
        result["delta_p50"] = result["b"]["p50"] - result["a"]["p50"]
        result["delta_p99"] = result["b"]["p99"] - result["a"]["p99"]

    if args.json:
        print(json.dumps(result, indent=2))
        return 0

    print()
    print("keystroke → render")
    print_row(floor_summary)
    print()
    print_row(result["a"])
    if "b" in result:
        print_row(result["b"])
        print()
        print(f"  delta  p50 {result['delta_p50']:+.1f} ms   p99 {result['delta_p99']:+.1f} ms")
    print()
    print("  The poll floor is inside every number above; it is the read round trip,")
    print("  and it applies to both sides equally.")
    print()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except termmeshError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
