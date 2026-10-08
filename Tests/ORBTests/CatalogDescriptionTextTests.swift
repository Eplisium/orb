import Testing
@testable import ORB

@Suite("Catalog description plain text")
struct CatalogDescriptionTextTests {
    @Test("Links, emphasis and code collapse to readable text")
    func strips() {
        let raw = "Pricing is as follows, [per the docs](https://example.com/p): **$0.04** per `1024x1024` image."
        #expect(CatalogDescriptionText.plain(raw) == "Pricing is as follows, per the docs: $0.04 per 1024x1024 image.")
    }

    @Test("A link cut off by truncation does not leave a stray bracket")
    func truncatedLink() {
        #expect(CatalogDescriptionText.plain("Pricing is as follows, [per the docs") == "Pricing is as follows, per the docs")
    }

    @Test("Headings, bullets and newlines become one line")
    func structure() {
        #expect(CatalogDescriptionText.plain("# Title\n- one\n- two") == "Title one two")
    }
}
