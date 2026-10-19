import CoreGraphics
import Testing
@testable import cutie

struct WheelGeometryTests {
    @Test func pickingByDirection() {
        let geometry = WheelGeometry(count: 8)
        let far = geometry.outerRadius + 200 // past the ring still picks by direction
        #expect(geometry.index(at: CGVector(dx: 0, dy: 100)) == 0) // up
        #expect(geometry.index(at: CGVector(dx: 100, dy: 0)) == 2) // right
        #expect(geometry.index(at: CGVector(dx: 0, dy: -far)) == 4) // down
        #expect(geometry.index(at: CGVector(dx: -100, dy: 0)) == 6) // left
        #expect(geometry.index(at: CGVector(dx: 70, dy: 70)) == 1) // up-right
        #expect(geometry.index(at: CGVector(dx: -5, dy: 100)) == 0) // just left of up
    }

    @Test func centerIsCancel() {
        let geometry = WheelGeometry(count: 6)
        #expect(geometry.index(at: CGVector(dx: 5, dy: 5)) == nil)
        #expect(geometry.index(at: CGVector(dx: 0, dy: geometry.innerRadius * 0.7)) == nil)
    }

    @Test func labelsSitOnTheirSlices() {
        let geometry = WheelGeometry(count: 5)
        let center = CGPoint(x: 200, y: 200)
        for index in 0..<5 {
            let point = geometry.point(for: index, radius: geometry.innerRadius + 30, center: center)
            // y-down view point → y-up offset for hit testing
            let offset = CGVector(dx: point.x - center.x, dy: center.y - point.y)
            #expect(geometry.index(at: offset) == index)
            #expect(geometry.slicePath(index, center: center).contains(point))
        }
    }

    @Test func ringGrowsWithMoreSlices() {
        #expect(WheelGeometry(count: 16).outerRadius > WheelGeometry(count: 6).outerRadius)
        #expect(WheelGeometry(count: 6).panelSize.height == WheelGeometry(count: 6).wheelSide + WheelGeometry.footerHeight)
    }
}
