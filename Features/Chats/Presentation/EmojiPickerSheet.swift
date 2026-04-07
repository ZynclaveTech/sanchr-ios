import SwiftUI

/// Lightweight emoji picker presented from the composer's smiley button.
/// Categories are static curated lists — no Unicode CLDR dependency, no
/// network, no third-party SDK. Tap an emoji to append it to the composer.
struct EmojiPickerSheet: View {

    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategory: Category = .smileys

    enum Category: String, CaseIterable, Identifiable {
        case smileys, people, animals, food, activity, travel, objects, symbols, flags
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .smileys: return "face.smiling"
            case .people: return "hand.wave"
            case .animals: return "pawprint"
            case .food: return "fork.knife"
            case .activity: return "soccerball"
            case .travel: return "airplane"
            case .objects: return "lightbulb"
            case .symbols: return "heart"
            case .flags: return "flag"
            }
        }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)

    var body: some View {
        VStack(spacing: 0) {
            // Category tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(Category.allCases) { cat in
                        Button {
                            selectedCategory = cat
                        } label: {
                            Image(systemName: cat.symbol)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(selectedCategory == cat ? SanchrColors.primary : SanchrExportColors.textTertiary)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            Divider()

            // Emoji grid
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(Self.emojis(for: selectedCategory), id: \.self) { emoji in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            onSelect(emoji)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 30))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: Curated emoji sets
    static func emojis(for c: Category) -> [String] {
        switch c {
        case .smileys: return [
            "😀","😃","😄","😁","😆","😅","🤣","😂","🙂","🙃","😉","😊","😇","🥰","😍","🤩",
            "😘","😗","😚","😙","🥲","😋","😛","😜","🤪","😝","🤑","🤗","🤭","🤫","🤔","🤐",
            "🤨","😐","😑","😶","😏","😒","🙄","😬","🤥","😌","😔","😪","🤤","😴","😷","🤒",
            "🤕","🤢","🤮","🥵","🥶","🥴","😵","🤯","🤠","🥳","😎","🤓","🧐","😕","😟","🙁",
            "☹️","😮","😯","😲","😳","🥺","😦","😧","😨","😰","😥","😢","😭","😱","😖","😣",
            "😞","😓","😩","😫","🥱","😤","😡","😠","🤬","😈","👿","💀","☠️","💩","🤡","👹"
        ]
        case .people: return [
            "👋","🤚","🖐","✋","🖖","👌","🤌","🤏","✌️","🤞","🤟","🤘","🤙","👈","👉","👆",
            "🖕","👇","☝️","👍","👎","✊","👊","🤛","🤜","👏","🙌","👐","🤲","🤝","🙏","✍️",
            "💅","🤳","💪","🦾","🦵","🦿","🦶","👣","👀","👁","👅","👄","🧠","🫀","🫁","🦷",
            "👶","🧒","👦","👧","🧑","👱","👨","🧔","👩","🧓","👴","👵","🙍","🙎","🙅","🙆"
        ]
        case .animals: return [
            "🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐻‍❄️","🐨","🐯","🦁","🐮","🐷","🐽","🐸",
            "🐵","🙈","🙉","🙊","🐒","🐔","🐧","🐦","🐤","🐣","🐥","🦆","🦅","🦉","🦇","🐺",
            "🐗","🐴","🦄","🐝","🪱","🐛","🦋","🐌","🐞","🐜","🪰","🪲","🦂","🐢","🐍","🦎",
            "🦖","🦕","🐙","🦑","🦐","🦞","🦀","🐡","🐠","🐟","🐬","🐳","🐋","🦈","🐊","🐅"
        ]
        case .food: return [
            "🍏","🍎","🍐","🍊","🍋","🍌","🍉","🍇","🍓","🫐","🍈","🍒","🍑","🥭","🍍","🥥",
            "🥝","🍅","🍆","🥑","🥦","🥬","🥒","🌶","🫑","🌽","🥕","🫒","🧄","🧅","🥔","🍠",
            "🥐","🥯","🍞","🥖","🥨","🧀","🥚","🍳","🧈","🥞","🧇","🥓","🥩","🍗","🍖","🌭",
            "🍔","🍟","🍕","🥪","🥙","🧆","🌮","🌯","🫔","🥗","🥘","🫕","🍝","🍜","🍲","🍛",
            "🍣","🍱","🥟","🦪","🍤","🍙","🍚","🍘","🍥","🥠","🥮","🍢","🍡","🍧","🍨","🍦",
            "🥧","🧁","🍰","🎂","🍮","🍭","🍬","🍫","🍿","🍩","🍪","🌰","🥜","🍯","🥛","🍼"
        ]
        case .activity: return [
            "⚽️","🏀","🏈","⚾️","🥎","🎾","🏐","🏉","🥏","🎱","🪀","🏓","🏸","🏒","🏑","🥍",
            "🏏","🪃","🥅","⛳️","🪁","🏹","🎣","🤿","🥊","🥋","🎽","🛹","🛼","🛷","⛸","🥌",
            "🎿","⛷","🏂","🪂","🏋️","🤼","🤸","⛹️","🤺","🤾","🏌️","🏇","🧘","🏄","🏊","🤽",
            "🚣","🧗","🚵","🚴","🏆","🥇","🥈","🥉","🏅","🎖","🏵","🎗","🎫","🎟","🎪","🤹"
        ]
        case .travel: return [
            "🚗","🚕","🚙","🚌","🚎","🏎","🚓","🚑","🚒","🚐","🛻","🚚","🚛","🚜","🦯","🦽",
            "🦼","🛴","🚲","🛵","🏍","🛺","🚨","🚔","🚍","🚘","🚖","🚡","🚠","🚟","🚃","🚋",
            "🚞","🚝","🚄","🚅","🚈","🚂","🚆","🚇","🚊","🚉","✈️","🛫","🛬","🛩","💺","🛰",
            "🚀","🛸","🚁","🛶","⛵️","🚤","🛥","🛳","⛴","🚢","⚓️","⛽️","🚧","🚦","🚥","🗺"
        ]
        case .objects: return [
            "💡","🔦","🕯","🪔","🧯","🛢","💸","💵","💴","💶","💷","🪙","💰","💳","💎","⚖️",
            "🪜","🧰","🪛","🔧","🔨","⚒","🛠","⛏","🪚","🔩","⚙️","🪤","🧱","⛓","🧲","🔫",
            "💣","🧨","🪓","🔪","🗡","⚔️","🛡","🚬","⚰️","🪦","⚱️","🏺","🔮","📿","🧿","💈",
            "⚗️","🔭","🔬","🕳","🩹","🩺","💊","💉","🩸","🧬","🦠","🧫","🧪","🌡","🧹","🪠"
        ]
        case .symbols: return [
            "❤️","🧡","💛","💚","💙","💜","🖤","🤍","🤎","💔","❣️","💕","💞","💓","💗","💖",
            "💘","💝","💟","☮️","✝️","☪️","🕉","☸️","✡️","🔯","🕎","☯️","☦️","🛐","⛎","♈️",
            "♉️","♊️","♋️","♌️","♍️","♎️","♏️","♐️","♑️","♒️","♓️","🆔","⚛️","🉑","☢️","☣️",
            "📴","📳","🈶","🈚️","🈸","🈺","🈷️","✴️","🆚","💮","🉐","㊙️","㊗️","🈴","🈵","🈹",
            "🈲","🅰️","🅱️","🆎","🆑","🅾️","🆘","❌","⭕️","🛑","⛔️","📛","🚫","💯","💢","♨️"
        ]
        case .flags: return [
            "🏳️","🏴","🏁","🚩","🏳️‍🌈","🏳️‍⚧️","🏴‍☠️","🇺🇳","🇺🇸","🇬🇧","🇨🇦","🇦🇺","🇮🇳","🇳🇵","🇯🇵","🇰🇷",
            "🇨🇳","🇩🇪","🇫🇷","🇮🇹","🇪🇸","🇧🇷","🇲🇽","🇷🇺","🇿🇦","🇦🇪","🇸🇦","🇮🇩","🇸🇬","🇹🇭","🇻🇳","🇵🇭",
            "🇲🇾","🇵🇰","🇧🇩","🇱🇰","🇹🇷","🇮🇱","🇪🇬","🇰🇪","🇳🇬","🇦🇷","🇨🇱","🇨🇴","🇵🇪","🇨🇭","🇸🇪","🇳🇴",
            "🇩🇰","🇫🇮","🇵🇱","🇳🇱","🇧🇪","🇦🇹","🇮🇪","🇵🇹","🇬🇷","🇨🇿","🇭🇺","🇷🇴","🇺🇦","🇮🇸","🇳🇿"
        ]
        }
    }
}
