/// A vector pictogram a backend supplies for a value, in the camera's own artwork (the mode-dial
/// icon for the shooting mode). Shapes fill with the non-zero winding rule inside a `width` × `height`
/// box, y pointing down. Symbols of one set share `height`, `baseline` and `capHeight`: the band
/// their capital letters (P, Av, M) occupy, which a view maps onto the text's capitals so letters
/// and pictograms line up with it. One colour: the camera's own (`tint`) or, without one, the text's.
/// Presentation only: not part of the encoded metadata.
public struct CameraSymbol: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public enum Element: Sendable, Equatable {
        case move(to: Point)
        case line(to: Point)
        case quadCurve(to: Point, control: Point)
        case curve(to: Point, control1: Point, control2: Point)
        case close
    }

    /// An sRGB colour, components 0...1.
    public struct Color: Sendable, Equatable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// The colour the camera prints the symbol in, for light and dark backgrounds: a dial colour
    /// chosen for a black body is too pale on a light popover.
    public struct Tint: Sendable, Equatable {
        public var light: Color
        public var dark: Color

        public init(light: Color, dark: Color) {
            self.light = light
            self.dark = dark
        }
    }

    public let width: Double
    public let height: Double
    /// Distance from the top of the box to the line the set's capital letters sit on.
    public let baseline: Double
    /// Height of the set's capital letters above `baseline`.
    public let capHeight: Double
    public let elements: [Element]
    /// Nil: drawn in the surrounding text's colour.
    public let tint: Tint?

    public init(width: Double, height: Double, baseline: Double, capHeight: Double, elements: [Element],
                tint: Tint? = nil) {
        self.width = width
        self.height = height
        self.baseline = baseline
        self.capHeight = capHeight
        self.elements = elements
        self.tint = tint
    }

    /// Parses absolute SVG path data restricted to `M`, `L`, `Q`, `C` and `Z`, each command letter
    /// followed by exactly its own coordinates ("M0 0L10 0Q5 5 0 10Z"). Nil when the data is malformed.
    public init?(width: Double, height: Double, baseline: Double, capHeight: Double, pathData: String,
                 tint: Tint? = nil) {
        var elements: [Element] = []
        var command: Character?
        var numbers: [Double] = []
        var number = ""

        func endNumber() -> Bool {
            guard !number.isEmpty else { return true }
            guard let value = Double(number) else { return false }
            numbers.append(value)
            number = ""
            return true
        }

        func endCommand() -> Bool {
            guard endNumber() else { return false }
            guard let command else { return numbers.isEmpty }
            let n = numbers
            let element: Element
            switch (command, n.count) {
            case ("M", 2): element = .move(to: Point(x: n[0], y: n[1]))
            case ("L", 2): element = .line(to: Point(x: n[0], y: n[1]))
            case ("Q", 4): element = .quadCurve(to: Point(x: n[2], y: n[3]), control: Point(x: n[0], y: n[1]))
            case ("C", 6):
                element = .curve(to: Point(x: n[4], y: n[5]), control1: Point(x: n[0], y: n[1]),
                                 control2: Point(x: n[2], y: n[3]))
            case ("Z", 0): element = .close
            default: return false
            }
            elements.append(element)
            numbers.removeAll(keepingCapacity: true)
            return true
        }

        for character in pathData {
            switch character {
            case "M", "L", "Q", "C", "Z":
                guard endCommand() else { return nil }
                command = character
            case "-":
                guard endNumber() else { return nil }
                number.append(character)
            case "0"..."9", ".":
                number.append(character)
            case " ", ",", "\n":
                guard endNumber() else { return nil }
            default:
                return nil
            }
        }
        guard endCommand() else { return nil }
        self.init(width: width, height: height, baseline: baseline, capHeight: capHeight, elements: elements, tint: tint)
    }
}
