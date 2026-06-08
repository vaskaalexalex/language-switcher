import Foundation

enum LayoutConverter {
    private static let enToRuPairs: [(Character, Character)] = [
        ("q","й"),("w","ц"),("e","у"),("r","к"),("t","е"),("y","н"),
        ("u","г"),("i","ш"),("o","щ"),("p","з"),("[","х"),("]","ъ"),
        ("a","ф"),("s","ы"),("d","в"),("f","а"),("g","п"),("h","р"),
        ("j","о"),("k","л"),("l","д"),(";","ж"),("'","э"),
        ("z","я"),("x","ч"),("c","с"),("v","м"),("b","и"),("n","т"),
        ("m","ь"),(",","б"),(".","ю"),("`","ё"),
        ("{","Х"),("}","Ъ"),(":","Ж"),("<","Б"),(">","Ю"),("\"","Э"),("~","Ё")
    ]

    private static let enToRu: [Character: Character] = {
        var dict: [Character: Character] = [:]
        for (en, ru) in enToRuPairs {
            dict[en] = ru
            let upEn = Character(String(en).uppercased())
            if upEn != en {
                let upRu = Character(String(ru).uppercased())
                dict[upEn] = upRu
            }
        }
        return dict
    }()

    private static let ruToEn: [Character: Character] = {
        var dict: [Character: Character] = [:]
        for (en, ru) in enToRuPairs {
            dict[ru] = en
            let upRu = Character(String(ru).uppercased())
            if upRu != ru {
                let upEn = Character(String(en).uppercased())
                dict[upRu] = upEn
            }
        }
        return dict
    }()

    private static let cyrillicRange: ClosedRange<Unicode.Scalar> = "\u{0400}"..."\u{04FF}"

    private static func isCyrillic(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            if cyrillicRange.contains(scalar) { return true }
        }
        return false
    }

    private static func isLatin(_ ch: Character) -> Bool {
        guard ch.isLetter else { return false }
        return !isCyrillic(ch)
    }

    private static func mapsToLetter(_ ch: Character, in table: [Character: Character]) -> Character? {
        guard let mapped = table[ch], mapped.isLetter else { return nil }
        return mapped
    }

    /// True when the character right after `index` is a letter (any script).
    /// Used to tell a word-internal/leading punctuation key (a layout letter, e.g.
    /// the `,` in "e,hfk" → "убрал") from a trailing real punctuation mark (the `.`
    /// in "Ghbdtn." → "Привет.").
    private static func nextIsLetter(_ chars: [Character], after index: Int) -> Bool {
        let next = index + 1
        return next < chars.count && chars[next].isLetter
    }

    static func convert(_ input: String) -> String {
        if input.isEmpty { return input }

        let hasLatin = input.contains(where: isLatin)
        let hasCyrillic = input.contains(where: isCyrillic)

        if hasLatin && hasCyrillic {
            return convertMixed(input)
        }
        if hasCyrillic {
            return convertWithTable(input, table: ruToEn)
        }
        return convertWithTable(input, table: enToRu)
    }

    /// Mixed-script token: Latin + physical keys that map to RU letters → RU; Cyrillic → keep.
    private static func convertMixed(_ input: String) -> String {
        let chars = Array(input)
        var out = String()
        out.reserveCapacity(chars.count)
        for i in chars.indices {
            let ch = chars[i]
            if isLatin(ch), let mapped = enToRu[ch] {
                out.append(mapped)
            } else if let mapped = mapsToLetter(ch, in: enToRu), nextIsLetter(chars, after: i) {
                out.append(mapped)
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func convertWithTable(_ input: String, table: [Character: Character]) -> String {
        let chars = Array(input)
        var out = String()
        out.reserveCapacity(chars.count)
        for i in chars.indices {
            let ch = chars[i]
            if ch.isLetter, let mapped = table[ch] {
                out.append(mapped)
            } else if let mapped = mapsToLetter(ch, in: table), nextIsLetter(chars, after: i) {
                out.append(mapped)
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
