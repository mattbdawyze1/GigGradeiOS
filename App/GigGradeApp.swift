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

        func mark(_ d: Decision) {
            if let id, let day { OfferLog.shared.setDecision(d, id: id, dayKey: day) }
        }

        switch response.actionIdentifier {
        case OfferAlert.acceptRouteAction:
            mark(.accepted)
            if let id { SharedStore.shared.addPendingToRoute(orderId: id.uuidString) }
        case OfferAlert.acceptAction:
            mark(.accepted)
        case OfferAlert.declineAction:
            mark(.declined)
        case UNNotificationDefaultActionIdentifier:
            NotificationCenter.default.post(name: .openOffers, object: nil)
        default:
            break
        }
        NotificationCenter.default.post(name: .logChanged, object: nil)
        NotificationCenter.default.post(name: .routeChanged, object: nil)
        completionHandler()
    }
}
