#!/usr/bin/env bash
# =============================================================================
# Proxmox VE 8 to 9 Upgrade Helper
# Author: Les Adams
# GitHub: https://github.com/J4yB33
# Repository: https://github.com/J4yB33/pve8-to-pve9-upgrade-helper
# License: MIT
#
# Description:
#   Repeatable helper for preparing and running a Proxmox VE 8.x to 9.x
#   in-place upgrade with repo cleanup, tmux protection, safety checks,
#   Ceph checks, apt-listchanges handling, and logging.
# =============================================================================
set -euo pipefail
shopt -s nullglob

LOG_DIR="/root/pve9-upgrade-logs"
BACKUP_DIR="/root/apt-repo-backup-$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/pve8-to-pve9-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$LOG_DIR"
mkdir -p "$BACKUP_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================================"
echo " Proxmox VE 8 to 9 upgrade helper"
echo " Host:   $(hostname)"
echo " Date:   $(date)"
echo " Log:    $LOG_FILE"
echo " Backup: $BACKUP_DIR"
echo "============================================================"
echo

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script as root."
  exit 1
fi

echo "[0] Current version"
pveversion || true
uname -r || true
echo

echo "[1] Confirm tmux"
if [ -n "${TMUX:-}" ]; then
  echo "PASS: running inside tmux."
else
  echo "ERROR: you are not inside tmux."
  echo
  echo "Run:"
  echo "tmux new -s pve9-upgrade"
  echo
  echo "Then run:"
  echo "bash /root/pve8-to-pve9-upgrade-helper.sh"
  exit 1
fi
echo

echo "[2] Backup existing APT repo files"
cp -a /etc/apt/sources.list "$BACKUP_DIR/sources.list.backup" 2>/dev/null || true
cp -a /etc/apt/sources.list.d "$BACKUP_DIR/sources.list.d.backup" 2>/dev/null || true
echo "Backed up APT sources to $BACKUP_DIR"
echo

echo "[3] Disable apt-listchanges pager"
cat > /etc/apt/listchanges.conf << 'APTLC'
[apt]
frontend=none
confirm=false
email_address=root
save_seen=/var/lib/apt/listchanges.db
which=news
APTLC
echo "Updated /etc/apt/listchanges.conf"
echo

echo "[4] Disable old, enterprise, beta, backup, and dpkg repo files"

REPO_FILES_TO_MOVE=(
  /etc/apt/sources.list.d/pve-enterprise.list
  /etc/apt/sources.list.d/pve-enterprise.sources
  /etc/apt/sources.list.d/ceph-enterprise.list
  /etc/apt/sources.list.d/ceph-enterprise.sources
  /etc/apt/sources.list.d/pve-install-repo.list
  /etc/apt/sources.list.d/pve-no-subscription.list
  /etc/apt/sources.list.d/ceph.list
  /etc/apt/sources.list.d/pvetest-for-beta.list
  /etc/apt/sources.list.d/*.dpkg-dist
  /etc/apt/sources.list.d/*.dpkg-old
  /etc/apt/sources.list.d/*.save
  /etc/apt/sources.list.d/*.bak
)

for file in "${REPO_FILES_TO_MOVE[@]}"; do
  if [ -e "$file" ]; then
    mv "$file" "$BACKUP_DIR/"
    echo "Moved: $file"
  fi
done
echo

echo "[5] Convert Debian base repos from Bookworm to Trixie"
if grep -q "bookworm" /etc/apt/sources.list 2>/dev/null; then
  sed -i 's/bookworm/trixie/g' /etc/apt/sources.list
  echo "Updated /etc/apt/sources.list"
else
  echo "No Bookworm entries found in /etc/apt/sources.list"
fi
echo

echo "[6] Create Proxmox VE 9 no-subscription repo"
cat > /etc/apt/sources.list.d/proxmox.sources << 'PVE'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
PVE
echo "Created /etc/apt/sources.list.d/proxmox.sources"
echo

echo "[7] Create Ceph Squid no-subscription repo"
cat > /etc/apt/sources.list.d/ceph.sources << 'CEPH'
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
CEPH
echo "Created /etc/apt/sources.list.d/ceph.sources"
echo

echo "[8] Check for remaining Bookworm entries"
BOOKWORM_LEFT="$(grep -R "bookworm" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || true)"

if [ -n "$BOOKWORM_LEFT" ]; then
  echo "ERROR: Bookworm entries still found:"
  echo "$BOOKWORM_LEFT"
  echo
  echo "Fix these before continuing."
  exit 1
else
  echo "PASS: no Bookworm entries found."
fi
echo

echo "[9] Check for enterprise repos"
ENTERPRISE_LEFT="$(grep -R "enterprise.proxmox.com" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || true)"

if [ -n "$ENTERPRISE_LEFT" ]; then
  echo "ERROR: Enterprise repo entries still found:"
  echo "$ENTERPRISE_LEFT"
  echo
  echo "Fix these before continuing."
  exit 1
else
  echo "PASS: no enterprise repos found."
fi
echo

echo "[10] apt update"
apt update
echo

echo "[11] apt policy summary"
apt policy | sed -n '1,160p'
echo

echo "[12] Run pve8to9 --full"
if ! command -v pve8to9 >/dev/null 2>&1; then
  echo "ERROR: pve8to9 not found."
  echo "Update this host to latest Proxmox VE 8.4 first."
  exit 1
fi

set +e
pve8to9 --full
PVE_CHECK_EXIT=$?
set -e

echo
echo "pve8to9 exit code: $PVE_CHECK_EXIT"
echo

echo "Review the pve8to9 output above."
echo "Continue only if FAILURES: 0, or you accept the risk."
read -rp "Continue to Ceph checks? [y/N]: " CONTINUE_AFTER_CHECK
CONTINUE_AFTER_CHECK="${CONTINUE_AFTER_CHECK:-N}"

if [[ ! "$CONTINUE_AFTER_CHECK" =~ ^[Yy]$ ]]; then
  echo "Stopped before upgrade."
  echo "Log saved to: $LOG_FILE"
  exit 0
fi

echo
echo "[13] Ceph check"
if command -v ceph >/dev/null 2>&1; then
  ceph -s || true
  echo
  read -rp "If this host uses Ceph, set 'noout' now? [y/N]: " SET_NOOUT
  SET_NOOUT="${SET_NOOUT:-N}"

  if [[ "$SET_NOOUT" =~ ^[Yy]$ ]]; then
    ceph osd set noout
    echo "Set Ceph noout."
  else
    echo "Skipped Ceph noout."
  fi
else
  echo "Ceph command not found. Skipping Ceph check."
fi
echo

echo "[14] Final upgrade confirmation"
echo "Before continuing, confirm:"
echo "1. You have valid VM/CT backups."
echo "2. pve8to9 showed FAILURES: 0, or you accept the risk."
echo "3. You are inside tmux, console, IPMI, or physical access."
echo "4. You understand this will upgrade the host packages."
echo
read -rp "Run apt dist-upgrade now? [y/N]: " RUN_UPGRADE
RUN_UPGRADE="${RUN_UPGRADE:-N}"

if [[ ! "$RUN_UPGRADE" =~ ^[Yy]$ ]]; then
  echo "Stopped before apt dist-upgrade."
  echo
  echo "When ready, run:"
  echo "APT_LISTCHANGES_FRONTEND=none apt dist-upgrade"
  echo
  echo "Log saved to: $LOG_FILE"
  exit 0
fi

echo
echo "[15] Running apt dist-upgrade"
echo
echo "Manual prompt guidance:"
echo "/etc/lvm/lvm.conf       choose Y"
echo "/etc/default/grub       choose N unless you know you want the new file"
echo "/etc/ssh/sshd_config    choose Y if SSH is default, choose D first if unsure"
echo "/etc/issue              choose N"
echo "/etc/chrony/chrony.conf choose Y if NTP is default"
echo
read -rp "Press Enter to start apt dist-upgrade..."

export APT_LISTCHANGES_FRONTEND=none
apt dist-upgrade

echo
echo "[16] Post-upgrade checker"
pve8to9 --full || true
echo

echo "[17] Current version after package upgrade"
pveversion || true
uname -r || true
echo

echo "============================================================"
echo " Package upgrade phase complete."
echo " Reboot is required."
echo " Log saved to: $LOG_FILE"
echo "============================================================"
echo

read -rp "Reboot now? [y/N]: " REBOOT_NOW
REBOOT_NOW="${REBOOT_NOW:-N}"

if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
  reboot
else
  echo
  echo "Reboot manually when ready:"
  echo "reboot"
fi
