# term-mesh vt100 patch

Source: https://github.com/doy/vt100-rust, crates.io release 0.16.2 (MIT).
The daemon workspace uses this copy through `[patch.crates-io]`, including
the CLI's parser. Runtime sources otherwise match the published crate.

`Row::resize` uses `Row::truncate` when shrinking, preserving the existing
rule that a wide character whose continuation is clipped must be cleared.
Without this, a later erase or overwrite calls `clear_wide` past the row's
end and panics. In the daemon this terminates the PTY reader task while the
child remains alive, eventually blocking the child's stdout.

Regression tests cover shrink, erase, overwrite, alternate screen, style
preservation, and repeated size changes. Remove the patch when an upstream
release passes these tests.
