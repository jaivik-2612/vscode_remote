#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Userspace model of the pop-up motor's sleep flags (kernel patch 0102).

Replays the failure sequences of two review findings against the flag
logic of hotdog-popup-motor.c, as 0102 first had it (old) and as fixed
(new), inside a small model of genpd:

  motor-safety-1  a close fails (a finger on the camera), so genpd keeps the
                  domain on with its consumer suspended; a suspend is then
                  aborted after the PM_SUSPEND_PREPARE retract: the old
                  reconcile raised the camera with no stream.
  motor-safety-2  the PM_SUSPEND_PREPARE retract fails; the gated noirq
                  callbacks never move the motor: the old reconcile left the
                  camera raised after resume.

It also checks that the fix keeps a stream held across sleep raised again.
It does not replay motor-safety-5 (no settle push on a seated camera): that
fix changes the close's motion, not the flags, and hardware-validation.md
item 34 checks it on the phone. Exits non-zero when the new logic fails a
sequence, or when the old logic no longer shows a defect (the replay would
have lost its teeth). Run by tests/lint.sh; the kernel is not involved.
"""
import sys

EPROTO = -71
EIO = -5


class Popup:
    """struct hotdog_popup's sleep flags; every method runs under popup->lock."""

    def __init__(self, new):
        self.new = new
        self.domain_on = True  # pm_genpd_init() starts the domain on
        self.consumer_on = False
        self.reopen_pending = False
        self.retract_pending = False
        self.sleeping = False
        self.raised = False  # the camera is off its seat
        self.fail_close = 0  # closes that fail: a finger on the camera
        self.fail_retract = 0  # PREPARE retracts that fail (-EPROTO)
        self.fail_hall = 0  # Hall reads that fail (I2C error)

    def close(self):  # hotdog_popup_close_with_retry()
        if self.fail_close:
            self.fail_close -= 1
            return EPROTO
        self.raised = False
        return 0

    def retract(self):  # hotdog_popup_retract(): (ret, raised)
        if self.fail_hall:
            self.fail_hall -= 1
            return EIO, False
        if not self.raised:
            return 0, False
        if self.fail_retract:
            self.fail_retract -= 1
            return EPROTO, True
        return self.close(), True

    def power_on(self, consumer_active):  # hotdog_popup_domain_power_on()
        if self.sleeping:
            self.domain_on = True
            if self.new:
                self.consumer_on = consumer_active
            self.reopen_pending = consumer_active
            return 0
        self.reopen_pending = False
        self.retract_pending = False
        self.raised = True  # hotdog_popup_auto_open()
        self.domain_on = True
        self.consumer_on = True
        return 0

    def power_off(self):  # hotdog_popup_domain_power_off()
        self.consumer_on = False
        self.reopen_pending = False
        if self.sleeping:
            self.domain_on = False
            return 0
        self.retract_pending = False
        ret = self.close()
        self.domain_on = ret != 0
        return ret

    def sleep_prepare(self):  # hotdog_popup_sleep_prepare()
        ret, raised = self.retract()
        if self.new:
            self.retract_pending = ret != 0
        if raised:
            self.reopen_pending = self.consumer_on if self.new else self.domain_on
        self.sleeping = True

    def reconcile(self):  # hotdog_popup_reconcile_work()
        if self.sleeping:
            return
        if self.retract_pending:
            self.retract_pending = False
            if not self.consumer_on:
                self.retract()
                return
        if not self.reopen_pending:
            return
        self.reopen_pending = False
        if not self.domain_on or (self.new and not self.consumer_on):
            return
        if not self.raised:
            self.raised = True  # hotdog_popup_auto_open()


class Genpd:
    """The pop-up domain as genpd sees it, with one consumer (the IMX471)."""

    def __init__(self, popup):
        self.p = popup
        self.on = True
        self.active = False

    def stream_start(self):  # genpd_runtime_resume()
        if not self.on and self.p.power_on(True) == 0:
            self.on = True
        self.active = True

    def stream_stop(self):  # genpd_runtime_suspend() -> genpd_power_off()
        self.active = False
        self.power_off_work()

    def power_off_work(self):  # genpd keeps the domain on when power_off fails
        if self.on and not self.active and self.p.power_off() == 0:
            self.on = False

    def suspend(self, abort=False, work_after_post=False):
        self.p.sleep_prepare()  # PM_SUSPEND_PREPARE
        if not abort:
            if self.on and self.p.power_off() == 0:  # suspend_noirq
                self.on = False
            if not self.on:  # resume_noirq, result ignored
                self.p.power_on(self.active)
                self.on = True
            if not work_after_post:  # genpd_complete(); pm_wq thaws first
                self.power_off_work()
        self.p.sleeping = False  # PM_POST_SUSPEND
        if work_after_post:
            self.power_off_work()
        self.p.reconcile()


def stuck_raised(new):
    """A stream ends with a finger on the camera: raised, domain on, idle."""
    p = Popup(new)
    g = Genpd(p)
    p.domain_on = g.on = False  # genpd powered the unused domain off
    g.stream_start()
    p.fail_close = 1
    g.stream_stop()
    assert p.raised and g.on and p.domain_on and not g.active
    return p, g


def ms1(new):
    p, g = stuck_raised(new)
    g.suspend(abort=True)
    return p.raised


def ms2(new, hall=False, work_after_post=False):
    p, g = stuck_raised(new)
    if hall:
        p.fail_hall = 1
    else:
        p.fail_retract = 1
    g.suspend(work_after_post=work_after_post)
    return p.raised


def stream_across_sleep(new, abort=False):
    p, g = stuck_raised(new)
    p.raised = False  # the finger is gone
    g.power_off_work()
    g.stream_start()
    g.suspend(abort=abort)
    return p.raised


# motor-safety-5 (no settle push for a camera already seated) is a change in
# hotdog_popup_close()'s motion, not in the flag logic modelled here; a
# replay would only restate the new condition. hardware-validation.md item
# 34 checks it on the phone.


CASES = [
    # name, function, value with the new logic, value with the old logic
    ("motor-safety-1: aborted suspend leaves the camera down", ms1, False, True),
    ("motor-safety-2: failed PREPARE retract retried after resume", ms2, False, True),
    ("motor-safety-2: failed PREPARE Hall read retried after resume",
     lambda n: ms2(n, hall=True), False, True),
    ("power-off work after PM_POST_SUSPEND also ends down",
     lambda n: ms2(n, work_after_post=True), False, False),
    ("stream held across sleep is raised again", stream_across_sleep, True, True),
    ("stream held across an aborted suspend is raised again",
     lambda n: stream_across_sleep(n, abort=True), True, True),
]


def main():
    fail = 0
    for name, fn, want_new, want_old in CASES:
        got_new, got_old = fn(True), fn(False)
        ok = got_new == want_new and got_old == want_old
        fail |= not ok
        print("%s  %s (new=%s old=%s)" % ("PASS" if ok else "FAIL", name, got_new, got_old))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
