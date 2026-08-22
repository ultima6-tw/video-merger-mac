import Foundation

/// 查 Localizable.xcstrings 裡的 key（英文原文當 key，繁中翻譯另外收在 catalog 裡），
/// 再用 %@ 依序代入動態內容。所有動態值一律先轉成 String 再傳進來，
/// 這樣 catalog 裡每一條都只用 %@，不用去猜 Int/Double 在 String(format:) 裡對應的 platform-specific
/// 格式化符號（%ld vs %lld 之類），降低出錯機會。
func L(_ key: String, _ args: CVarArg...) -> String {
    let template = String(localized: String.LocalizationValue(key))
    guard !args.isEmpty else { return template }
    return String(format: template, arguments: args)
}
