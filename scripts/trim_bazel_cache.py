"""Bound the CI disk-cache snapshot after Bazel has shut down."""

import sys
from pathlib import Path


def trim_cache(directory, max_bytes=4 * 1024**3):
    directory = Path(directory)
    if max_bytes < 0 or directory.is_symlink() or not directory.is_dir():
        raise ValueError("Expected a cache directory and a non-negative size limit")

    entries = []
    for path in directory.rglob("*"):
        # Never follow links outside the dedicated cache directory.
        if path.is_symlink():
            raise ValueError("Cache must not contain symbolic links")
        if path.is_file():
            info = path.stat()
            entries.append((info.st_mtime_ns, path, info.st_size))

    before = remaining = sum(size for _, _, size in entries)
    # Bazel refreshes mtime on both cache reads and writes (unlike filesystem atime).
    for _, path, size in sorted(entries):
        if remaining <= max_bytes:
            break
        path.unlink()
        remaining -= size

    print(f"Bazel cache: {before} -> {remaining} bytes (limit {max_bytes})")
    return remaining


if __name__ == "__main__":
    trim_cache(sys.argv[1])
