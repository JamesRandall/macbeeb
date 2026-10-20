// Lets device state stored in InlineArrays be Codable.

extension InlineArray: @retroactive Encodable where Element: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for i in indices {
            try container.encode(self[i])
        }
    }
}

extension InlineArray: @retroactive Decodable where Element: Decodable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self = try InlineArray { _ in try container.decode(Element.self) }
    }
}
