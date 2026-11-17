import Foundation

public enum WheelMath {
    /// Segment under a pointer offset from the wheel center (`dy` positive = up).
    /// Segment 0 is centered at 12 o'clock and indices run clockwise.
    /// Returns nil inside the dead zone.
    public static func segment(dx: Double, dy: Double, deadZone: Double, count: Int = 8) -> Int? {
        guard count > 0, (dx * dx + dy * dy).squareRoot() >= deadZone else { return nil }
        let span = 360.0 / Double(count)
        var deg = atan2(dx, dy) * 180 / .pi + span / 2
        deg = (deg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return min(count - 1, Int(deg / span))
    }

    /// Center angle of a segment in degrees, clockwise from 12 o'clock.
    public static func centerAngle(of index: Int, count: Int = 8) -> Double {
        Double(index) * 360.0 / Double(count)
    }
}
