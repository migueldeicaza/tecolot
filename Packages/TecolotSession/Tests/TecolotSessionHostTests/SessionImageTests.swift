import Foundation
import Synchronization
import SwiftTerm
import Testing
import TecolotWire
@testable import TecolotSessionHost
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// Images and bidi context in frames.
struct SessionImageTests {
    /// The size owner's grid: 10 × 20 device pixel cells.
    static let size = WireGridSize(columns: 40, rows: 10, cellWidth: 10, cellHeight: 20)

    /// A red Sixel image, 20 pixels wide and 18 high.
    static let sixel = "\u{1b}Pq#0;2;100;0;0#0!20~-!20~-!20~\u{1b}\\"

    /// Fetches the pixels of an image and joins its chunks.
    func fetch(_ client: TestClient, _ imageID: UInt64) async throws -> ImageDataMessage? {
        client.channel.send(FetchImageMessage(imageID: imageID), flags: .required, requestID: 41)
        var result: ImageDataMessage?
        _ = try await client.wait("image \(imageID)") { client in
            let chunks = client.state.withLock { state in
                state.events.filter { $0.kind == .imageData }.compactMap { try? $0.decode(ImageDataMessage.self) }
                    .filter { $0.imageID == imageID }
            }
            guard let first = chunks.first else { return false }
            if first.width == 0 {
                result = first
                return true
            }
            let bytes = chunks.sorted { $0.offset < $1.offset }.flatMap(\.bytes)
            guard bytes.count == first.totalBytes else { return false }
            result = ImageDataMessage(imageID: imageID, width: first.width, height: first.height, bytes: bytes)
            return true
        }
        return result
    }

    func rowImages(_ client: TestClient) -> [(line: UInt64, image: WireRowImage)] {
        client.state.withLock { state in
            state.rows.flatMap { line, row in row.header.images.map { (line, $0) } }.sorted { $0.line < $1.line }
        }
    }

    @Test func sixelSlicesTravelInRowsAndPixelsOnRequest() async throws {
        let host = makeHost(columns: 40, rows: 10)
        let client = try TestClient(host: host, size: Self.size)
        _ = try await client.wait("screen") { $0.lastFrame != nil }
        host.inject("A" + Self.sixel + "\r\nB")
        _ = try await client.wait("image row") { !self.rowImages($0).isEmpty }
        let slices = rowImages(client)
        // 18 pixels in 20 pixel rows: one slice, after "A".
        #expect(slices.count == 1)
        let slice = try #require(slices.first?.image)
        #expect(slice.column == 1)
        #expect(slice.width == 20)
        #expect(slice.height == 18)
        #expect(slice.sourceY == 0)
        #expect(slice.sourceHeight == 18)

        let pixels = try #require(try await fetch(client, slice.imageID))
        #expect(pixels.width == 20)
        #expect(pixels.height == 18)
        #expect(Array(pixels.bytes.prefix(4)) == [255, 0, 0, 255])

        // An unknown image answers with an empty image.
        let missing = try #require(try await fetch(client, 99_999))
        #expect(missing.width == 0)
        client.channel.close()
    }

    /// At 2 device pixels per point, the 40 columns of 10 pixel cells are 400
    /// device pixels (200 points). Programs size Sixel images in device
    /// pixels: a 300 pixel image fits and keeps its size; a 500 pixel image
    /// takes the terminal's width.
    @Test func sixelImagesShrinkOnlyWhenWiderThanTheTerminal() async throws {
        let host = makeHost(columns: 40, rows: 10)
        let client = try TestClient(host: host, size: Self.size)
        _ = try await client.wait("screen") { $0.lastFrame != nil }
        host.inject("\u{1b}Pq#0;2;100;0;0#0!300~\u{1b}\\\r\n")
        _ = try await client.wait("first image") { self.rowImages($0).count == 1 }
        #expect(rowImages(client).first?.image.width == 300)
        host.inject("\u{1b}Pq#0;2;100;0;0#0!500~\u{1b}\\\r\n")
        _ = try await client.wait("second image") { self.rowImages($0).count == 2 }
        #expect(rowImages(client).last?.image.width == 400)
        client.channel.close()
    }

    #if canImport(ImageIO)
    @Test func iTermImagesAreDecoded() async throws {
        // A 4 × 2 blue PNG, sent as OSC 1337 File=.
        let width = 4
        let height = 2
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: rgba.count, by: 4) {
            rgba[index + 2] = 255
            rgba[index + 3] = 255
        }
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false,
                                         intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let host = makeHost(columns: 40, rows: 10)
        let client = try TestClient(host: host, size: Self.size)
        _ = try await client.wait("screen") { $0.lastFrame != nil }
        host.inject("\u{1b}]1337;File=inline=1:\((data as Data).base64EncodedString())\u{07}")
        _ = try await client.wait("image row") { !self.rowImages($0).isEmpty }
        let slice = try #require(rowImages(client).first?.image)
        let pixels = try #require(try await fetch(client, slice.imageID))
        #expect(pixels.width == 4)
        #expect(pixels.height == 2)
        #expect(Array(pixels.bytes.prefix(4)) == [0, 0, 255, 255])
        client.channel.close()
    }
    #endif

    @Test func kittyPlacementsAndImagesArriveInFrames() async throws {
        let host = makeHost(columns: 40, rows: 10)
        let client = try TestClient(host: host, size: Self.size)
        _ = try await client.wait("screen") { $0.lastFrame != nil }
        // A green 2 × 2 RGB image, placed over 3 × 1 cells.
        let green = Data([0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0]).base64EncodedString()
        host.inject("x\u{1b}_Gi=7,f=24,s=2,v=2,a=T,c=3,r=1;\(green)\u{1b}\\")
        var state: WireKittyState?
        _ = try await client.wait("kitty state") { client in
            state = client.state.withLock { $0.frames.compactMap(\.kitty).last }
            return state?.placements.isEmpty == false
        }
        let kitty = try #require(state)
        let placement = try #require(kitty.placements.first)
        #expect(placement.kittyID == 7)
        #expect(placement.column == 1)
        #expect(placement.columns == 3)
        #expect(placement.rows == 1)
        #expect(!placement.isVirtual)
        let frame = try #require(client.lastFrame)
        #expect(UInt64(placement.line) == frame.viewTop)
        let image = try #require(kitty.images.first)
        #expect(image.kittyID == 7)
        #expect(image.width == 2)
        let pixels = try #require(try await fetch(client, image.imageID))
        #expect(pixels.bytes == Array(repeating: [0, 255, 0, 255], count: 4).flatMap { $0 })

        // Deleting the image clears the state.
        host.inject("\u{1b}_Ga=d,d=A\u{1b}\\")
        _ = try await client.wait("kitty cleared") { client in
            client.state.withLock { $0.frames.compactMap(\.kitty).last?.placements.isEmpty == true }
        }
        client.channel.close()
    }

    /// A running Kitty animation sends frames by itself, without output, and
    /// a looping animation reuses the image IDs of the frames it already sent.
    @Test func kittyAnimationsAdvanceWithoutOutput() async throws {
        let host = makeHost(columns: 40, rows: 10)
        let client = try TestClient(host: host, size: Self.size)
        _ = try await client.wait("screen") { $0.lastFrame != nil }
        func kitty(_ control: String, _ pixels: [UInt8]) -> String {
            "\u{1b}_G\(control);\(Data(pixels).base64EncodedString())\u{1b}\\"
        }
        let red: [UInt8] = [255, 0, 0, 255]
        let blue: [UInt8] = [0, 0, 255, 255]
        host.inject(kitty("a=T,f=32,s=1,v=1,i=1,c=2,r=1,q=2", red) +
                    kitty("a=f,f=32,s=1,v=1,i=1,z=30,q=2", blue) +
                    kitty("a=a,i=1,r=1,z=30,q=2", []) +
                    kitty("a=a,i=1,s=3,q=2", []))
        // Collect the image IDs that frames show for image 1, without more output.
        var shown: [UInt64] = []
        _ = try await client.wait("animation frames", timeout: 5) { client in
            shown = client.state.withLock { state in
                state.frames.compactMap { $0.kitty?.images.first { $0.kittyID == 1 }?.imageID }
            }
            var changes = 0
            for index in shown.indices.dropFirst() where shown[index] != shown[index - 1] { changes += 1 }
            return changes >= 4
        }
        #expect(Set(shown).count == 2, "image IDs \(shown)")
        client.channel.close()
    }

    /// A wrapped right-to-left paragraph that starts above the view comes with
    /// its rows above the view; a left-to-right one does not.
    @Test func bidiParagraphsBringTheirRowsAboveTheView() async throws {
        let host = makeHost(columns: 20, rows: 3)
        let client = try TestClient(host: host, size: WireGridSize(columns: 20, rows: 3, cellWidth: 10, cellHeight: 20))
        _ = try await client.wait("screen") { $0.lastFrame != nil }
        #expect(client.state.withLock { $0.frames.first?.maximumBidiParagraphRows } == 500)

        // Four rows of Latin text, then one row: the first two rows are above the view.
        host.inject("\u{1b}[2J\u{1b}[3J\u{1b}[H" + String(repeating: "abcdefghij", count: 8) + "\r\nend")
        _ = try await client.wait("latin") { $0.screen().contains { $0.hasPrefix("end") } }
        var frame = try #require(client.lastFrame)
        // The client may hold an older blank row there, but not the paragraph's text.
        #expect(client.text(ofLine: frame.viewTop - 1)?.contains("abc") != true)

        // The same with Arabic: the rows above the view arrive too.
        let arabic = String(repeating: "مرحبا بالع ", count: 7)
        host.inject("\r\n" + arabic + "\r\nend2")
        _ = try await client.wait("arabic") { $0.screen().contains { $0.hasPrefix("end2") } }
        frame = try #require(client.lastFrame)
        let above = client.state.withLock { state in
            (1 ... 3).compactMap { state.rows[frame.viewTop - $0] }
        }
        #expect(above.count >= 1)
        #expect(above.contains { $0.header.rightToLeft })
        client.channel.close()
    }

    @Test func arrowKeySwapIsAnInputMode() async throws {
        let host = makeHost()
        let client = try TestClient(host: host, size: Self.size)
        _ = try await client.wait("screen") { $0.lastFrame != nil }
        host.inject("\u{1b}[?1243h")
        _ = try await client.wait("mode") { client in
            client.state.withLock { ($0.frames.compactMap(\.modes).last?.input ?? 0) & (1 << 16) != 0 }
        }
        client.channel.close()
    }
}

/// The helper encodes keys with SwiftTerm's host input API. The app's key
/// parity test applies the client's messages with the same calls; this pins
/// the helper to them.
struct SessionKeyEncodingTests {
    final class Capture: TerminalDelegate, @unchecked Sendable {
        let bytes = Mutex<[UInt8]>([])
        func send(source: Terminal, data: ArraySlice<UInt8>) { bytes.withLock { $0 += data } }
    }

    @Test func helperEncodesKeysLikeSwiftTerm() async throws {
        let host = makeHost()
        let written = Capture()
        host.trace = { event in
            if case .childInput(let data) = event { written.bytes.withLock { $0 += data } }
        }
        let client = try TestClient(host: host, size: SessionImageTests.size)
        _ = try await client.wait("screen") { $0.lastFrame != nil }

        let reference = Capture()
        let terminal = Terminal(delegate: reference, options: TerminalOptions(cols: 40, rows: 10))
        let modes = ["", "\u{1b}[?1h\u{1b}=", "\u{1b}[>1u", "\u{1b}[>31u"]
        let keys: [KeyMessage] = [
            KeyMessage(key: "ArrowLeft", code: "ArrowLeft", modifiers: 2),
            KeyMessage(key: "F5", code: "F5", modifiers: 1),
            KeyMessage(key: "1", code: "Numpad1", text: "1"),
            KeyMessage(key: "a", code: "KeyA", modifiers: 1, text: "A", shiftedKey: 65),
            KeyMessage(key: "a", code: "KeyA", modifiers: 4, baseLayoutKey: 0),
            KeyMessage(key: "f", code: "KeyF", modifiers: 2),
            KeyMessage(key: "Enter", code: "NumpadEnter"),
            KeyMessage(key: "Tab", code: "Tab", modifiers: 1),
        ]
        for mode in modes {
            host.inject(mode)
            terminal.feed(text: mode)
            for key in keys {
                written.bytes.withLock { $0 = [] }
                reference.bytes.withLock { $0 = [] }
                client.channel.send(key)
                client.channel.send(TextMessage(text: "é"))
                client.channel.send(InputMessage(bytes: [0xff]))
                let result = terminal.sendHostKey(key: key.key, code: key.code, modifiers: key.modifiers,
                                                  eventType: key.eventType, text: key.text,
                                                  shiftedKey: key.shiftedKey, baseLayoutKey: key.baseLayoutKey)
                if result == 0, let text = key.text, !text.isEmpty { _ = terminal.sendHostText(text) }
                _ = terminal.sendHostText("é")
                terminal.sendUserInput([0xff][...])
                let expected = reference.bytes.withLock { $0 }
                _ = try await client.wait("\(key.key) after \(mode.debugDescription)") { _ in
                    written.bytes.withLock { $0.last == 0xff }
                }
                #expect(written.bytes.withLock { $0 } == expected, "\(key.key) \(key.code) in \(mode.debugDescription)")
            }
        }
        client.channel.close()
    }
}
