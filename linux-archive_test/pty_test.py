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

# --------------------------------------------------------------- resize
t = Term(d, rows=24, cols=80)
t.expect(r'Main menu')
t.expect(r'❯ Zip', since_mark=False)   # wait for the first full frame
w1 = max((len(l) for l in strip(t.raw.decode('utf-8', 'replace')).split('\n') if l.startswith('╭')), default=0)
t.mark = len(t.raw)
t.resize(30, 60)
ok = t.expect(r'╭─+╮', timeout=10)
tops = re.findall(r'╭─+╮', t.since())
w2 = len(tops[-1]) if tops else 0
report(ok and w1 > w2 and w2 == 59, 'pty: terminal resize (SIGWINCH) re-draws the menu at the new width (%d -> %d)' % (w1, w2))
t.mark = len(t.raw)
t.resize(24, 100)
t.expect(r'╭─+╮', timeout=10)
tops = re.findall(r'╭─+╮', t.since())
report(bool(tops) and len(tops[-1]) == 99, 'pty: growing the terminal re-draws wider (boxes capped at 100 columns)', 'width=%s' % (len(tops[-1]) if tops else None))
t.kill()

# ------------------------------------------------- numbered-menu fallback
for label, kwargs in (('TERM=dumb', dict(env={'TERM': 'dumb'})), ('--plain', dict(args=['--plain']))):
    t = Term(d, **kwargs)
    ok = t.expect(r'Choose 1-3')
    txt = t.text()
    report(ok and '1) Zip' in txt and '\x1b[?25l' not in t.raw.decode('utf-8', 'replace'), 'pty: %s falls back to a numbered menu' % label, txt[-300:])
    t.send(b'3\r')
    t.wait_exit(4)
    report(t.exit_code() == 0, 'pty: numbered menu works (3 = quit)')
    t.kill()

# ------------------------------------------- password typed hidden in the UI
d = mkdir('hidden_pw')
write(os.path.join(d, 'doc.txt'), b'some content\n' * 50)
CANARY = 'Pty-Canary-7Zx91'
t = Term(d)
t.expect(r'Main menu'); t.send(ENTER)
t.expect(r'Selection mode'); t.send(ENTER)
t.expect(r'Choose the item'); t.send(ENTER)
t.expect(r'Archive format'); t.send(DOWN); t.send(ENTER)   # 7z
t.expect(r'Compression level'); t.send(ENTER)
ok = t.expect(r'Password protection')
t.send(DOWN); t.send(ENTER)
ok = ok and t.expect(r'Enter password')
t.send(CANARY + '\r', settle=0.3)
ok = ok and t.expect(r'Repeat password')
before = len(t.raw)
t.send(CANARY + '\r', settle=0.3)
ok = ok and t.expect(r'Archive name', timeout=8)
t.send(ENTER, settle=0.3)
ok = ok and t.expect(r'Archive created and verified', timeout=30)
report(ok and os.path.exists(os.path.join(d, 'doc.txt.7z')), 'pty: 7z with password created through the TUI', t.since()[-300:])
report(CANARY not in t.text(), 'pty: typed password is NOT echoed to the terminal (hidden input)')
t.send(ENTER, settle=0.3)
t.expect(r'Main menu'); t.send(b'q'); t.wait_exit(4)
report(not zipinfo_leftovers(d), 'pty: no temp leftovers after a successful run')
t.kill()

# -------------------------------------------------- Ctrl+C during creation
d = mkdir('ctrlc_create')
if not os.path.exists(os.path.join(ROOT, 'big.bin')):
    # base64 of random data: ~6 bits/byte entropy, slow for LZMA2 -mx=9 (a fast "all random" file would finish too soon)
    os.system(f"head -c 60000000 /dev/urandom | base64 -w 76 > '{os.path.join(ROOT, 'big.bin')}'")
os.link(os.path.join(ROOT, 'big.bin'), os.path.join(d, 'big.bin'))
t = Term(d)
t.expect(r'Main menu'); t.send(ENTER)
t.expect(r'Selection mode'); t.send(ENTER)
t.expect(r'Choose the item'); t.send(ENTER)
t.expect(r'Archive format'); t.send(DOWN); t.send(ENTER)   # 7z
t.expect(r'Compression level')
for _ in range(2):
    t.send(DOWN)      # Normal -> Maximum -> Ultra
t.send(ENTER)
t.expect(r'Password protection'); t.send(ENTER)
t.expect(r'Archive name'); t.send_now(ENTER)
started = t.expect(r'Creating big\.bin\.7z|Creating', timeout=15, settle=False)
time.sleep(1.5)
report(started and any(n.startswith('.linux-archive.') for n in os.listdir(d)), 'pty: archive creation is running (temp dir present) before Ctrl+C')
t.send_now(CTRL_C, settle=0.2)
done = t.wait_exit(15)
txt = t.text()
report(done and t.exit_code() == 130, 'pty: Ctrl+C during creation -> exit code 130', 'code=%s' % t.exit_code())
report('Interrupted' in txt and 'partial archive was deleted' in txt, 'pty: Ctrl+C prints a clear "partial archive was deleted" message')
left = sorted(os.listdir(d))
report(left == ['big.bin'], 'pty: no partial archive and no temp folder remains after Ctrl+C', 'dir=%s' % left)
lfl = termios.tcgetattr(t.fd)[3]
report((lfl & termios.ECHO) and (lfl & termios.ICANON), 'pty: terminal modes (echo, canonical) are restored after Ctrl+C')
report(t.raw.rfind(b'\x1b[?25h') > t.raw.rfind(b'\x1b[?25l'), 'pty: cursor is visible again after Ctrl+C')
time.sleep(0.3)
stale = os.popen("pgrep -f '7z[za]* a .*linux-archive' | head -n 3").read().strip()
report(stale == '', 'pty: no stray 7z process survives Ctrl+C', stale)
t.kill()

# ------------------------------------------------- Ctrl+C during extraction
d = mkdir('ctrlc_extract')
big_tgz = os.path.join(ROOT, 'big.tar.gz')
if not os.path.exists(big_tgz):
    os.system(f"cd '{ROOT}' && head -c 300000000 /dev/urandom > big300.bin && tar -czf big.tar.gz big300.bin && rm -f big300.bin")
os.link(big_tgz, os.path.join(d, 'big.tar.gz'))
t = Term(d)
t.expect(r'Main menu'); t.send(DOWN); t.send(ENTER)
t.expect(r'Choose the archive'); t.send(ENTER)
ok = t.expect(r'Next step', timeout=60)
fr = t.last_frame()
report(ok and 'Archive summary' in fr and 'big.tar.gz' in fr and 'Next step' in fr and 'Extract' in fr, 'pty: review screen shows the archive summary AND the Extract/Cancel menu together', fr[:500])
t.send(ENTER)                                   # Extract
t.expect(r'Extract into folder'); t.send_now(ENTER)
started = t.expect(r'Extracting', timeout=20, settle=False)
time.sleep(0.6)
t.send_now(CTRL_C, settle=0.2)
done = t.wait_exit(15)
txt = t.text()
report(started and done and t.exit_code() == 130, 'pty: Ctrl+C during extraction -> exit code 130', 'started=%s code=%s' % (started, t.exit_code()))
report('Interrupted' in txt and 'partial extraction was deleted' in txt, 'pty: Ctrl+C prints "partial extraction was deleted"')
left = sorted(os.listdir(d))
report(left == ['big.tar.gz'], 'pty: no staging folder and no partial output remains after Ctrl+C', 'dir=%s' % left)
lfl = termios.tcgetattr(t.fd)[3]
report((lfl & termios.ECHO) and (lfl & termios.ICANON), 'pty: terminal modes restored after Ctrl+C during extraction')
t.kill()

# ----------------------------------------------------- Ctrl+C in a menu
d = mkdir('ctrlc_menu')
t = Term(d)
t.expect(r'Main menu')
t.send(CTRL_C, settle=0.3)
t.wait_exit(5)
lfl = termios.tcgetattr(t.fd)[3]
report(t.exit_code() == 130 and (lfl & termios.ECHO) and (lfl & termios.ICANON) and t.raw.rfind(b'\x1b[?25h') > t.raw.rfind(b'\x1b[?25l'),
       'pty: Ctrl+C inside a menu exits (130) and restores echo/canonical mode/cursor', 'code=%s' % t.exit_code())
t.kill()

# ----------------------------- notes stay visible next to menus (TUI repaint)
d = mkdir('notes')
write(os.path.join(d, 'doc.txt'), b'hello\n' * 100)
os.system(f"""cd '{d}' && python3 - <<'PY2'
import tarfile, io
t = tarfile.open('links.tar', 'w')
ti = tarfile.TarInfo('ok.txt'); ti.size = 3; t.addfile(ti, io.BytesIO(b'ok\\n'))
ti = tarfile.TarInfo('abs_link'); ti.type = tarfile.SYMTYPE; ti.linkname = '/etc/hostname'; t.addfile(ti)
t.close()
PY2""")
t = Term(d)
t.expect(r'Main menu'); t.send(ENTER)
t.expect(r'Selection mode'); t.send(ENTER)
t.expect(r'Choose the item'); t.send(DOWN); t.send(ENTER)       # entries: doc.txt, links.tar -> links.tar
ok = t.expect(r'Archive format')
report(ok and 'Selected: links.tar' in t.last_frame(), 'pty: the "Selected: ..." note is visible together with the format menu', t.last_frame()[:300])
t.send(DOWN); t.send(ENTER)    # 7z
t.expect(r'Compression level'); t.send(ENTER)
ok = t.expect(r'Password protection')
fr = t.last_frame()
report(ok and 'AES-256' in fr and 'file NAMES are encrypted' in fr, 'pty: the AES-256 / encrypted-names note is visible together with the password menu', fr[:400])
t.kill()
t = Term(d)
t.expect(r'Main menu'); t.send(DOWN); t.send(ENTER)             # Unzip
ok = t.expect(r'Choose the archive')
t.send(ENTER)                                                   # links.tar
ok = t.expect(r'Next step', timeout=15)
fr = t.last_frame()
report(ok and 'Archive summary' in fr and 'links.tar' in fr and 'First entries' in fr and 'abs_link' in fr, 'pty: review shows summary + first entries + menu on one screen', fr[:700])
t.send(ENTER)                                                   # Extract
t.expect(r'Extract into folder'); t.send(ENTER, settle=0.3)
ok = t.expect(r'dangerous symlinks|point outside', timeout=15)
ok = t.expect(r'Remove them', timeout=15) and ok    # the menu frame is drawn after the title
fr = t.last_frame()
report(ok and 'abs_link -> /etc/hostname' in fr and 'Remove them' in fr, 'pty: dangerous-symlink screen lists the links together with the Remove/Keep/Abort menu', fr[:600])
t.send(ENTER)                                                   # Remove (default)
t.expect(r'Extraction finished', timeout=10)
t.send(ENTER, settle=0.3); t.expect(r'Main menu'); t.send(b'q'); t.wait_exit(4)
report(os.path.isfile(os.path.join(d, 'links', 'ok.txt')) and not os.path.lexists(os.path.join(d, 'links', 'abs_link')), 'pty: choosing "Remove" in the TUI removed the dangerous symlink and kept the file')
t.kill()

# ------------------------------------------------ long list: scrolling
d = mkdir('scroll')
for i in range(60):
    write(os.path.join(d, 'file%02d.txt' % i), b'x')
t = Term(d, rows=24, cols=80)
t.expect(r'Main menu'); t.send(ENTER)
t.expect(r'Selection mode'); t.send(ENTER)
ok = t.expect(r'Choose the item to compress')
fr = t.last_frame()
report(ok and 'of 60' in fr and 'file59.txt' not in fr and 'file00.txt' in fr, 'pty: a 60-entry list is windowed to the screen with a "n-m of 60" indicator', fr[:300])
t.send(b'G')
fr = t.last_frame()
report('❯ file59.txt' in fr and 'file00.txt' not in fr, "pty: 'G'/End jumps to the last entry and scrolls the window", fr[:400])
t.send(b'g')
report('❯ file00.txt' in t.last_frame(), "pty: 'g'/Home jumps back to the first entry")
t.send(b'\x1b[6~')
report('❯ file' in t.last_frame() and '❯ file00.txt' not in t.last_frame(), 'pty: Page Down moves a page')
t.send(UP)
t.kill()

# -------------------------------------------- NO_COLOR and a useless TERM
d = mkdir('nocolor')
t = Term(d, env={'NO_COLOR': '1'})
t.expect(r'Main menu')
t.expect(r'❯ Zip', since_mark=False)   # the menu frame is drawn after the title
sgr = re.findall(rb'\x1b\[(?:3[0-7]|9[0-7]|4[0-7]|1;3[0-7])m', t.raw)
report(not sgr and '❯ Zip' in t.text(), 'pty: NO_COLOR=1 -> no colour escape sequences, pointer glyph still marks the current item', str(sgr[:3]))
t.send(b'q'); t.wait_exit(3); t.kill()
t = Term(d, env={'TERM': ''})
ok = t.expect(r'Choose 1-3')
report(ok and '1) Zip' in t.text() and b'\x1b[?25l' not in t.raw, 'pty: empty TERM -> numbered-menu fallback (no cursor-control sequences)')
t.send(b'3\r'); t.wait_exit(3); t.kill()

# ----------------------------------------------- read-only folder message
d = mkdir('readonly')
os.chmod(d, 0o555)
t = Term(d)
t.expect(r'Main menu'); t.send(ENTER)
report(t.expect(r'not writable'), 'pty: read-only folder -> clear "not writable" message instead of a crash')
t.send(ENTER, settle=0.3); t.send(b'q'); t.wait_exit(4)
t.kill()
os.chmod(d, 0o755)
print('PTY_DONE', flush=True)
