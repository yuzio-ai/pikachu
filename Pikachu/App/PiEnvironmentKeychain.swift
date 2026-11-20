import Foundation
import Security

struct PiEnvironmentKeychain: Sendable {
    let service: String

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "Pi child process environment"
        ]
    }

    func load() throws -> [String: String]? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StorageFailure() }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    func save(_ values: [String: String]) throws {
        let data = try JSONEncoder().encode(values)
        let attributes = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, attributes)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw StorageFailure() }

        let added = add(data)
        if added == errSecSuccess { return }
        if added == errSecDuplicateItem, SecItemUpdate(query as CFDictionary, attributes) == errSecSuccess { return }
        throw StorageFailure()
    }

    func migrateIfAbsent(_ values: [String: String]) throws -> [String: String] {
        let status = add(try JSONEncoder().encode(values))
        if status == errSecSuccess { return values }
        if status == errSecDuplicateItem, let saved = try load() { return saved }
        throw StorageFailure()
    }

    private func add(_ data: Data) -> OSStatus {
        var item = query
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil)
    }

    private struct StorageFailure: Error {}
}
