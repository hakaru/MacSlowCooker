import Foundation
import os.log
import Security

private let logger = Logger(subsystem: "com.macslowcooker.app", category: "KeychainStore")

struct KeychainStore {
    let service: String

    func write(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        let attrs: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                logger.error("KeychainStore.write add failed: \(addStatus) service=\(self.service) key=\(key)")
                assertionFailure("KeychainStore.write failed: OSStatus \(addStatus)")
            }
        } else if updateStatus != errSecSuccess {
            logger.error("KeychainStore.write update failed: \(updateStatus) service=\(self.service) key=\(key)")
            assertionFailure("KeychainStore.write failed: OSStatus \(updateStatus)")
        }
    }

    func read(forKey key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(forKey key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("KeychainStore.delete failed: \(status) service=\(self.service) key=\(key)")
            assertionFailure("KeychainStore.delete failed: OSStatus \(status)")
        }
    }
}
