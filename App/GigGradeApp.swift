import SwiftUI
import UserNotifications
import GigCore

extension Notification.Name {
    static let routeChanged = Notification.Name("giggrade.routeChanged")
    static let openMap = Notification.Name("giggrade.openMap")
}

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
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        LocationTracker.shared.start()
        return true
    }

    // Show the banner even when GigGrade itself is open (e.g. "Test with a sample offer").
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // "Add to route" / "Open route map" buttons on the offer banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let orderId = response.notification.request.content.userInfo["orderId"] as? String
        switch response.actionIdentifier {
        case OfferAlert.addAction:
            if let orderId { SharedStore.shared.addPendingToRoute(orderId: orderId) }
            NotificationCenter.default.post(name: .routeChanged, object: nil)
        case OfferAlert.mapAction, UNNotificationDefaultActionIdentifier:
            NotificationCenter.default.post(name: .openMap, object: nil)
        default: break
        }
        completionHandler()
    }
}
