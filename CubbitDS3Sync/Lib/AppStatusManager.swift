import SwiftUI

@Observable class AppStatusManager {
    static var instance: AppStatusManager?
    
    var status: AppStatus = .idle
    
    private init() {
        
    }
    
    static public func `default`() -> AppStatusManager {
        if AppStatusManager.instance == nil {
            AppStatusManager.instance = AppStatusManager()
        }
        
        return AppStatusManager.instance!
    }
}
