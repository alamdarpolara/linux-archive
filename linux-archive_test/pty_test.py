#!/usr/bin/env python3
"""pty_test.py - drives linux-archive's interactive UI through a real pseudo-terminal.

usage: pty_test.py <path-to-linux-archive.sh> <work-dir>
Prints PASS/FAIL/SKIP lines (consumed by tests.sh).
"""
import fcntl
import os
import pty
import re
import select
import shutil
import signal
import struct
import sys
import termios
import time

LA = os.path.abspath(sys.argv[1])
ROOT = os.path.abspath(sys.argv[2])
shutil.rmtree(ROOT, ignore_errors=True)
os.makedirs(ROOT)

UP, DOWN, RIGHT, LEFT = b'\x1b[A', b'\x1b[B', b'\x1b[C', b'\x1b[D'
ENTER, SPACE, ESC, CTRL_C = b'\r', b' ', b'\x1b', b'\x03'
ANSI = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Z0-9]|\x1b[=>]')


def report(ok, name, detail=''):
    print(('PASS' if ok else 'FAIL') + '  ' + name + (('  -- ' + detail[:300]) if (detail and not ok) else ''), flush=True)


def strip(s):
    return ANSI.sub('', s)


class Term:
    def __init__(self, cwd, args=(), env=None, rows=24, cols=80):
        e = dict(os.environ, TERM='xterm-256color', LC_ALL='C.UTF-8')
        e.pop('NO_COLOR', None)
        e.update(env or {})
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(cwd)
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
            os.execvpe(LA, [LA, *args], e)
        self.pid, self.fd = pid, fd
        self.raw = b''
        self.mark = 0
        self.status = None
        self.initial_lflag = termios.tcgetattr(fd)[3]

    def pump(self, timeout=0.2):
        end = time.time() + timeout
        while True:
            left = end - time.time()
            if left <= 0:
                break
            r, _, _ = select.select([self.fd], [], [], left)
            if not r:
                break
            try:
                d = os.read(self.fd, 65536)
            except OSError:
                break
            if not d:
                break
            self.raw += d
        return self

    def send(self, data, settle=0.12):
        """write keys, then wait until the program has redrawn: some output has
        arrived and the terminal stayed quiet for `settle` seconds (at most 4 s;
        1.5 s if nothing arrives) - robust on a loaded machine."""
        if isinstance(data, str):
            data = data.encode()
        self.mark = len(self.raw)
        os.write(self.fd, data)
        start = time.time()
        while True:
            before = len(self.raw)
            self.pump(settle)
            got = len(self.raw) > self.mark
            if got and len(self.raw) == before:
                break
            if time.time() - start > (4.0 if got else 1.5):
                break

    def send_now(self, data, settle=0.1):
        """write keys and return almost at once (for keys that start a long job)"""
        if isinstance(data, str):
            data = data.encode()
        self.mark = len(self.raw)
        os.write(self.fd, data)
        self.pump(settle)

    def since(self):
        return strip(self.raw[self.mark:].decode('utf-8', 'replace'))

    def text(self):
        return strip(self.raw.decode('utf-8', 'replace'))

    def last_frame(self):
        """text drawn after the last 'cursor home' (the current screen)"""
        s = self.raw.decode('utf-8', 'replace')
        return strip(s.split('\x1b[H')[-1])

    def settle(self, quiet=0.25, limit=3.0):
        """read until the terminal has been quiet for `quiet` s (a frame is
        written in pieces; a match on its first lines does not mean it is complete)"""
        end = time.time() + limit
        while time.time() < end:
            before = len(self.raw)
            self.pump(quiet)
            if len(self.raw) == before:
                return

    def expect(self, pattern, timeout=12.0, since_mark=True, settle=True):
        end = time.time() + timeout
        rx = re.compile(pattern, re.S)
        while time.time() < end:
            self.pump(0.1)
            hay = self.since() if since_mark else self.text()
            if rx.search(hay):
                if settle:
                    self.settle()
                return True
            if self.exited():
                hay = self.since() if since_mark else self.text()
                return bool(rx.search(hay))
        return False

    def exited(self):
        if self.status is not None:
            return True
        try:
            pid, st = os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            self.status = -1
            return True
        if pid:
            self.status = st
            return True
        return False

    def wait_exit(self, timeout=10.0):
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.1)
            if self.exited():
                self.pump(0.2)
                return True
        return False

    def exit_code(self):
        if self.status is None or self.status < 0:
            return None
        st = self.status          # os.waitstatus_to_exitcode needs Python 3.9 (EL8 has 3.6)
        if os.WIFEXITED(st):
            return os.WEXITSTATUS(st)
        if os.WIFSIGNALED(st):
            return -os.WTERMSIG(st)
        return None

    def resize(self, rows, cols):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
        try:
            os.killpg(os.getpgid(self.pid), signal.SIGWINCH)
        except ProcessLookupError:
            pass

    def kill(self):
        try:
            os.killpg(os.getpgid(self.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.exited()


def mkdir(name):
    d = os.path.join(ROOT, name)
    os.makedirs(d, exist_ok=True)
    return d


def write(path, data=b'x'):
    with open(path, 'wb') as f:
        f.write(data)


def zipinfo_leftovers(d):
    return [n for n in os.listdir(d) if n.startswith('.linux-archive.')]


# --------------------------------------------------------------- test 1/2
d = mkdir('menus')
os.makedirs(os.path.join(d, 'folder'))
write(os.path.join(d, 'a.txt'), b'aaa')
write(os.path.join(d, 'b.txt'), b'bbb')
write(os.path.join(d, 'c.txt'), b'ccc')
write(os.path.join(d, 'notes.md'), b'not an archive')
write(os.path.join(d, 'fake.zip'), b'plain text with a zip extension')
write(os.path.join(d, 'zero.zip'), b'')
os.system(f"cd '{d}' && mkdir -p mk && echo hi > mk/f && tar -czf real.tar.gz mk && zip -q real.zip mk/f && rm -rf mk")
write(os.path.join(d, 'renamed.bin'), open(os.path.join(d, 'real.zip'), 'rb').read())

t = Term(d)
ok = t.expect(r'Main menu') and t.expect(r'Zip\s+- create an archive', since_mark=False)
report(ok, 'pty: main menu is drawn (banner, Zip/Unzip/Quit)', t.text()[-300:])
raw_ok = b'\x1b[7m' in t.raw or b'\x1b[7;' in t.raw or b'\x1b[1m\x1b[7m' in t.raw or b'\x1b[7m\x1b[1m' in t.raw or '\x1b[7m'.encode() in t.raw
report(raw_ok and ('❯' in t.text()), 'pty: current item is highlighted (reverse video + pointer)')
t.send(DOWN)
report('❯ Unzip' in t.last_frame(), 'pty: Down arrow moves the highlight to "Unzip"', t.last_frame()[:400])
t.send(UP)
report('❯ Zip' in t.last_frame(), 'pty: Up arrow moves the highlight back to "Zip"')
t.send(UP)
report('❯ Quit' in t.last_frame(), 'pty: Up from the first item wraps to the last')
t.send(DOWN)
t.send(b'j')
report('❯ Unzip' in t.last_frame(), "pty: 'j' also moves down")
t.send(ENTER)
ok = t.expect(r'Choose the archive to extract')   # menu title, part of the frame itself
fr = t.last_frame()
report(ok and 'real.tar.gz' in fr and 'real.zip' in fr and 'renamed.bin' in fr, 'pty: unzip view shows real archives (also a zip renamed to .bin)', fr[:500])
hidden = [n for n in ('notes.md', 'fake.zip', 'zero.zip', 'folder', 'a.txt', 'b.txt') if n in fr.split('Choose the archive')[-1]]
report(not hidden, 'pty: unzip view hides non-archives, fake/zero-byte archives and folders', 'visible: %s' % hidden)
report('hidden' in fr, 'pty: unzip view says that invalid archive files are hidden')
t.send(ESC, settle=0.4)
report(t.expect(r'Main menu'), 'pty: Esc goes back to the main menu')
t.send(b'q', settle=0.5)
t.wait_exit(5)
report(t.exit_code() == 0 and 'Bye!' in t.text(), "pty: 'q' leaves the program cleanly (exit 0)", 'code=%s' % t.exit_code())
report(t.raw.rfind(b'\x1b[?25h') > t.raw.rfind(b'\x1b[?25l'), 'pty: cursor is visible again after exit')
t.kill()

# ----------------------------------------------------------- zip menus
t = Term(d)
t.expect(r'Main menu')
t.send(ENTER)
report(t.expect(r'Selection mode'), 'pty: Enter on "Zip" opens the selection-mode menu')
t.send(ENTER)  # single
ok = t.expect(r'Choose the item to compress')
fr = t.last_frame()
report(ok and 'folder/' in fr and 'a.txt' in fr and fr.index('folder/') < fr.index('a.txt'), 'pty: single-select lists folders and files (folders first)', fr[:500])
t.send(DOWN); t.send(DOWN)   # folder/, a.txt, b.txt -> b.txt
t.send(ENTER)
ok = t.expect(r'Archive format')
fr = t.last_frame()
report(ok and 'gzip  (single file)' in fr and 'ZIP' in fr and '7z' in fr and 'SquashFS' in fr, 'pty: formats offered for ONE regular file include gz/xz/zst', fr[:600])
t.send(ESC, settle=0.4)
report(t.expect(r'Choose the item to compress'), 'pty: Esc in the format menu goes back to the item list')
t.send(ESC, settle=0.4)
report(t.expect(r'Selection mode'), 'pty: Esc again goes back to the selection mode')
t.send(DOWN); t.send(ENTER)   # multiple
ok = t.expect(r'Choose the items to compress')
fr = t.last_frame()
report(ok and '[ ] folder/' in fr, 'pty: multi-select shows unchecked boxes', fr[:400])
t.send(SPACE)
report('[x] folder/' in t.last_frame(), 'pty: Space ticks the highlighted item')
t.send(DOWN); t.send(SPACE)
t.send(SPACE)
report('[ ] a.txt' in t.last_frame(), 'pty: Space again un-ticks it')
t.send(b'a')
fr = t.last_frame()
report('[x] folder/' in fr and '[x] a.txt' in fr and '[x] c.txt' in fr, "pty: 'a' ticks everything")
t.send(b'n')
fr = t.last_frame()
report('[x]' not in fr, "pty: 'n' clears the selection")
t.send(ENTER)
report('Nothing selected' in t.last_frame(), 'pty: Enter with nothing ticked is refused with a hint')
t.send(DOWN); t.send(SPACE); t.send(DOWN); t.send(SPACE)
t.send(ENTER)
ok = t.expect(r'Archive format')
fr = t.last_frame()
report(ok and 'gzip  (single file)' not in fr, 'pty: gz/xz/zst are NOT offered for a multiple selection', fr[:500])
t.kill()
