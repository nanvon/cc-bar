// 价格规则文件的校验工具，供 `.github/workflows/pricing-rules.yml` 使用。
// 与 App 编译同一份 `Core/Pricing/PricingRules.swift`，校验结果与 App 加载时一致：
//   xcrun swiftc -parse-as-library Core/Pricing/PricingRules.swift scripts/pricing-rules-tool.swift -o build/pricing-rules-tool
//   build/pricing-rules-tool Resources/pricing-rules.json   # 通过时输出 revision
import Foundation

@main
struct PricingRulesTool {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("用法：pricing-rules-tool <pricing-rules.json>\n", stderr)
            exit(2)
        }
        let path = CommandLine.arguments[1]
        do {
            let rules = try PricingRules.decode(Data(contentsOf: URL(fileURLWithPath: path)))
            print(rules.revision)
        } catch {
            fputs("价格规则校验失败：\(path)：\(error)\n", stderr)
            exit(1)
        }
    }
}
