# linux-archive
A terminal-only archive helper for Linux. You type `linux-archive` in any folder, pick **Zip** (create) or **Unzip** (extract) from an arrow-key menu, and it works on that folder. It is pure bash with ANSI colours and `tput`; it does not need `dialog`, `fzf` or `whiptail`. If the terminal can't do cursor control, it falls back to numbered menus.
