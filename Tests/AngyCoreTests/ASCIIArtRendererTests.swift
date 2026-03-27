import AngyCore
import Testing

struct ASCIIArtRendererTests {
    @Test
    func transparentPixelsRemainTransparent() {
        let pixels = Array(repeating: UInt8(0), count: 4 * 4 * 4)

        let frame = ASCIIArtRenderer.render(
            rgbaBytes: pixels,
            width: 4,
            height: 4,
            options: ASCIIArtOptions(
                outputColumns: 2,
                characterAspectRatio: 1.0,
                alphaThreshold: 0.1,
                brightness: 0,
                contrast: 1,
                gamma: 1,
                orderedDitherStrength: 0,
                charset: " .#"
            )
        )

        #expect(frame.columns == 2)
        #expect(frame.rows == 2)
        #expect(frame.cells.allSatisfy { $0.glyph == " " })
        #expect(frame.cells.allSatisfy { $0.color.isTransparent })
    }

    @Test
    func darkerPixelsMapToDenserGlyphsThanBrightPixels() {
        let darkPixel: [UInt8] = [0, 0, 0, 255]
        let brightPixel: [UInt8] = [255, 255, 255, 255]
        let pixels = darkPixel + brightPixel

        let frame = ASCIIArtRenderer.render(
            rgbaBytes: pixels,
            width: 2,
            height: 1,
            options: ASCIIArtOptions(
                outputColumns: 2,
                characterAspectRatio: 1.0,
                alphaThreshold: 0.1,
                brightness: 0,
                contrast: 1,
                gamma: 1,
                orderedDitherStrength: 0,
                charset: " .#"
            )
        )

        #expect(frame.columns == 2)
        #expect(frame.rows == 1)
        #expect(frame[column: 0, row: 0].glyph == "#")
        #expect(frame[column: 1, row: 0].glyph == ".")
    }

    @Test
    func sampledColorTracksVisiblePixels() {
        let pixels: [UInt8] = [
            255, 0, 0, 255,
            0, 0, 255, 255
        ]

        let frame = ASCIIArtRenderer.render(
            rgbaBytes: pixels,
            width: 2,
            height: 1,
            options: ASCIIArtOptions(
                outputColumns: 2,
                characterAspectRatio: 1.0,
                alphaThreshold: 0.1,
                brightness: 0,
                contrast: 1,
                gamma: 1,
                orderedDitherStrength: 0,
                charset: " .#"
            )
        )

        #expect(frame[column: 0, row: 0].color.red > frame[column: 0, row: 0].color.blue)
        #expect(frame[column: 1, row: 0].color.blue > frame[column: 1, row: 0].color.red)
        #expect(frame.cells.allSatisfy { $0.color.alpha == 255 })
    }
}
