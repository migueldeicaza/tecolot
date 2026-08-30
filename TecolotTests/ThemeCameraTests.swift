//
//  ThemeCameraTests.swift
//  TecolotTests
//
import CoreGraphics
import Testing
@testable import Tecolot

final class ThemeCameraTests {
    @Test func cameraConstrainsPitchZoomAndYaw() {
        var camera = ThemeCamera(yaw: 725, pitch: 100, zoom: 10)
        #expect(camera.yaw == 5)
        #expect(camera.pitch == ThemeCamera.maximumPitch)
        #expect(camera.zoom == ThemeCamera.maximumZoom)

        camera.rotate(horizontalDelta: -2_000, verticalDelta: -2_000)
        camera.setZoom(0.1)
        #expect(camera.yaw >= -180 && camera.yaw <= 180)
        #expect(camera.pitch == ThemeCamera.minimumPitch)
        #expect(camera.zoom == ThemeCamera.minimumZoom)
    }

    @Test func canonicalCameraIsDeterministicAndOrthographic() {
        let first = ThemeCamera.canonical(for: .colorSpace3D)
        let second = ThemeCamera.canonical(for: .colorSpace3D)
        #expect(first == second)

        let size = CGSize(width: 600, height: 380)
        let origin = first.projectedPosition(of: SIMD3(0, 0, 0), in: size)
        let up = first.projectedPosition(of: SIMD3(0, 1, 0), in: size)
        let near = first.projectedPosition(of: SIMD3(0, 0, 1), in: size)
        let far = first.projectedPosition(of: SIMD3(0, 0, -1), in: size)

        #expect(up.point.y < origin.point.y)
        #expect(near.depth > far.depth)
    }

    @Test func horizontalScaleWidensOnlyTheScreenXCoordinate() {
        let camera = ThemeCamera(yaw: 0, pitch: 0)
        let size = CGSize(width: 800, height: 500)
        let normal = camera.projectedPosition(of: SIMD3(1, 0, 0), in: size)
        let wide = camera.projectedPosition(
            of: SIMD3(1, 0, 0),
            in: size,
            horizontalScale: 2
        )

        #expect(abs(wide.point.x - size.width / 2) == 2 * abs(normal.point.x - size.width / 2))
        #expect(wide.point.y == normal.point.y)
        #expect(wide.depth == normal.depth)
    }
}
