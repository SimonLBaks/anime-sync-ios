import AppKit
import Darwin
import Foundation
import WebKit

/// Compile beside the actual ProviderBridge.swift with -D PROVIDER_RULES_ONLY.
/// No copied rules, WebView document, network request, account or simulator.
@main struct ProviderRuleCompilerCheck {
    @MainActor static func main() async {
        _ = NSApplication.shared
        do {
            let compiled = try await ProviderRuleLists.privateRequests()
            let evidence: [String: Any] = [
                "compiled": true,
                "ruleCount": ProviderRuleLists.privateFilters.count,
                "identifier": compiled.identifier
            ]
            let encoded = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: encoded, as: UTF8.self))
        } catch {
            fputs("Production WebKit privacy rule compilation failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
