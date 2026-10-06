# Cameras

The OnePlus 7T Pro has three rear cameras (IMX586 main, S5K3M5 telephoto,
IMX481 ultra-wide) and a pop-up front camera (IMX471). This page describes
how Antumbra uses them, what does not work, who can reach them, and why the
OnePlus camera app is not part of it.

## The camera path

| Layer | What | Where it comes from |
|---|---|---|
| Kernel | Qualcomm CAMSS (`qcom_camss`), the camera I2C controller (CCI), the four sensor drivers, the pop-up motor and its Hall sensors, all as modules | the port's patches 0013-0015 on the 6.17 kernel; Antumbra's patch `0102` for motor safety |
| libcamera | the `simple` pipeline handler with libcamera's software ISP (debayering, colour and exposure control done on the CPU) | `libcamera0.7` and `libcamera-ipa` 0.7.1 from trixie-backports, or 0.7.2 with the port's patches (below) |
| PipeWire | one camera node per libcamera camera, created by WirePlumber's libcamera monitor | PipeWire 1.6.9 and WirePlumber 0.5.12 from trixie-backports |
| Portal | `org.freedesktop.portal.Camera` in `xdg-desktop-portal`; the prompt is Phosh's Access dialog (`phosh-portals.conf` routes it to the shell) | trixie |
| Application | GNOME Snapshot 48 | trixie |

Why the backports: trixie's PipeWire camera plugin (`libspa-0.2-libcamera`
1.4.2) is built against libcamera 0.4. The only build against libcamera 0.7
is trixie-backports' 1.6.9, which requires the PipeWire modules of the same
version, so the whole PipeWire stack comes from backports
(`config/rootfs/etc/apt/preferences.d/antumbra-backports` pins exactly those
packages; everything else stays on trixie). PipeWire 1.6.9 also passes the
sensor's mounting rotation on as a video transform, which the IMX471,
mounted at 90 degrees, needs.

`gnome-snapshot`, `libcamera-ipa` and `libspa-0.2-libcamera` are listed in
`config/packages/apps.list`: Snapshot only recommends the last two, and the
image is built without recommends. Without them there would be no software
ISP and no camera in PipeWire.

Megapixels, which earlier versions listed, is gone: it has no configuration
for this phone and exits at start, it reads the V4L2 devices directly
instead of going through PipeWire, and it has no automatic exposure.

### One owner for the camera hardware

PipeWire is meant to be the only program that configures CAMSS.
`config/rootfs/etc/wireplumber/wireplumber.conf.d/90-antumbra-camera.conf`
keeps WirePlumber's V4L2 monitor away from CAMSS's raw video nodes (raw
Bayer, one per VFE output), which it would otherwise offer to applications
as extra cameras: WirePlumber's own deduplication only drops the V4L2
nodes that libcamera reports using. libcamera's monitor stays on.

The rule has to match a property that PipeWire's V4L2 udev monitor
provides when WirePlumber applies the rules, before the device exists;
`api.v4l2.cap.driver` is added only afterwards and would match nothing. It
matches either of:

- `device.product.name = "Qualcomm Camera Subsystem"`: the udev monitor
  takes the product name from `ID_V4L_PRODUCT` when a device has no USB or
  PCI model, and udev's `v4l_id` sets that to the card name CAMSS reports;
- `device.sysfs.path` ending in `.camss/video4linux/videoN`: the CAMSS
  platform device is `acb3000.camss`.

That is read from the code (PipeWire 1.6.9 `v4l2-udev.c`, WirePlumber
0.5.12, the CAMSS driver), not yet seen on the phone. The VM exercises the
same mechanism with the virtual camera's card name, and
`hardware-validation.md` has the check on the phone.

The port runs the opposite arrangement: WirePlumber's libcamera monitor
disabled ("the SM8150 CAMSS graph cannot currently be shared with
PipeWire's passive libcamera monitor"), and Plasma Camera using libcamera
directly. Antumbra ships no program that opens the cameras directly, so
PipeWire is the only user; whether that holds up on this hardware is the
first thing to validate. If it does not, the fallback is to disable the
libcamera monitor too and ship a Megapixels configuration
(`/etc/megapixels/config/oneplus,hotdog.ini`): front camera
`driver=imx471`, `media-driver=qcom-camss`, 1748x1748 `RGGB10P`, and media
links that keep `imx471:0->msm_csiphy2:0` (Megapixels uses the link list
to set the pad formats and ignores the error from the immutable link),
then `msm_csiphy2:1->msm_csid0:0` and `msm_csid0:1->msm_vfe0_rdi0:0`. The
entity names are unverified and Megapixels offers manual exposure only.
None of this is shipped.

## The pop-up front camera

In the port's kernel the pop-up motor is a power domain of the IMX471
sensor, and the sensor driver powers the sensor only while it streams.
When an application starts streaming from the front camera, the kernel
raises the camera first; when the stream stops, the sensor powers down and
the camera retracts. Opening the device without streaming moves nothing.
The port validated this on hardware. Any camera application works; no
OnePlus software is involved.

With Snapshot, PipeWire starts the stream when Snapshot shows the front
camera's preview and stops it when Snapshot quits, is killed, or switches
to a rear camera. Every start and stop is a full course of the motor.

What follows from that:

- The raised camera shows that the front camera is in use, whichever
  program uses it. It is an indicator, not a security boundary against
  root.
- The rear cameras have no indicator at all.
- There is no drop protection: OxygenOS retracts the camera when the phone
  falls, on a signal from the sensor DSP, which Antumbra disables. Do not
  keep the front camera open while walking, and do not push a raised
  camera down by hand.
- Antumbra's kernel patch `0102` retracts the camera before suspend and
  power-off and at boot; `hardware-validation.md` lists the motor checks.

## Limits

- The front camera has one mode, 1748x1748 RAW10. Snapshot shows a square
  picture.
- Image quality comes from libcamera's software ISP with untuned
  parameters: the port's tuning files are generic (`imx471.yaml` is
  byte-identical to the files for several other sensors). There is no
  production colour, no flash control, no optical stabilisation and no
  touch focus, and video recording is untested.
- With the default libcamera 0.7.1 the four sensors have no sensor data in
  libcamera (gain model, black level, control delays), so exposure and
  colour are rougher than on the port, and libcamera logs warnings about
  it. The optional rebuild below adds the port's data.
- A CAMSS failure (CSID/VFE reset timeouts) can need a reboot; reloading
  the module does not clear it on the port.
- The preview's orientation and mirroring on the phone are untested: the
  rotation reaches Snapshot as a video transform, and whether Snapshot's
  GTK video sink applies it has not been checked.

## Who can use the cameras

The camera portal asks once per session, "Allow app to Use the Camera?".
For programs installed in the system, which is every program Antumbra
ships including Tor Browser, `xdg-desktop-portal` records a single
decision for all of them (it maps every program that is not sandboxed to
the same empty application id), so the prompt is not a per-application
permission. It is not an access control either:

- logind gives the session user access to `/dev/video*`, `/dev/media*` and
  `/dev/v4l-subdev*` (systemd's `70-uaccess.rules`), whatever groups that
  user is in; leaving `amnesia` out of the `video` group would change
  nothing;
- PipeWire's access module and WirePlumber's default access policy give
  every client that is not a Flatpak access to all nodes, the camera nodes
  included;
- the camera portal itself: once the session's one decision for host
  programs is "allow" (a single tap on Allow, for Snapshot or for any
  other program), every host program that asks the portal over the session
  bus (`org.freedesktop.portal.Camera`: `AccessCamera`, then
  `OpenPipeWireRemote`) gets a connected PipeWire file descriptor for the
  cameras, without a prompt, for the rest of the session. The decision is
  kept in the portal's permission store
  (`org.freedesktop.impl.portal.PermissionStore`), which any program on
  the session bus can write, so a program can also give itself access
  without any prompt at all.

So any program running as `amnesia`, Tor Browser and anything that
compromises it included, can use the cameras without a prompt. Enforcement
needs Tor Browser confined, and the confinement has to close all three
ways in: an AppArmor profile that denies `/dev/video*`, `/dev/media*`,
`/dev/v4l-subdev*` and the PipeWire socket (`/run/user/1000/pipewire-0`),
and that also denies the browser's session-bus calls to the camera portal
and to the permission store. Rules for the devices and the socket alone
are not enough: the portal hands the browser an already connected PipeWire
file descriptor, so the browser never opens a camera device or PipeWire's
socket by path. For example:

```
deny dbus send bus=session path=/org/freedesktop/portal/desktop interface=org.freedesktop.portal.Camera,
deny dbus send bus=session interface=org.freedesktop.impl.portal.PermissionStore,
```

Better, the profile allows the session bus only for the names the browser
needs. AppArmor's D-Bus rules are enforced by the bus daemon: the image's
`dbus-daemon` is built with AppArmor support and the 6.17 kernel
advertises AppArmor D-Bus mediation, so session-bus rules in the profile
should apply; the profile's own tests have to show that they do. The other
way is Tails' plan, a Flatpak sandbox: the portal then knows the browser
by its own application id and keeps a separate decision for it, and
Flatpak's D-Bus proxy keeps it away from the permission store. A
bubblewrap sandbox that is not a Flatpak still counts as a host program
for the portal. The image has no Tor Browser profile yet; it is planned
(`roadmap.md`). The VM camera checks call the portal as `amnesia` from
inside the browser's network namespace and expect a PipeWire connection
(`vm-testing.md`). The physical pop-up remains the only signal for the
front camera.

## Why there is no OnePlus Camera

Antumbra does not ship, download or script the installation of the
OxygenOS camera app ("OnePlus Camera"), and it would not work if it did.

Licence:

- The OxygenOS end-user licence allows use only on a OnePlus device for
  personal purposes (section 2.2(a)) and forbids making OxygenOS available
  "in whole or in part ... to any person" (section 3(g)).
- Google Play's terms do not allow redistributing apps obtained there.
- The app bundles other companies' proprietary libraries under their own
  terms (ArcSoft, Megvii and Qualcomm SNPE among them).

Technical:

- The app talks to Qualcomm's CamX/CHI camera HAL (`camera.qcom.so`,
  `com.qti.chi.override.so`, the `CAMERA_ICP` firmware), which drives
  Qualcomm's downstream camera kernel driver (`cam_req_mgr`). Mainline
  Linux has neither; the port uses the mainline CAMSS driver.
- Inside an Android container (Waydroid), the Android 13 image uses AOSP's
  External Camera HAL, which accepts only MJPEG or depth frames from
  `/dev/video*`; CAMSS delivers raw Bayer.
- On OxygenOS the pop-up is moved by a system service, not by the camera
  app (observed on the OnePlus 7 Pro), so the app would not bring the
  pop-up with it anyway.

None of it is needed: the kernel raises the pop-up for any application.
`tests/no-oneplus-camera.py` looks for OnePlus camera software and
Qualcomm's camera HAL files by file name (also with a compression suffix),
and for OnePlus Android packages by package name, whatever their file
name. It looks inside everything that can hold them, without mounting or
extracting anything, recursively: APKs, APEXes, XAPK, APKS and APKM
bundles and their split APKs, app bundles, zip, tar and cpio archives (the
initramfs), gzip, xz, bzip2 and zstd files, and ext2/3/4, EROFS and
Android sparse images, Waydroid's `system.img` and `vendor.img` among
them. A file in one of those formats that it cannot read entirely (an
EROFS image with compressed files, an Android super image or OTA payload,
an encrypted zip member, nesting deeper than eight levels) is reported,
so the check fails closed. `tests/lint.sh` runs it over the source tree;
the VM camera checks run it in the guest over the root file system, then
over a small fixture it must flag (a OnePlus camera APK inside an ext4
image and inside a zstd-compressed XAPK).

## Optional: the port's patched libcamera

`ANTUMBRA_LIBCAMERA_LOCAL=1` adds the `libcamera` build step
(`build/libcamera.sh`, run by `build.sh` before `rootfs.sh`). It rebuilds
Debian's libcamera 0.7.2-1 source package (the release the port's patches
target) for trixie with:

- the port's patches 0003-0010 from `aports/temp/libcamera` at the port's
  `v0.2.0-alpha.2` tag: sensor data for the IMX471, IMX586, IMX481 and
  S5K3M5 (camera sensor helpers and properties), soft-ISP autofocus and
  the port's 3A changes. The port's 0001 and 0002 were written for the
  PinePhone (0001 turns the software ISP on for its `sun6i-csi`; 0002
  stops offering unprocessed formats while the software ISP is on) and are
  not applied; upstream libcamera already turns the software ISP on for
  CAMSS;
- the port's tuning files for those four sensors in
  `/usr/share/libcamera/ipa/simple/` (the port ships nine more for sensors
  this phone does not have);
- `device/oneplus-hotdog/libcamera/antumbra-packaging.diff`: no
  tensorflow-lite (not in trixie; the trixie-backports package drops it
  the same way), no Python bindings or qcam, so the cross build needs
  neither a cross Python nor Qt.

The `.dsc` is pinned by SHA-256 in `sources.lock` (with a
snapshot.debian.org fallback for when the Debian pool drops it) and pins
the two tarballs; the patches and tuning files are pinned in
`device/oneplus-hotdog/libcamera/patches.sha256`, applied in the order of
`patches.list`. The packages keep Debian's names (`libcamera0.7`,
`libcamera-ipa`, `gstreamer1.0-libcamera`, `libcamera-tools`,
`libcamera-v4l2`, `libcamera-dev`) at version `0.7.2-1~antumbra1`, so
backports' PipeWire plugin, which needs `libcamera0.7 (>= 0.7.1)`, uses
them. Tests stay enabled at build time (`-Dtest=true`), which keeps the
`vimc` and `virtual` pipeline handlers the VM needs.

The build runs in a throwaway trixie chroot made by `mmdebstrap`. On an
x86-64 host it is a cross build (`dpkg-buildpackage -aarm64`, with
`crossbuild-essential-arm64` and the arm64 build dependencies installed
through multiarch); on an arm64 host it is native. On a 4-core x86-64
host the whole step, chroot included, takes about five minutes. The
result is a local repository in `build/out/libcamera-repo/` (or
`build/out/<profile>/libcamera-repo/`) that `rootfs.sh` adds for the
installation only, with every libcamera package pinned to it at priority
990; the source and the pin are removed before the build hooks run, and
`rootfs.sh` fails if `libcamera0.7` did not come from it.

libcamera signs its IPA modules with a key generated during the build and
checks them against the key built into `libcamera0.7`; a module whose
signature does not verify is run in a separate, isolated process instead.
So both packages must come from the same build, which the pin guarantees.
Debian's rules check the signatures only in native builds, so the script
checks them after every build: each module against the build's key, and
that key inside the packaged library. The fresh key also means two builds
never produce identical packages.

Default images do not use this step: the patches are the port's alpha
work, untested by Antumbra on the phone. An image built with it contains
libcamera built from source that Debian does not publish; whoever
distributes such an image must also offer that source (`legal.md`).

## Testing

In the VM (`vm-testing.md`): the qemu-virt kernel builds `vimc`, the
kernel's virtual media-controller camera, which libcamera drives with its
`vimc` pipeline handler. In debug builds of that profile, hook
`72-vm-camera.sh` loads it at boot and hides its raw V4L2 nodes with a
rule of the same kind as the CAMSS one (matched on the card name
`vimc`), and `config/packages/vm-debug.list` adds `libcamera-tools` for
`cam`. `tests/vm-smoke.sh --through-welcome --camera` then checks the
camera path from the kernel to a saved picture.

On the phone: `hardware-validation.md`, "Camera userspace".
