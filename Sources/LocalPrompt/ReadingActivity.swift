import Foundation
import IOKit.pwr_mgt

/// A temporary display-sleep assertion, held only during an active reading session.
/// Manual sleep and closing a laptop's lid still work normally.
@MainActor
final class ReadingActivity {
    private var assertion: IOPMAssertionID?

    func setActive(_ active: Bool) {
        if active {
            guard assertion == nil else { return }
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "LocalPrompt active reading" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                assertion = id
            } else {
                NSLog("LocalPrompt could not prevent idle display sleep (%d).", result)
            }
        } else if let assertion {
            IOPMAssertionRelease(assertion)
            self.assertion = nil
        }
    }

    deinit {
        if let assertion { IOPMAssertionRelease(assertion) }
    }
}
