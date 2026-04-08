import Foundation
import SwiftUI

/// A single tutorial slide.
///
/// Each slide maps to one of the seven UX requirements delivered in
/// Phase 05 (UX-01 ... UX-07). The view consumes localized title /
/// description keys from `Localizable.xcstrings` so the tutorial is
/// localized in English and Italian out of the box.
///
/// `imageName` is the asset-catalog name of the slide screenshot.
/// During Plan 05-14 the imagesets are created as PLACEHOLDER assets
/// (a solid brand-color PNG with the slide title) and reshot by the
/// human reviewer at the human-verify checkpoint.
struct Slide: Identifiable {
    let id: String
    let imageName: String
    let titleKey: LocalizedStringKey
    let descriptionKey: LocalizedStringKey
}
