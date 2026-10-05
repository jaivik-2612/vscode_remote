// SPDX-License-Identifier: GPL-2.0-only
/*
 * genpd system-sleep test for Antumbra's pop-up motor patch
 * (device/oneplus-hotdog/kernel/patches/0102-*.patch).
 *
 * The pop-up camera motor is a generic PM domain whose power_on and
 * power_off callbacks drive the motor over I2C-read Hall sensors. This
 * module registers a domain with logging callbacks and one runtime-PM
 * consumer, so a suspend-to-idle cycle in the VM shows:
 *
 *  - that genpd calls the provider's power_on in resume_noirq for a domain
 *    that was off (and power_off in suspend_noirq for one that was on),
 *    where the real driver cannot read its Hall sensors;
 *  - that the patch's sleeping gate, mirrored here, turns every such call
 *    into a recorded state change without motion;
 *  - that a consumer held active across sleep (a stream) gets the camera
 *    raised again by the post-resume reconcile, and only then.
 *
 * "Motion" is a counter: the fake camera is raised by an ungated power_on
 * and retracted by an ungated power_off or by the PM_SUSPEND_PREPARE
 * retract. Results are read-only module parameters; see README.md.
 */

#include <linux/cleanup.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include <linux/pm.h>
#include <linux/pm_domain.h>
#include <linux/pm_runtime.h>
#include <linux/suspend.h>
#include <linux/workqueue.h>

#define DRV_NAME "antumbra-genpd-sleep-test"

static bool gate = true;
module_param(gate, bool, 0444);
MODULE_PARM_DESC(gate, "Mirror the 0102 sleeping gate (0: unpatched behaviour)");

static bool active;
module_param(active, bool, 0444);
MODULE_PARM_DESC(active, "Hold the consumer runtime-active, like a stream kept across sleep");

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
static bool raised;
module_param(raised, bool, 0444);
MODULE_PARM_DESC(raised, "Fake camera position");
static bool domain_on;
module_param(domain_on, bool, 0444);
MODULE_PARM_DESC(domain_on, "Domain state as genpd last asked for it");

/* Set between the consumer's own suspend_noirq and resume_noirq. */
static bool in_noirq;

static DEFINE_MUTEX(test_lock);
static bool sleeping;
static bool reopen_pending;

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
		reopen_pending = consumer;
		pr_info(DRV_NAME ": power_on gated (noirq=%d consumer_active=%d)\n",
			noirq, consumer);
		return 0;
	}

	/* hotdog-popup-motor.c would run its opening course here. */
	if (noirq)
		noirq_moves++;
	raised = true;
	domain_on = true;
	reopen_pending = false;
	pr_info(DRV_NAME ": power_on raises the camera (noirq=%d)\n", noirq);
	return 0;
}

static int test_power_off(struct generic_pm_domain *domain)
{
	bool noirq = READ_ONCE(in_noirq);

	guard(mutex)(&test_lock);
	if (noirq)
		noirq_power_off++;
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
	raised = false;
	domain_on = false;
	pr_info(DRV_NAME ": power_off retracts the camera (noirq=%d)\n", noirq);
	return 0;
}

static void test_reconcile(struct work_struct *work)
{
	guard(mutex)(&test_lock);
	if (sleeping || !reopen_pending)
		return;

	reopen_pending = false;
	if (!domain_on || raised)
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
		scoped_guard(mutex, &test_lock) {
			if (raised) {
				raised = false;
				prepare_retracts++;
				reopen_pending = domain_on;
				pr_info(DRV_NAME ": retract before sleep\n");
			}
			sleeping = true;
		}
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

	ret = register_pm_notifier(&test_pm_nb);
	if (ret)
		goto err_remove_device;

	ret = platform_driver_register(&test_consumer_driver);
	if (ret)
		goto err_notifier;

	pr_info(DRV_NAME ": ready (gate=%d active=%d)\n", gate, active);
	return 0;

err_notifier:
	unregister_pm_notifier(&test_pm_nb);
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
	unregister_pm_notifier(&test_pm_nb);
	cancel_work_sync(&reconcile_work);
	pm_genpd_remove_device(&test_pdev->dev);
	platform_device_unregister(test_pdev);
	pm_genpd_remove(&test_genpd);
}
module_exit(genpd_sleep_test_exit);

MODULE_DESCRIPTION("genpd system-sleep test for the Antumbra pop-up motor patch");
MODULE_LICENSE("GPL");
