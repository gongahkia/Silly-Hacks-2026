import Foundation

public struct ASCIIArtOptions: Sendable, Equatable {
    public var outputColumns: Int
    public var characterAspectRatio: Double
    public var alphaThreshold: Double
    public var brightness: Double
    public var contrast: Double
    public var gamma: Double
    public var orderedDitherStrength: Double
    public var charset: String

    public init(
        outputColumns: Int,
        characterAspectRatio: Double,
        alphaThreshold: Double,
        brightness: Double,
        contrast: Double,
        gamma: Double,
        orderedDitherStrength: Double,
        charset: String
    ) {
        self.outputColumns = outputColumns
        self.characterAspectRatio = characterAspectRatio
        self.alphaThreshold = alphaThreshold
        self.brightness = brightness
        self.contrast = contrast
        self.gamma = gamma
        self.orderedDitherStrength = orderedDitherStrength
        self.charset = charset
    }
}

public extension ASCIIArtOptions {
    static let grainradInspiredSticker = ASCIIArtOptions(
        outputColumns: 40,
        characterAspectRatio: 0.55,
        alphaThreshold: 0.08,
        brightness: 0.02,
        contrast: 1.18,
        gamma: 0.92,
        orderedDitherStrength: 0.045,
        charset: " .'`^\",:;Il!i><~+_-?][}{1)(|\\/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$"
    )
}

public struct ASCIIArtColor: Sendable, Equatable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var isTransparent: Bool {
        alpha == 0
    }
}

public struct ASCIIArtCell: Sendable, Equatable {
    public var glyph: Character
    public var color: ASCIIArtColor

    public init(glyph: Character, color: ASCIIArtColor) {
        self.glyph = glyph
        self.color = color
    }
}

public struct ASCIIArtFrame: Sendable, Equatable {
    public var columns: Int
    public var rows: Int
    public var cells: [ASCIIArtCell]

    public init(columns: Int, rows: Int, cells: [ASCIIArtCell]) {
        self.columns = columns
        self.rows = rows
        self.cells = cells
    }

    public subscript(column column: Int, row row: Int) -> ASCIIArtCell {
        cells[(row * columns) + column]
    }
}

public enum ASCIIArtRenderer {
    private static let orderedDither4x4: [Double] = [
        -0.50,  0.00, -0.38,  0.12,
         0.25, -0.25,  0.38, -0.12,
        -0.31,  0.19, -0.44,  0.06,
         0.44, -0.06,  0.31, -0.19
    ]

    public static func render(
        rgbaBytes: [UInt8],
        width: Int,
        height: Int,
        options: ASCIIArtOptions = .grainradInspiredSticker
    ) -> ASCIIArtFrame {
        guard width > 0, height > 0 else {
            return ASCIIArtFrame(columns: 0, rows: 0, cells: [])
        }

        let pixelCount = width * height
        guard rgbaBytes.count >= pixelCount * 4 else {
            return ASCIIArtFrame(columns: 0, rows: 0, cells: [])
        }

        let columns = max(1, options.outputColumns)
        let rows = max(
            1,
            Int(
                (
                    (Double(height) / Double(width))
                    * Double(columns)
                    * max(0.1, options.characterAspectRatio)
                ).rounded()
            )
        )

        let visibleCharset = visibleCharacters(from: options.charset)
        let xStep = Double(width) / Double(columns)
        let yStep = Double(height) / Double(rows)

        var cells: [ASCIIArtCell] = []
        cells.reserveCapacity(columns * rows)

        for row in 0..<rows {
            for column in 0..<columns {
                let startX = min(width - 1, Int(Double(column) * xStep))
                let endX = max(startX + 1, min(width, Int(Double(column + 1) * xStep)))
                let startY = min(height - 1, Int(Double(row) * yStep))
                let endY = max(startY + 1, min(height, Int(Double(row + 1) * yStep)))

                let sample = sampleCell(
                    rgbaBytes: rgbaBytes,
                    width: width,
                    startX: startX,
                    endX: endX,
                    startY: startY,
                    endY: endY
                )

                guard sample.alpha >= options.alphaThreshold, sample.weight > 0 else {
                    cells.append(
                        ASCIIArtCell(
                            glyph: " ",
                            color: ASCIIArtColor(red: 0, green: 0, blue: 0, alpha: 0)
                        )
                    )
                    continue
                }

                let dither = orderedDither4x4[(row % 4) * 4 + (column % 4)] * options.orderedDitherStrength
                let luminance = adjustedLuminance(
                    red: sample.red,
                    green: sample.green,
                    blue: sample.blue,
                    brightness: options.brightness,
                    contrast: options.contrast,
                    gamma: options.gamma,
                    dither: dither
                )

                let glyphIndex = Int(
                    ((1.0 - luminance) * Double(visibleCharset.count - 1)).rounded()
                )
                let glyph = visibleCharset[clamp(glyphIndex, lower: 0, upper: visibleCharset.count - 1)]

                cells.append(
                    ASCIIArtCell(
                        glyph: glyph,
                        color: ASCIIArtColor(
                            red: UInt8(clamp(Int((sample.red * 255.0).rounded()), lower: 0, upper: 255)),
                            green: UInt8(clamp(Int((sample.green * 255.0).rounded()), lower: 0, upper: 255)),
                            blue: UInt8(clamp(Int((sample.blue * 255.0).rounded()), lower: 0, upper: 255)),
                            alpha: UInt8(clamp(Int((sample.alpha * 255.0).rounded()), lower: 0, upper: 255))
                        )
                    )
                )
            }
        }

        return ASCIIArtFrame(columns: columns, rows: rows, cells: cells)
    }

    private static func visibleCharacters(from charset: String) -> [Character] {
        let trimmed = Array(charset).drop(while: { $0 == " " })
        return trimmed.isEmpty ? ["#"] : Array(trimmed)
    }

    private static func sampleCell(
        rgbaBytes: [UInt8],
        width: Int,
        startX: Int,
        endX: Int,
        startY: Int,
        endY: Int
    ) -> (red: Double, green: Double, blue: Double, alpha: Double, weight: Double) {
        var redSum = 0.0
        var greenSum = 0.0
        var blueSum = 0.0
        var alphaSum = 0.0
        var weightSum = 0.0
        var samples = 0.0

        for y in startY..<endY {
            for x in startX..<endX {
                let offset = ((y * width) + x) * 4
                let red = Double(rgbaBytes[offset]) / 255.0
                let green = Double(rgbaBytes[offset + 1]) / 255.0
                let blue = Double(rgbaBytes[offset + 2]) / 255.0
                let alpha = Double(rgbaBytes[offset + 3]) / 255.0
                let weight = max(0.0, alpha)

                redSum += red * weight
                greenSum += green * weight
                blueSum += blue * weight
                alphaSum += alpha
                weightSum += weight
                samples += 1.0
            }
        }

        guard samples > 0 else {
            return (0, 0, 0, 0, 0)
        }

        guard weightSum > 0 else {
            return (0, 0, 0, 0, 0)
        }

        return (
            red: redSum / weightSum,
            green: greenSum / weightSum,
            blue: blueSum / weightSum,
            alpha: alphaSum / samples,
            weight: weightSum
        )
    }

    private static func adjustedLuminance(
        red: Double,
        green: Double,
        blue: Double,
        brightness: Double,
        contrast: Double,
        gamma: Double,
        dither: Double
    ) -> Double {
        let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
        let contrasted = ((luminance + brightness - 0.5) * contrast) + 0.5 + dither
        let clamped = clamp(contrasted, lower: 0.0, upper: 1.0)
        let safeGamma = max(0.01, gamma)
        return pow(clamped, 1.0 / safeGamma)
    }

    private static func clamp<T: Comparable>(_ value: T, lower: T, upper: T) -> T {
        min(max(value, lower), upper)
    }
}
