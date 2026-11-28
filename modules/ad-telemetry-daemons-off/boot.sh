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
# 1.3.0 — those two come back under suppression, in the one form the measurement
# permits: vendor opt-out file plus `systemctl stop`, never a mask. Both units
# carry the gate on this image (systemctl cat, 2026-11-28):
#   slive-provider-daemon.service          ConditionPathExists=!$OPTOUT/slive-provider-daemon
#     Type=dbus BusName=com.samsung.FCCallListener
#   com.samsung.tv.context-aware-service   ConditionPathExists=!$OPTOUT/com.samsung.tv.context-aware-service
#     Type=dbus BusName=org.tizen.tv.contextaware2
# so the file keeps them from starting at all, and a stopped-but-unmasked name
# owner costs the input path nothing: two press rounds on this set — stop
# slive-provider-daemon, then stop com.samsung.tv.context-aware-service, with no
# mask applied either time — were both judged instant, where masking them was
# sluggish. data-service is NOT expressible this way and must never be added:
# `systemctl cat data-service.service` shows no ConditionPathExists at all, so
# anything that asks for org.tizen.tv.logger starts it again, and the only lever
# that would hold it down is the mask that caused the dead zone.
#
# Vendor opt-out switches for the plain daemons use the same negated
# ConditionPathExists; touching the matching path keeps a unit from starting at
# all, persists across boots, and is reverted by deleting the file. Masks remain on
# the Type=simple units, where they also block manual and D-Bus starts; for the two
# name owners above a mask is never applied.
OPTOUT=/opt/usr/share/systemd/system
mkdir -p $OPTOUT 2>/dev/null

# Heal first, before any new state is written: a boot that ran 1.1.0 still has that
# release's runtime masks on the two name owners, and systemd caches masked state
# in memory rather than re-deriving it from /run — so unmask, then daemon-reload,
# and only then apply the gate. Skipping the reload leaves the gate evaluated
# against a unit systemd still refuses to look at.
for u in slive-provider-daemon.service com.samsung.FCCallListener.busname \
         com.samsung.tv.context-aware-service.service \
         com.samsung.tv.context-aware-service.path; do
    systemctl unmask --runtime "$u" >/dev/null 2>&1
done
systemctl daemon-reload >/dev/null 2>&1

for o in pisa-service canalysis-daemon \
         com.samsung.tv.context-aware-agent \
         slive-provider-daemon com.samsung.tv.context-aware-service; do
    touch $OPTOUT/$o 2>/dev/null
done

# NOTE: slive-provider-daemon and com.samsung.tv.context-aware-service stay out of
# UNITS. Gated and stopped, not masked — see 1.3.0 above.
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

# Stop the two gated name owners if this boot started them before the gate existed;
# the file only decides future starts. --no-block for the reason documented in
# samsung-telemetry-off: the module loop runs inside the boot agent's sdb session,
# whose CLI window is 45 s, and a blocking stop on a Restart=always unit that is
# still activating can hold it for minutes.
for u in slive-provider-daemon com.samsung.tv.context-aware-service; do
    systemctl stop --no-block "$u.service" >/dev/null 2>&1
    printf '%s -> active=%s load=%s gated=%s\n' "$u" \
        "$(systemctl is-active "$u.service" 2>&1 | head -1)" \
        "$(systemctl show "$u.service" -p LoadState --value 2>&1)" \
        "$([ -f "$OPTOUT/$u" ] && echo yes || echo no)"
done
for u in $UNITS; do
    printf '%s -> %s\n' "$u" "$(systemctl is-active "$u.service" 2>&1)"
done
# Last, not inline: samsung-telemetry-off's sweep SIGKills adagent and pisa,
# which systemd records as failed. Clearing it here keeps --failed meaningful.
for u in $UNITS $COMPANIONS slive-provider-daemon com.samsung.tv.context-aware-service; do
    systemctl reset-failed "$u" >/dev/null 2>&1
done
exit 0
