import Testing
@testable import LanguageSwitcher

@Suite
struct LayoutConverterTests {
    @Test
    func testEmptyStringStaysEmpty() {
        #expect(LayoutConverter.convert("") == "")
    }

    @Test
    func testEnglishLettersConvertToRussian() {
        #expect(LayoutConverter.convert("qwerty") == "йцукен")
        #expect(LayoutConverter.convert("QWERTY") == "ЙЦУКЕН")
        #expect(LayoutConverter.convert("Hello") == "Руддщ")
    }

    @Test
    func testRussianLettersConvertToEnglish() {
        #expect(LayoutConverter.convert("привет") == "ghbdtn")
        #expect(LayoutConverter.convert("Привет") == "Ghbdtn")
    }

    @Test
    func testLayoutPunctuationConvertsForEnglishInput() {
        #expect(LayoutConverter.convert("What.") == "Црфею")
        #expect(LayoutConverter.convert("hello, world!") == "руддщб цщкдв!")
        #expect(LayoutConverter.convert("Test123") == "Еуые123")
    }

    @Test
    func testNonLetterSymbolsStayInPlace() {
        #expect(LayoutConverter.convert("ivan @#$^&?/ 123") == "шмфт @#$^&?/ 123")
        #expect(LayoutConverter.convert("Иван @#$^&?/ 123") == "Bdfy @#$^&?/ 123")
    }

    @Test
    func testWrongLayoutWordWithComma() {
        #expect(LayoutConverter.convert("e,hfk") == "убрал")
    }

    @Test
    func testMixedScriptWordKeepsCorrectCyrillic() {
        #expect(LayoutConverter.convert("e,рал") == "убрал")
    }

    @Test
    func testPunctuationAndDigitsStayInPlaceForRussianInput() {
        #expect(LayoutConverter.convert("Цена $100.") == "Wtyf $100.")
        #expect(LayoutConverter.convert("Привет, мир!") == "Ghbdtn, vbh!")
    }

    @Test
    func testRussianLettersCanMapToPhysicalSymbols() {
        #expect(LayoutConverter.convert("бюэжхъё") == ",.';[]`")
        #expect(LayoutConverter.convert("БЮЭЖХЪЁ") == "<>\":{}~")
        #expect(LayoutConverter.convert("х") == "[")
        #expect(LayoutConverter.convert("Х") == "{")
        #expect(LayoutConverter.convert("ё") == "`")
        #expect(LayoutConverter.convert("Ё") == "~")
    }

    @Test
    func testMixedCaseLettersConvert() {
        #expect(LayoutConverter.convert("aBcDe") == "фИсВу")
        #expect(LayoutConverter.convert("АбВгД") == "F,DuL")
    }

    @Test
    func testWhitespaceAndNewlinesStayInPlace() {
        #expect(LayoutConverter.convert("hi there\nagain") == "рш еруку\nфпфшт")
    }

    // MARK: - Round-trip (the table is a bijection for the mapped keys)

    @Test
    func testFullLowercaseAlphabetRoundTrips() {
        let en = "qwertyuiopasdfghjklzxcvbnm"
        let ru = LayoutConverter.convert(en)
        #expect(ru == "йцукенгшщзфывапролдячсмить")
        #expect(LayoutConverter.convert(ru) == en)
    }

    @Test
    func testFullUppercaseAlphabetRoundTrips() {
        let en = "QWERTYUIOPASDFGHJKLZXCVBNM"
        let ru = LayoutConverter.convert(en)
        // Pin the intermediate too, so a symmetric mangling can't slip through.
        #expect(ru == "ЙЦУКЕНГШЩЗФЫВАПРОЛДЯЧСМИТЬ")
        #expect(LayoutConverter.convert(ru) == en)
    }

    @Test
    func testWordsRoundTripEnRuEn() {
        for word in ["hello", "world", "ghbdtn", "swift", "keyboard"] {
            #expect(LayoutConverter.convert(LayoutConverter.convert(word)) == word)
        }
    }

    @Test
    func testPunctuationKeyedLettersRoundTrip() {
        // Words whose Russian letters come from punctuation keys (б ю э ж х ъ ё).
        for word in ["e,hfk", "убрал"] {
            #expect(LayoutConverter.convert(LayoutConverter.convert(word)) == word)
        }
        #expect(LayoutConverter.convert("убрал") == "e,hfk")
    }

    @Test
    func testDigitsAndSpacesArePreserved() {
        #expect(LayoutConverter.convert("12345 67890") == "12345 67890")
        #expect(LayoutConverter.convert("  ") == "  ")
    }

    @Test
    func testSingleLetterConversions() {
        #expect(LayoutConverter.convert("f") == "а")
        #expect(LayoutConverter.convert("а") == "f")
        #expect(LayoutConverter.convert("q") == "й")
        #expect(LayoutConverter.convert("й") == "q")
    }

    @Test
    func testNonConvertibleCharactersPassThrough() {
        // Emoji and characters outside both layouts are emitted unchanged.
        #expect(LayoutConverter.convert("👍") == "👍")
        #expect(LayoutConverter.convert("hi 👍 there") == "рш 👍 еруку")
    }
}
