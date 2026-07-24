#!/bin/bash
###############################################################################
# WRN Combined Maintenance Script
#
# Combines:
#   - OS drive space cleanup     (was wrnOSspacefixfinal.sh)
#   - Storage drive fstab/UUID fix (was newfstab_update.sh)
#
# References:
#   https://support.hanwhavision.com/hc/en-001/articles/47257219141651-WRN-How-do-I-prevent-the-OS-drive-on-my-WRN-from-filling-to-capacity
#   https://support.hanwhavision.com/hc/en-001/articles/47257194830611-How-to-Prevent-Storage-Drives-from-Unmounting-on-WRN-1632-S-and-WRN-816S
#
# Run from a Cockpit terminal as root, e.g.:
#   curl -fsSL <URL>/wrn_maintenance.sh | sudo bash
# or
#   sudo bash -c "$(curl -fsSL <URL>/wrn_maintenance.sh)"
#
# Why this script self-detaches:
#   The fstab section restarts hanwha-mediaserver (the Wave service that
#   proxies the Cockpit web terminal). A normal foreground run would die
#   together with the Cockpit terminal when that restart happens.
#   This bootstrap writes a worker to /usr/local/sbin/ and launches it in
#   a new session via setsid + nohup with stdio redirected away from the
#   terminal, so the worker keeps running after disconnect. Reconnect and
#   tail the log file to see progress.
###############################################################################

set -u

# --- Must be root -----------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "Error: must run as root. Try:" >&2
    echo "    curl -fsSL <URL>/wrn_maintenance.sh | sudo bash" >&2
    exit 1
fi

WORKER="/usr/local/sbin/wrn_maintenance_worker.sh"
LOG_DIR="/var/log/wrn-maintenance"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/run_$(date +%Y%m%d_%H%M%S).log"
ln -sf "$LOG" "$LOG_DIR/latest.log"

# --- Emit the worker script to disk -----------------------------------------
# Quoted heredoc delimiter: nothing inside expands at write-time; the worker
# is preserved verbatim and expanded only when the worker shell runs it.
cat > "$WORKER" <<'WRN_WORKER_EOF'
#!/bin/bash
###############################################################################
# wrn_maintenance_worker.sh — actual work; runs detached from the terminal.
###############################################################################

# Reattach stdio to the log file in case the parent's redirection was lost.
exec </dev/null
exec >>"${WRN_LOG_FILE:-/var/log/wrn-maintenance/latest.log}" 2>&1

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(ts)" "$*"; }

log "===== WRN maintenance worker starting (PID $$) ====="

###############################################################################
# SECTION 1 — OS DRIVE SPACE CLEANUP
# (logs / journal / snaps / unused desktop packages)
###############################################################################
log "--- Section 1: OS drive cleanup ---"

# Reset and define logrotate config for rsyslog.
log "Configuring /etc/logrotate.d/rsyslog"
if [ ! -f /etc/logrotate.d/rsyslog ]; then
    touch /etc/logrotate.d/rsyslog
fi
chown root:root /etc/logrotate.d/rsyslog 2>/dev/null
truncate -s 0 /etc/logrotate.d/rsyslog
tee /etc/logrotate.d/rsyslog > /dev/null <<'EOL'
su root syslog
/var/log/kern.log
/var/log/syslog
{
    rotate 2
    daily
    size 350M
    missingok
    notifempty
    delaycompress
    compress
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
EOL

# Add a hard size cap on syslog via an rsyslog $outchannel.
log "Configuring rsyslog 50-default.conf size cap"
if ! grep -q '\$outchannel mysyslog,/var/log/syslog,367001600' /etc/rsyslog.d/50-default.conf 2>/dev/null; then
    sed -i '/\*\.\*;auth,authpriv\.none/i \$outchannel mysyslog,/var/log/syslog,367001600' /etc/rsyslog.d/50-default.conf
fi
sed -i "s/\*\.\*;auth,authpriv\.none\s*\-\/var\/log\/syslog/\*\.\*;auth,authpriv\.none          :omfile:\$mysyslog/" /etc/rsyslog.d/50-default.conf

chown -R root:root /etc 2>/dev/null

log "Removing existing /var/log/syslog* and restarting rsyslog"
rm -f /var/log/syslog*
systemctl restart rsyslog.service &
logrotate -f /etc/logrotate.conf       > /dev/null 2>&1
logrotate -d /etc/logrotate.d/rsyslog  > /dev/null 2>&1

###############################################################################
# AUTH.LOG ROTATION AND INITIAL CLEANUP
###############################################################################

log "Configuring separate auth.log rotation policy"

tee /etc/logrotate.d/auth-log-cap > /dev/null <<'AUTH_LOGROTATE_EOF'
/var/log/auth.log {
    su root syslog
    size 50M
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    create 0640 syslog adm
    sharedscripts
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
AUTH_LOGROTATE_EOF

chown root:root /etc/logrotate.d/auth-log-cap
chmod 0644 /etc/logrotate.d/auth-log-cap

log "Forcing initial auth.log rotation"

if logrotate -v -f /etc/logrotate.d/auth-log-cap; then
    log "Initial auth.log rotation completed"
    rm -f -- /var/log/auth.log.[0-9]*
    log "Existing rotated auth.log history removed"
else
    log "WARNING: auth.log rotation failed; rotated history was not removed"
fi

# Journald: vacuum and tighten retention.
log "Vacuuming journald and tightening journald.conf"
journalctl --vacuum-size=100M  > /dev/null 2>&1
journalctl --vacuum-files=5    > /dev/null 2>&1
sed -i \
  -e 's/^#\?SystemMaxUse=.*/SystemMaxUse=100M/' \
  -e 's/^#\?SystemKeepFree=.*/SystemKeepFree=50M/' \
  -e 's/^#\?SystemMaxFileSize=.*/SystemMaxFileSize=50M/' \
  -e 's/^#\?SystemMaxFiles=.*/SystemMaxFiles=5/' \
  /etc/systemd/journald.conf
systemctl restart systemd-journald &

# Snap: keep only the last two revisions, drop disabled ones.
log "Setting snap retain=2 and removing disabled snap revisions"
snap set system refresh.retain=2 > /dev/null 2>&1 || true
sh -c 'rm -rf /var/lib/snapd/cache/*' > /dev/null 2>&1 || true
LANG=C snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
    [ -n "$snapname" ] && snap remove "$snapname" --revision="$revision" > /dev/null 2>&1
done

# Purge bulky packages a WRN appliance does not need.
log "Purging libreoffice/thunderbird/valgrind packages and apt cleaning"
apt purge --auto-remove libreoffice* -y > /dev/null 2>&1 || true
apt purge --auto-remove thunderbird*  -y > /dev/null 2>&1 || true
apt purge --auto-remove valgrind*     -y > /dev/null 2>&1 || true
apt clean -y                              > /dev/null 2>&1 || true

# Uninstall Firefox if present (snap or apt).
log "Checking for and removing Firefox (snap and apt)"
if command -v snap &>/dev/null && snap list firefox &>/dev/null 2>&1; then
    log "  -> removing Firefox snap"
    snap remove firefox > /dev/null 2>&1 || true
fi
if dpkg-query -W -f='${Status}' firefox 2>/dev/null | grep -q "ok installed"; then
    log "  -> removing Firefox apt package"
    apt purge --auto-remove firefox firefox-locale-en -y > /dev/null 2>&1 || true
fi
if [ -f /usr/bin/firefox ] || [ -f /usr/local/bin/firefox ]; then
    log "  -> removing stale firefox binaries"
    rm -f /usr/bin/firefox /usr/local/bin/firefox 2>/dev/null || true
fi
# Also try matching any leftover firefox-* dpkg packages.
dpkg -l 2>/dev/null | awk '/^ii  firefox/{print $2}' | while read -r pkg; do
    log "  -> purging leftover package: $pkg"
    apt purge --auto-remove "$pkg" -y > /dev/null 2>&1 || true
done

# Install localepurge and strip all locales except en_US.
log "Installing localepurge and removing non-en_US locales"
printf '%s\n' \
    'localepurge localepurge/use-dpkg-feature boolean false' \
    'localepurge localepurge/nopurge string en_US en_US.UTF-8' \
    'localepurge localepurge/quickndirty boolean false' \
    'localepurge localepurge/showfreedspace boolean false' \
    'localepurge localepurge/dontbothermewithapologies boolean true' \
    | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get install -y localepurge > /dev/null 2>&1 || true
printf 'en_US\nen_US.UTF-8\n' > /etc/locale.nopurge
localepurge > /dev/null 2>&1 || true

# Remove old Wave client versions, keep only the highest semver.
WAVE_CLIENT_DIR="/home/wave/.local/share/Hanwha/client/hanwha"
log "Pruning old Wave client versions under $WAVE_CLIENT_DIR"
if [ -d "$WAVE_CLIENT_DIR" ]; then
    # Collect entries that look like version dirs: digits-and-dots only.
    mapfile -t WAVE_VERSIONS < <(
        find "$WAVE_CLIENT_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
        | grep -E '^[0-9]+(\.[0-9]+)*$' \
        | sort -V
    )
    if [ "${#WAVE_VERSIONS[@]}" -le 1 ]; then
        log "  -> ${#WAVE_VERSIONS[@]} version(s) present; nothing to prune"
    else
        KEEP="${WAVE_VERSIONS[-1]}"
        log "  -> keeping highest version: $KEEP"
        for v in "${WAVE_VERSIONS[@]}"; do
            if [ "$v" != "$KEEP" ]; then
                log "  -> removing old version: $v"
                rm -rf -- "${WAVE_CLIENT_DIR:?}/${v}"
            fi
        done
    fi
else
    log "  -> $WAVE_CLIENT_DIR not present; skipping"
fi

# Wait for the backgrounded service restarts above.
wait
log "Section 1 complete"

###############################################################################
# SECTION 2 — STORAGE DRIVE FSTAB / UUID FIX
# (replaces /dev/sd* with UUID=, adds nofail + device-timeout, sets pass=2)
###############################################################################
log "--- Section 2: storage drive fstab/UUID fix ---"

log "Stopping hanwha-mediaserver (Wave) — Cockpit may disconnect here"
systemctl stop hanwha-mediaserver 2>&1 | sed 's/^/    /'

log "Running mount -a once to refresh existing mounts"
mount -a 2>&1 | sed 's/^/    /' || true

FSTAB_FILE="/etc/fstab"
BACKUP_FILE="${FSTAB_FILE}.$(date +%Y%m%d_%H%M%S).bak"
TARGET_DEVICES=("/dev/sda" "/dev/sdb" "/dev/sdc" "/dev/sdd")
TARGET_MOUNT_POINTS=("/mnt/sda" "/mnt/sdb" "/mnt/sdc" "/mnt/sdd")

log "Backing up $FSTAB_FILE -> $BACKUP_FILE"
cp "$FSTAB_FILE" "$BACKUP_FILE"

ROOT_DEVICE_KNAME=$(lsblk -no KNAME "$(findmnt -n / -o SOURCE)" | head -n 1)
BOOT_DEV_PARENT="/dev/${ROOT_DEVICE_KNAME%[0-9]*}"
if [ -z "$BOOT_DEV_PARENT" ]; then
    log "ERROR: could not determine boot device parent; aborting Section 2"
else
    log "Boot device parent: $BOOT_DEV_PARENT"

    for i in "${!TARGET_DEVICES[@]}"; do
        DEV_PATH="${TARGET_DEVICES[$i]}"
        MOUNT_POINT="${TARGET_MOUNT_POINTS[$i]}"
        log "Processing $DEV_PATH (mount $MOUNT_POINT)"

        if [ "$DEV_PATH" = "$BOOT_DEV_PARENT" ]; then
            log "  -> matches boot device parent; skipping for safety"
            continue
        fi
        if [ ! -b "$DEV_PATH" ]; then
            log "  -> device file not present; skipping"
            continue
        fi

        DEV_INFO=$(blkid -c /dev/null -o export "$DEV_PATH" 2>/dev/null)
        if [ -z "$DEV_INFO" ] || [[ "$DEV_INFO" != *UUID=* ]]; then
            log "  -> blkid returned no UUID (unformatted?); skipping"
            continue
        fi

        unset UUID FSTYPE
        eval "$DEV_INFO"
        if [ -z "${UUID:-}" ]; then
            log "  -> UUID not set after eval; skipping"
            continue
        fi

        NEW_IDENTIFIER="UUID=${UUID}"
        log "  -> rewriting identifier to $NEW_IDENTIFIER"

        # Replace the first column on the matching mount-point row with the UUID.
        TEMP_FSTAB=$(mktemp)
        awk -v mp="$MOUNT_POINT" -v id="$NEW_IDENTIFIER" '
            $2 == mp && $0 !~ /^#/ { $1 = id; print $0 }
            $2 != mp || $0 ~ /^#/  { print $0 }
        ' "$FSTAB_FILE" > "$TEMP_FSTAB"
        mv "$TEMP_FSTAB" "$FSTAB_FILE"

        # Force options column 4 and dump/pass columns 5 6 on this row.
        mp_re=$(printf '%s' "$MOUNT_POINT" | sed -e 's/[][\/.^$*+?(){}|]/\\&/g')
        sed -i -E "/[[:space:]]+${mp_re}[[:space:]]/ {
            s/^(([^[:space:]]+[[:space:]]+){3})[^[:space:]]+/\1defaults,nofail,x-systemd.device-timeout=60s/
        }" "$FSTAB_FILE"
        sed -i -E "/[[:space:]]+${mp_re}[[:space:]]/ {
            s/^(([^[:space:]]+[[:space:]]+){3}[^[:space:]]+)[[:space:]].*/\1 0 2/
        }" "$FSTAB_FILE"

        log "  -> options + dump/pass updated"
    done

    log "systemctl daemon-reload"
    systemctl daemon-reload

    log "Final mount -a"
    if mount -a 2>&1 | sed 's/^/    /'; then
        log "mount -a OK (warnings are expected if fewer than 4 HDDs are connected)"
    else
        log "mount -a returned non-zero — review above; original fstab backed up at $BACKUP_FILE"
    fi
fi

log "Starting hanwha-mediaserver"
systemctl start hanwha-mediaserver 2>&1 | sed 's/^/    /'

log "Section 2 complete"

log "===== WRN maintenance worker finished at $(date) ====="
WRN_WORKER_EOF

chmod 0755 "$WORKER"

# --- Launch the worker fully detached from the calling terminal -------------
echo
echo "WRN maintenance: launching detached worker"
echo "  Worker:  $WORKER"
echo "  Log:     $LOG"
echo "  Live:    sudo tail -f $LOG_DIR/latest.log"
echo

# setsid -> new session (no controlling TTY)
# nohup  -> SIGHUP ignored
# </dev/null + >>LOG 2>&1 -> stdio off the terminal
# &      -> background
# disown -> detach from this shell's job table
WRN_LOG_FILE="$LOG" setsid nohup "$WORKER" </dev/null >>"$LOG" 2>&1 &
PID=$!
disown "$PID" 2>/dev/null || true

echo "  PID:     $PID"
echo
echo "The worker continues running even if Cockpit/SSH disconnects when"
echo "hanwha-mediaserver (Wave) restarts. Reconnect and tail the log above"
echo "to follow progress, or run:  ps -p $PID"
exit 0
