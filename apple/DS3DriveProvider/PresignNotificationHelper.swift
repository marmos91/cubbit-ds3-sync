import Foundation
@preconcurrency import UserNotifications

enum PresignNotificationHelper {
    static func postSuccess(expiryLabel: String) {
        post(title: "Link copied", body: "Expires in \(expiryLabel)")
    }

    static func postError() {
        post(title: "Failed to copy link", body: "Could not generate presigned URL")
    }

    static func postFoldersNotSupported() {
        post(title: "Can't share folders", body: "Presigned URLs only work for files")
    }

    /// Authorization is requested by the main app at launch. The extension
    /// only submits notifications — requestAuthorization from an extension
    /// context is unreliable on macOS and may silently fail.
    private static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        Task { @MainActor in
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
