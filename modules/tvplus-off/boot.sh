#!/bin/sh
# tvroot module: tvplus-off
# Disables Samsung TV Plus (internal name "slive", Samsung Live) at every boot.
#
# Findings below come from the T-RSMFDEUC-0090 (S95F, Tizen 9) rootfs,
# 2026-11-21:
# - Settings > ... > "Autorun Samsung TV Plus" (settings-datafw item
#   auto-run-samsung-tvplus) is stored in the buxton/vconf key
#   db/menu/autorun_tv_plus, a bool that defaults to TRUE (etc/buxton2/system.db).
#   boot-helper-dyboost-tv reads it (getBootModeByFileFlag) to decide whether
#   the TV cold-boots into TV Plus. db/menu/autorun_tv_plus_state (firmware
#   default "hide", "enable" on a live S95F) only controls whether the menu
#   item is visible.
# - /opt/usr/apps/bstr_tvplus_mode is the boost-boot flag: fastboot
#   (fb_common.sh) starts tvs-daemon for TV Plus, and bms.path and
#   slive-provider-daemon.path fire on it. bms.path also watches
#   /tmp/tvplus_ready and /run/user/5001/bms_ready.
# - Backend: bms-service (the TV Plus player; tvs calls LaunchBMSDaemon) and
#   slive-provider-daemon (dbus com.samsung.FCCallListener; it fetches the
#   channel lineup), both from /opt/usr/apps/com.samsung.tv.slive-daemon.
#   Both units have Restart=always and vendor opt-out conditions:
#   bms.service has !/run/user/5001/bms_block and
#   !/opt/usr/share/systemd/system/bms; slive-provider-daemon.service has
#   !/opt/usr/share/systemd/system/slive-provider-daemon.
# - Standalone TV Plus app: HEPsqFNie0.tvplusstandalone
#   (db/tvplus/equivalent_appid_mapping maps it to org.tizen.tv-viewer).
#   On a live S95F the TV Plus UI is hosted by the home screen
#   (memory/tvplus/appid = com.samsung.tv.csfs), which is deliberately NOT
#   killed here; without bms-service it has nothing to play.
#
# Overlap: samsung-telemetry-off already masks bms. Repeating that here is
# idempotent and keeps this module correct on its own.
#
# 1.1.0 — slive-provider-daemon is neither masked nor killed any more. It is
# Type=dbus with BusName=com.samsung.FCCallListener, a bus-name owner, and
# masking a name owner leaves callers waiting for an owner that can never
# appear. That is the measured mechanism behind the 2-3 s remote-key dead zone
# produced by masking data-service / org.tizen.tv.logger (see
# samsung-telemetry-off 1.4.0; ad-telemetry-daemons-off 1.2.0 applies the same
# rule). TV Plus does not need slive down: the UI is hosted by the home screen
# and, as noted above, without bms-service it has nothing to play - so the
# setting (autorun_tv_plus), the boot flag and the player (bms-service) are what
# this module takes away, while the lineup fetcher idles. Whether slive can
# safely be suppressed after all is a separate open measurement, tracked in the
# Home Assistant repo's DISCOVERY.md; this module no longer depends on it.
# 1.2.0 — the open question in 1.1.0 closed, in the direction of more coverage:
# suppression by vendor opt-out file plus stop is safe on this set. Two press
# rounds (stop slive-provider-daemon, then stop com.samsung.tv.context-aware-service,
# no mask applied either time) were both judged instant, and the unit carries
# ConditionPathExists=!/opt/usr/share/systemd/system/slive-provider-daemon, so the
# lineup fetcher now stays down across boots. What is still forbidden is the mask: a
# masked name owner is the measured fault (2-3 s behind every key press), a stopped
# one is not. ad-telemetry-daemons-off 1.3.0 applies the identical method, so the two
# modules no longer disagree about whether slive is suppressed.
#
# Not touched: db/tvplus/support (a product capability flag; turning it off
# has unknown effects on tv-viewer and channel-list) and the TV Plus
# virtual channels that already exist in the channel DB. Delete those from
# Channel List > Edit if they still show up.
#
# Disabled state: touch <module dir>/disabled or toggle in the manager. The
# runner skips disabled modules, so revival needs a reboot (masks live in
# tmpfs). To restore autorun, turn the setting back on in the TV menu or run
# (as root): vconftool set -f -t bool db/menu/autorun_tv_plus 1
MODULE_DIR=${MODULE_DIR:-/opt/usr/share/selfroot/modules/tvplus-off}
EVIDENCE=${EVIDENCE:-/home/owner/share/tmp/sdk_tools/selfroot-evidence}
UI=/home/owner/share/tmp/sdk_tools/selfroot-ui/modules
UNITS="bms.service bms.path sliveutil_channeldump_eventd_activation.service"

if [ -s "$UI/disabled/tvplus-off" ] || { [ -f "$MODULE_DIR/disabled" ] && [ ! -s "$UI/enabled/tvplus-off" ]; }; then
    systemctl stop tvroot-tvplus.service >/dev/null 2>&1
    exit 0
fi

# 1. vendor setting: Autorun Samsung TV Plus -> Off.
vconftool set -f -t bool db/menu/autorun_tv_plus 0 >/dev/null 2>&1
printf 'autorun_tv_plus -> %s\n' "$(vconftool get db/menu/autorun_tv_plus 2>&1)"

# 2. boot-into-TV-Plus flag and the path-unit triggers.
rm -f /opt/usr/apps/bstr_tvplus_mode /tmp/tvplus_ready 2>/dev/null

# 3. vendor opt-out switches (persistent, via negated ConditionPathExists) +
#    the tmpfs bms block.
OPTOUT=/opt/usr/share/systemd/system
mkdir -p $OPTOUT 2>/dev/null
touch $OPTOUT/bms 2>/dev/null
# Heal what 1.0.x did to the name owner, then gate it the vendor way and stop it.
# Runtime masks are tmpfs so a cold boot is already clean, but systemd caches masked
# state in memory: unmask and daemon-reload are both required before the gate means
# anything, and no mask is ever re-applied (slive owns com.samsung.FCCallListener).
for u in slive-provider-daemon.service slive-provider-daemon.path \
         com.samsung.FCCallListener.busname; do
    systemctl unmask --runtime "$u" >/dev/null 2>&1
done
systemctl daemon-reload >/dev/null 2>&1
touch $OPTOUT/slive-provider-daemon 2>/dev/null
systemctl stop --no-block slive-provider-daemon.service >/dev/null 2>&1
mkdir -p /run/user/5001 2>/dev/null
touch /run/user/5001/bms_block 2>/dev/null

# 4. runtime masks (also block manual and dbus starts) + stop. --no-block:
#    the module loop runs inside the boot agent's sdb session, and a blocking
#    stop on a unit that is still activating can hold it for minutes.
for u in $UNITS; do
    systemctl mask --runtime "$u" >/dev/null 2>&1
    systemctl stop --no-block "$u" >/dev/null 2>&1
    systemctl reset-failed "$u" >/dev/null 2>&1
done
for u in bms slive-provider-daemon; do
    printf '%s -> active=%s load=%s gated=%s\n' "$u" \
        "$(systemctl is-active "$u.service" 2>&1 | head -1)" \
        "$(systemctl show "$u.service" -p LoadState --value 2>&1)" \
        "$([ -f "$OPTOUT/$u" ] && echo yes || echo no)"
done

# 5. kill sweep. Collect PIDs first, then skip $$, PID 1 and the launchpad
#    pool (same self-exclusion rule as samsung-telemetry-off).
# slive-provider-daemon: gated and stopped in step 3, not killed.
PATTERNS="tvplusstandalone|bms-service|slive-util"
POOL=$(ps -ef | grep "launchpad-process-pool" | grep -v grep | tr -s " " | cut -d" " -f2 | head -1)
PIDS=$(ps -ef | grep -E "$PATTERNS" | grep -v grep | tr -s " " | cut -d" " -f2)
for pid in $PIDS; do
    if [ "$pid" != "$$" ] && [ "$pid" != "1" ] && [ "$pid" != "$POOL" ]; then
        cmd=$(tr '\0' ' ' </proc/$pid/cmdline 2>/dev/null | cut -c1-60)
        kill -9 "$pid" >/dev/null 2>&1 && echo "killed $pid $cmd"
    fi
done

# 6. supervised watchdog. The app is demand-launched and the setting could be
#    flipped back, so a 30s loop owned by systemd (unit in tmpfs, rewritten
#    each boot) re-applies 1, 2 and 5. The unit runs it via cat|bash for UEP.
WD=$MODULE_DIR/watchdog.sh
RD=/run/systemd/system
cat > $RD/tvroot-tvplus.service <<EOF
[Unit]
Description=TVRoot Samsung TV Plus watchdog
DefaultDependencies=false
[Service]
Type=simple
ExecStart=/bin/sh -c 'cat $WD | MODULE_DIR=$MODULE_DIR EVIDENCE=$EVIDENCE bash'
Restart=always
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=3
EOF
systemctl daemon-reload 2>/dev/null
systemctl restart tvroot-tvplus.service 2>/dev/null
systemctl is-active tvroot-tvplus.service 2>&1
exit 0
