"""Hand a verification command the terminal and return it after the job ends."""

import errno
import os
from pathlib import Path
import signal
import subprocess
import sys


def foreground_group():
    try:
        return os.tcgetpgrp(0)
    except OSError as error:
        if error.errno in (errno.ENOTTY, errno.ENXIO):
            return None
        raise


def set_foreground(group):
    previous = signal.signal(signal.SIGTTOU, signal.SIG_IGN)
    try:
        os.tcsetpgrp(0, group)
    finally:
        signal.signal(signal.SIGTTOU, previous)


def restore_terminal(owner, job):
    foreground = foreground_group()
    if foreground is None or foreground == owner:
        return
    if foreground > 0 and foreground != job:
        try:
            os.killpg(foreground, 0)
        except ProcessLookupError:
            pass
        else:
            return
    set_foreground(owner)


def reset_command_signals():
    for interrupt in (signal.SIGINT, signal.SIGTSTP, signal.SIGTTIN, signal.SIGTTOU):
        signal.signal(interrupt, signal.SIG_DFL)


def run_terminal_command(owner, suspension_marker, command):
    job = os.getpgrp()
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTSTP, signal.SIG_IGN)
    if foreground_group() == owner:
        set_foreground(job)

    process = subprocess.Popen(command, preexec_fn=reset_command_signals)
    while True:
        _, status = os.waitpid(process.pid, os.WUNTRACED)
        if not os.WIFSTOPPED(status):
            process.returncode = os.waitstatus_to_exitcode(status)
            return process.returncode if process.returncode >= 0 else 128 - process.returncode

        # The calling shell tracks the wrapper's group, so suspend it too.
        suspension_marker.touch()
        os.killpg(owner, signal.SIGSTOP)


def main(action, *args):
    if action == "owner":
        if foreground_group() == os.getpgrp():
            print(os.getpgrp())
    elif action == "run":
        owner, suspension_marker, *command = args
        return run_terminal_command(int(owner), Path(suspension_marker), command)
    elif action == "resume":
        owner, job = (int(group) for group in args)
        if foreground_group() == owner:
            set_foreground(job)
    elif action == "restore":
        restore_terminal(*(int(group) for group in args))


if __name__ == "__main__":
    try:
        sys.exit(main(*sys.argv[1:]))
    except OSError as error:
        sys.exit(f"[isolated-verify] Terminal setup failed: {error}")
