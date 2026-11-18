import SwiftUI
import UserNotifications
import GigCore

@main
struct GigGradeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        OfferAlert.registerCategories()
        SoundInstaller.install()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        LocationTracker.shared.start()
        Task {
            await Cloud.shared.pushStateNow() // make sure the screen reader has your current settings
            await Cloud.shared.flush()
        }
        return true
    }

    // Show the banner even when GigGrade itself is open (e.g. "Test with a sample offer").
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // Buttons on the offer banner: Accepted / Accepted + add to route / Declined. Tapping the banner opens Offers.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = (info["recordId"] as? String).flatMap(UUID.init(uuidString:))
        let day = info["dayKey"] as? String
        let action = response.actionIdentifier

        if action == UNNotificationDefaultActionIdentifier {
            NotificationCenter.default.post(name: .openOffers, object: nil)
            completionHandler()
            return
        }

        Task { @MainActor in
            func mark(_ d: Decision) async {
                guard let id else { return }
                if let day { OfferLog.shared.setDecision(d, id: id, dayKey: day) } // if this phone has it
                await Cloud.shared.queueDecision(d, id: id)                     // and in the cloud
            }
            switch action {
            case OfferAlert.acceptRouteAction:
                await mark(.accepted)
                if let id {
                    let store = SharedStore.shared
                    if !store.addPendingToRoute(orderId: id.uuidString), let found = await Cloud.shared.stops(for: id) {
                        var planner = TripPlanner(stops: store.stops)
                        planner.addOrder(origin: store.currentLocation, pickup: found.pickup, dropoff: found.dropoff)
                        store.stops = planner.stops
                    }
                    await Cloud.shared.pushStateNow()
                }
            case OfferAlert.acceptAction:
                await mark(.accepted)
            case OfferAlert.declineAction:
                await mark(.declined)
            default:
                break
            }
            NotificationCenter.default.post(name: .logChanged, object: nil)
            NotificationCenter.default.post(name: .routeChanged, object: nil)
            completionHandler()
        }
    }
}
