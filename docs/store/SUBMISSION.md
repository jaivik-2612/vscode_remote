# Submission runbook

The repo carries the complete native scaffold; these are the steps that need
a human, a machine with the platform tools, and the developer accounts.

## One-time setup
1. **Google Play**: register ($25 one-time) at play.google.com/console.
   Personal accounts must run a closed test with 12+ testers for 14 days
   before production release — plan for it.
2. **Apple**: join the Apple Developer Program ($99/yr). Building and
   submitting requires a Mac with Xcode (or a macOS CI runner).
3. Change `appId` in `capacitor.config.json` from the placeholder
   `com.fairshare.app` to an identifier you control, BEFORE first upload —
   it is permanent on both stores. Update `android/app/build.gradle`
   (applicationId, namespace) and the Xcode bundle identifier to match, or
   re-run `npx cap add` after deleting the platform folders.
4. Host `docs/store/PRIVACY.md` at a public URL (GitHub Pages works); both
   stores require a privacy-policy link.

## Every release
```
npm run build:app        # bundle the web app + cap sync into both platforms
```

### Android
1. `npx cap open android` (Android Studio).
2. First time: Build > Generate Signed Bundle, create a keystore, KEEP IT
   SAFE (losing it means losing the app listing).
3. Build the .aab, upload to Play Console.
4. Complete: Data safety (no data collected), content rating, and the
   Financial features declaration (educational calculator — no trading,
   no loans, no advice).

### iOS
1. `npx cap open ios` (Xcode, on a Mac). CocoaPods must be installed.
2. Set your team under Signing & Capabilities.
3. Product > Archive > Distribute to App Store Connect.
4. In App Store Connect: fill the listing from `LISTING.md`, set the
   privacy label to "Data Not Collected", run TestFlight, submit.

Screenshots for both stores can be produced from the web build at device
sizes (e.g. 1290x2796 for 6.7" iPhone) — the page is responsive.
