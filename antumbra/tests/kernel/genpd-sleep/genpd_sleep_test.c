// SPDX-License-Identifier: GPL-2.0-only
/*
 * genpd system-sleep test for Antumbra's pop-up motor patch
 * (device/oneplus-hotdog/kernel/patches/0102-*.patch).
 *
 * The pop-up camera motor is a generic PM domain whose power_on and
 * power_off callbacks drive the motor over I2C-read Hall sensors. This
 * module registers a domain with logging callbacks and one runtime-PM
 * consumer. Its callbacks and PM notifier are a model of the patch's sleep
 * gate: a copy of the driver's flag logic, not the driver. A suspend-to-idle
 * cycle in the VM shows:
 *
 *  - that genpd calls the provider's power_on in resume_noirq for a domain
 *    that was off (and power_off in suspend_noirq for one that was on),
 *    where the real driver cannot read its Hall sensors;
 *  - that the gate turns every such call into a recorded state change
 *    without motion;
 *  - that a consumer held active across sleep (a stream) gets the camera
 *    raised again by the post-resume reconcile, and only then: not after an
 *    aborted suspend while a failed close keeps the domain on;
 *  - that a retract which failed before sleep is retried after resume.
 *
 * "Motion" is a flag: the fake camera is raised by an ungated power_on and
 * retracted by an ungated power_off, the PM_SUSPEND_PREPARE retract or the
 * reconcile. Results are read-only module parameters; see README.md.
 */

#include <linux/cleanup.h>
#include <linux/lockdep.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/notifier.h>
#include <linux/platform_device.h>
#include <linux/pm.h>
#include <linux/pm_domain.h>
#include <linux/pm_runtime.h>
#include <linux/suspend.h>
#include <linux/workqueue.h>

#define DRV_NAME "antumbra-genpd-sleep-test"

static bool gate = true;
module_param(gate, bool, 0444);
MODULE_PARM_DESC(gate, "Model the 0102 sleeping gate (0: unpatched behaviour)");

static bool legacy;
module_param(legacy, bool, 0444);
MODULE_PARM_DESC(legacy, "Model the gate as 0102 first had it: reopen on domain_on, no retry of a failed retract");

static bool active;
module_param(active, bool, 0444);
MODULE_PARM_DESC(active, "Hold the consumer runtime-active, like a stream kept across sleep");

static bool fail_close;
module_param(fail_close, bool, 0444);
MODULE_PARM_DESC(fail_close, "At load, raise the camera for the consumer, then fail its close once: camera raised, domain on, consumer suspended");

static bool fail_retract;
module_param(fail_retract, bool, 0444);
MODULE_PARM_DESC(fail_retract, "Fail the PM_SUSPEND_PREPARE retract once");

static bool veto;
module_param(veto, bool, 0444);
MODULE_PARM_DESC(veto, "Refuse PM_SUSPEND_PREPARE from a notifier after the gate's (an aborted suspend)");

/* Results, under /sys/module/genpd_sleep_test/parameters/. */
static unsigned int noirq_power_on;
module_param(noirq_power_on, uint, 0444);
MODULE_PARM_DESC(noirq_power_on, "power_on calls in the noirq phases");
static unsigned int noirq_power_off;
module_param(noirq_power_off, uint, 0444);
MODULE_PARM_DESC(noirq_power_off, "power_off calls in the noirq phases");
static unsigned int noirq_moves;
module_param(noirq_moves, uint, 0444);
MODULE_PARM_DESC(noirq_moves, "Motor courses started in the noirq phases (must be 0 when gated)");
static unsigned int gated_calls;
module_param(gated_calls, uint, 0444);
MODULE_PARM_DESC(gated_calls, "Callbacks that only recorded state");
static unsigned int prepare_retracts;
module_param(prepare_retracts, uint, 0444);
MODULE_PARM_DESC(prepare_retracts, "Retracts at PM_SUSPEND_PREPARE");
static unsigned int reconcile_raises;
module_param(reconcile_raises, uint, 0444);
MODULE_PARM_DESC(reconcile_raises, "Raises by the post-resume reconcile");
static unsigned int reconcile_retracts;
module_param(reconcile_retracts, uint, 0444);
MODULE_PARM_DESC(reconcile_retracts, "Retracts by the post-resume reconcile");
static unsigned int reconcile_runs;
module_param(reconcile_runs, uint, 0444);
MODULE_PARM_DESC(reconcile_runs, "Runs of the post-resume reconcile");
static unsigned int failed_closes;
module_param(failed_closes, uint, 0444);
MODULE_PARM_DESC(failed_closes, "power_off calls that failed (fail_close)");
static unsigned int failed_retracts;
module_param(failed_retracts, uint, 0444);
MODULE_PARM_DESC(failed_retracts, "Retracts that failed (fail_retract)");
static unsigned int vetoes;
module_param(vetoes, uint, 0444);
MODULE_PARM_DESC(vetoes, "Suspends refused at PM_SUSPEND_PREPARE (veto)");
static bool raised;
module_param(raised, bool, 0444);
MODULE_PARM_DESC(raised, "Fake camera position");
static bool domain_on;
module_param(domain_on, bool, 0444);
MODULE_PARM_DESC(domain_on, "Domain state as genpd last asked for it, or left on by a failed power_off");
static bool consumer_on;
module_param(consumer_on, bool, 0444);
MODULE_PARM_DESC(consumer_on, "Whether a consumer holds the camera");

/* Set between the consumer's own suspend_noirq and resume_noirq. */
static bool in_noirq;

/* The driver's popup->lock: every flag and counter above is written under it. */
static DEFINE_MUTEX(test_lock);
static bool sleeping;
static bool reopen_pending;
static bool retract_pending;

static struct generic_pm_domain test_genpd;
static struct platform_device *test_pdev;

/* Same check as hotdog-popup-motor.c; genpd holds its lock here. */
static bool test_consumer_active(struct generic_pm_domain *domain)
{
	struct pm_domain_data *pdd;

	list_for_each_entry(pdd, &domain->dev_list, list_node)
		if (!pm_runtime_status_suspended(pdd->dev))
			return true;

	return false;
}

static int test_power_on(struct generic_pm_domain *domain)
{
	bool noirq = READ_ONCE(in_noirq);
	bool consumer = test_consumer_active(domain);

	guard(mutex)(&test_lock);
	if (noirq)
		noirq_power_on++;

	if (gate && sleeping) {
		gated_calls++;
		domain_on = true;
		consumer_on = consumer;
		reopen_pending = consumer_on;
		pr_info(DRV_NAME ": power_on gated (noirq=%d consumer_active=%d)\n",
			noirq, consumer);
		return 0;
	}

	/* hotdog-popup-motor.c would run its opening course here. */
	if (noirq)
		noirq_moves++;
	reopen_pending = false;
	retract_pending = false;
	raised = true;
	domain_on = true;
	consumer_on = true;
	pr_info(DRV_NAME ": power_on raises the camera (noirq=%d)\n", noirq);
	return 0;
}

static int test_power_off(struct generic_pm_domain *domain)
{
	bool noirq = READ_ONCE(in_noirq);

	guard(mutex)(&test_lock);
	if (noirq)
		noirq_power_off++;
	consumer_on = false;
	reopen_pending = false;

	if (gate && sleeping) {
		gated_calls++;
		domain_on = false;
		pr_info(DRV_NAME ": power_off gated (noirq=%d)\n", noirq);
		return 0;
	}

	/* hotdog-popup-motor.c would run its closing course here. */
	if (noirq)
		noirq_moves++;
	retract_pending = false;
	if (fail_close && !failed_closes) {
		/* A finger on the camera: genpd keeps the domain on. */
		failed_closes++;
		domain_on = true;
		pr_info(DRV_NAME ": power_off fails, the camera stays raised\n");
		return -EPROTO;
	}

	raised = false;
	domain_on = false;
	pr_info(DRV_NAME ": power_off retracts the camera (noirq=%d)\n", noirq);
	return 0;
}

/* hotdog_popup_retract(): close a camera that is not closed. */
static int test_retract(const char *why, unsigned int *count)
{
	lockdep_assert_held(&test_lock);
	if (!raised)
		return 0;

	if (fail_retract && !failed_retracts) {
		failed_retracts++;
		pr_info(DRV_NAME ": retract at %s fails, the camera stays raised\n",
			why);
		return -EPROTO;
	}

	raised = false;
	(*count)++;
	pr_info(DRV_NAME ": retract at %s\n", why);
	return 0;
}

/* hotdog_popup_sleep_prepare() */
static void test_sleep_prepare(void)
{
	bool was_raised;
	int ret;

	guard(mutex)(&test_lock);
	was_raised = raised;
	ret = test_retract("system sleep", &prepare_retracts);
	if (!legacy)
		retract_pending = ret != 0;
	if (was_raised)
		reopen_pending = legacy ? domain_on : consumer_on;
	sleeping = true;
}

/* hotdog_popup_reconcile_work() */
static void test_reconcile(struct work_struct *work)
{
	guard(mutex)(&test_lock);
	reconcile_runs++;
	if (sleeping)
		return;

	if (retract_pending) {
		retract_pending = false;
		if (!consumer_on) {
			test_retract("resume", &reconcile_retracts);
			return;
		}
	}

	if (!reopen_pending)
		return;

	reopen_pending = false;
	if (!domain_on || (!legacy && !consumer_on))
		return;

	/* hotdog_popup_is_open(): already up. */
	if (raised)
		return;

	raised = true;
	reconcile_raises++;
	pr_info(DRV_NAME ": reconcile raises the camera for a consumer held across sleep\n");
}

static DECLARE_WORK(reconcile_work, test_reconcile);

static int test_pm_notify(struct notifier_block *nb, unsigned long action,
			  void *data)
{
	if (!gate)
		return NOTIFY_DONE;

	switch (action) {
	case PM_HIBERNATION_PREPARE:
	case PM_RESTORE_PREPARE:
	case PM_SUSPEND_PREPARE:
		cancel_work_sync(&reconcile_work);
		test_sleep_prepare();
		break;
	case PM_POST_HIBERNATION:
	case PM_POST_RESTORE:
	case PM_POST_SUSPEND:
		scoped_guard(mutex, &test_lock)
			sleeping = false;
		queue_work(system_freezable_wq, &reconcile_work);
		break;
	}

	return NOTIFY_DONE;
}

static struct notifier_block test_pm_nb = {
	.notifier_call = test_pm_notify,
};

/*
 * Registered after test_pm_nb at the same priority, so it runs after the
 * gate's PM_SUSPEND_PREPARE; the PM core then sends PM_POST_SUSPEND to the
 * notifiers before it and never freezes: an aborted suspend.
 */
static int test_veto_notify(struct notifier_block *nb, unsigned long action,
			    void *data)
{
	if (!veto || action != PM_SUSPEND_PREPARE)
		return NOTIFY_DONE;

	scoped_guard(mutex, &test_lock)
		vetoes++;
	pr_info(DRV_NAME ": refusing PM_SUSPEND_PREPARE\n");
	return notifier_from_errno(-EBUSY);
}

static struct notifier_block test_veto_nb = {
	.notifier_call = test_veto_notify,
};

/*
 * genpd_complete() queues the domain's power-off work on pm_wq, which is
 * thawed before PM_POST_SUSPEND goes out, so that work usually runs while
 * the gate is still closed. Flushing it from a notifier that runs before
 * the gate's makes that order certain.
 */
static int test_order_notify(struct notifier_block *nb, unsigned long action,
			     void *data)
{
	switch (action) {
	case PM_POST_HIBERNATION:
	case PM_POST_RESTORE:
	case PM_POST_SUSPEND:
		flush_work(&test_genpd.power_off_work);
		break;
	}

	return NOTIFY_DONE;
}

static struct notifier_block test_order_nb = {
	.notifier_call = test_order_notify,
	.priority = 1,
};

/*
 * genpd_finish_suspend() calls the device's own suspend_noirq before it
 * powers the domain off, and genpd_finish_resume() powers the domain on
 * before the device's own resume_noirq: between the two is noirq time.
 */
static int test_consumer_suspend_noirq(struct device *dev)
{
	WRITE_ONCE(in_noirq, true);
	return 0;
}

static int test_consumer_resume_noirq(struct device *dev)
{
	WRITE_ONCE(in_noirq, false);
	return 0;
}

static const struct dev_pm_ops test_consumer_pm_ops = {
	NOIRQ_SYSTEM_SLEEP_PM_OPS(test_consumer_suspend_noirq,
				  test_consumer_resume_noirq)
};

static int test_consumer_probe(struct platform_device *pdev)
{
	int ret;

	ret = devm_pm_runtime_enable(&pdev->dev);
	if (ret)
		return ret;

	/*
	 * A stream that ends with a finger on the camera: power_on raises it,
	 * power_off fails, genpd keeps the domain on and the consumer is
	 * suspended.
	 */
	if (fail_close) {
		ret = pm_runtime_resume_and_get(&pdev->dev);
		if (ret)
			return ret;
		pm_runtime_put_sync(&pdev->dev);
	}

	/* A runtime-active consumer is what a streaming IMX471 looks like. */
	if (active)
		return pm_runtime_resume_and_get(&pdev->dev);

	return 0;
}

static void test_consumer_remove(struct platform_device *pdev)
{
	if (active)
		pm_runtime_put_sync(&pdev->dev);
}

static struct platform_driver test_consumer_driver = {
	.probe = test_consumer_probe,
	.remove = test_consumer_remove,
	.driver = {
		.name = DRV_NAME,
		.pm = pm_sleep_ptr(&test_consumer_pm_ops),
	},
};

static int __init genpd_sleep_test_init(void)
{
	int ret;

	test_genpd.name = DRV_NAME;
	test_genpd.power_on = test_power_on;
	test_genpd.power_off = test_power_off;
	/* Off, like the pop-up domain once its consumer has idled. */
	ret = pm_genpd_init(&test_genpd, NULL, true);
	if (ret)
		return ret;

	test_pdev = platform_device_register_simple(DRV_NAME, PLATFORM_DEVID_NONE,
						    NULL, 0);
	if (IS_ERR(test_pdev)) {
		ret = PTR_ERR(test_pdev);
		goto err_genpd;
	}

	ret = pm_genpd_add_device(&test_genpd, &test_pdev->dev);
	if (ret)
		goto err_pdev;

	ret = register_pm_notifier(&test_order_nb);
	if (ret)
		goto err_remove_device;

	ret = register_pm_notifier(&test_pm_nb);
	if (ret)
		goto err_order_notifier;

	ret = register_pm_notifier(&test_veto_nb);
	if (ret)
		goto err_notifier;

	ret = platform_driver_register(&test_consumer_driver);
	if (ret)
		goto err_veto_notifier;

	pr_info(DRV_NAME ": ready (gate=%d legacy=%d active=%d fail_close=%d fail_retract=%d veto=%d)\n",
		gate, legacy, active, fail_close, fail_retract, veto);
	return 0;

err_veto_notifier:
	unregister_pm_notifier(&test_veto_nb);
err_notifier:
	unregister_pm_notifier(&test_pm_nb);
err_order_notifier:
	unregister_pm_notifier(&test_order_nb);
err_remove_device:
	pm_genpd_remove_device(&test_pdev->dev);
err_pdev:
	platform_device_unregister(test_pdev);
err_genpd:
	pm_genpd_remove(&test_genpd);
	return ret;
}
module_init(genpd_sleep_test_init);

static void __exit genpd_sleep_test_exit(void)
{
	platform_driver_unregister(&test_consumer_driver);
	unregister_pm_notifier(&test_veto_nb);
	unregister_pm_notifier(&test_pm_nb);
	unregister_pm_notifier(&test_order_nb);
	cancel_work_sync(&reconcile_work);
	pm_genpd_remove_device(&test_pdev->dev);
	platform_device_unregister(test_pdev);
	pm_genpd_remove(&test_genpd);
}
module_exit(genpd_sleep_test_exit);

MODULE_DESCRIPTION("genpd system-sleep test for the Antumbra pop-up motor patch");
MODULE_LICENSE("GPL");
