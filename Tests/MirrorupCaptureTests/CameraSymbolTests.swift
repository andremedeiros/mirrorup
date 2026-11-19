import Testing
import MirrorupCapture

@Suite struct CameraSymbolTests {
    private typealias P = CameraSymbol.Point

    @Test func parsesEveryCommandAcrossSeparators() throws {
        let symbol = try #require(CameraSymbol(width: 10, height: 10, baseline: 8, capHeight: 7, pathData: """
            M0 0L10-5Q1,2 3.5 4
            C1 2 3 4 5 6Z
            """))
        #expect(symbol.elements == [
            .move(to: P(x: 0, y: 0)),
            .line(to: P(x: 10, y: -5)),
            .quadCurve(to: P(x: 3.5, y: 4), control: P(x: 1, y: 2)),
            .curve(to: P(x: 5, y: 6), control1: P(x: 1, y: 2), control2: P(x: 3, y: 4)),
            .close,
        ])
    }

    @Test(arguments: ["M0", "L1 2 3", "0 0", "M0 0 X", "M1..2 3", "Z1"])
    func rejectsMalformedData(_ data: String) {
        #expect(CameraSymbol(width: 1, height: 1, baseline: 1, capHeight: 1, pathData: data) == nil)
    }
}
