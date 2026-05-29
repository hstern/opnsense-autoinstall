# opnsense-autoinstall

Turn a stock OPNsense live image into one that **installs itself** — no
keyboard, no `dialog` menus, no key-press to import config. Boot the
customized image in a VM (or from USB) and it partitions the disk,
clones OPNsense onto it, drops in your `config.xml`, and reboots into a
fully-configured firewall.

Useful for Terraform/Packer/CI pipelines, lab rebuilds, and anywhere you
want OPNsense provisioned reproducibly instead of clicked through by hand.

> **Status: early / mechanism-verified.** The install mechanism was
> derived by reading the installer scripts straight off the OPNsense
> install media and is documented in full below. Treat the scripts as a
> starting point and test in a throwaway VM before trusting them with a
> real disk. PRs welcome.

## Why this isn't as simple as "use a preseed"

If you've automated FreeBSD installs, your instinct is the
[`bsdinstall` scripted install](https://man.freebsd.org/cgi/man.cgi?bsdinstall):
drop an `installerconfig` and let `bsdinstall script` run it. **That does
not work on OPNsense, for two independent reasons:**

1. **The boot path never consults `installerconfig`.** OPNsense's live
   image autologins and runs `opnsense-installer` → `bsdinstall opnsense`.
   That `opnsense` subcommand is OPNsense's own orchestrator — a pure
   interactive `dialog` menu loop with **no scripted mode and no
   `installerconfig` check**. (Stock FreeBSD's `startbsdinstall` *does*
   honor `/etc/installerconfig`, but it isn't on OPNsense's boot path.)

2. **There are no distribution sets to extract.** A normal FreeBSD
   scripted install fetches and extracts `base.txz`/`kernel.txz`.
   OPNsense ships none — it installs by **`cpdup`-cloning the running
   live filesystem** onto the target disk
   (`/usr/libexec/bsdinstall/opnsense-install`). So even if you reached
   `bsdinstall script`, the extract step would have nothing to do.

This is why "unattended OPNsense" is largely unexplored: the obvious
mechanism is a dead end, and the working one isn't documented.

## How it actually works

The OPNsense orchestrator (`/usr/libexec/bsdinstall/opnsense`) is, under
the menus, just a **sequencer over non-interactive sub-commands**:

```
bsdinstall keymap          # skipped if BSDINSTALL_KEYMAP_DONE=1
bsdinstall opnsense-ufs     # partition (interactive disk picker; the work
                            #   underneath is plain scriptedpart + gpart)
bsdinstall mount
bsdinstall opnsense-install # cpdup clone of the live FS — non-interactive
bsdinstall bootconfig
bsdinstall opnsense-rootpass
bsdinstall entropy
bsdinstall umount
```

`autoinstall.sh` replaces the orchestrator with a headless version that
calls those same steps directly: it auto-selects the disk, replicates
`opnsense-ufs`'s GPT layout (`scriptedpart` + `gpart`) with no dialogs,
runs the `cpdup` clone, and writes the bootloader.

The last trick is the config import. `opnsense-install` clones the live
system's `/conf/config.xml` to the target. Overwrite the target's copy
with **your** `config.xml` before unmounting, and the installed system
boots fully configured — no interactive "Import Config", no seed CD, no
key-press:

```sh
cp your-config.xml ${BSDINSTALL_CHROOT}/conf/config.xml
```

## Usage

You need two things: a stock OPNsense **vga** image, and a **FreeBSD host**
to run the customizer on (it mounts the image's UFS filesystem read-write
via `mdconfig`, which macOS and Linux can't do reliably — an existing
OPNsense box or a throwaway FreeBSD VM works fine).

```sh
# 1. Get a stock OPNsense vga image (the raw disk image, not the DVD ISO —
#    it has a writable UFS filesystem, so no ISO9660 repackaging).
fetch https://pkg.opnsense.org/releases/26.1.6/OPNsense-26.1.6-vga-amd64.img.bz2
bunzip2 OPNsense-26.1.6-vga-amd64.img.bz2

# 2. Build an unattended installer image (run on FreeBSD, as root).
#    -c is optional; omit it to install OPNsense with its default config.
./mkimage.sh \
    -i OPNsense-26.1.6-vga-amd64.img \
    -o opnsense-unattended.img \
    -c examples/config.xml \
    -d auto \
    -s 8G

# 3. Boot opnsense-unattended.img in the target VM (as its boot disk,
#    alongside the empty install-target disk). It installs hands-off and
#    reboots into the configured system.
```

### Running from Linux / macOS / Windows

`mkimage.sh` itself must run on FreeBSD, but you don't need a FreeBSD
workstation. `mkimage-vagrant.sh` borrows a throwaway FreeBSD VM: it
boots one with Vagrant, copies the inputs in over SSH, runs `mkimage.sh`
inside it, copies the finished image back, and destroys the VM. Same
flags as `mkimage.sh`:

```sh
./mkimage-vagrant.sh \
    -i OPNsense-26.1.6-vga-amd64.img \
    -o opnsense-unattended.img \
    -c examples/config.xml -s 8G
```

Needs `vagrant` + a provider (VirtualBox is the cross-platform default;
on Apple Silicon use the qemu/utm provider, or run `mkimage.sh` on a
real FreeBSD box). If you already have a FreeBSD or OPNsense box, skip
Vagrant entirely — `scp` the inputs over and run `mkimage.sh` there.

**Why not a Docker image?** Writing into the image needs FreeBSD's UFS2
read-write driver. Containers share the *host* kernel, so a Linux Docker
host only has Linux's UFS driver — whose write support is experimental
and historically corrupting (`CONFIG_UFS_FS_WRITE`, the "say N" option).
There's no FreeBSD-kernel container on Linux. The reliable cross-OS path
is a real FreeBSD kernel, i.e. a VM — which is what `mkimage-vagrant.sh`
gives you.

### Options (`mkimage.sh`)

| Flag | Meaning | Default |
|---|---|---|
| `-i` | stock OPNsense vga `.img` (decompressed) | required |
| `-o` | output customized image | required |
| `-c` | `config.xml` to install as the target's `/conf/config.xml` | none (stock config) |
| `-d` | target install disk in the VM (`auto` = sole/first disk) | `auto` |
| `-s` | swap partition size (gpart syntax, e.g. `8G`) | none |
| `-f` | `reboot` or `halt` when finished | `reboot` |

## The `config.xml`

Any valid OPNsense `config.xml` works. The one gotcha worth knowing:
WebGUI login authenticates against the `<user>`/`<group>` blocks in
`config.xml`, **not** `/etc/master.passwd`. A `<user>` with no
`<groupname>admins</groupname>` (and a matching `<group>` carrying
`<priv>page-all</priv>`) logs in but has no privileges. See
[`examples/config.xml`](examples/config.xml) for a minimal working
shape (root in `admins`, bcrypt password, WebGUI/SSH enabled). Generate
the password hash with:

```sh
# bcrypt; the leading empty username is intentional
htpasswd -bnBC 10 "" 'your-password' | tr -d ':\n'
```

## Boot trigger

`mkimage.sh` installs the headless installer as `/etc/rc.local` on the
live image, which runs late in multi-user startup. If a given OPNsense
release doesn't honor `rc.local` on the live image, the alternative is
to repoint the console autologin at `opnsense-autoinstall` instead of
`opnsense-installer`. (Confirming the most robust trigger across releases
is on the TODO list — see below.)

## Caveats / TODO

- **Mechanism verified by source-reading; end-to-end test in progress.**
  Validate in a throwaway VM first.
- **`mkimage.sh` requires FreeBSD** (UFS r/w mount). `mkimage-vagrant.sh`
  covers Linux/macOS/Windows by borrowing a throwaway FreeBSD VM; a
  native userspace-UFS path (no VM) would be nicer still — PRs welcome.
- **Boot trigger robustness** across OPNsense releases (rc.local vs.
  autologin replacement) needs confirming.
- **ZFS** target layout isn't wired yet (only UFS); `opnsense-zfs`
  follows the same pattern.
- Tested against OPNsense **26.1**. Earlier/later releases shift the
  installer scripts; the approach holds but paths/constants may move.

## How this was figured out

Everything above came from reading these scripts off the install media
(`isoinfo -i OPNsense-*.iso -R -x /path`):

- `/usr/local/sbin/opnsense-installer` — entry point.
- `/usr/libexec/bsdinstall/opnsense` — the interactive orchestrator.
- `/usr/libexec/bsdinstall/opnsense.subr` — disk enumeration + sizes.
- `/usr/libexec/bsdinstall/opnsense-ufs` — UFS partitioning.
- `/usr/libexec/bsdinstall/opnsense-install` — the cpdup clone.
- `/usr/libexec/bsdinstall/startbsdinstall` — stock launcher (the one
  that *does* honor `installerconfig`, but isn't on OPNsense's path).

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with or endorsed by Deciso B.V. / the OPNsense project.
"OPNsense" is a registered trademark of Deciso B.V.
