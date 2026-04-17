import Foundation

enum LayoutConverter {
    private static let enToRuPairs: [(Character, Character)] = [
        ("q","й"),("w","ц"),("e","у"),("r","к"),("t","е"),("y","н"),
        ("u","г"),("i","ш"),("o","щ"),("p","з"),("[","х"),("]","ъ"),
        ("a","ф"),("s","ы"),("d","в"),("f","а"),("g","п"),("h","р"),
        ("j","о"),("k","л"),("l","д"),(";","ж"),("'","э"),
        ("z","я"),("x","ч"),("c","с"),("v","м"),("b","и"),("n","т"),
        ("m","ь"),(",","б"),(".","ю"),("/","."),("`","ё"),
        ("@","\""),("#","№"),("$",";"),("^",":"),("&","?")
    ]

    private static let enToRu: [Character: Character] = {
        var dict: [Character: Character] = [:]
        for (en, ru) in enToRuPairs {
            dict[en] = ru
            // Only add an uppercase mapping if the EN side actually has a
            // distinct uppercase. Otherwise we'd overwrite punctuation entries
            // (e.g. "," would be replaced by an uppercased-Russian version).
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

    static func convert(_ input: String) -> String {
        if input.isEmpty { return input }
        let hasCyrillic = input.contains(where: isCyrillic)
        let table = hasCyrillic ? ruToEn : enToRu
        var out = String()
        out.reserveCapacity(input.count)
        for ch in input {
            if let mapped = table[ch] {
                out.append(mapped)
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
