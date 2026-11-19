import Foundation

private final class PiRuntimeAdapterBundleToken {}

extension Bundle {
    static let piRuntimeAdapter = Bundle(for: PiRuntimeAdapterBundleToken.self)
}
