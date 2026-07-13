import SwiftUI

extension Color {
    static let bdBg      = Color(red: 0.043, green: 0.043, blue: 0.055)  // #0B0B0E
    static let bdCard    = Color(red: 0.110, green: 0.110, blue: 0.133)  // #1C1C22
    static let bdCard2   = Color(red: 0.086, green: 0.086, blue: 0.098)  // #161619
    static let bdBorder  = Color(red: 0.176, green: 0.176, blue: 0.208)  // #2D2D35
    static let bdPrimary = Color(red: 0.486, green: 0.361, blue: 0.988)  // #7C5CFC
    static let bdGreen   = Color(red: 0.204, green: 0.827, blue: 0.600)  // #34D399
    static let bdRed     = Color(red: 1.000, green: 0.361, blue: 0.424)  // #FF5C6C
    static let bdMuted   = Color(red: 0.545, green: 0.545, blue: 0.584)  // #8B8B95
    static let bdMuted2  = Color(red: 0.337, green: 0.337, blue: 0.373)  // #56565F
}

extension Font {
    static func bdTitle()    -> Font { .system(size: 27, weight: .heavy) }
    static func bdHeadline() -> Font { .system(size: 20, weight: .bold) }
    static func bdBody()     -> Font { .system(size: 15, weight: .medium) }
    static func bdCaption()  -> Font { .system(size: 12, weight: .semibold) }
    static func bdMicro()    -> Font { .system(size: 10, weight: .bold) }
}

extension Color {
    static func bdCategory(_ category: String) -> Color {
        switch category {
        case "WORK":    return Color(red: 0.40, green: 0.70, blue: 1.00)
        case "HOME":    return Color(red: 0.90, green: 0.60, blue: 0.30)
        case "FINANCE": return Color.bdGreen
        case "HEALTH":  return Color(red: 1.00, green: 0.45, blue: 0.45)
        case "ERRANDS": return Color(red: 0.90, green: 0.80, blue: 0.20)
        default:        return Color.bdPrimary
        }
    }
}

struct CategoryChip: View {
    let category: String
    var body: some View {
        Text(category)
            .font(.bdMicro())
            .foregroundStyle(Color.bdCategory(category))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.bdCategory(category).opacity(0.12))
            .cornerRadius(6)
    }
}
