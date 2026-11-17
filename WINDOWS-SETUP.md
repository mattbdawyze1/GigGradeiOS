# Building GigGrade for iPhone from a Windows PC

Apple's iPhone build tools only run on macOS. You don't need to own a Mac, though: **GitHub's cloud Macs build the app for you**, and you do every step in a web browser on Windows.

There are two ways to get the app onto your iPhone:

| | **A. TestFlight (recommended)** | **B. Sideloadly (free)** |
|---|---|---|
| Cost | Apple Developer Program (paid, yearly) | Free Apple ID |
| Install | TestFlight app on iPhone, no cable | USB cable + Sideloadly on Windows |
| Lasts | 90 days per build (re-run to refresh) | 7 days, then re-sideload |
| Screen-reader extension | ✅ Fully supported | ⚠️ May not work. Free signing can drop the App Group the reader needs. |

---

## Step 0: Put the project on GitHub (both options)
1. Create a free account at github.com and install **GitHub Desktop** (desktop.github.com).
2. Unzip `GigGrade-iPhone.zip`. In GitHub Desktop, choose *File → Add local repository*, pick the `GigGradeiOS` folder, and click "create a repository" when prompted. Then **Publish repository**.
   - A public repo gets free cloud-Mac build minutes. On a private repo, Mac minutes count extra against your free allowance. Each build takes roughly 10–15 minutes.
3. On github.com, open your repo and go to the **Actions** tab. Enable workflows if asked. The **"iOS build check"** workflow runs automatically and confirms everything compiles.

---

## Option A: TestFlight (recommended)

### 1. Apple account setup (one time, in your browser)
1. Join the **Apple Developer Program** at developer.apple.com/programs.
2. **Pick your bundle ID**, e.g. `com.yourname.giggrade`. It has to be unique.
3. Go to developer.apple.com → *Certificates, IDs & Profiles* → **Identifiers**:
   - Click **+** → *App Groups* → create `group.com.yourname.giggrade`
   - Click **+** → *App IDs* → *App* → create `com.yourname.giggrade` with **App Groups** checked. Then click *Configure* and select your group.
   - Repeat for `com.yourname.giggrade.broadcast`, with the same App Group.
4. Go to **appstoreconnect.apple.com** → *Apps* → **+ New App**:
   - Platform: iOS
   - Name: anything unique, e.g. "GigGrade – Your Name"
   - Bundle ID: `com.yourname.giggrade`
   - SKU: anything
5. Still in App Store Connect, go to *Users and Access* → **Integrations** → *App Store Connect API* → **Team Keys** → **+**:
   - Name: GitHub. Access: **Admin**. Admin is needed so the cloud Mac can create signing certificates.
   - **Download** the `.p8` file. You can only download it once.
   - Note the **Key ID** and the **Issuer ID** shown on that page.
6. Find your **Team ID** at developer.apple.com → *Account* → **Membership details**.

### 2. Give GitHub those details
In your GitHub repo, go to **Settings → Secrets and variables → Actions**.

**Secrets** tab → *New repository secret* for each:
| Name | Value |
|---|---|
| `APPLE_TEAM_ID` | your Team ID |
| `ASC_KEY_ID` | Key ID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8` | Open the `.p8` file in **Notepad** and paste **all** of it, including the BEGIN/END lines |

**Variables** tab → *New repository variable*:
| Name | Value |
|---|---|
| `BASE_BUNDLE_ID` | `com.yourname.giggrade` |

### 3. Build it
**Actions** tab → **Build & send to TestFlight** → **Run workflow**. When it turns green, App Store Connect takes another 5–30 minutes to "process" the build.

### 4. Install on your iPhone
1. In App Store Connect → your app → **TestFlight** → *Internal Testing* → **+**, create a group and add yourself.
2. On the iPhone, install **TestFlight** from the App Store, accept the invite, and tap **Install**.
3. For updates, run the workflow again and TestFlight offers the new build.

---

## Option B: Sideloadly (free)
1. On GitHub, open **Actions** → the latest green **iOS build check** run → under *Artifacts*, download **GigGrade-unsigned-ipa** and unzip it to get `GigGrade-unsigned.ipa`.
2. On Windows, install **Sideloadly** from sideloadly.io. It also needs iTunes and iCloud **downloaded from apple.com**, not the Microsoft Store versions.
3. Plug in your iPhone and tap *Trust*. In Sideloadly, drop in the `.ipa`, enter your Apple ID, and press **Start**.
4. On the iPhone:
   - Turn on **Settings → Privacy & Security → Developer Mode** (it restarts).
   - Then go to **Settings → General → VPN & Device Management**, tap your Apple ID, and tap *Trust*.
5. The app expires after 7 days; repeat step 3.

If **GigGrade Offer Reader** doesn't appear when you tap the record button, or offers never get graded, free signing has stripped what the screen reader needs. Use Option A.

---

## Editing the code on Windows
You can edit any `.swift` file in **VS Code**, commit and push with GitHub Desktop, and the cloud Mac re-checks it. If something fails, open the red run on the Actions tab and copy the error text. Paste it to Claude and it can tell you what to fix.
