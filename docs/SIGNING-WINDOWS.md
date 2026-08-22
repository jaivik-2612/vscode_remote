# Signing FairShare on Windows

Everything here runs in **PowerShell** on a Windows machine with Android
Studio installed. No Mac, no Linux, no WSL.

The one thing to understand before starting: **the upload keystore you make
in step 1 is the app's identity for its entire life.** Lose it and you cannot
ship another update to the same listing — you would have to publish a new
app under a new package name and lose every install and review. Back it up
before you do anything else with it.

---

## 0. Where the tools live

`keytool` is not on PATH. It ships inside Android Studio's bundled JDK:

```
C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe
```

(Older Studio installs use `...\Android Studio\jre\bin\`. A standalone JDK
puts it in `C:\Program Files\Java\jdk-<version>\bin\`.)

The path contains spaces, so it must be quoted and invoked with PowerShell's
call operator `&`. Every command below does this. To save typing:

```powershell
$keytool = 'C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe'
```

---

## 1. Generate the upload keystore — once, ever

```powershell
New-Item -ItemType Directory -Force 'C:\keys' | Out-Null

& $keytool -genkeypair -v `
  -keystore 'C:\keys\fairshare-upload.jks' `
  -alias fairshare-upload `
  -keyalg RSA -keysize 2048 -validity 10000 `
  -dname 'CN=Jaivik Patel, OU=FairShare, O=FairShare, L=City, ST=State, C=CA'
```

`keytool` will not create a missing folder, hence the `New-Item` first.

**Let it prompt you for the password. Do not pass `-storepass` on the command
line.** PowerShell interpolates inside double quotes, so a password
containing `$` becomes something else entirely, and you will not find out
until CI reports a wrong password weeks later. Typed-at-the-prompt passwords
also stay out of your PSReadLine history.

**The store password and the key password must be the same string.** On
JDK 9 and later `keytool` writes a PKCS12 keystore even when the filename
ends `.jks`, and PKCS12 cannot hold two different passwords — it prints a
warning and quietly uses the store password for both. Just press Enter when
it offers to reuse the store password for the key.

Now record the fingerprint, so you can prove later that the right key signed
your bundle:

```powershell
& $keytool -list -v -keystore 'C:\keys\fairshare-upload.jks' -alias fairshare-upload
```

Copy the `SHA256:` line somewhere safe.

### Back it up now

Copy `fairshare-upload.jks` and its password to at least two places that are
not this laptop — a password manager entry with the file attached is ideal.
Google cannot recover it for you.

---

## 2. Encode it for GitHub

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\keys\fairshare-upload.jks')) | Set-Clipboard
```

That is one unbroken line on your clipboard, ready to paste. Piping straight
to the clipboard avoids every file-encoding trap below.

### Three ways this goes wrong — all silent until CI fails

| Do not | Why |
|---|---|
| `Get-Content -Raw` to read the keystore | It reads the file as **text**, mangling any byte that is not valid in the assumed encoding into `U+FFFD`. The base64 looks fine and decodes to a corrupt file. Only `[IO.File]::ReadAllBytes` reads raw bytes. |
| `certutil -encode` | Wraps at 64 columns and adds `-----BEGIN CERTIFICATE-----` armor. The workflow now strips both, so this will actually survive — but there is no reason to use it. |
| `> file.b64` or `Out-File` | Windows PowerShell 5.1 writes **UTF-16LE with a BOM** — a NUL byte between every character. Unusable. (PowerShell 7 changed this default; Windows ships 5.1 as "Windows PowerShell".) |

### Verify the round trip before you trust it

```powershell
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\keys\fairshare-upload.jks'))
[IO.File]::WriteAllBytes('C:\keys\roundtrip.jks', [Convert]::FromBase64String($b64.Trim()))
(Get-FileHash 'C:\keys\fairshare-upload.jks' -Algorithm SHA256).Hash -eq `
  (Get-FileHash 'C:\keys\roundtrip.jks' -Algorithm SHA256).Hash
```

This must print `True`. Then delete `roundtrip.jks`.

---

## 3. Add the four repository secrets

GitHub → the repo → **Settings → Secrets and variables → Actions → New
repository secret**. The names must match exactly:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | the clipboard contents from step 2 |
| `ANDROID_KEYSTORE_PASSWORD` | the password you typed at the prompt |
| `ANDROID_KEY_ALIAS` | `fairshare-upload` |
| `ANDROID_KEY_PASSWORD` | **the same password again** (see PKCS12 above) |

### What "no secrets" looks like, so you don't misread it

Until these exist, the Android workflow still runs the entire release path —
it builds the bundle, signs it with a throwaway key it generates on the spot,
verifies the signature, then **deletes the bundle** and uploads only the
debug APK. A green run with no `fairshare-release-aab-*` artifact is the
expected behaviour, not a broken build. It exists so the signing chain is
proven continuously rather than being attempted for the first time on the day
it matters.

Once the secrets are set, the same run uploads
`fairshare-release-aab-v<versionCode>`.

---

## 4. Build and download the bundle

Actions → **Android build** → *Run workflow*. You can set:

- **versionName** — what users see, e.g. `1.0.0`
- **versionCode** — Play rejects any code it has already seen. Left blank it
  uses the workflow run number, which only ever increases.

When it finishes, open the run and download the artifact from the
**Artifacts** section. The browser saves a `.zip`; right-click → **Extract
All** properly rather than dragging the `.aab` out of Explorer's preview.

With the GitHub CLI (`winget install --id GitHub.cli`, then `gh auth login`)
it is one command and no zip:

```powershell
gh run download --name fairshare-release-aab-v42 --dir C:\builds\v42
```

---

## 5. Verify it before uploading to Play

`apksigner` **cannot read app bundles** — jarsigner and keytool are the tools
for `.aab` files.

```powershell
& $keytool -printcert -jarfile 'C:\builds\v42\app-release.aab'
```

Compare the `SHA256:` fingerprint against the one you recorded in step 1. If
they match, the secret round-tripped correctly and the right key signed it.

---

## 6. Test it on a real phone

**Easiest smoke test** — the debug APK from the same run, no keystore or Java
needed:

```powershell
$env:Path += ";$env:LOCALAPPDATA\Android\Sdk\platform-tools"
adb install -r C:\builds\app-debug.apk
```

On the phone first: **Settings → About phone**, tap **Build number** seven
times, then **Settings → System → Developer options → USB debugging**.
Connect by USB, set the connection to **File Transfer / MTP** (charging-only
blocks the handshake), and tap **Allow** on the RSA fingerprint prompt,
ticking *Always allow from this computer*. `adb devices` should then show
`device` rather than `unauthorized`.

The debug build installs as `io.github.jaivik2612.fairshare.debug`, a
separate app from the release build, so both can sit on the phone at once.

**Testing the real signed bundle** — the honest way is Play Console →
**Internal app sharing**: upload the `.aab`, get a link, open it on the
phone. That installs exactly what Play would deliver, split APKs and all.

Or convert locally with [bundletool](https://github.com/google/bundletool/releases)
(`bundletool-all-1.18.3.jar`; it is a jar, there is no `.exe`):

```powershell
& 'C:\Program Files\Android\Android Studio\jbr\bin\java.exe' -jar C:\tools\bundletool-all-1.18.3.jar `
  build-apks --bundle=C:\builds\v42\app-release.aab --output=C:\builds\v42\app.apks `
  --mode=universal --ks=C:\keys\fairshare-upload.jks --ks-key-alias=fairshare-upload

& 'C:\Program Files\Android\Android Studio\jbr\bin\java.exe' -jar C:\tools\bundletool-all-1.18.3.jar `
  install-apks --apks=C:\builds\v42\app.apks
```

Use Studio's bundled `java.exe` explicitly if an old Java 8 is first on your
PATH, or bundletool fails with `UnsupportedClassVersionError`.

---

## If you ever lose the keystore

You are not completely sunk **if you enrolled in Play App Signing** (which is
mandatory now, so you will have). Google holds the actual app signing key;
yours is only the *upload* key. Play Console → **Test and release → Setup →
App integrity → App signing** lets you request an upload key reset: you
generate a new keystore, export its certificate with

```powershell
& $keytool -export -rfc -keystore 'C:\keys\fairshare-upload-2.jks' `
  -alias fairshare-upload -file 'C:\keys\upload_certificate.pem'
```

and send that `.pem` to Google. It takes a couple of days. Losing the *app
signing* key, by contrast, is unrecoverable — which is exactly why letting
Google hold it is the right call.
