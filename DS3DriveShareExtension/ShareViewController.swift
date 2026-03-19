#if os(iOS)
import UIKit
import SwiftUI
import DS3Lib
import os.log

/// UIViewController that hosts the Share Extension's SwiftUI view hierarchy.
/// Acts as the bridge between UIKit's extension lifecycle and the SwiftUI-based UI.
class ShareViewController: UIViewController {

    private let logger = Logger(subsystem: "io.cubbit.DS3Drive.share", category: "extension")

    override func viewDidLoad() {
        super.viewDidLoad()

        logger.info("ShareViewController viewDidLoad")

        let viewModel = ShareUploadViewModel()
        let shareView = ShareExtensionView(viewModel: viewModel, extensionContext: extensionContext)
        let hostingController = UIHostingController(rootView: shareView)

        addChild(hostingController)
        view.addSubview(hostingController.view)

        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        hostingController.view.backgroundColor = .systemBackground
        hostingController.didMove(toParent: self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(completeExtension),
            name: Notification.Name("ShareExtensionComplete"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cancelExtension),
            name: Notification.Name("ShareExtensionCancel"),
            object: nil
        )
    }

    @objc private func completeExtension() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    @objc private func cancelExtension() {
        extensionContext?.cancelRequest(withError: NSError(
            domain: NSCocoaErrorDomain,
            code: NSUserCancelledError
        ))
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
#endif
