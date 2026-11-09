// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.Manifest
import android.app.Application
import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.SystemClock
import android.provider.Telephony
import android.telecom.TelecomManager
import android.telephony.CarrierConfigManager
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * WEL9 on Android (README, "Apps: location, phone state and carrier
 * privileges"): [AppRules]' plan, applied by the device owner with
 * setPermissionGrantState (POLICY_FIXED either way) and setApplicationHidden.
 *
 * A pass reads the installed apps, the session's choice, the default phone
 * and SMS apps, the carrier configuration and the module's live list (MOD10,
 * in memory) again each time, so passes may
 * come in any order and the last one is right. They run one at a time on
 * their own thread: at boot (LOCKED_BOOT_COMPLETED first, then
 * BOOT_COMPLETED), on becoming the device owner and at Start (the baseline,
 * [Policies.applyBaseline]), at the process's start, after Start, when the
 * default phone or SMS app changes, and at each install or update (the new
 * package alone first, then every app), carrier-configuration change
 * ([AppWatch]) and change of the module's live list ([LiveList],
 * StateProvider). No step throws: each is caught on its own, and the log
 * names no app.
 */
object AppPolicies {
    private const val TAG = "AntumbraApps"

    /** At shutdown, how long the chosen apps' denials may take; the next boot denies them anyway. */
    private const val SHUTDOWN_WAIT_MS = 6_000L

    /** Every package, whether or not it runs in direct boot (a pass runs at LOCKED_BOOT_COMPLETED); hidden ones are not listed. */
    private const val LIST_FLAGS = PackageManager.GET_PERMISSIONS or PackageManager.MATCH_DIRECT_BOOT_AWARE or
        PackageManager.MATCH_DIRECT_BOOT_UNAWARE
    private const val FLAGS = LIST_FLAGS or PackageManager.GET_SIGNING_CERTIFICATES

    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "antumbra-apps").apply { isDaemon = true } }
    private val queued = AtomicBoolean(false)

    /** Closed at shutdown: no grant lands after the shutdown's denials begin. */
    private val gate = GrantGate()

    /**
     * The last pass ran in this session and took location away from every
     * app the person installed but the chosen ones. Only then does Welcome
     * switch Location on for the chosen apps ([PositionPlatform.appsReady]).
     */
    @Volatile
    var locationReady = false
        private set

    /** The default phone and SMS apps the last pass read ([AppWatch.rolesLook] compares). */
    @Volatile
    var lastRoles: RoleHolders? = null
        private set

    /** A pass over every app, on the apps' thread; a pass still waiting to begin covers this request too. */
    fun request(context: Context, why: String) {
        val app = context.applicationContext
        if (!queued.compareAndSet(false, true)) return
        worker.execute {
            queued.set(false)
            try {
                pass(app, why, null)
            } catch (e: Exception) {
                Log.w(TAG, "$why: the pass stopped (${e.javaClass.simpleName})")
            }
        }
    }

    /** A pass over one package just installed or updated, ahead of the pass over every app. */
    fun requestPackage(context: Context, pkg: String) {
        val app = context.applicationContext
        worker.execute {
            try {
                pass(app, "install", pkg)
            } catch (e: Exception) {
                Log.w(TAG, "install: the pass stopped (${e.javaClass.simpleName})")
            }
        }
    }

    /** One pass; [only] limits it to that package (its steps are those of a pass over every app). */
    private fun pass(context: Context, why: String, only: String?) {
        val dpm = context.getSystemService(DevicePolicyManager::class.java)
        if (!dpm.isDeviceOwnerApp(context.packageName)) return
        val admin = AdminReceiver.component(context)
        val started = Session.current().started
        val chosen = if (started) Session.locationApps() else null
        val apps = if (only == null) installedApps(context) else listOfNotNull(installedApp(context, only))
        val roles = roleHolders(context)
        val privileged = if (roles == null) null else CarrierConfigSource(context).privileged(apps)
        // MOD10's live list from root, the second source: the SIM's own access rules and an eSIM profile's.
        val live = if (roles == null) emptySet() else LiveList.privileged(apps)
        val plan = AppRules.plan(apps, context.packageName, chosen, roles, privileged.orEmpty() + live)
        var failed = 0
        var locationLeft = 0
        for (s in plan.steps) {
            // Shutdown has denied the chosen apps: a pass still running grants nothing after it.
            val ok = if (s.grant == Grant.GRANTED) gate.grant { setGrant(dpm, admin, s) } else setGrant(dpm, admin, s)
            if (!ok) {
                failed++
                if (s.grant == Grant.DENIED && s.permission in AppRules.LOCATION) locationLeft++
            }
        }
        for (pkg in plan.refuse) {
            val hidden = try {
                dpm.setApplicationHidden(admin, pkg, true)
            } catch (e: Exception) {
                false
            }
            if (!hidden) failed++
        }
        // Welcome's own phone-state block on the current default apps, back to Android's default; never granted.
        val lifts = AppRules.liftsToApply(plan.lifts) { policyState(dpm, admin, it) }
        for (l in lifts) {
            val ok = try {
                dpm.setPermissionGrantState(admin, l.pkg, l.permission, DevicePolicyManager.PERMISSION_GRANT_STATE_DEFAULT)
            } catch (e: Exception) {
                false
            }
            if (!ok) failed++
        }
        if (only == null) {
            lastRoles = roles
            locationReady = started && Session.current().started && locationLeft == 0 && !gate.isClosed()
        }
        // How many of the refused the module's live list named: never how many it names.
        val byLiveList = plan.refuse.count { it in live }
        Log.i(
            TAG,
            "$why: ${plan.steps.size} grant states, ${plan.refuse.size} refused ($byLiveList of them by the module's list), ${lifts.size} lifted, $failed failed" +
                (if (privileged == null && roles != null) "; the carrier configuration could not be read" else "") +
                (if (plan.rolesUnknown) "; the default phone or SMS app could not be read: no phone-state step and no refusal" else ""),
        )
    }

    private fun setGrant(dpm: DevicePolicyManager, admin: ComponentName, s: GrantStep): Boolean = try {
        dpm.setPermissionGrantState(
            admin, s.pkg, s.permission,
            if (s.grant == Grant.GRANTED) DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED else DevicePolicyManager.PERMISSION_GRANT_STATE_DENIED,
        )
    } catch (e: Exception) {
        Log.w(TAG, "a grant state could not be set (${e.javaClass.simpleName})")
        false
    }

    /** The device owner's state for a lift's permission; DEFAULT (nothing to lift) when it cannot be read. */
    private fun policyState(dpm: DevicePolicyManager, admin: ComponentName, l: Lift): PolicyState = try {
        when (dpm.getPermissionGrantState(admin, l.pkg, l.permission)) {
            DevicePolicyManager.PERMISSION_GRANT_STATE_DENIED -> PolicyState.DENIED
            DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED -> PolicyState.GRANTED
            else -> PolicyState.DEFAULT
        }
    } catch (e: Exception) {
        PolicyState.DEFAULT
    }

    /**
     * At shutdown (its last step, after Wi-Fi's): grants stop for good, then
     * the chosen apps' location is denied again, waiting [SHUTDOWN_WAIT_MS]
     * at most. Returns how many denials did not land; the next boot's pass
     * denies them anyway.
     */
    fun atShutdown(context: Context): Int {
        locationReady = false
        val steps = AppRules.atShutdown(Session.locationApps(), context.packageName)
        val dpm = context.getSystemService(DevicePolicyManager::class.java)
        val admin = AdminReceiver.component(context)
        val left = AtomicInteger(steps.size)
        thread(name = "antumbra-apps-shutdown", isDaemon = true) {
            // Waits for a grant under way, so that no grant lands after these denials.
            gate.close()
            if (dpm.isDeviceOwnerApp(context.packageName)) {
                for (s in steps) if (setGrant(dpm, admin, s)) left.decrementAndGet()
            }
        }.join(SHUTDOWN_WAIT_MS)
        return left.get()
    }

    /** The installed packages as [AppRules] sees them, certificates included. */
    fun installedApps(context: Context): List<InstalledApp> =
        context.packageManager.getInstalledPackages(PackageManager.PackageInfoFlags.of(FLAGS.toLong())).map { app(it) }

    private fun installedApp(context: Context, pkg: String): InstalledApp? = try {
        app(context.packageManager.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(FLAGS.toLong())))
    } catch (e: PackageManager.NameNotFoundException) {
        null
    }

    private fun app(info: PackageInfo, label: String = info.packageName): InstalledApp = InstalledApp(
        pkg = info.packageName,
        // Without its ApplicationInfo it counts as a system app: left alone.
        system = isSystem(info),
        certs = signatures(info),
        requested = info.requestedPermissions?.toSet().orEmpty(),
        label = label,
    )

    private fun isSystem(info: PackageInfo): Boolean = info.applicationInfo.let { it == null || it.flags and ApplicationInfo.FLAG_SYSTEM != 0 }

    /** As UiccAccessRule.getSignatures: the signing history, or every signer when there are several. */
    private fun signatures(info: PackageInfo): List<ByteArray> {
        val s = info.signingInfo ?: return emptyList()
        val signatures = if (s.hasMultipleSigners()) s.apkContentsSigners else s.signingCertificateHistory
        return signatures?.map { it.toByteArray() }.orEmpty()
    }

    /**
     * The default phone and SMS apps, read again at every pass: a device
     * owner may not watch the role holders (RoleManager's listener needs
     * OBSERVE_ROLE_HOLDERS, signature|installer|module). Null when either
     * cannot be read (none, or an exception).
     */
    fun roleHolders(context: Context): RoleHolders? = try {
        val dialer = context.getSystemService(TelecomManager::class.java)?.defaultDialerPackage
        val sms = Telephony.Sms.getDefaultSmsPackage(context)
        if (dialer.isNullOrEmpty() || sms.isNullOrEmpty()) null else RoleHolders(dialer, sms)
    } catch (e: Exception) {
        null
    }

    /**
     * The apps the Welcome screen offers for location, with their labels;
     * off the main thread, and only when [AppWatch.generation] has changed.
     * System apps are dropped before any label is loaded, and no
     * certificate is read.
     */
    fun offered(context: Context): List<LocationApp> = try {
        val pm = context.packageManager
        val apps = pm.getInstalledPackages(PackageManager.PackageInfoFlags.of(LIST_FLAGS.toLong()))
            .filter { !isSystem(it) && it.packageName != context.packageName }
            .filter { info -> info.requestedPermissions?.any { it == AppRules.COARSE || it == AppRules.FINE } == true }
            .map { info -> app(info, label = info.applicationInfo?.let { pm.getApplicationLabel(it).toString() } ?: info.packageName) }
        AppRules.offered(apps, context.packageName, roleHolders(context))
    } catch (e: Exception) {
        emptyList()
    }
}

/**
 * The carrier configuration's certificate list
 * (KEY_CARRIER_CERTIFICATE_STRING_ARRAY), every SIM slot's: the one of
 * Android's three sources of carrier privileges a device owner can read
 * (READ_PHONE_STATE, which Welcome holds). A slot's list counts only when a
 * carrier's own configuration has been applied
 * (CarrierConfigManager.isConfigForIdentifiedCarrier), as
 * CarrierPrivilegesTracker has it. Only the list is read, never an
 * identifier; a slot's subscription number is a local counter.
 */
class CarrierConfigSource(private val context: Context) : PrivilegeSource {
    override fun privileged(apps: List<InstalledApp>): Set<String>? = slots()?.let { CarrierConfigRules(it).privileged(apps) }

    /** Null when it could not be read. */
    fun slots(): List<SlotConfig>? {
        if (context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) return null
        return try {
            val ccm = context.getSystemService(CarrierConfigManager::class.java) ?: return null
            val tm = context.getSystemService(TelephonyManager::class.java) ?: return null
            (0 until tm.activeModemCount)
                .map { SubscriptionManager.getSubscriptionId(it) }
                .filter { SubscriptionManager.isValidSubscriptionId(it) }
                .map { sub ->
                    val bundle = ccm.getConfigForSubId(sub, KEY)
                    SlotConfig(CarrierConfigManager.isConfigForIdentifiedCarrier(bundle), bundle.getStringArray(KEY)?.toList())
                }
        } catch (e: Exception) {
            null
        }
    }

    companion object {
        const val KEY = CarrierConfigManager.KEY_CARRIER_CERTIFICATE_STRING_ARRAY
    }
}

/**
 * What brings a pass besides boot and Start, registered from the process's
 * start (WelcomeApp): each install or update (ACTION_PACKAGE_ADDED and
 * ACTION_PACKAGE_REPLACED, sent by system_server: the package alone first,
 * then every app), each change of the carrier configuration, through
 * CarrierConfigManager's listener, and a change of the default phone app
 * (TelecomManager.ACTION_DEFAULT_DIALER_CHANGED, sent by system_server) or
 * of either default app seen by the screens' polls ([rolesLook]). Each
 * install, update or removal also tells the Welcome screen to read its
 * list again ([generation]).
 *
 * Not a receiver for ACTION_CARRIER_CONFIG_CHANGED: the phone process
 * (uid 1001) sends it, and Android lets only root and system_server reach a
 * receiver that is not exported, in the manifest or registered with
 * RECEIVER_NOT_EXPORTED (BroadcastSkipPolicy, checkComponentPermission). The
 * listener is TelephonyRegistry's, called for every change, and needs no
 * permission.
 */
object AppWatch {
    private const val TAG = "AntumbraApps"
    private var started = false

    /** Changes with each install, update or removal, and with the default apps: the Welcome screen's list is read again then. */
    @Volatile
    var generation = 0
        private set

    private fun changed() {
        generation++
    }

    @Synchronized
    fun start(app: Application) {
        if (started) return
        started = true
        try {
            app.registerReceiver(
                object : BroadcastReceiver() {
                    override fun onReceive(context: Context, intent: Intent) {
                        when (intent.action) {
                            Intent.ACTION_PACKAGE_ADDED, Intent.ACTION_PACKAGE_REPLACED -> {
                                // The new package first (location, phone state, carrier privileges), then every app.
                                intent.data?.schemeSpecificPart?.let { AppPolicies.requestPackage(context, it) }
                                AppPolicies.request(context, "install")
                                changed()
                            }
                            Intent.ACTION_PACKAGE_REMOVED -> changed()
                        }
                    }
                },
                IntentFilter().apply {
                    addAction(Intent.ACTION_PACKAGE_ADDED)
                    addAction(Intent.ACTION_PACKAGE_REPLACED)
                    addAction(Intent.ACTION_PACKAGE_REMOVED)
                    addDataScheme("package")
                },
                Context.RECEIVER_NOT_EXPORTED,
            )
            app.registerReceiver(
                object : BroadcastReceiver() {
                    override fun onReceive(context: Context, intent: Intent) {
                        if (intent.action == TelecomManager.ACTION_DEFAULT_DIALER_CHANGED) {
                            changed()
                            AppPolicies.request(context, "default apps")
                        }
                    }
                },
                IntentFilter(TelecomManager.ACTION_DEFAULT_DIALER_CHANGED),
                Context.RECEIVER_NOT_EXPORTED,
            )
        } catch (e: Exception) {
            Log.w(TAG, "the install listener could not be registered", e)
        }
        try {
            app.getSystemService(CarrierConfigManager::class.java)
                ?.registerCarrierConfigChangeListener(app.mainExecutor) { _, _, _, _ ->
                    AppPolicies.request(app, "carrier configuration")
                }
        } catch (e: Exception) {
            Log.w(TAG, "the carrier-configuration listener could not be registered", e)
        }
        AppPolicies.request(app, "process start")
    }

    /** How often a change seen by [rolesLook] may bring a pass. */
    const val ROLES_PASS_MS = 30_000L

    @Volatile
    private var lastRolesPass: Long? = null

    /**
     * The default phone and SMS apps read again (two calls, off the main
     * thread): when they differ from the last pass's, a pass (Welcome's own
     * block on the new default lifted, the former one denied again), at most
     * once per [ROLES_PASS_MS], and the Welcome screen's list read again.
     * From the screens' polls.
     */
    fun rolesLook(context: Context) {
        val now = AppPolicies.roleHolders(context) ?: return
        if (now == AppPolicies.lastRoles) return
        val t = SystemClock.elapsedRealtime()
        if (!AppRules.due(lastRolesPass, t, ROLES_PASS_MS)) return
        lastRolesPass = t
        changed()
        AppPolicies.request(context, "default apps")
    }
}
