import Foundation
import Security

enum ProxyKeychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.sponge1645.ytdl.native",
        kSecAttrAccount as String: "download-proxy"
    ]

    static func read() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        try check(SecItemCopyMatching(request as CFDictionary, &result))
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode))
        }
        return value
    }

    static func write(_ value: String) throws {
        let data = Data(value.utf8)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    static func remove() {
        SecItemDelete(query as CFDictionary)
    }

    private static func check(_ status: OSStatus) throws {
        if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
