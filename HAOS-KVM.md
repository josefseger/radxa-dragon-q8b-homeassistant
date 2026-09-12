# Home Assistant OS on KVM — verified deployment

Verified on Radxa Dragon Q8B on 2026-09-12.

## Final VM configuration

- Home Assistant OS 18.2, Generic AArch64 QCOW2
- KVM / libvirt on Debian 13
- 6 vCPU
- 8 GiB RAM
- 512 GiB sparse QCOW2
- AArch64 `virt` machine
- UEFI via AAVMF, Secure Boot disabled
- VirtIO SCSI disk
- VirtIO NIC attached to Linux bridge `br0`
- libvirt autostart enabled

## HAOS image

Image:

```text
haos_generic-aarch64-18.2.qcow2.xz
```

Verified SHA-256:

```text
2c3e1822a4d83498980708d45573da1b74bc25c0643510bf29937a1bf70b1134
```

Download and verify:

```bash
cd /tmp
curl -4 -L --fail --progress-bar \
  -o haos_generic-aarch64-18.2.qcow2.xz \
  https://github.com/home-assistant/operating-system/releases/download/18.2/haos_generic-aarch64-18.2.qcow2.xz
sha256sum haos_generic-aarch64-18.2.qcow2.xz
```

Install the image:

```bash
unxz haos_generic-aarch64-18.2.qcow2.xz
sudo mv haos_generic-aarch64-18.2.qcow2 /var/lib/libvirt/images/haos-18.2.qcow2
sudo chown root:libvirt-qemu /var/lib/libvirt/images/haos-18.2.qcow2
sudo chmod 660 /var/lib/libvirt/images/haos-18.2.qcow2
```

## 512 GiB sparse disk

```bash
sudo qemu-img resize /var/lib/libvirt/images/haos-18.2.qcow2 512G
sudo qemu-img info /var/lib/libvirt/images/haos-18.2.qcow2
sudo du -h /var/lib/libvirt/images/haos-18.2.qcow2
```

Verified immediately after resize:

```text
virtual size: 512 GiB
disk size:    about 428 MiB
```

The large virtual size does not immediately consume 512 GiB on the host NVMe because QCOW2 allocates storage sparsely.

## Bridged networking

The physical Ethernet interface is `eth0` and the VM uses bridge `br0`.

Final topology:

```text
LAN
 |
eth0
 |
br0 ----- Debian host
 |
vnet0
 |
HAOS VM
```

After cutover, `eth0` is a Layer-2 bridge port with no host IP address of its own. IPv4, IPv6 and the default route are on `br0`.

Wi-Fi was deliberately kept active during the bridge migration as a recovery path.

Before creating the VM, the following were verified through `br0`:

- IPv4 LAN gateway
- IPv4 Internet
- DNS
- HTTPS
- IPv6 routes
- raw IPv6 Internet connectivity

## KVM and UEFI validation

The tested host provides:

```text
/dev/kvm
/usr/bin/qemu-system-aarch64
/usr/bin/virt-install
/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd
/usr/share/AAVMF/AAVMF_VARS.fd
```

`virt-host-validate qemu` passed KVM access, vhost-net, TUN and required cgroup checks.

The host does not expose normal ACPI IORT IOMMU device-assignment support. That does not prevent this HAOS VM because it does not require PCI passthrough.

## Create the VM

```bash
sudo virt-install \
  --connect qemu:///system \
  --name haos \
  --description "Home Assistant OS 18.2" \
  --virt-type kvm \
  --arch aarch64 \
  --machine virt \
  --os-variant generic \
  --memory 8192 \
  --vcpus 6 \
  --cpu host-passthrough \
  --disk path=/var/lib/libvirt/images/haos-18.2.qcow2,format=qcow2,bus=scsi \
  --controller type=scsi,model=virtio-scsi \
  --network bridge=br0,model=virtio \
  --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
  --import \
  --graphics none \
  --noautoconsole
```

The `--osinfo generic` warning is expected here. KVM, CPU mode and VirtIO devices are explicitly configured.

Verified libvirt state:

```text
6 vCPU
8192 MiB RAM
CPU mode host-passthrough
AAVMF UEFI
Secure Boot disabled
VirtIO SCSI disk
VirtIO NIC on br0
```

## Find the correct HAOS address

When several Home Assistant installations exist on the same LAN, do not rely on `homeassistant.local` to identify the new VM.

Get the VM MAC address:

```bash
sudo virsh domiflist haos
```

Then match that MAC against the bridge neighbor table:

```bash
ip neigh show dev br0
```

A DHCP reservation can then be created for that VM MAC.

On the tested fresh HAOS installation, the Home Assistant frontend responded on HTTP port 80:

```bash
curl -sS -o /dev/null \
  -w 'HTTP %{http_code} - remote %{remote_ip}\n' \
  http://HAOS_IP/
```

A successful test returned `HTTP 200`.

## Enable VM autostart

After networking and Home Assistant were verified:

```bash
sudo virsh autostart haos
sudo virsh dominfo haos | grep -E '^(Name|State|Autostart):'
```

Expected:

```text
Name:       haos
State:      running
Autostart:  enable
```

## USB passthrough and reboot-safe serial adapters

The tested HAOS installation uses three USB devices passed through from the Debian host:

- onboard Bluetooth radio: `13d3:3570`
- Z-Wave serial adapter: Silicon Labs CP2102N, `10c4:ea60`
- RFXCOM serial adapter: Silicon Labs CP2102N, `10c4:ea60`

The Bluetooth adapter has a unique VID:PID and is therefore safe to keep as a normal persistent libvirt USB hostdev:

```xml
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source startupPolicy='optional'>
    <vendor id='0x13d3'/>
    <product id='0x3570'/>
  </source>
</hostdev>
```

The two CP2102N adapters are different devices but expose the same VID:PID. A persistent rule containing only `10c4:ea60` is ambiguous, while host USB `device` numbers are not stable across reconnects or host reboots.

The verified solution is therefore:

1. keep only Bluetooth as a static persistent libvirt USB hostdev
2. identify Z-Wave and RFXCOM from their unique USB serial numbers in `/sys/bus/usb/devices/*/serial`
3. discover the current host `busnum` and `devnum` at runtime
4. attach each CP2102N to the running HAOS VM with `virsh attach-device --live`
5. repeat the check from a systemd timer so the setup also self-recovers after a reconnect or VM restart

The production host uses:

```text
/usr/local/sbin/haos-usb-serial-attach.sh
/etc/systemd/system/haos-usb-attach.service
/etc/systemd/system/haos-usb-attach.timer
```

The script deliberately verifies that a matched serial still belongs to `10c4:ea60` before attaching it.

Example structure:

```bash
ZWAVE_SERIAL="<unique-Z-Wave-serial>"
RFXCOM_SERIAL="<unique-RFXCOM-serial>"

for d in /sys/bus/usb/devices/*; do
    [[ -r "$d/serial" ]] || continue
    serial="$(tr -d '\r\n' < "$d/serial")"
    # Match the requested serial, then read busnum/devnum/idVendor/idProduct.
done
```

The systemd timer is enabled at boot and runs the oneshot attach service approximately every 30 seconds:

```ini
[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=haos-usb-attach.service
```

Enable it with:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now haos-usb-attach.timer
```

### USB persistence verification

The serial-number attach mechanism was tested before reboot by live-detaching each CP2102N and running the service again.

RFXCOM changed from host USB device number `3/8` to `3/9`; the script still found the correct adapter from its unique serial and reattached it successfully. Z-Wave was also detached and reattached successfully.

A subsequent full Q8B host reboot provided the stronger validation: the USB device numbers changed again, and the timer attached the correct adapters automatically:

```text
Z-Wave: attaching ... from USB 3/2 (3-1)
Z-Wave: attach successful
RFXCOM: attaching ... from USB 3/3 (3-2)
RFXCOM: attach successful
```

After recovery:

```text
Bluetooth    present in HAOS
Z-Wave       present in HAOS
RFXCOM       present in HAOS
host ttyUSB  none
host hci     none
```

The absence of host `/dev/ttyUSB*` nodes and host Bluetooth controllers is expected while HAOS owns those USB devices.

## Reading the physical Q8B CPU temperature from HAOS

A Home Assistant `command_line` sensor running inside HAOS cannot directly read the Debian host's `/sys/class/thermal` tree. It sees the VM guest namespace, not the physical Q8B thermal sensors.

On the tested Q8B, the useful CPU aggregate sensors are identified by thermal `type`, not by a fixed zone number:

```text
cluster0-thermal
cluster1-thermal
```

At one tested boot these happened to be `thermal_zone24` and `thermal_zone37`, but zone numbering should not be hard-coded because it may change with kernel or device-tree changes.

The host-side solution is a tiny read-only HTTP service that searches the thermal zones by `type`, reads both cluster temperatures and exports the higher value as the overall CPU temperature.

Example response:

```json
{"cpu":41.8,"cluster0":40.8,"cluster1":41.8}
```

The tested host service is installed as:

```text
/usr/local/sbin/radxa-temperature-api.py
/etc/systemd/system/radxa-temperature-api.service
```

Core sensor lookup logic:

```python
import glob


def read_thermal(sensor_type):
    for zone in glob.glob("/sys/class/thermal/thermal_zone*"):
        try:
            with open(f"{zone}/type", "r") as f:
                zone_type = f.read().strip()
            if zone_type == sensor_type:
                with open(f"{zone}/temp", "r") as f:
                    return round(int(f.read().strip()) / 1000.0, 1)
        except (OSError, ValueError):
            continue
    return None
```

The HTTP endpoint is exposed on TCP port 9101 on the Debian host. Bind it to the host bridge address rather than assuming a particular `thermal_zoneN` path.

Enable persistence with:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now radxa-temperature-api.service
```

Verify:

```bash
systemctl is-enabled radxa-temperature-api.service
systemctl is-active radxa-temperature-api.service
curl -s http://RADXA_HOST_IP:9101/cpu-temp
```

Expected systemd state:

```text
enabled
active
```

Home Assistant can then consume the host value with a REST sensor:

```yaml
rest:
  - resource: http://RADXA_HOST_IP:9101/cpu-temp
    scan_interval: 15
    sensor:
      - name: CPU Temperature
        unique_id: radxa_dragon_q8b_cpu_temperature
        unit_of_measurement: "°C"
        device_class: temperature
        state_class: measurement
        value_template: "{{ value_json.cpu }}"
```

This keeps the Home Assistant entity persistent while correctly reporting the physical Q8B host CPU temperature rather than a guest thermal value.

## Reboot validation

### VM reboot

```bash
sudo virsh reboot haos
```

The VM returned on its DHCP reservation and the Home Assistant HTTP endpoint returned 200.

### Full host reboot

The complete Radxa host was then rebooted.

Verified automatically after host startup:

```text
br0       UP
eth0      forwarding under br0
vnet0     forwarding under br0
libvirtd  active
haos      running
autostart enabled
HAOS ping working
HAOS HTTP 200
Bluetooth passed through
Z-Wave attached by serial-number service
RFXCOM attached by serial-number service
```

The HAOS network stack becomes reachable before the Home Assistant HTTP frontend is necessarily ready; a short additional startup delay before HTTP returns `200` is normal.

This validates the unattended chain:

```text
Qualcomm UEFI
 -> real systemd-boot
 -> EL2/VHE kernel
 -> Debian + NetworkManager br0
 -> libvirt
 -> HAOS autostart
 -> USB serial attach timer
 -> LAN DHCP
 -> Home Assistant frontend
```

## Result

The Radxa Dragon Q8B now runs Home Assistant OS as a reboot-safe, KVM-accelerated ARM64 virtual machine while retaining Debian as the host operating system. Bridged networking, Bluetooth, Z-Wave, RFXCOM and host CPU temperature reporting have all been validated with persistent host-side configuration.
