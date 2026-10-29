#!/usr/bin/env python3
"""Exercise the real CLI with pseudo-terminals and offline curl/runtime fixtures."""

import errno
import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import tempfile
import time


binary = Path(sys.argv[1] if len(sys.argv) > 1 else "target/debug/rdh").resolve()
releases = "https://github.com/cole-brokamp/rdh/releases"


def read_terminal(fd):
    chunks = []
    os.set_blocking(fd, False)
    try:
        while chunk := os.read(fd, 4096):
            chunks.append(chunk)
    except OSError as error:
        if error.errno not in (errno.EIO, errno.EAGAIN):
            raise
    return b"".join(chunks).decode()


with tempfile.TemporaryDirectory(prefix="rdh-update-") as temporary:
    root = Path(temporary)
    fake_bin = root / "bin"
    fake_bin.mkdir()
    curl = fake_bin / "curl"
    curl.write_text(
        '#!/bin/sh\n'
        'printf "%s\\n" "$@" >> "$UPDATE_REQUESTS"\n'
        'printf "%s" "$UPDATE_URL"\n'
        'printf "network error\\n" >&2\n'
        'exit "$UPDATE_STATUS"\n'
    )
    curl.chmod(0o755)
    runtime = fake_bin / "container"
    runtime.write_text(
        '#!/bin/sh\nprintf "runtime stdout\\n"\n'
        'printf "runtime stderr\\n" >&2\nexit 7\n'
    )
    runtime.chmod(0o755)
    requests = root / "requests"
    cache = root / "cache"
    marker = cache / "update-check"
    environment = os.environ.copy()
    environment.pop("RDH_NO_UPDATE_CHECK", None)
    environment.update(
        PATH=str(fake_bin),
        RDH_RUNTIME="container",
        RDH_DB_PROFILE="MBHI",
        RDH_IMAGE="docker://example.invalid/rdh:test",
        RDH_DATA_DIR=str(root / "data"),
        RDH_CACHE_DIR=str(cache),
        UPDATE_REQUESTS=str(requests),
        UPDATE_URL=f"{releases}/tag/v9999.12.1",
        UPDATE_STATUS="0",
    )

    def run(arguments=(), redirected=None, extra_env=None):
        terminals = [pty.openpty() for _ in range(3)]
        streams = [slave for _, slave in terminals]
        if redirected is not None:
            streams[redirected] = subprocess.PIPE
        try:
            result = subprocess.Popen(
                [str(binary), *arguments],
                stdin=streams[0],
                stdout=streams[1],
                stderr=streams[2],
                env=environment | (extra_env or {}),
                cwd=root,
            )
            if redirected == 0:
                result.stdin.close()
            captured = [[], []]
            descriptors = [
                result.stdout.fileno() if redirected == 1 else terminals[1][0],
                result.stderr.fileno() if redirected == 2 else terminals[2][0],
            ]
            deadline = time.monotonic() + 10
            while result.poll() is None:
                if time.monotonic() > deadline:
                    result.kill()
                    result.wait()
                    raise AssertionError(f"CLI timed out: {arguments}")
                ready, _, _ = select.select(descriptors, [], [], 0.05)
                for index, fd in enumerate(descriptors):
                    if fd in ready:
                        captured[index].append(os.read(fd, 4096))
            # Drain before closing slaves: macOS discards unread terminal data
            # on last close. The child has exited, so reads can be nonblocking.
            for index, fd in enumerate(descriptors):
                captured[index].append(read_terminal(fd).encode())
            stdout, stderr = [b"".join(chunks).decode() for chunks in captured]
            if result.stdout:
                result.stdout.close()
            if result.stderr:
                result.stderr.close()
        finally:
            for master, slave in terminals:
                os.close(master)
                os.close(slave)
        return result.returncode, stdout, stderr

    def reset():
        requests.unlink(missing_ok=True)
        marker.unlink(missing_ok=True)

    code, stdout, stderr = run()
    assert code == 7, (code, stderr)
    assert stdout.strip() == "runtime stdout", stdout
    assert "rdh 9999.12.1 is available" in stderr, stderr
    assert f"{releases}/tag/v9999.12.1" in stderr, stderr
    assert "Update: curl -fsSL" in stderr, stderr
    assert "network error" not in stderr, stderr
    arguments = requests.read_text().splitlines()
    assert arguments[0] == "--disable", arguments
    assert arguments[arguments.index("--max-time") + 1] == "2", arguments
    assert arguments[arguments.index("--connect-timeout") + 1] == "1", arguments
    assert arguments[-1] == f"{releases}/latest", arguments
    count = requests.read_bytes()
    assert "is available" not in run()[2]
    assert requests.read_bytes() == count

    # Expiration permits a new check; failures also consume the daily attempt.
    marker.write_text("0")
    code, _, stderr = run(extra_env={"UPDATE_STATUS": "28"})
    assert code == 7 and stderr.strip() == "runtime stderr", stderr
    count = requests.read_bytes()
    run()
    assert requests.read_bytes() == count

    for url in (
        f"{releases}/tag/v2000.01.0",
        f"{releases}/tag/v2026.10.0",
        f"{releases}/tag/v9999.12.1-dev",
        "invalid response",
    ):
        reset()
        code, _, stderr = run(extra_env={"UPDATE_URL": url})
        assert code == 7 and stderr.strip() == "runtime stderr", stderr

    # No requests or markers for opt-out, scripts, or any redirected stream.
    for arguments in (
        ("Rscript", "analysis.R"),
        ("R", "-e", "1"),
        ("R", "--file=analysis.R"),
        ("R", "CMD", "BATCH", "analysis.R"),
        ("check",),
        ("shell",),
        ("help",),
        ("version",),
        ("doctor",),
        ("pull",),
    ):
        reset()
        run(arguments)
        assert not requests.exists(), arguments
        assert not marker.exists(), arguments
    for redirected in (0, 1, 2):
        reset()
        run(redirected=redirected)
        assert not requests.exists(), redirected
        assert not marker.exists(), redirected
    reset()
    run(extra_env={"RDH_NO_UPDATE_CHECK": "1"})
    assert not requests.exists() and not marker.exists()

    # Missing curl and an unusable cache must preserve runtime output/status.
    curl.unlink()
    code, stdout, stderr = run()
    assert code == 7 and stdout.strip() == "runtime stdout"
    assert stderr.strip() == "runtime stderr", stderr
    code, _, stderr = run(extra_env={"RDH_CACHE_DIR": str(runtime)})
    assert code == 7 and stderr.strip() == "runtime stderr", stderr

print("interactive update notice checks passed")
