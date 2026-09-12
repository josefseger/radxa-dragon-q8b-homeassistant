# Home Assistant on Radxa Dragon Q8B

This project documents the work needed to prepare a **Radxa Dragon Q8B** to run **Home Assistant OS in a KVM virtual machine** while keeping Debian as the host operating system.

The project is still in progress. Home Assistant OS has **not yet been installed in the VM**. The difficult platform work has been the main focus so far: enabling KVM/EL2 without losing the Q8B audio DSP, fan control, and video hardware acceleration.

## Hardware and software used

- Radxa Dragon Q8B
- Qualcomm Snapdragon 8cx Gen 3 / SC8280XP
- 16 GB RAM
- NVMe SSD
- Debian 13 (Trixie)
- Radxa kernel baseline: `7.0.11-6-qcom`
- BIOS updated to Radxa release `260825`

## Goal

The planned Home Assistant VM is:

- ARM64 Home Assistant OS
- KVM acceleration
- 4 vCPU
- 8 GB RAM
- 512 GB sparse `qcow2` disk
- UEFI boot
- bridged Ethernet

The VM itself is intentionally the next step. We first wanted the host platform to be stable with KVM enabled.

---

# What we learned and did

## 1. Install Debian on the Q8B

Debian Trixie was installed on NVMe and used as the normal desktop/host OS.

Basic hardware such as Ethernet, Wi-Fi, Bluetooth, display, audio and fan control worked in the normal boot mode.

The stock kernel used during the first tests was:

```bash
uname -r
# 7.0.11-6-qcom
```

## 2. Install the virtualization tools

KVM/QEMU/libvirt/virt-manager were installed on Debian.

The important check is:

```bash
ls -l /dev/kvm
```

With the BIOS in its normal/automatic hypervisor mode, `/dev/kvm` was not available.

## 3. Enable EL2 in BIOS

BIOS was updated to `260825`.

Then:

- BIOS -> **Hypervisor Override** -> **Enabled**

Linux then booted at EL2 and KVM initialized successfully:

```text
kvm [1]: VHE mode initialized successfully
```

and:

```bash
ls -l /dev/kvm
```

showed the KVM device.

### New problem

With EL2 enabled, the Qualcomm ADSP and CDSP remote processors stopped starting correctly.

Typical errors were:

```text
qcom_q6v5_pas ... error -22 initializing firmware ...qcadsp8280.mbn
qcom_q6v5_pas ... error -22 initializing firmware ...qccdsp8280.mbn
```

This caused two visible problems:

- audio stopped working
- automatic fan control stopped working

So simply enabling KVM was not enough.

## 4. Understand the Q8B boot chain

The active Q8B boot chain was found to be:

```text
Qualcomm UEFI
  -> /EFI/BOOT/BOOTAA64.EFI
  -> Radxa embloader 0.7
  -> BLS entry
  -> Linux kernel + initrd + DTB
```

The important discovery was that Radxa's `embloader` is not the normal Debian `systemd-boot` implementation and does not automatically load EFI drop-in drivers from:

```text
/EFI/systemd/drivers/
```

The existing fallback bootloader was kept untouched for recovery.

## 5. Chainload real Debian systemd-boot

A separate copy of Debian's real systemd-boot was added without replacing the Radxa bootloader:

```text
/EFI/systemd/systemd-boot-real-aa64.efi
```

A BLS entry was then used to chainload it from the Radxa boot menu.

This gave a safe two-stage boot path:

```text
Radxa embloader
  -> real Debian systemd-boot
  -> test kernel / DTB
```

This was important because real systemd-boot supports EFI driver autoloading.

## 6. Use qebspil to start Qualcomm DSPs before Linux

We used:

- project: `stephan-gh/qebspil`
- tested commit: `8e4d9e676a3b3afe136cda9b953a2139ff1a32d0`

The EFI driver was installed as:

```text
/boot/efi/EFI/systemd/drivers/qebspilaa64.efi
```

The ADSP and CDSP firmware files were also staged on the EFI System Partition so qebspil could load them before Linux.

ADSP firmware:

```text
/firmware/qcom/sc8280xp/radxa/dragon-q8b/qcadsp8280.mbn
```

CDSP firmware:

```text
/firmware/qcom/sc8280xp/qccdsp8280.mbn
```

## 7. Create an EL2-specific DTB

A custom EL2 device tree was created from the normal Q8B DTB plus the Radxa EL2 overlay.

The qebspil-specific change marks the ADSP and CDSP remote processors with:

```dts
&remoteproc_adsp {
    qcom,broken-reset;
};

&remoteproc_nsp0 {
    qcom,broken-reset;
};
```

The normal DTB was left unchanged.

## 8. Patch the kernel remoteproc attach path

The Radxa kernel already contained support for attaching to remote processors that were started before Linux.

One missing part was found in the Qualcomm minidump remoteproc operations used by ADSP: the attach callback was missing.

The custom kernel work used:

- Radxa packaging repo: `radxa-pkg/linux-qcom`
- package tag: `7.0.11-6`
- kernel source commit used during testing: `657c0f722940cd9d3b51abfa7383655ec7d2c795`
- custom kernel version: `7.0.11-6+q8bel2.1-qcom`

The local commits were:

```text
13227941a903  remoteproc minidump attach fix
4eb7a4ca155b  Q8B qebspil EL2 overlay
```

## 9. Successful EL2 + KVM + DSP boot

The working boot sequence became:

```text
BIOS Hypervisor Override = Enabled
  -> Radxa embloader
  -> REAL systemd-boot
  -> Q8B EL2 qebspil test entry
  -> custom kernel + EL2 DTB
```

The result:

```bash
uname -r
# 7.0.11-6+q8bel2.1-qcom
```

KVM works:

```bash
ls -l /dev/kvm
```

ADSP and CDSP attach instead of failing:

```text
remoteproc0: attaching to adsp
remoteproc0: remote processor adsp is now attached
remoteproc1: attaching to cdsp
remoteproc1: remote processor cdsp is now attached
```

Audio works again.

Automatic fan control works again. The fan hwmon device appears as:

```text
radxa_svc_glink
```

and automatic mode is:

```text
pwm1_enable = 2
```

This was the first important milestone: **KVM, audio and fan control working together at EL2.**

## 10. Remaining EL2 problem: Iris video firmware

The Qualcomm Iris VPU still fails to start under EL2.

The error is:

```text
qcom-iris aa00000.video-codec: error -22 initializing firmware qcom/vpu/vpu20_p4_gen2_s6.mbn
```

The failure happens in the Qualcomm PAS firmware initialization path for **PAS ID 9**.

This problem is still open.

Important: this is separate from ADSP/CDSP. KVM, audio and fan control are already working under EL2.

## 11. Test the Iris VPU in normal EL1 mode

To understand whether the VPU hardware itself was working, the machine was booted in the normal EL1 configuration.

In EL1 the Iris decoder starts correctly and appears as:

```text
/dev/video0
iris_driver
Iris Decoder
```

A 4K HEVC Main10 test file was then used.

The hardware decoder opened correctly, but FFmpeg failed when the decoder switched its capture format from NV12 to P010.

## 12. Find missing P010 support in FFmpeg 7.1.5 V4L2M2M

Two missing pieces were found in FFmpeg 7.1.5.

### Fix 1 - map V4L2 P010 to FFmpeg P010LE

In:

```text
libavcodec/v4l2_fmt.c
```

we added:

```c
#ifdef V4L2_PIX_FMT_P010
    { AV_FMT(P010LE),      AV_CODEC(RAWVIDEO),    V4L2_FMT(P010) },
#endif
```

Without this mapping, Iris could return P010 but FFmpeg could not represent the format correctly.

### Fix 2 - handle single-memory-plane P010 like NV12

Iris exposes P010 as one V4L2 memory buffer containing two image planes: Y followed by interleaved UV.

FFmpeg already handled this layout for NV12/NV21, but not P010.

In:

```text
libavcodec/v4l2_buffers.c
```

we added:

```c
case AV_PIX_FMT_P010LE:
```

to the existing NV12/NV21 special case.

This gives the second P010 image plane a valid data pointer and line stride.

The complete minimal FFmpeg patch is included in:

```text
patches/ffmpeg-7.1.5-v4l2m2m-p010.patch
```

## 13. Build a local patched FFmpeg

We deliberately did not replace Debian's FFmpeg packages.

The source was cloned from FFmpeg `n7.1.5`, patched locally and built separately.

Example:

```bash
git clone --depth 1 --branch n7.1.5 \
  https://github.com/FFmpeg/FFmpeg.git \
  ~/src/ffmpeg-7.1.5-p010
```

A shared `libavcodec.so.61` was then built and tested with Debian's existing mpv using `LD_PRELOAD`.

## 14. Hardware HEVC Main10 decoding now works in mpv

The patched library is loaded only for the test process:

```bash
LD_PRELOAD="$HOME/src/ffmpeg-7.1.5-p010/build-shared/libavcodec/libavcodec.so.61" \
mpv \
  --no-config \
  --vo=gpu \
  --gpu-api=opengl \
  --hwdec=v4l2m2m-copy \
  VIDEO_FILE
```

The important mpv output is now:

```text
Using hardware decoding (v4l2m2m-copy).
VO: [gpu] 3840x2160 p010
```

Longer playback remained synchronized and stable:

```text
A-V: 0.000
```

The fan also remained at low speed, which is consistent with the video being decoded by the Iris hardware decoder instead of the CPU.

No test media filenames are included in this repository.

---

# Current status

| Feature | EL1 / normal boot | EL2 / KVM boot |
|---|---|---|
| Debian desktop | Working | Working |
| KVM `/dev/kvm` | No | Working |
| ADSP | Working | Working with qebspil + custom kernel |
| CDSP | Working | Working with qebspil + custom kernel |
| Audio | Working | Working |
| Automatic fan control | Working | Working |
| Iris VPU firmware | Working | **PAS 9 error -22** |
| HEVC 10-bit hardware decode | Working with FFmpeg P010 patch | Not yet, because Iris PAS 9 fails |
| Home Assistant OS VM | Not created yet | Next milestone |

# Important recovery/safety notes

During development we kept the original boot path available.

Recommended rules:

- Do not overwrite `/EFI/BOOT/BOOTAA64.EFI`.
- Keep the original Radxa boot entry available.
- Keep the stock kernel/DTB as a recovery entry.
- Do not modify `extlinux.conf`; it was not the active boot path in this setup.
- Keep the custom EL2 test entry separate from the normal boot entry.
- BIOS **Hypervisor Override = Auto** plus the stock boot entry is the recovery path.
- Do not force the fan PWM manually when `pwm1_enable=2`; that is automatic mode.

# Next step: Home Assistant OS VM

Now that the EL2/KVM platform works with audio and fan control, the next project step is to create the Home Assistant OS ARM64 virtual machine.

Planned configuration:

```text
4 vCPU
8 GB RAM
512 GB sparse qcow2
UEFI
KVM
bridged Ethernet
```

Before making this the permanent configuration, the remaining Iris/PAS 9 EL2 issue should be documented and ideally solved so the Debian host keeps hardware video decoding while KVM is enabled.

# Project status

**Experimental / work in progress.**

This repository records a real Q8B bring-up and the fixes that were verified on the hardware. It is not yet a one-command installer.
