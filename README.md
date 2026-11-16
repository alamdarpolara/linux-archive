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
