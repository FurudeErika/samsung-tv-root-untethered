#!/bin/sh
# tvroot module: ad-telemetry-daemons-off
# Masks and stops Samsung's ad/telemetry daemons at every boot.
#
# Why mask --runtime: the units live on the read-only root image with
# Restart=always, and /run/systemd/system is tmpfs, so a plain stop just
# respawns and a persistent mask has nowhere to live. The boot-time module
# runner re-applies this every boot, right after the root chain lands —
# the daemons get ~60-90s of life per power cycle and nothing else.
#
# 1.1.0 — list rebuilt from the live image on QN65S90FAGXZB / T-RSMFUABC-0090
# (2026-11-25). What changed and why:
# - contents-ui-detector-service: After=contents-recognition-service, DB
#   samsung.tv.nvision-analysis-dbmgr. It is the sensor that feeds the
#   recogniser, so masking the recogniser alone left screen analysis running.
# - contents-cognition-service-manager: D-Bus samsung.tizen.CCSMServer, DB
#   samsung.tv.contents-cognition-dbmgr, Restart=always — the supervisor of the
#   contents-analysis stack, i.e. the thing that can re-arm it.
# - COMPANIONS: the trigger units. pisa and both context-aware units are
#   started by .path watchers (active), and pisa is socket-activated as well.
#   Masking a service while its watcher stays live converts a clean disable
#   into activation failures in the boot log.
# - stops are queued with --no-block, the reason documented in
#   samsung-telemetry-off: a blocking stop on a still-activating unit held the
#   boot agent's sdb session for minutes. (1.0.2 dodged the hang by running
#   the stops in parallel, which raced daemon-reload against the mask instead.)
# Neither new service carries a vendor opt-out switch (no negated
# ConditionPathExists in its unit file), so mask is the only lever there.
#
# Disabled state: touch <module dir>/disabled
# Undo (run once as root, ALL of it): systemctl unmask <u> && systemctl daemon-reload && systemctl start <u>
# Measured 2026-11-26 on QN65S90FAGXZB/T-RSMFUABC-0090: deleting the /run/systemd/system/<u> symlink
# (or `unmask`) leaves `systemctl start` answering "Unit <u> is masked" until daemon-reload runs — the
# masked state is cached in systemd's memory, not re-derived from /run. Both steps are required.
# Caution measured the same night: `systemctl stop` on a Restart=always unit plus daemon-reload is slow
# enough that combining them with anything else in one root command crossed the CLI's 45 s window and left
# sdbd refusing until a mains power cycle. If the set is merely in the masked state you want anyway, the
# cheap undo is a power cycle - this script re-masks at boot, so no manual step is needed at all.
# Scope note: contents-recognition-service and contents-ui-detector-service were unmasked and started once
# to test whether their retained frame could be read for a Home Assistant camera. They do not produce one on
# this firmware (the CaptureManager singleton stays NULL even while video plays), so they stay masked here
# and are deliberately NOT excluded from UNITS.
#
# 1.2.0 — two units leave the list on a measured finding, not a hunch:
# slive-provider-daemon (Type=dbus, BusName=com.samsung.FCCallListener) and
# com.samsung.tv.context-aware-service (Type=dbus,
# BusName=org.tizen.tv.contextaware2). Masking a unit that OWNS a bus name is
# not the same as masking a plain daemon: callers block waiting for a name owner
# that can never appear. That is how masking data-service (org.tizen.tv.logger)
# put a 2-3 s dead zone behind every remote key press on this set, and masking
# the busname unit alongside it does not shorten the wait - it makes it
# permanent. These are the only two name owners here; everything else in UNITS is
# Type=simple with no BusName, verified with systemctl show -p Type -p BusName.
# Same audit is the leading suspect for the standby wedge that forced the 1.2.0
# extension of samsung-telemetry-off to be reverted (both of them were in that
# arm).
# Vendor opt-out switches (negated ConditionPathExists in the unit files):
# touching the matching path under /opt/usr/share/systemd/system keeps the
# unit from starting at all — persistent, no mask needed, trivially reverted
# by deleting the file. Masks are still applied as belt-and-braces (they
# also block manual/dbus starts).
OPTOUT=/opt/usr/share/systemd/system
mkdir -p $OPTOUT 2>/dev/null
for o in pisa-service canalysis-daemon \
         com.samsung.tv.context-aware-agent; do
    touch $OPTOUT/$o 2>/dev/null
done

# Heal a boot where 1.1.0 masked the two name owners: undo the masks and their
# opt-out switches, reload, start them. The runtime masks are tmpfs so a cold
# boot is already clean, but the manager can re-apply this module without one.
for u in slive-provider-daemon.service com.samsung.FCCallListener.busname \
         com.samsung.tv.context-aware-service.service \
         com.samsung.tv.context-aware-service.path; do
    systemctl unmask --runtime "$u" >/dev/null 2>&1
done
rm -f $OPTOUT/slive-provider-daemon $OPTOUT/com.samsung.tv.context-aware-service 2>/dev/null
systemctl daemon-reload >/dev/null 2>&1
for u in slive-provider-daemon com.samsung.tv.context-aware-service; do
    systemctl start --no-block "$u.service" >/dev/null 2>&1
done

# NOTE (1.2.0): slive-provider-daemon and com.samsung.tv.context-aware-service
# are deliberately absent - both own a D-Bus name the UI can call. See header.
UNITS="
adagent-service
pisa-service
canalysis-service
contents-recognition-service
contents-ui-detector-service
contents-cognition-service-manager
com.samsung.tv.context-aware-agent
com.samsung.tv.cis-api-service-app
"
# Activation triggers for the services above, same treatment.
COMPANIONS="
pisa-service.socket
pisa-service.path
com.samsung.tv.context-aware-agent.path
"
# 1.2.0 dropped two companions together with their services:
# com.samsung.FCCallListener.busname (slive-provider-daemon's activation unit)
# and com.samsung.tv.context-aware-service.path. Killing the activation unit of a
# name owner does not turn client calls into fast failures, it makes them wait
# forever, because nothing is ever allowed to own the name again.
for u in $UNITS $COMPANIONS; do
    systemctl mask --runtime "$u" >/dev/null 2>&1
    systemctl stop --no-block "$u" >/dev/null 2>&1
done
for u in $UNITS; do
    printf '%s -> %s\n' "$u" "$(systemctl is-active "$u.service" 2>&1)"
done
# Last, not inline: samsung-telemetry-off's sweep SIGKills adagent and pisa,
# which systemd records as failed. Clearing it here keeps --failed meaningful.
for u in $UNITS $COMPANIONS; do
    systemctl reset-failed "$u" >/dev/null 2>&1
done
exit 0
