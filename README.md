# vopy

An open-source, terminal-based resilient file copying utility written in V. It operates as a systems-level utility, managing raw file descriptors directly to handle interrupted physical transfers, prevent SSD write-amplification, and enforce block-level data consistency.

While traditional copy commands assume stable hardware connections, `vopy` brings transactional persistence to standard file operations on local, network, and volatile external storage devices.

> Note: Developed to target cross-platform file systems, this utility functions natively on Linux, macOS, and Windows with zero platform-specific external dependencies.

[![ASan Verified](https://img.shields.io/badge/ASan-Verified-success?style=flat-square&logo=github-actions&logoColor=white)](#)
[![UBSan Passed](https://img.shields.io/badge/UBSan-Passed-success?style=flat-square&logo=github-actions&logoColor=white)](#)
[![TSan Secured](https://img.shields.io/badge/TSan-Secured-success?style=flat-square&logo=github-actions&logoColor=white)](#)
[![MSan Clean](https://img.shields.io/badge/MSan-Clean-success?style=flat-square&logo=github-actions&logoColor=white)](#)

## Transactional Resiliency: Data Integrity Over Naive Speed

Traditional copying tools operate on a fire-and-forget basis. If an interruption occurs, such as a bus reset, USB disconnect, or sudden power loss, the partially written destination file is left in an unverified state. Often, the operating system's write-cache delays lead to trailing corruptions or null-bytes that remain undetected until the file is accessed.

`vopy` operates on the principle that recovery should be deterministic and seamless. It takes an active transactional approach, tracking exact physical block commits using RAM-buffered atomic metadata transactions. This allows the utility to resume transfers precisely from the last verified block, overwriting any trailing uncommitted bytes at the destination to ensure the final file matches the source.

Furthermore, `vopy` supports safe block-level differential patching, bypassing unnecessary storage writes on matching sectors to protect media life while guaranteeing transactional consistency.

## Core Mechanics

* **Write-Amplification Mitigation:** Performs read and write operations in fixed $1\text{ MB}$ buffer blocks. Aligning disk writes with common flash-memory page boundaries avoids the severe wear-and-tear and performance degradation associated with single-byte or misaligned small writes on SSDs.
* **Block-Level Differential Synchronization (Smart Overwrite):** When executed with `-m`, the engine compares the source and destination files block-by-block. It dynamically allocates isolated, safe comparison buffers in memory. If a block matches, the physical write system call is bypassed entirely, preserving SSD write endurance (TBW). If a mismatch is detected, it rewinds the file descriptor and overwrites the exact dirty block in-place.
* **Automated Shift-Cancellation Realignment:** During differential synchronization, if local byte shifts (due to insertions or deletions) are resolved or cancelled out further down the file (e.g., in structured code files, log rotations, or database offsets), the stream pointers naturally realign. The utility automatically transitions back to read-only comparison mode, shielding the rest of the target file from cascading writes.
* **State-Driven Truncation Safeguard:** When starting a fresh transfer (where no `.resume` ledger is active), the target file is cleanly truncated to zero bytes via standard POSIX creation flags (`O_CREAT | O_TRUNC`). This prevents trailing junk data when copying a smaller file over a pre-existing larger file, bypassing unreliable platform-specific `truncate` C-binding bugs.
* **Atomic Metadata Ledger:** Caches progress state in memory and commits updates temporally to a temporary staging file (`.resume.tmp`) first, then executes an atomic rename to the stable checkpoint file (`.resume`) based on a user-defined sync interval. This prevents the checkpoint data itself from becoming corrupted if a power failure occurs mid-write while reducing continuous small write stresses.
* **Overwriting Recovery (Correction Seek):** To resume a transfer, the tool seeks to the exact offset stored in the metadata ledger. Any uncommitted, garbage, or incomplete bytes written past this offset during the previous session are overwritten, ensuring no invalid gaps exist.
* **Idempotent Path Mapping:** Enforces deterministic path resolution during directory traversal. This ensures that repeated execution of an interrupted recursive copy command consistently targets the same subdirectory structure, preventing orphaned partial progress blocks.

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

* `-r`, `--recursive`       : Copy directories recursively while maintaining internal structure.
* `-f`, `--force`           : Force a fresh copy from offset zero, bypassing any existing `.resume` metadata.
* `-i`, `--interactive`     : Prompt the user for confirmation before initiating a resume or overwriting an existing destination.
* `-n`, `--no-preserve`     : Do not preserve file modification time (`mtime`).
* `-s`, `--size-only`       : Skip files if size matches, ignoring modification time.
* `-t`, `--sync-interval`   : Interval in seconds (default: `5`, clamped to a minimum safety threshold of `1` second) to flush RAM buffers and commit state checkpoints to the disk.
* `-m`, `--smart-overwrite` : Only overwrite changed blocks by performing block-by-block read-compare-write operations, bypassing standard metadata skipping.
* `-v`, `--verbose`         : Print verbose output explaining transfer offsets, resumption events, and validation phases.

## Emergency Restore

Sending a standard interruption signal (such as `Ctrl+C` or `SIGINT`) halts the active copy loop safely. Because the metadata ledger is committed to the disk at configured temporal boundaries, the current offset is preserved immediately on the destination storage medium, allowing the copy process to resume at any point in the future.

## Disclaimer

This utility is provided for standard file management, backup preservation, and storage systems testing. Ensure critical data is backed up before executing low-level disk operations on unstable hardware.

## License

![License: EUPL 1.2](https://img.shields.io/badge/License-EUPL%201.2-gray.svg)
