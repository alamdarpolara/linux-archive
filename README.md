# linux-archive

A terminal-only archive helper for Linux. Run `linux-archive` (or `larc`) in
any folder to pick **Zip** (create) or **Unzip** (extract) from an arrow-key
menu, or use a subcommand to enter a flow directly. It is pure bash with ANSI
colours and `tput`; it does not need `dialog`, `fzf` or `whiptail`. If the
terminal can't do cursor control, it falls back to numbered menus.

## Files

| File | Purpose |
|---|---|
| `install.sh` | Installs the dependencies with the distribution's own package manager. It is POSIX `sh`, so it also runs where bash is missing (it installs bash). |
| `setup.sh` | Installs the `linux-archive` command system-wide (root only). |
| `uninstall_setup.sh` | Removes everything `setup.sh` installed, plus optionally the packages that `install.sh` added. |
| `linux-archive.sh` | The tool itself. It runs on its own with `./linux-archive.sh` and needs no setup. |

### Requirements

linux-archive needs bash 4.4 or newer and these helper tools, which
`install.sh` installs for you and `linux-archive --check` reports on: `tar`,
`gzip`, `bzip2`, `xz`, `zstd`, `lz4`, `zip`, `unzip`, `mksquashfs`,
`unsquashfs`, `cabextract`, `rpm2cpio`, `cpio`, `ar`, `dpkg-deb`, `bsdtar`,
`file`, `setsid`, `flock` and `tput`. It also needs 7-Zip, a RAR extractor,
and the GNU versions of tar, findutils, coreutils and util-linux.

`--check` prints one line per tool and ends with a count. A missing tool is
marked `[MISSING]` together with the package that provides it:

```text
linux-archive 2.0.0 - dependency check

  [ok]      tar          /usr/bin/tar
  [ok]      gzip         /usr/bin/gzip
  [MISSING] lz4          package: lz4
  ...

22 present, 1 missing.  Run: sudo ./install.sh
```

## Usage

```sh
sudo ./install.sh            # or: sudo ./install.sh --yes --with-setup
sudo ./setup.sh
# open a new terminal, cd into any folder:
linux-archive
larc zip                        # same tool, jump directly into Zip
linux-archive unzip             # jump directly into the archive picker
linux-archive 7z dir1 file2     # skip selection and format menus
linux-archive tgz -- -report    # protect a leading-dash filename with --
linux-archive unzip a.zip b.7z  # extract archives in the order specified
# remove again:
sudo ./uninstall_setup.sh    # add --remove-deps to also remove packages install.sh added
```

### Try it without installing

`linux-archive.sh` needs no setup, so it can run straight from a checkout:

```sh
./install.sh --dry-run        # preview the dependency installation; no root needed
./linux-archive.sh --check    # see which helper tools are present
./linux-archive.sh zip        # start the Zip flow in the current folder
```

### Direct commands

| Invocation | Prompts retained |
|---|---|
| `linux-archive` | Full Zip/Unzip menu; numbered-menu fallback without cursor control. |
| `linux-archive zip` | Single/multiple items, picker, format, level, optional hidden password, output name and overwrite policy. |
| `linux-archive unzip` | Archive picker, safety review, destination and overwrite policy. |
| `linux-archive FORMAT` | Single/multiple items and picker (single-file formats skip the redundant count question); skips Zip/Unzip and format menus. |
| `linux-archive zip file1 file2` | Format, level, optional password, output name and overwrite policy; no selection question or picker. |
| `linux-archive FORMAT file1 file2` | Level (if applicable), optional password (zip/7z), output name and overwrite policy; no selection or format menus. |
| `linux-archive unzip a.zip b.7z` | Safety review and destination for **each** archive; no archive picker. |

Creation formats: `zip` (chosen through the `zip` flow), `7z`, `tar`, `tar.gz`
(alias `tgz`), `tar.bz2`, `tar.xz`, `tar.zst`, `squashfs`, and the single-file
formats `gz`, `xz`, `zst`. The last three require exactly one regular file, not
a directory or symlink. Arguments must name entries directly inside the current
directory (bare name or `./name`); absolute, nested and `..` paths are refused.
Use `--` before a dash-leading filename. Spaces, quotes, Unicode, newlines and
other unusual names are passed as individual, quoted arguments; display of
control characters and bidi overrides is sanitised. `--plain` and `--no-color`
still work; `--check`, `--verify`, `--help`/`-h`, and `--version`/`-V` remain
available on their own. Unknown commands and invalid combinations exit 2 with
usage on stderr, never with the interactive menu. No password option or
environment variable is accepted; passwords still use the hidden prompt.

`larc` accepts precisely the same arguments and runs the same installed script.
Its help and version display `larc` when invoked through that name.

### install.sh options

| Option | Effect |
|---|---|
| `-y, --yes` | Never ask. Uses safe defaults and only the repositories that are already enabled. It **never** enables EPEL, a non-free component or RPM Fusion. |
| `--with-nonfree` | Installs the real (non-free) `unrar` from Debian non-free, Ubuntu multiverse, RPM Fusion nonfree, openSUSE non-oss, or Arch `[extra]`. |
| `--no-nonfree` | Never installs non-free software and never asks about it. |
| `--with-epel` | On RHEL rebuilds, enables EPEL and CRB/PowerTools. They are needed there for 7-Zip, cabextract and dpkg. `--with-nonfree` implies this. |
| `--dry-run` | Only shows what would be done. Root is not needed. |
| `--with-setup` | Runs `setup.sh` after a successful installation. |
| `--no-update` | Skips the package metadata refresh. |

Exit codes:

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | A required tool is still missing |
| 2 | Usage error |
| 3 | Not root and no sudo |
| 4 | Unsupported or unknown system |
| 5 | Immutable system |
| 6 | Package manager is busy (lock) or failing |

### setup.sh / uninstall_setup.sh

- **`sudo ./setup.sh [--yes]`** installs `/opt/linux-archive/linux-archive.sh` and creates
  `/usr/local/bin/linux-archive` (the primary symlink) and `/usr/local/bin/larc`
  (the short symlink). It also adds a marked interactive alias block for the
  long name to the system-wide bash file and writes a manifest to
  `/var/lib/linux-archive/manifest`: the installed script has a SHA-256 sum;
  symlinks have fixed expected targets. Before creating `larc`, setup checks
  `command -v larc` and the destination path. An existing foreign command or
  file is never overwritten. Setup warns, installs everything else and records
  the skipped alias as a collision in the manifest. To resolve one, inspect
  the reported command, move or rename it yourself if appropriate, then rerun
  `sudo ./setup.sh`. A matching symlink without prior manifest ownership is
  also treated as foreign.
- After installing, `setup.sh` checks that a new user's interactive bash
  really sees the alias. The check runs under `setsid` (no controlling
  terminal) with `timeout -k`, so it cannot hang on a real terminal.
- **`sudo ./setup.sh --verify`**, **`linux-archive --verify`** or **`larc --verify`**
  compare manifest-owned files and both symlink targets to the manifest.
  A foreign `larc` collision is reported as skipped, **not** claimed as ours.
- **`sudo ./uninstall_setup.sh [--dry-run] [--yes] [--remove-deps] [--keep-backup]`**
  removes the installation and manifest-owned `larc` symlink only when it still
  points at the recorded script; it leaves any foreign replacement untouched.
  `sudo ./setup.sh --uninstall` runs the same thing.

### Supported distributions

These distributions were tested in containers. To verify the current revision,
run the test matrix described under [Tests](#tests).

| Family | Tested releases | Package manager | System bash file used for the alias |
|---|---|---|---|
| Debian | 12, 13 | apt | `/etc/bash.bashrc` |
| Ubuntu | 22.04, 24.04, 26.04 | apt | `/etc/bash.bashrc` |
| Fedora | 44 | dnf5 | `/etc/bashrc` |
| RHEL rebuilds | Rocky 8 and 9, AlmaLinux 8, 9 and 10 (10: the official x86_64_v2 image) | dnf (+EPEL) | `/etc/bashrc` |
| openSUSE | Leap 16.0, Tumbleweed | zypper | `/etc/bash.bashrc.local` |
| Arch Linux | rolling | pacman | `/etc/bash.bashrc` |
| Alpine | 3.24 | apk | `/etc/bash/bashrc` |

Derivatives are recognised through `ID_LIKE` in `/etc/os-release` (Mint,
Pop!_OS, Manjaro, EndeavourOS and others), but they were not tested. Unknown
systems are refused and get a list of the tools they need. The minimum bash
version is **4.4**, which is the bash of Rocky/Alma 8, the oldest tested
system.

Immutable or declarative systems are detected and refused with exit code 5:

- NixOS
- rpm-ostree / bootc images such as Silverblue, Kinoite and CoreOS (`/run/ostree-booted`)
- Transactional openSUSE/SUSE such as MicroOS, Aeon and SLE Micro
- Ubuntu Core
- Any system with a read-only `/usr`

`linux-archive.sh` itself still runs there if the tools exist.

### Package names per distribution

These names were verified with each package manager.

| Tool | Debian/Ubuntu | Fedora | Rocky/Alma 8–9 | openSUSE | Arch | Alpine |
|---|---|---|---|---|---|---|
| 7-Zip | `7zip` (`p7zip-full` on old releases) | `7zip` | `p7zip` + `p7zip-plugins` (EPEL 8/9), `7zip` (EPEL 10) | `7zip` | `7zip` | `7zip` |
| xz | `xz-utils` | `xz` | `xz` | `xz` | `xz` | `xz` |
| squashfs | `squashfs-tools` | `squashfs-tools` | `squashfs-tools` | `squashfs` | `squashfs-tools` | `squashfs-tools` |
| rpm2cpio | `rpm2cpio` | `rpm` | `rpm` | `rpm` | `rpm-tools` | `rpm2cpio` |
| bsdtar | `libarchive-tools` | `bsdtar` | `bsdtar` | `bsdtar` | `libarchive` | `libarchive-tools` |
| tput | `ncurses-bin` | `ncurses` | `ncurses` | `ncurses-utils` | `ncurses` | `ncurses` |
| flock / setsid | `util-linux` | `util-linux` | `util-linux` | `util-linux` | `util-linux` | `flock` (setsid from BusyBox) |
| cabextract, dpkg | `cabextract`, `dpkg` | same | same (EPEL) | same | same | same |
| non-free unrar | `unrar` (non-free / multiverse) | `unrar` (RPM Fusion nonfree) | `unrar` (RPM Fusion nonfree EL) | `unrar` (non-oss) | `unrar` (`[extra]`) | not packaged |

On Alpine, the BusyBox applets are replaced by the real tools: GNU tar,
coreutils, findutils, grep, gzip and cpio, plus bzip2, xz, Info-ZIP unzip and
util-linux flock. linux-archive uses options that the BusyBox versions lack.

## What it does

### Zip

1. Pick one item or several items. Names with spaces, Unicode, quotes, a
   leading dash or newlines are all handled.
2. Pick the format: zip, 7z, tar, tar.gz, tar.bz2, tar.xz, tar.zst or squashfs.
   gz, xz and zst are also offered when exactly one regular file is selected.
3. Pick a compression level, if the format has levels.
4. Optionally set a password (zip and 7z only):
   - **zip** uses AES-256 through 7-Zip. Weak ZipCrypto is never used.
   - **7z** uses AES-256 and also encrypts the file names (`-mhe=on`).
5. Choose what happens if the output exists: Overwrite, Rename or Skip.
6. The archive is built in a private temporary folder, gets an integrity test,
   and is then moved into place atomically.

### Unzip

1. Only real archives are shown. They are detected by `file` and by
   magic-byte checks, so renamed archives are found too.
2. Supported formats: zip, 7z, rar, tar, tar.gz/tgz, tar.bz2, tar.xz, tar.zst,
   gz, bz2, xz, zst, lz4, lzma, iso, deb, rpm, cpio, ar/.a, cab, squashfs, jar,
   war and apk.
3. A password is asked for only when it is needed, including for header-encrypted
   7z and RAR. You get 3 attempts.
4. A preview and a safety scan run before anything is extracted.
5. The archive is extracted into a new folder named after it, with Overwrite,
   Rename or Skip if that folder exists.

## Security model

### Threat model

- Local multi-user host where other users can read `ps` and `/proc`.
- Malicious archives: path traversal, symlink/hard-link escapes, device nodes,
  setuid files, zip bombs, file-count bombs, hostile file names.
- Hostile environment variables.
- Concurrent runs.
- Root can always modify anything. That is out of scope.

### Passwords

- Passwords are read hidden with `read -rs`. When creating an archive, you
  type the password twice.
- They are never put in argv. They reach 7-Zip or `unrar` through a pipe from
  the builtin `printf`, and the tool runs under `setsid`, so it has no tty.
- They are never fed through a here-string or heredoc. bash before 5.1 backs
  those with temp files.
- They are never exported, written to disk or logged. The variable is
  overwritten and unset after use.
- Core dumps are off (`ulimit -c 0`) and history is off.
- xtrace is forced off while a password is held, so `bash -x linux-archive.sh`
  does not show it.
- Tools that accept passwords only on argv are never used for encrypted
  archives:
  - Info-ZIP `zip -P` / `unzip -P`
  - `unar -p`
  - `bsdtar --passphrase`

### Extraction

- Files are extracted into a private staging folder (mode 0700) inside the
  destination filesystem. It is checked and only then moved into place.
- Before extraction, these are refused:
  - absolute paths and `..` members
  - members stored below a symlink of the same archive
  - hard links with `..` targets
  - cpio and rpm archives whose listing contains a member name with a line
    break, or any other line that is not a listing record (GNU cpio prints
    names raw, so `x<LF>/../../etc/p` would otherwise list as two harmless
    lines). Such stray lines are also checked as paths for every format.
- These limits are hard:
  - more than 64 GiB declared size
  - more than 1,000,000 members
  - a compression ratio of 1000:1 or more when the result is 1 GiB or larger
  - not enough free disk space
- A ratio of 100:1 or more with at least 50 MiB unpacked gets a warning only.
- A watchdog stops any extraction that grows beyond what the archive declared
  or what the disk can hold.
- Listing runs have a 15-minute timeout.
- After extraction:
  - symlinks that point outside the folder are reported, then removed or kept
    as you choose
  - hard links to files outside the folder abort the extraction
  - device nodes, FIFOs and sockets are deleted
  - setuid, setgid and sticky bits and world-write permission are stripped
  - when running as root, ownership is reset to root
- tar/bsdtar run with `--no-same-owner --no-same-permissions`.
- Nested archives are never extracted automatically.

### Environment and terminal

- At start-up, linux-archive always sets a fixed `PATH` and removes these
  variables:
  - `BASH_ENV`, `ENV`, `CDPATH`, `GLOBIGNORE`, `POSIXLY_CORRECT`
  - the tools' option variables: `TAR_OPTIONS`, `GZIP`, `XZ_OPT`, `ZIPOPT`, `UNZIP`, …
- `SHELLOPTS` and `BASHOPTS` are un-exported.
- bash reads `BASH_ENV` and `SHELLOPTS` before the first line of any script
  runs, so this protects the rest of the script and every child process. The
  copy that `setup.sh` installs uses `#!/bin/bash`, so `env` never looks bash
  up through `PATH`. `sudo` resets the environment.
- File names and archive listings are sanitised before printing. Control
  characters, escape sequences and bidi override characters become `?`.

### Output files and concurrency

- An output path that is a pre-created symlink is refused.
- The final rename runs under a `flock` on the directory and uses `mv -T`. It
  never writes through a symlink.
- If two runs target the same name, they never clobber each other.

### System files

- `setup.sh` and `uninstall_setup.sh` take an exclusive lock
  (`/run/linux-archive-setup.lock`), so they never run at the same time.
- `setup.sh` refuses to install below a directory that is group- or
  world-writable or not owned by root.
- The bash file is edited atomically, keeping its owner, mode and SELinux label.
- `uninstall_setup.sh` deletes `/opt/linux-archive` only if it matches the
  manifest exactly. It never runs a blind `rm -rf`.

### Repositories

Only official repositories are used.

- RPM Fusion's release packages are verified with the keys from the signed
  `distribution-gpg-keys` package, instead of the documented `--nogpgcheck`.
- EPEL comes from the distribution's own signed extras repository.

## Known limitations

- **RAR:** creating RAR is not supported (proprietary format and licence).
  Encrypted RAR needs either the real `unrar` (non-free) or a 7-Zip build that
  includes the RAR decoder, as on Arch. The free fallbacks (unar, unrar-free,
  bsdtar/libarchive) only handle unencrypted RAR. libarchive older than 3.4 has
  no RAR5 support at all; this affects Rocky/Alma 8.
- **ZIP passwords** must be ASCII. 7-Zip limits this for ZIP AES; the 7z format
  accepts any characters.
- **Root** can always change the installed files. `--verify` only detects
  changes after the fact.
- **`sudo linux-archive`** needs `/usr/local/bin` in sudo's `secure_path`.
  Otherwise use `sudo /usr/local/bin/linux-archive`. Running as root is
  discouraged anyway.
- **Old tool versions** that the tests met and that linux-archive handles:
  - p7zip 16.02 (EPEL 8/9) asks for the password twice when creating, so it
    gets it twice.
  - 7-Zip before 22 (Ubuntu 22.04) skips absolute or escaping symlinks. The
    skipped links are recreated inside the staging folder so that you decide
    (remove or keep), just as with newer 7-Zip.
  - squashfs-tools before 4.6 need `-f` to extract into the staging folder.
  - squashfs-tools 4.3 has no `-quiet`, so it is only passed when supported.
- **RPM Fusion's `unrar` for EL10** is built for x86-64-v3. On older CPUs it
  does not run, so `install.sh` removes it again, removes RPM Fusion, and uses
  bsdtar. This happened in the AlmaLinux 10 x86_64_v2 test.
- **Not tested:**
  - **Rocky Linux 10 and the official `almalinux:10` image:** they require
    x86-64-v3, which the test host's CPU lacks. AlmaLinux 10 was tested
    through its x86_64_v2 build.
  - **Real hosts with SELinux/AppArmor enforcing:** labels are copied with
    `chcon --reference` if SELinux is enabled.
  - **Real immutable systems:** only fake markers were tested.

## Tests

`linux-archive_test/run_all.sh` is not a deliverable. It builds one container
image per distribution through the real `install.sh`, then runs:

- the `install.sh` scenarios in fresh containers
- the root suite: `setup.sh`, `uninstall_setup.sh`, locking, tampering,
  disk-full and extraction as root
- the main suite as an unprivileged user: every format × level × password,
  extract-only formats, negative cases, security cases, password-leak proof,
  and the pty-driven UI

The root suite also runs `setup.sh` on a pseudo-terminal. Containers have no
tty, so this is the only test that catches terminal-only hangs.

```sh
cd linux-archive_test
./run_all.sh                       # all 15 distributions (see distros.sh)
ONLY=debian13,arch ./run_all.sh    # a subset
JOBS=2 ./run_all.sh                # distributions in parallel
SKIP_BUILD=1 SKIP_INSTALL=1 ./run_all.sh   # reuse images, only root + main suites
# also: SKIP_ROOT=1, SKIP_MAIN=1
```

It needs docker or podman and never installs them. Each run writes local
`logs/<distro>.log` and `logs/SUMMARY.txt`; generated logs are not published.

The full matrix has not been rerun since the latest two fixes (the cpio
line-break check and the setup.sh pty test). Run it to verify this revision.
