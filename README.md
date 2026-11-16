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
