# Reboot-safe USB serial passthrough for HAOS

Verified on the Radxa Dragon Q8B + HAOS KVM installation on 2026-09-12.

## Problem

The installation uses two Silicon Labs CP2102N USB serial adapters:

- Z-Wave
- RFXCOM

Both expose the same USB VID:PID:

```text
10c4:ea60
```

A normal persistent libvirt rule based only on VID:PID is therefore ambiguous. Matching by host USB `bus/device` is also not reboot-safe because the Linux USB device number changes after reconnects and host reboots.

The two adapters do, however, have different USB serial numbers. The verified solution is to identify each adapter by its serial number on the Debian host, discover its current `busnum` and `devnum`, and attach that exact USB device to the running HAOS VM.

## Design

```text
CP2102N Z-Wave serial
        |
        +-- scan /sys/bus/usb/devices/*/serial
        |
        +-- read current busnum/devnum
        |
        +-- verify VID:PID = 10c4:ea60
        |
        +-- virsh attach-device --live
        |
        `--> HAOS

CP2102N RFXCOM serial
        |
        `--> same process
```

The attach check is run by a systemd timer every 30 seconds. This makes the setup self-recovering after:

- host reboot
- HAOS VM restart
- unplug/replug of either CP2102N adapter
- changed Linux USB device numbers

The onboard Bluetooth adapter is different: it has unique VID:PID `13d3:3570`, so it remains a normal persistent libvirt USB hostdev.

## Repository files

The reusable implementation is stored in:

```text
scripts/haos-usb-serial-attach.sh
systemd/haos-usb-attach.service
systemd/haos-usb-attach.timer
examples/haos-usb-attach.default
```

The repository version intentionally keeps the actual adapter serial numbers out of Git. Put the locally discovered serials in `/etc/default/haos-usb-attach`.

## Discover the serial numbers

With both adapters temporarily available to the Debian host:

```bash
ls -l /dev/serial/by-id/
```

or inspect sysfs directly:

```bash
for d in /sys/bus/usb/devices/*; do
    [ -f "$d/serial" ] || continue
    [ -f "$d/idVendor" ] || continue
    [ -f "$d/idProduct" ] || continue

    if [ "$(cat "$d/idVendor")" = "10c4" ] && \
       [ "$(cat "$d/idProduct")" = "ea60" ]; then
        echo "DEVICE: $(basename "$d")"
        echo "SERIAL: $(cat "$d/serial")"
        echo "BUS:    $(cat "$d/busnum")"
        echo "DEVNUM: $(cat "$d/devnum")"
        echo "DEVPATH:$(cat "$d/devpath")"
        echo
    fi
done
```

Identify which serial belongs to Z-Wave and which belongs to RFXCOM before enabling the service.

## Install

From the repository checkout:

```bash
sudo install -m 0755 \
  scripts/haos-usb-serial-attach.sh \
  /usr/local/sbin/haos-usb-serial-attach.sh

sudo install -m 0644 \
  systemd/haos-usb-attach.service \
  /etc/systemd/system/haos-usb-attach.service

sudo install -m 0644 \
  systemd/haos-usb-attach.timer \
  /etc/systemd/system/haos-usb-attach.timer

sudo install -m 0600 \
  examples/haos-usb-attach.default \
  /etc/default/haos-usb-attach
```

Edit the local configuration:

```bash
sudoedit /etc/default/haos-usb-attach
```

Set:

```text
VM=haos
URI=qemu:///system
ZWAVE_SERIAL=<unique Z-Wave CP2102N serial>
RFXCOM_SERIAL=<unique RFXCOM CP2102N serial>
```

Then enable the timer:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now haos-usb-attach.timer
```

## Why only `--live` is used for the two CP2102N devices

The persistent HAOS libvirt XML must not contain static entries for the CP2102N adapters by dynamic host `device` number. Only the unique Bluetooth device stays persistent.

The timer discovers the current CP2102N host address and performs:

```bash
virsh -c qemu:///system attach-device haos <generated.xml> --live
```

The generated XML has the current host address:

```xml
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <address bus='3' device='CURRENT_DEVICE_NUMBER'/>
  </source>
</hostdev>
```

Because this is generated from the serial number every time, the current device number does not need to remain stable.

## Bluetooth

The tested Q8B Bluetooth radio is:

```text
13d3:3570 IMC Networks Bluetooth Radio
```

It can be stored directly in the persistent HAOS libvirt XML:

```xml
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source startupPolicy='optional'>
    <vendor id='0x13d3'/>
    <product id='0x3570'/>
  </source>
</hostdev>
```

When HAOS owns it, `bluetoothctl list` on the Debian host is expected to show no controller.

## Validation before reboot

Check script syntax:

```bash
sudo bash -n /usr/local/sbin/haos-usb-serial-attach.sh
```

Run it manually:

```bash
sudo /usr/local/sbin/haos-usb-serial-attach.sh
```

Check the service:

```bash
sudo systemctl restart haos-usb-attach.service
sudo systemctl status haos-usb-attach.service --no-pager
sudo journalctl -u haos-usb-attach.service --no-pager -n 50
```

A successful oneshot service is normally `inactive (dead)` after completion with `status=0/SUCCESS`.

Check the timer:

```bash
systemctl is-enabled haos-usb-attach.timer
systemctl is-active haos-usb-attach.timer
systemctl list-timers haos-usb-attach.timer --no-pager
```

Expected:

```text
enabled
active
```

## Verified reconnect behavior

The solution was tested by live-detaching the RFXCOM adapter. It returned to the Debian host and its USB device number changed from `3/8` to `3/9`.

The service then logged:

```text
RFXCOM: attaching ... from USB 3/9 (3-2)
RFXCOM: attach successful
```

The same detach/reattach test succeeded for the Z-Wave adapter.

This proves that the attach logic follows the unique serial number rather than a stale Linux `device` number.

## Verified full host reboot

A complete Q8B reboot was then performed.

After the reboot the two adapters had changed again:

```text
Z-Wave  -> USB 3/2
RFXCOM  -> USB 3/3
```

The timer attached both automatically:

```text
Z-Wave: attaching ... from USB 3/2 (3-1)
Z-Wave: attach successful
RFXCOM: attaching ... from USB 3/3 (3-2)
RFXCOM: attach successful
```

The live HAOS VM XML then contained Bluetooth plus both dynamically attached CP2102N devices. The Debian host had no `/dev/ttyUSB*` nodes and no Bluetooth controller because HAOS owned all three devices.

## Home Assistant serial paths

Inside HAOS/Home Assistant, integrations should use `/dev/serial/by-id/...` rather than `/dev/ttyUSB0` or another numbered TTY path.

The serial-number-based path remains tied to the actual adapter even if the Linux host USB device number changes.

## Useful diagnostics

Current live USB devices attached to HAOS:

```bash
sudo virsh dumpxml haos | \
sed -n "/<hostdev mode='subsystem' type='usb'/,/<\/hostdev>/p"
```

Persistent USB configuration:

```bash
sudo virsh dumpxml haos --inactive | \
sed -n "/<hostdev mode='subsystem' type='usb'/,/<\/hostdev>/p"
```

Current service log for this boot:

```bash
sudo journalctl -b -u haos-usb-attach.service --no-pager -l
```

Host serial devices should normally be absent while HAOS owns both adapters:

```bash
ls -l /dev/serial/by-id/ 2>/dev/null || true
ls -l /dev/ttyUSB* 2>/dev/null || true
```

## Result

This serial-number-driven approach is the verified solution for reboot-safe passthrough of two otherwise indistinguishable `10c4:ea60` CP2102N adapters to the HAOS KVM guest on the Radxa Dragon Q8B.
