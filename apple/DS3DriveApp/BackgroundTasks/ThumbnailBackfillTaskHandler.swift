#if os(iOS)
    import BackgroundTasks
    import Foundation
    import os.log

    @MainActor
    final class ThumbnailBackfillTaskHandler {
        static let identifier = "io.cubbit.DS3Drive.thumbnailBackfill"
        private static let batchSize = 10
        private static let logger = Logger(subsystem: "io.cubbit.DS3Drive", category: "bgtask")

        private let driver: ForegroundBackfillDriver

        init(driver: ForegroundBackfillDriver) {
            self.driver = driver
        }

        func register() {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: Self.identifier,
                using: nil
            ) { [weak self] task in
                guard let self, let processingTask = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.handle(task: processingTask)
            }
            Self.logger.info("Registered BGProcessingTask: \(Self.identifier, privacy: .public)")
        }

        func schedule() {
            let request = BGProcessingTaskRequest(identifier: Self.identifier)
            request.requiresNetworkConnectivity = true
            request.requiresExternalPower = false
            request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
            do {
                try BGTaskScheduler.shared.submit(request)
                Self.logger.info("Submitted BGProcessingTask request")
            } catch {
                Self.logger.error(
                    "Failed to submit BGProcessingTask: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        private func handle(task: BGProcessingTask) {
            Self.logger.info("BGProcessingTask started")
            schedule()

            var workTask: Task<Void, Never>?
            task.expirationHandler = {
                Self.logger.warning("BGProcessingTask expiring — cancelling work")
                workTask?.cancel()
            }

            workTask = Task { @MainActor in
                let processed = await driver.drainBatch(maxItems: Self.batchSize)
                Self.logger.info("BGProcessingTask drained \(processed, privacy: .public) items")
                task.setTaskCompleted(success: true)
            }
        }
    }
#endif
