vyy
===

An ostree-based full fledged Arch Linux distribution, with no package
manager. Basically Fedora Silverblue but with CachyOS' **Zen4**
packages, because we all want that 1% performance improvement.

It's a largely vibe coded attempt at essentially gerrymandering a
standard GNOME-based Arch Linux setup into Fedora's immutable system.
And yes, it works perfectly in its current state.

This README isn't written by an AI though so you can at least take it
at face value.

**Warning**: This project is work-in-progress and even though it is
very usable and stable it might miss some random stuff here and there.

Install Guide
-------------

### GHCR – recommended but you kind of have to trust the ordeal

* Install Silverblue, or Kinoite, or Bazzite, or whatever

```
sudo bootc switch ghcr.io/myyc/vyy-zen4:latest
```

Reboot. `bootc upgrade` to update it. The kernel is signed so you can 
enable secure boot after trusting the key.

```
sudo mokutil --import /usr/share/vyy/secureboot.cer
```

There are no automated `zen3` builds but you can build one
yourself.

### Build it yourself

* Install Silverblue, or Kinoite, or Bazzite, or whatever
* Run `scripts/dev.sh zen3` as root (yes, sorry).
* From there, run `build-vyy-root.sh zen3`
* Commit to your ostree repo, deploy and reboot.

```
sudo ostree commit --repo=/ostree/repo \
    --branch=vyy --owner-uid=0 --owner-gid=0 \
    --subject="vyy YYYYMMDD" \
    --skip-list=/path/to/vyy/config/ostree-skip-list \
    /path/to/vyy/work
sudo ostree admin deploy vyy
```

You will lose out-of-the-box secure boot this way but you can
create your own keys. As long as the paths are right the scripts
will do it for you.

You could also use `scripts/daily-build.sh` and the systemd
units if you have a server to run this on; edit the placeholders
first though.

All the scripts default to `zen4` but you can launch them with
`zen3` or `generic` as arguments. I haven't tested these two, but
they should work.

### Is this even safe

The "install Silverblue" part is pretty much what makes this distro
solid avoiding most possible sources of human error. Partitioning,
encryption (if you want) and the bootloader are Fedora's defaults,
which should be more than enough for most people – Silverblue by
default configures `btrfs` and has native encryption, so hooray.

This is also why you can use this sort of thing on relatively critical
devices – I literally developed all of this on the only device I had
access too, for work included. It doesn't boot? Roll back and forget.

The deployed system keeps your `/etc` and, slightly less intuitively,
your kernel parameters, even though they're nowhere besides `/proc`.
If you want to edit them the process is a bit of a leap of faith
since there is no `rpm-ostree`. Assuming you're in your *latest*
build (i.e. not something that will be overwritten on reboot), you
need to edit your current build's entry in `/boot/loader/entries`,
reboot, and then whichever update will use the new parameters as a
base.

No package manager?
-------------------

No package manager. The system is immutable. Want to add stuff? Fork
and edit `config/packages.conf`. Or use `distrobox`. It's included.

What's under the hood?
----------------------

The core thing is just a basic pacstrap setup with a bunch of
packages added. You can see all of them in `confg/packages.txt`.
The main build script doesn't do much else, besides perhaps
setting the locale.

Most of the hammering is done by `restructure.sh` which is
invoked by `build-vyy-root.sh` so you might as well check that
too since it runs within a rootful container.

Globally, it does a few things, e.g.:

* Building the initramfs with the ostree module (and others)
* Moving everything system inside `/usr` (including **most of /etc**)
* Ensuring the root is compatible with ostree
* Allowing `sudo` for wheel users (otherwise you're locked out)
* Some sane defaults for `pam` (including the fingerprint)

Why depend on AUR packages?
---------------------------

So like ... it doesn't *actually* depend on them yet. The only
core one is `bootc`. If you want to build locally you don't need it,
you only need vanilla ostree. You don't even need it if you want
to update from your own ostree repo.

The other packages are more of a personal convenience. They're
the Mullvad CLI, `ibus-m17n` which is required for certain
input methods, and `raw-thumbnailer`.

Why not NixOS at this point?
----------------------------

Fuck off
