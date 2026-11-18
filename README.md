# GigGrade for iPhone: offer grader for gig drivers

The app reads gig offers live from your screen through iOS screen broadcasting (ReplayKit) and Apple's on-device text recognition (Vision). Frames are never saved or uploaded.

## What it does
1. **Grades every offer.** A banner drops down over DoorDash, Uber, Grubhub, Instacart, Spark, etc. with:
   - letter grade (A+ to F), pay, **$/hr and $/mi**
   - **% of your targets** for each (✅ ⚠️ ❌)
   - miles, minutes, and pay **after your cost per mile**
2. **Checks offers from other apps.** If you already have stops on your route, the banner updates to say whether the new offer is:
   - ✅ **ON THE WAY**: it adds ≤ your max-detour miles.
   - ✅ **ENDS NEAR YOUR FINAL STOP**: within your radius.
   - ❌ **OFF ROUTE**

   It also shows **$ per *extra* mile**, the real value of stacking an order.
3. **Route map.** Pull the banner down and tap **Add to route**. The pickup and dropoff go into the cheapest order. The **Route** tab draws you and your stops on Apple Maps road routes, with a **max of 4 stops**. **Navigate** opens the whole multi-stop route in Google Maps.

> iOS doesn't let any app draw a floating card over other apps, so results come as notification banners instead of an overlay.

## What's new in version 2
- **Home tab** (was "Offers"): recording timer top-right, today's good / fair / bad counts, **double sliders** for $/hr and $/mi (red below the left handle, yellow between, green past the right handle), and a **Done** button to close the number pad.
- **Banner content and sounds:** choose which details the offer banner shows, and pick a sound for good, fair and bad offers (4 built-in sounds + iPhone default + silent).
- **Offers tab:** every offer is logged with a screenshot, color coded green / yellow / red, labeled with its app, and organized by day, week, month, quarter or year. Mark each **✓ Accepted** or **✕ Declined** (also from the banner).
- **Earnings tab:** income, average $/hr, average $/mi, miles, after-cost earnings and per-app totals from offers you marked Accepted.
- **Insights tab:** charts and plain-English takeaways (earnings, offers by color, $/hr and $/mi vs your levels, income by app, accepted vs declined) split by hour / day / week / month inside the chosen period.
- **Route tab:** address suggestions as you type (near your location), and a fix for one tap adding both a pickup and a dropoff.

> The Offers log, screenshots and timer are shared between the screen reader and the app through the App Group. With a free Apple ID (Sideloadly) iOS may strip the App Group; if the Offers tab stays empty while banners still appear, that's why. TestFlight fixes it.

## Version 3: cloud sync (Supabase)
The screen reader and the app now share data through your own Supabase project, so everything works
even when iOS doesn't give a sideloaded install shared storage:
- the screen reader loads your targets, banner choices, route and location from the cloud;
- every real offer (and its screenshot) is uploaded and appears in Offers / Earnings / Insights;
- ✓ / ✕ choices, "Accepted + add to route" and the recording timer all sync.
Changes made without signal are queued on the phone and sent later.

Setup (single user, no login): run `supabase/setup.sql` in Supabase → SQL Editor, then add
`SUPABASE_URL` and `SUPABASE_SECRET_KEY` in Codemagic → Environment variables (group **supabase**).
Codemagic writes them into the app at build time — never put them in `Shared/SupabaseSecrets.swift`
in GitHub (the repo is public), and don't share the built .ipa (it contains the secret key).
If the key ever leaks, create a new one in Supabase and rebuild.

## On Windows? Start here → **[WINDOWS-SETUP.md](WINDOWS-SETUP.md)**
GitHub's cloud Macs build the app and deliver it to your iPhone via TestFlight. No Mac needed.

## What you need (building on a Mac instead)
- A **Mac with Xcode 15 or newer**
- An iPhone on iOS 17+
- An Apple ID. A free one works for installing on your own phone, but the app expires after 7 days and must be re-run from Xcode. If Xcode shows a signing error about **App Groups**, or you want to use TestFlight, you need the paid Apple Developer Program.

## Build & install
1. Install XcodeGen: `brew install xcodegen`
2. In `project.yml`, change `BASE_BUNDLE_ID` to something unique, e.g. `com.yourname.giggrade`. That's the only change needed.
3. In this folder, run `xcodegen generate`, then open **GigGrade.xcodeproj**.
4. For **both** targets (GigGrade and GigGradeBroadcast), go to *Signing & Capabilities* and choose your Team.
5. Plug in your iPhone, select it, and press ▶ Run. On the phone, trust the developer under Settings → General → VPN & Device Management.

## Using it
1. Open GigGrade and allow **notifications** and **location** (choose "Always" so it works while you're in your gig apps).
2. Set your targets on the **Offers** tab.
3. Tap the round record button, choose **GigGrade Offer Reader**, then **Start Broadcast**.
   - Tip: add *Screen Recording* to Control Center. Long-press it to start GigGrade without opening the app.
4. Open your gig app. Offers get graded within about 1 second.
5. **Test with a sample offer** shows a banner without needing a real offer.

## Tuning
- Offer screens change often. All reading rules are in `Packages/GigCore/Sources/GigCore/OfferParser.swift`. Add real examples to `Tests/GigCoreTests/LogicTests.swift` and run `swift test` in `Packages/GigCore`.
- Grade cutoffs are in `OfferScorer.swift` (`grade(for:)`).
- If the broadcast stops by itself on an older iPhone, iOS's 50 MB limit for extensions was hit. In `BroadcastExtension/SampleHandler.swift`, change `.accurate` to `.fast`.

## Known limits
- The red recording indicator is visible while it runs. iOS may end the broadcast if the phone gets hot or memory is tight; just restart it.
- Many offers show only a restaurant name or a rough dropoff area. The app searches Apple Maps near you. If it can't find both ends, you still get the grade, but the on-the-way check is skipped. You can add stops by hand in the Route tab.
- The on-the-way verdict uses straight-line distance × 1.3 so it's instant. The Route tab shows real driving miles and minutes.
- The app **only advises**. It never taps Accept. Auto-accepting breaks gig platforms' terms and can get accounts deactivated.

## GitHub check
`.github/workflows/ios.yml` runs the logic tests and compiles the app plus the extension on a Mac runner every time you push.

## Code map
| Path | What it does |
|---|---|
| `BroadcastExtension/SampleHandler.swift` | Live screen frames → Vision OCR (1/sec) |
| `Shared/OfferPipeline.swift` | OCR text → grade banner → on-the-way update |
| `Shared/OfferAlert.swift` | Banner text and the Add-to-route action |
| `Shared/PlaceFinder.swift` | Address/business name → map coordinates |
| `Packages/GigCore/…/OfferParser.swift` | Reads pay / miles / minutes / pickup / dropoff |
| `Packages/GigCore/…/OfferScorer.swift` | $/hr, $/mi, net, letter grade |
| `Packages/GigCore/…/TripPlanner.swift` | 4-stop route, cheapest insertion, on-the-way verdict |
| `Packages/GigCore/…/SharedStore.swift` | Settings and route shared between app and extension |
| `App/RouteView.swift` | Map, road routes, stop list, Google Maps hand-off |
| `App/ContentView.swift` | Settings, start-broadcast button, sample test |
