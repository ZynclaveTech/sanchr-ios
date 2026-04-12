import UIKit

// MARK: - StickerPack

struct StickerPack: Identifiable {
    let id: String
    let name: String
    let icon: String        // emoji used as the pack selector icon
    let stickers: [String]  // ordered emoji strings
}

// MARK: - StickerStore

/// Built-in sticker packs backed by emoji rendered to UIImage on demand.
/// All packs are bundled — no network required, no SDK dependency.
final class StickerStore: @unchecked Sendable {

    static let shared = StickerStore()
    private init() {}

    let packs: [StickerPack] = [
        StickerPack(id: "faces", name: "Faces", icon: "😊", stickers: [
            "😀","😃","😄","😁","😆","😅","🤣","😂","🙂","🙃","😉","😊","😇","🥰","😍","🤩",
            "😘","😗","😚","😙","🥲","😋","😛","😜","🤪","😝","🤑","🤗","🤭","🤫","🤔","🤐",
            "🤨","😐","😑","😶","😏","😒","🙄","😬","🤥","😌","😔","😪","🤤","😴","😷","🤒",
            "🥺","😦","😧","😨","😰","😥","😢","😭","😱","😖","😣","😞","😓","😩","😫","🥱",
            "😤","😡","😠","🤬","😈","👿","💀","☠️","💩","🤡","👹","👺","👻","👽","👾","🤖",
        ]),
        StickerPack(id: "animals", name: "Animals", icon: "🐶", stickers: [
            "🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐻‍❄️","🐨","🐯","🦁","🐮","🐷","🐽","🐸",
            "🐵","🙈","🙉","🙊","🐒","🐔","🐧","🐦","🐤","🐣","🐥","🦆","🦅","🦉","🦇","🐺",
            "🐗","🐴","🦄","🦋","🐌","🐞","🐜","🦂","🐢","🐍","🦎","🐙","🦑","🦐","🦞","🦀",
            "🐡","🐠","🐟","🐬","🐳","🐋","🦈","🐊","🐅","🐆","🦓","🦍","🦧","🦣","🐘","🦛",
        ]),
        StickerPack(id: "food", name: "Food", icon: "🍕", stickers: [
            "🍏","🍎","🍐","🍊","🍋","🍌","🍉","🍇","🍓","🫐","🍒","🍑","🥭","🍍","🥥","🥝",
            "🍅","🍆","🥑","🥦","🥬","🥒","🌶","🫑","🌽","🥕","🧄","🧅","🥔","🥐","🥯","🍞",
            "🍔","🍟","🍕","🌭","🌮","🌯","🥪","🥙","🧆","🍣","🍱","🥟","🍜","🍝","🍲","🍛",
            "🍦","🍧","🍨","🍩","🍪","🎂","🍰","🧁","🍫","🍬","🍭","🧃","☕️","🍵","🧋","🍺",
        ]),
        StickerPack(id: "gestures", name: "Hands", icon: "👋", stickers: [
            "👋","🤚","🖐","✋","🖖","👌","🤌","🤏","✌️","🤞","🤟","🤘","🤙","👈","👉","👆",
            "👍","👎","✊","👊","🤛","🤜","👏","🙌","👐","🤲","🤝","🙏","💪","🦾","🫶","❤️",
            "🧡","💛","💚","💙","💜","🖤","🤍","🤎","💔","❣️","💕","💞","💓","💗","💖","💘",
            "✨","🌟","💫","⭐️","🌈","🎉","🎊","🎈","🎁","🎀","🏆","🥇","💯","🔥","❄️","💥",
        ]),
    ]

    /// Renders an emoji string to a PNG `Data` at `size`×`size` points with a transparent background.
    func renderStickerPNG(_ emoji: String, size: CGFloat = 160) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { _ in
            let fontSize = size * 0.8
            let font = UIFont.systemFont(ofSize: fontSize)
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let str = emoji as NSString
            let textSize = str.size(withAttributes: attrs)
            let origin = CGPoint(
                x: (size - textSize.width) / 2,
                y: (size - textSize.height) / 2
            )
            str.draw(at: origin, withAttributes: attrs)
        }
        return image.pngData() ?? Data()
    }
}
