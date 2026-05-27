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
        #expect(LayoutConverter.convert("х") == "[")
        #expect(LayoutConverter.convert("ё") == "`")
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
}
