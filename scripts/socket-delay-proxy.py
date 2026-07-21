#!/usr/bin/env python3
"""socket-delay-proxy.py — a Unix socket in front of another, with latency.

`PeerPaneHostSpec.direct(sockPath:)` connects to whatever Unix socket you name,
so putting a proxy in the middle is all it takes to ask "what does N ms of
transport latency actually cost here" without ssh, a slow host, or a network in
the picture. Two points on that curve tell you whether an overhead is a
constant or a multiple of the round trip — which a single real host cannot.

  ./scripts/socket-delay-proxy.py --listen /tmp/delay.sock \\
      --target /tmp/term-mesh-peer-501/peer.sock --delay-ms 60

--delay-ms is ONE WAY, so the round trip grows by twice that. Delays are
applied per chunk in order; nothing is merged or reordered, so a stream stays a
stream and only its timing changes.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys


async def pump(reader: asyncio.StreamReader, writer: asyncio.StreamWriter, delay_s: float, counter: list):
    """Delay bytes without serialising them.

    Sleeping in the read loop looks like latency and is not: it stops the next
    chunk from even being read until the previous one has been delivered, so
    two writes issued back-to-back — which is exactly how a frame's header and
    payload go out — cost two delays instead of overlapping. A real link
    carries them at once. Chunks are therefore stamped with a deadline as they
    arrive and released on their own, so anything in flight together stays
    together, and order is preserved because the queue is FIFO and every entry
    carries the same delay.
    """
    queue: asyncio.Queue = asyncio.Queue()

    async def releaser():
        while True:
            item = await queue.get()
            if item is None:
                break
            deadline, chunk = item
            now = asyncio.get_running_loop().time()
            if deadline > now:
                await asyncio.sleep(deadline - now)
            try:
                writer.write(chunk)
                await writer.drain()
            except (ConnectionResetError, BrokenPipeError):
                break
            counter[0] += len(chunk)

    task = asyncio.create_task(releaser())
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            deadline = asyncio.get_running_loop().time() + delay_s
            queue.put_nowait((deadline, chunk))
    except (ConnectionResetError, BrokenPipeError, asyncio.IncompleteReadError):
        pass
    finally:
        queue.put_nowait(None)
        try:
            await asyncio.wait_for(task, timeout=delay_s + 1.0)
        except Exception:
            task.cancel()
        try:
            writer.close()
        except Exception:
            pass


async def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--listen", required=True, help="socket path to create")
    ap.add_argument("--target", required=True, help="socket path to forward to")
    ap.add_argument("--delay-ms", type=float, default=0.0, help="one-way delay; RTT grows by 2x this")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(args.target):
        print(f"target socket does not exist: {args.target}", file=sys.stderr)
        return 1
    if os.path.exists(args.listen):
        os.unlink(args.listen)

    delay_s = args.delay_ms / 1000.0
    conns = [0]

    async def handle(client_reader, client_writer):
        conns[0] += 1
        n = conns[0]
        try:
            host_reader, host_writer = await asyncio.open_unix_connection(args.target)
        except Exception as exc:
            if not args.quiet:
                print(f"[{n}] connect to target failed: {exc}", file=sys.stderr)
            client_writer.close()
            return
        up, down = [0], [0]
        if not args.quiet:
            print(f"[{n}] open", flush=True)
        await asyncio.gather(
            pump(client_reader, host_writer, delay_s, up),
            pump(host_reader, client_writer, delay_s, down),
        )
        if not args.quiet:
            print(f"[{n}] close  up={up[0]}B down={down[0]}B", flush=True)

    server = await asyncio.start_unix_server(handle, path=args.listen)
    os.chmod(args.listen, 0o600)
    if not args.quiet:
        print(
            f"listening {args.listen} -> {args.target}  "
            f"(+{args.delay_ms:.1f} ms each way, +{args.delay_ms * 2:.1f} ms RTT)",
            flush=True,
        )
    async with server:
        await server.serve_forever()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except KeyboardInterrupt:
        sys.exit(130)
