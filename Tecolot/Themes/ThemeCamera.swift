//
//  ThemeCamera.swift
//  Tecolot
//
//  Pure camera math for the Canvas three-dimensional theme spaces.
//
import CoreGraphics
import Foundation
import simd

nonisolated struct ThemeCamera: Sendable, Equatable {
    static let canonicalYaw = 36.0
    static let canonicalPitch = 22.0
    static let minimumPitch = -80.0
    static let maximumPitch = 80.0
    static let minimumZoom = 0.5
    static let maximumZoom = 4.0
    /// Uses the available preview height while retaining room for labels.
    static let defaultProjectionScale = 0.76

    /// Degrees. Yaw is wrapped to keep numeric values bounded.
    var yaw: Double {
        didSet { yaw = Self.wrap(yaw) }
    }
    /// Degrees. Pitch is constrained so the view cannot invert.
    var pitch: Double {
        didSet { pitch = min(max(pitch, Self.minimumPitch), Self.maximumPitch) }
    }
    var zoom: Double {
        didSet { zoom = min(max(zoom, Self.minimumZoom), Self.maximumZoom) }
    }

    init(yaw: Double = ThemeCamera.canonicalYaw, pitch: Double = ThemeCamera.canonicalPitch, zoom: Double = 1) {
        self.yaw = Self.wrap(yaw)
        self.pitch = min(max(pitch, Self.minimumPitch), Self.maximumPitch)
        self.zoom = min(max(zoom, Self.minimumZoom), Self.maximumZoom)
    }

    static func canonical(for mode: ThemePlotMode) -> ThemeCamera {
        // V1 uses one carefully chosen viewpoint. The per-mode factory is
        // intentional: it leaves a stable place for future tuned views.
        ThemeCamera()
    }

    mutating func rotate(horizontalDelta: Double, verticalDelta: Double, sensitivity: Double = 0.45) {
        yaw += horizontalDelta * sensitivity
        pitch += verticalDelta * sensitivity
    }

    mutating func setZoom(_ value: Double) {
        zoom = value
    }

    func cameraSpacePosition(of position: SIMD3<Double>) -> SIMD3<Double> {
        let yawRadians = yaw * .pi / 180
        let pitchRadians = pitch * .pi / 180

        let yawed = SIMD3(
            cos(yawRadians) * position.x - sin(yawRadians) * position.z,
            position.y,
            sin(yawRadians) * position.x + cos(yawRadians) * position.z
        )
        return SIMD3(
            yawed.x,
            cos(pitchRadians) * yawed.y - sin(pitchRadians) * yawed.z,
            sin(pitchRadians) * yawed.y + cos(pitchRadians) * yawed.z
        )
    }

    /// Orthographic projection. Camera-space positive Z is nearer the user.
    /// Color Space uses a wider horizontal projection to show its chroma ring.
    func projectedPosition(
        of position: SIMD3<Double>,
        in size: CGSize,
        horizontalScale: Double = 1
    ) -> (point: CGPoint, depth: Double) {
        let cameraSpace = cameraSpacePosition(of: position)
        let screenScale = min(Double(size.width), Double(size.height))
            / 2 * Self.defaultProjectionScale * zoom
        return (
            CGPoint(
                x: size.width / 2 + cameraSpace.x * screenScale * horizontalScale,
                y: size.height / 2 - cameraSpace.y * screenScale
            ),
            cameraSpace.z
        )
    }

    private static func wrap(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped > 180 ? wrapped - 360 : (wrapped <= -180 ? wrapped + 360 : wrapped)
    }
}
