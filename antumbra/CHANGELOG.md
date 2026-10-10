# Changelog

One plain-language line per change, newest first. Releases are drafts on
GitHub; their notes take these lines.

## Unreleased (0.1.0-alpha.3)

- The screen settings (60 Hz, the phone's scale, no Xwayland) now apply to
  the session after login too, not only to the Welcome screen. Up to
  alpha.2 the session would have used the 90 Hz mode, which has display
  errors on this phone.
- A test run on GitHub for every change: the system is built and started
  in a virtual machine, with screenshots and measurements.
- The install guide: unlock the phone first, then install OxygenOS F.22 in
  both slots (an OxygenOS update before the unlock may make unlocking
  harder).
- A setup page for trying Antumbra's interface on the phone inside Termux,
  without installing anything over Android.
