#!/usr/bin/env python3
"""Checks that `llimit accounts add` hides a secret while it is typed.

Runs the given llimit binary on a pseudo-terminal with throwaway HOME and XDG
directories, waits for the API key prompt to switch terminal echo off, types a
probe token, and fails if the token is echoed back or the account is not saved.
CI runs it against the static musl binary that ships in the .deb.

Usage: scripts/test-llimit-secret-input.py <path-to-llimit>
"""

import os
import pty
import select
import signal
import sys
import tempfile
import termios
import time

# Venice prompts for exactly one field, a required secret.
PROVIDER = "venice"
PROMPT = b"API key: "
SECRET = b"llimit-echo-probe-0123456789"
TIMEOUT_SECONDS = 15
POLL_SECONDS = 0.05


def fail(message, transcript):
    print(f"FAIL: {message}", file=sys.stderr)
    print("Terminal output:", file=sys.stderr)
    print(transcript.decode(errors="replace"), file=sys.stderr)
    sys.exit(1)


def read_chunk(fd, timeout):
    """Returns new output, b"" when nothing arrived in time, or None at EOF."""
    ready, _, _ = select.select([fd], [], [], timeout)
    if not ready:
        return b""
    try:
        chunk = os.read(fd, 4096)
    except OSError:  # EIO once the child has closed the terminal.
        return None
    return chunk or None


def wait_for_exit(pid, deadline):
    """Returns the wait status, or None if the child is still running at the deadline."""
    while True:
        reaped, status = os.waitpid(pid, os.WNOHANG)
        if reaped == pid:
            return status
        if time.monotonic() > deadline:
            return None
        time.sleep(POLL_SECONDS)


def run(binary, home):
    env = {
        "HOME": home,
        "XDG_CONFIG_HOME": os.path.join(home, "config"),
        "XDG_DATA_HOME": os.path.join(home, "data"),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "TERM": "dumb",
    }
    argv = [binary, "accounts", "add", "--provider", PROVIDER]
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execve(binary, argv, env)
        finally:
            os._exit(127)

    transcript = b""
    deadline = time.monotonic() + TIMEOUT_SECONDS
    status = None
    try:
        while PROMPT not in transcript:
            if time.monotonic() > deadline:
                fail("no API key prompt", transcript)
            chunk = read_chunk(fd, POLL_SECONDS)
            if chunk is None:
                fail("llimit exited before prompting", transcript)
            transcript += chunk

        # On a pty master, tcgetattr reports the slave's settings, which llimit
        # changes. Typing before echo is off would race its TCSAFLUSH.
        while termios.tcgetattr(fd)[3] & termios.ECHO:
            if time.monotonic() > deadline:
                fail("terminal echo stayed on at the secret prompt", transcript)
            time.sleep(POLL_SECONDS)

        typed_from = len(transcript)
        os.write(fd, SECRET + b"\n")
        while True:
            if time.monotonic() > deadline:
                fail("llimit did not finish after the secret was typed", transcript)
            chunk = read_chunk(fd, POLL_SECONDS)
            if chunk is None:
                break
            transcript += chunk

        # EOF only means the terminal was closed, not that llimit exited.
        status = wait_for_exit(pid, deadline)
        if status is None:
            fail("llimit kept running after it closed the terminal", transcript)
    finally:
        if status is None:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(fd)

    if SECRET in transcript[typed_from:]:
        fail("the secret was echoed to the terminal", transcript)
    if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
        fail(f"llimit failed with wait status {status}", transcript)

    settings = os.path.join(env["XDG_CONFIG_HOME"], "LLimit", "quota-settings.json")
    try:
        with open(settings, "rb") as file:
            saved = file.read()
    except OSError as error:
        fail(f"cannot read the saved settings: {error}", transcript)
    if SECRET not in saved:
        fail("the typed secret was not saved", transcript)


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)

    binary = os.path.abspath(sys.argv[1])
    with tempfile.TemporaryDirectory(prefix="llimit-secret-input.") as home:
        run(binary, home)
    print("PASS: llimit hid the secret while it was typed")


if __name__ == "__main__":
    main()
