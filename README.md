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
3. **Route map.** Pull the banner down and tap **Add to route**. The pickup and dropoff go into the cheapest order. The **Route** tab draws you and your stops on Apple Maps road routes, with a **max of 9 stops** (drag to reorder) — the most Google Maps can navigate in one go. **Navigate** opens the whole multi-stop route in Google Maps.

> iOS doesn't let any app draw a floating card over other apps, so results come as notification banners instead of an overlay.

## What's new in version 2
- **Home tab** (was "Offers"): recording timer top-right, today's good / fair / bad counts, **double sliders** for $/hr and $/mi (red below the left handle, yellow between, green past the right handle), and a **Done** button to close the number pad.
- **Banner content and sounds:** choose which details the offer banner shows, and pick a sound for good, fair and bad offers (4 built-in sounds + iPhone default + silent).
- **Offers tab:** every offer is logged with a screenshot, color coded green / yellow / red, labeled with its app, and organized by day, week, month, quarter or year. Mark each **✓ Accepted** or **✕ Declined** (also from the banner).
- **Earnings tab:** income, average $/hr, average $/mi, miles, after-cost earnings and per-app totals from offers you marked Accepted.
- **Insights tab:** charts and plain-English takeaways (earnings, offers by color, $/hr and $/mi vs your levels, income by app, accepted vs declined) split by hour / day / week / month inside the chosen period.
- **Route tab:** address suggestions as you type (near your location), and a fix for one tap adding both a pickup and a dropoff.

> The Offers log, screenshots and timer are shared between the screen reader and the app through the App Group. With a free Apple ID (Sideloadly) iOS may strip the App Group; if the Offers tab stays empty while banners still appear, that's why. TestFlight fixes it.

## Version 5.6.1

- Uber "Add a delivery" offers (the price has a "+" in front, e.g. "+ $1.91" for "+ 13 min (+ 1.4 mi) total") are read now. A "+" amount is only ignored when there's another price on screen (like "+ $2.00 Peak pay" next to the real pay). These offers are graded on the extra pay for the extra minutes and miles.

## Version 5.6: stop names and addresses

- Every stop now has two fields: a **name** (store or customer) and a **full address**. Stops added by 👓 or by hand fill both.
- Route tab rows look the same when collapsed ("3. Mike R · 15 France St", cut off with … if long). **Tap a row** to expand it and see the full name and full address; tap again to collapse.
- **Swipe left** on a stop: 🗑 Delete or ✏️ Edit. Edit lets you fix the name and the address (with address suggestions as you type, like adding a stop by hand). Choosing a suggestion, or saving a typed address, moves the pin to the new spot. Return/Done on the keyboard, or the Done button above it, puts the keyboard away.
- Older stops that had "name · street" in one label are split into the two fields automatically.

## Version 5.5: 👓 for DoorDash

- 👓 now also appears on DoorDash offers (after you mark them ✓). While it's on, GigGrade reads:
  - **"Your route"** (gear icon): every stop in order. Tap each stop to open its pop-up so the full address is read (hold ~2 s), then go back.
  - **The task screen** ("Pick up by …" dragged up shows who you're picking up for; "Deliver by …" shows the customer's address and which store their order is from). These link dropoffs to stores and fill in addresses.
- Leaving "Your route" for 5 seconds finishes the reading, same as Uber's Trip Guide. An offer popping up ends it early.
- No address is added twice, and nothing already in your route is added again (same house number + street, same spot, or same name), the same as Uber. A store listed twice becomes one pickup with 2 orders; two orders going to one address become one dropoff, linked to both pickups.
- A dropoff can be linked to more than one pickup: in the Route tab, tap 🔗 on it and tick each pickup (it shows both letters, e.g. "A B"). It always stays after every pickup it's linked to, including when you drag or optimize. 👓 does this on its own when a second order goes to an address already in your route.

## Version 5.4: 👓 add Uber stops to your route

- The orange 👓 button sits next to ✕ on Uber offers in the Offers tab. It works once you've marked the offer accepted (✓); before that it's grayed out.
- Tap 👓 and it turns on (solid orange, pulsing). Only then does the screen reader read Uber's **Trip Guide** (pieced together as you scroll; tap each stop to expand it so its address shows) and Uber's **pickup screen** ("Pick up 1 order" + who it's for). Nothing is read before you press it.
- When you leave the Trip Guide (5 seconds off screen), GigGrade adds every stop to the Route tab top to bottom, skipping stops already in your route, links pickups to dropoffs, sends a "🗺️ Route updated" notification and turns 👓 off (usually about 7–8 seconds after you leave: GigGrade checks every second while 👓 is on, and looks up all the addresses at once). Tap 👓 while it's on to cancel. It gives up after 15 minutes.
- Offers come first: if an offer pops up while 👓 is reading, the reading ends right away and whatever was read goes into the route. After you accept (press 👓 on the new offer) or decline (press 👓 again), the next reading picks up where it left off: stops already in the route are skipped, and pickup screens seen in the last 3 hours still count for linking. The "Route updated" notification waits until any offer banner is at least 15 seconds old, and ranks below offer banners.
- Linking: the pickup screen decides when it was seen; otherwise each dropoff goes with the earliest pickup above it that still has an order (first in, first out). A dropoff with no pickup above it is linked to its store if that store is already in your route, otherwise left unlinked.
- Handles OCR mix-ups ("·l order", "l40l Brook Ave" → 1401). No Supabase setup needed: the request and the result go through your existing private storage bucket.

## Version 5.3: zoom in to pick the right address

- When the tapped address matches more than one place within the offer's miles, the street names printed around the customer pin on your zoomed map decide: the match that actually has those streets within about half a mile wins. If they can't decide, the map's first estimate breaks the tie when exactly one match is near it.
- Still undecided: the banner says "📍 multiple matches — zoom in and tap again". While the bubble stays up, it re-checks every 3 seconds as you zoom; tapping the pin again also redoes the check. When it's settled you get the verdict banner.
- Tap again any time: the bubble reappearing redoes the check (a new banner only if the verdict changes).
- DoorDash no longer guesses the customer from two street names (that guess searched in the store's town and could land in the wrong town). Uber still uses it when needed.

## Version 5.2: DoorDash route check waits for your tap

- DoorDash offers: the first banner goes out right away with the grade and rates, and line 3 says "📍 Tap the customer pin for the route check". The map is still read in the background, silently.
- Tap the customer pin: one banner with the verdict, from the exact address, or from the map's estimate if the address can't be found. It's sent even if the verdict matches the map's.
- After that, another banner only if the verdict changes (e.g. you tap a different customer).
- Uber and other apps are unchanged.

## Version 5.1: DoorDash address bubble

- While a DoorDash offer is up, tap a customer pin on its map. GigGrade reads the address bubble ("54 Elderwood Lane") and pins that customer exactly, picking the right street with the map's estimate (within 1.5 mi) or the offer's miles.
- Tapped the last customer (or the only one): its address becomes the final stop, labeled with the real address (no ≈).
- Tapped a different customer on a multi-dropoff offer: its exact address plus the store pin place the last customer on the map.
- Works even after a verdict. An updated banner goes out only if the verdict itself changes (e.g. OFF ROUTE → ON THE WAY).

## Version 5.0: Optimize route + linked stops

- **Optimize route** button on the Route tab: gets real driving times between your stops from Apple Maps (the closest pairs are measured, the rest estimated from them, because Apple limits requests per minute), then checks every valid stop order (dynamic programming over subsets) and picks the fastest. With up to 9 stops that's the true best order, not a guess.
- Keeps your order if the best one saves under 30 seconds. **Undo** puts the old order back.
- **Linking:** tap 🔗 on a dropoff to link it to a pickup (or unlink it). Linked stops share a letter (A, B, C…) in the list and on the map. A linked dropoff always stays after its pickup, both when you drag and when you optimize. Linking a dropoff that sits above its pickup moves it just below. Offers accepted from a banner are linked automatically; one pickup can have several dropoffs.

## Version 4.9: zoom in to finish the on-the-way check

- If the customer pin couldn't be placed, GigGrade keeps re-reading the map every 2 seconds for up to 90 seconds while the offer stays on screen.
- Zoom in on the customer pin. If your blue dot and the store pin are still on screen, the pins are measured again. Otherwise GigGrade reads the two street names printed closest to the customer pin and looks up where they cross.
- When it works, an **updated banner** replaces the first one with the verdict and "Dropoff ≈ A & B (from map)".
- Street names are also tried on the first read when the pins alone weren't enough.
- A first banner that went out without a verdict (lookup took over 3.5 s) is now followed by an updated one when the check finishes.

## Version 4.8: add orders by hand

- **Add order** button (top right of the Offers tab): app, pay, miles, minutes, time, accepted/declined, optional pickup/dropoff. Graded against your targets live, saved to the log and the cloud, and counted in Earnings/Insights when accepted.
- **Missed** (top right of the Offers tab, after Add order) is the log of offers the screen reader saw but couldn't read.

## Version 4.7.2

- Missed offers screen shows the exact reason when it can't load (instead of a general message), and reads Supabase dates with 6-digit fractions.

## Version 4.7.1

- **Missed offers** button at the top right of the Offers tab.

## Version 4.7: sturdier Uber reading + Missed offers log
- **Uber store vs dropoff by brightness:** the store line is bold/bright, the dropoff gray — measured from the
  screen pixels, so wrapped or run-together lines no longer get mixed up. Text after a store's ")" that
  looks like an address is treated as the dropoff when brightness isn't available.
- **Better lookups:** cross streets try several phrasings plus each street + town; name-only stores also
  try "name, town".
- **Uber map reading (light and dark maps):** green pickup pin, black/gray dropoff pin and your arrow.
  Used when an address can't be found, and to overrule an address lookup that landed far from the pin.
- **Partial verdicts:** if only the dropoff is found, you still get "≈ ON THE WAY / ≈ OFF ROUTE".
- **Looser double-check:** an offer needs the same pay + miles twice (minutes can flicker).
- **Missed offers log** (Offers tab → Missed offers): offers that were on screen but got no banner, with the
  reason, what was read, and a screenshot. Needs the `missed_offers` table (bottom of `supabase/setup.sql`).

## Version 4: DoorDash map reading
DoorDash shows the customer only as a pin on its map. GigGrade now finds the pins in the screen frame
(store icon vs person icon, plus your blue GPS dot), uses your GPS position and the store's address as
two known points to get the map's scale, and works out the customer's location — usually within a few
blocks. That feeds the on-the-way check and "Accepted + add to route". Offer details show the pickup and
estimated customer on a map next to the screenshot so you can compare.
Tuned on real DoorDash screenshots (dark map). Needs the blue dot and the store pin on screen, and a
recent GPS fix (location permission "Always" keeps it fresh).

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
| `Packages/GigCore/…/TripPlanner.swift` | 9-stop route, cheapest insertion, drag reorder, on-the-way verdict |
| `Packages/GigCore/…/SharedStore.swift` | Settings and route shared between app and extension |
| `App/RouteView.swift` | Map, road routes, stop list, Google Maps hand-off |
| `App/ContentView.swift` | Settings, start-broadcast button, sample test |
