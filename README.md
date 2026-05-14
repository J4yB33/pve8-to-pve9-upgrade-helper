# Proxmox VE 8 to 9 Upgrade Helper

A repeatable helper script for preparing and running an in-place upgrade from Proxmox VE 8.x to Proxmox VE 9.x.

The script is built for lab and small server environments where you want a controlled, repeatable upgrade process with repo cleanup, safety checks, logging, and `tmux` protection.

## What it does

- Requires root.
- Requires `tmux`.
- Backs up current APT source files.
- Disables Proxmox enterprise repositories.
- Disables beta/test repositories.
- Moves old repo files, including:
  - `.list`
  - `.dpkg-dist`
  - `.dpkg-old`
  - `.save`
  - `.bak`
- Converts Debian base repositories from `bookworm` to `trixie`.
- Adds the Proxmox VE 9 no-subscription repository.
- Adds the Ceph Squid no-subscription repository.
- Disables the `apt-listchanges` pager.
- Runs `apt update`.
- Runs `pve8to9 --full`.
- Shows Ceph health if Ceph is installed.
- Offers to set Ceph `noout`.
- Runs `apt dist-upgrade` only after manual confirmation.
- Writes logs to `/root/pve9-upgrade-logs/`.
- Backs up repo files to `/root/apt-repo-backup-YYYYMMDD-HHMMSS/`.

## Warning

This script changes APT repositories and can start a major Proxmox upgrade.

Before running it:

- Confirm all VMs and containers are backed up.
- Confirm you have console, IPMI, iDRAC, iLO, or physical access.
- Do not rely only on SSH.
- Run it on one node at a time.
- Review `pve8to9 --full` before continuing.
- Do not run it blindly on production systems.

## Tested scenario

Used for Proxmox VE 8.4.x to Proxmox VE 9.x preparation.

Example starting version:

```text
pve-manager/8.4.19
kernel 6.8.12-x-pve
```

## Repository layout

```text
.
├── README.md
├── LICENSE
├── .gitignore
└── scripts
    └── pve8-to-pve9-upgrade-helper.sh
```

## Install on a Proxmox host

Install required tools:

```bash
apt update
apt install git tmux -y
```

Clone the repo:

```bash
git clone https://github.com/J4yB33/pve8-to-pve9-upgrade-helper.git
cd pve8-to-pve9-upgrade-helper
```

Copy the script to `/root`:

```bash
cp scripts/pve8-to-pve9-upgrade-helper.sh /root/
chmod +x /root/pve8-to-pve9-upgrade-helper.sh
```

## Run

Start `tmux` first:

```bash
tmux new -s pve9-upgrade
```

Run the script inside `tmux`:

```bash
bash /root/pve8-to-pve9-upgrade-helper.sh
```

If SSH drops, reconnect to the server and reattach:

```bash
tmux attach -t pve9-upgrade
```

## Manual prompt guidance

During `apt dist-upgrade`, Debian or Proxmox may ask how to handle changed config files.

Use these choices unless you know you changed the file:

```text
/etc/lvm/lvm.conf       Y
/etc/default/grub       N
/etc/ssh/sshd_config    Y if SSH is default, choose D first if unsure
/etc/issue              N
/etc/chrony/chrony.conf Y if NTP is default
```

## Ceph note

If the host uses Ceph, the script shows:

```bash
ceph -s
```

It can also set:

```bash
ceph osd set noout
```

After the node is upgraded and stable, unset it:

```bash
ceph osd unset noout
```

## Logs

Script logs are written to:

```text
/root/pve9-upgrade-logs/
```

APT repo backups are written to:

```text
/root/apt-repo-backup-YYYYMMDD-HHMMSS/
```

## Recovery notes

If SSH drops and the upgrade appears stuck, check active upgrade processes:

```bash
ps -ef | grep -E 'apt|dpkg|apt-listchanges|pager' | grep -v grep
```

Check live APT logs:

```bash
tail -f /var/log/apt/term.log
```

Check live dpkg logs:

```bash
tail -f /var/log/dpkg.log
```

If `apt-listchanges` is stuck in a pager, this script prevents that by setting:

```bash
APT_LISTCHANGES_FRONTEND=none
```

## Common failure: old Bookworm repo remains

If the script stops with:

```text
ERROR: Bookworm entries still found
```

Find the file:

```bash
grep -R "bookworm" /etc/apt/sources.list /etc/apt/sources.list.d/ || true
```

Move the old file out of the repo path:

```bash
mkdir -p /root/apt-repo-backup-manual
mv /etc/apt/sources.list.d/FILE-NAME /root/apt-repo-backup-manual/
```

Then rerun the script.

## Common failure: Proxmox enterprise repo remains

If the script stops with:

```text
ERROR: Enterprise repo entries still found
```

Find the file:

```bash
grep -R "enterprise.proxmox.com" /etc/apt/sources.list /etc/apt/sources.list.d/ || true
```

Move the enterprise repo file out of the repo path:

```bash
mkdir -p /root/apt-repo-backup-manual
mv /etc/apt/sources.list.d/FILE-NAME /root/apt-repo-backup-manual/
```

Then rerun the script.

## After reboot

Check the Proxmox version:

```bash
pveversion
```

Check the running kernel:

```bash
uname -r
```

Run the checker again:

```bash
pve8to9 --full
```

If Ceph `noout` was set, unset it after the node is stable:

```bash
ceph osd unset noout
```

## License

MIT
