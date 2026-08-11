# vopy

An open-source, terminal-based resilient file copying utility written in V. It operates as a systems-level utility, managing raw file descriptors directly to handle interrupted physical transfers, prevent SSD write-amplification, and enforce block-level data integrity.

While traditional copy commands assume stable hardware connections, `vopy` brings transactional persistence to standard file operations on local, network, and volatile external storage devices.

> Note: Developed to target cross-platform file systems, this utility functions natively on Linux, macOS, and Windows with zero platform-specific external dependencies.

## Transactional Resiliency: Data Integrity Over Naive Speed

Traditional copying tools operate on a fire-and-forget basis. If an interruption occurs, such as a bus reset, USB disconnect, or sudden power loss the partially written destination file is left in an unverified state. Often, the operating system's write-cache delays lead to trailing corruptions or null-bytes that remain undetected until the file is accessed.

`vopy` operates on the principle that recovery should be deterministic and seamless. It takes an active transactional approach, tracking exact physical block commits using double-buffered atomic metadata transactions. This allows the utility to resume transfers precisely from the last verified block, overwriting any trailing uncommitted bytes at the destination to ensure the final file matches the source.

## Core Mechanics

* **Write-Amplification Mitigation:** Performs read and write operations in fixed $64\text{ KB}$ buffer blocks. Aligning disk writes with common flash-memory page boundaries avoids the severe wear-and-tear and performance degradation associated with single-byte or misaligned small writes on SSDs.
* **Atomic Metadata Ledger:** Writes state updates to a temporary staging file (`.resume.tmp`) first, then executes an atomic rename to the stable checkpoint file (`.resume`). This prevents the checkpoint data itself from becoming corrupted if a power failure occurs mid-write.
* **Overwriting Recovery (Correction Seek):** To resume a transfer, the tool seeks to the exact offset stored in the metadata ledger. Any uncommitted, garbage, or incomplete bytes written past this offset during the previous session are overwritten, ensuring no invalid gaps exist.
* **Zero-Dependency Verification:** Compares the final destination file against the source block-by-block using sequential memory comparison. This ensures absolute identity without relying on external cryptographic libraries, which can introduce compilation overhead or CPU bottlenecks.

## Prerequisites

* V compiler installed and configured in your system path.
* C compiler (such as GCC, Clang, or MSVC) for V to target during compilation.

## Build

Compile the binary with production-level optimizations:

```bash
v -prod vopy.v -o vopy
```

## Execution

Run the compiled executable by specifying the source and destination paths:

```bash
vopy [OPTIONS] <source> <destination>
```

### Options

* `-r`, `--recursive` : Copy directories recursively while maintaining internal structure.
* `-f`, `--force`     : Force a fresh copy from offset zero, bypassing any existing `.resume` metadata.
* `-i`, `--interactive` : Prompt the user for confirmation before initiating a resume or overwriting an existing destination.
* `-p`, `--preserve`    : Sync the source file's last modified timestamp (`mtime`) to the destination upon successful transfer.
* `-v`, `--verbose`     : Print verbose output explaining transfer offsets, resumption events, and validation phases.

## Emergency Restore

Sending a standard interruption signal (such as `Ctrl+C` or `SIGINT`) halts the active copy loop safely. Because the metadata ledger is committed to the disk at every chunk boundary, the current offset is preserved immediately on the destination storage medium, allowing the copy process to resume at any point in the future.

## Disclaimer

This utility is provided for standard file management, backup preservation, and storage systems testing. Ensure critical data is backed up before executing low-level disk operations on unstable hardware.

## License

![License: EUPL 1.2](https://img.shields.io/badge/License-EUPL%201.2-gray.svg)
