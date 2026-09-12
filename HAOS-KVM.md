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
```

This validates the unattended chain:

```text
Qualcomm UEFI
 -> real systemd-boot
 -> EL2/VHE kernel
 -> Debian + NetworkManager br0
 -> libvirt
 -> HAOS autostart
 -> LAN DHCP
 -> Home Assistant frontend
```

## Result

The Radxa Dragon Q8B now runs Home Assistant OS as a reboot-safe, KVM-accelerated ARM64 virtual machine while retaining Debian as the host operating system.
