// 发布前用 App 实际内置的公钥验签，避免 CI 的公钥与私钥配置不匹配。
// 参数和输出只包含公开数据；私钥由 Sparkle sign_update 从标准输入读取。
import CryptoKit
import Foundation

do {
    guard CommandLine.arguments.count == 4,
          let publicKeyData = Data(base64Encoded: CommandLine.arguments[1]),
          let signature = Data(base64Encoded: CommandLine.arguments[2]),
          publicKeyData.count == 32,
          signature.count == 64 else {
        throw NSError(domain: "CCBar.UpdateRelease", code: 1)
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    let contents = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
    guard publicKey.isValidSignature(signature, for: contents) else {
        throw NSError(domain: "CCBar.UpdateRelease", code: 2)
    }
} catch {
    fputs("更新包验签失败：请确认 SPARKLE_PUBLIC_ED_KEY 与 SPARKLE_PRIVATE_ED_KEY 是同一对密钥。\n", stderr)
    exit(1)
}
