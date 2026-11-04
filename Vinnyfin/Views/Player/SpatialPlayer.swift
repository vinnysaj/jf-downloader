import AetherEngine
import SwiftUI
#if os(visionOS)
import AVFoundation
import OSLog
import RealityKit

/// The picture in the player's window on Vision Pro. Whatever AVPlayer plays, RealityKit's video
/// player draws: in 3D when the title is (MV-HEVC, or side-by-side and over-under HEVC, which the
/// engine signals as stereo), with the room tinted by the picture's light. An `AVPlayerLayer`
/// can only show it flat. What the engine decodes itself has no AVPlayer, and goes through its
/// own layer, in 2D.
struct PlayerSurface: View {
    let engine: AetherEngine
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoScreen(player: player)
                    .id(ObjectIdentifier(player))
            } else {
                AetherPlayerSurface(engine: engine)
                    .background(.black)
            }
        }
        .onReceive(engine.$currentAVPlayer) { player = $0 }
    }
}

/// AVPlayer's picture on a RealityKit screen that fills the view.
private struct VideoScreen: View {
    let player: AVPlayer
    @Environment(PlayerCoordinator.self) private var coordinator
    /// The screen's size in meters at a scale of 1, once the video's shape is known.
    @State private var screenSize: SIMD2<Float> = .zero
    @State private var subscriptions: [EventSubscription] = []

    var body: some View {
        GeometryReader3D { geometry in
            RealityView { content in
                // RealityView centers what it holds in its frame, so the screen is placed in this
                // entity's space rather than the scene's.
                let stage = Entity()
                content.add(stage)
                let screen = Entity()
                screen.name = "screen"
                var video = VideoPlayerComponent(avPlayer: player)
                video.isPassthroughTintingEnabled = true
                screen.components.set(video)
                // Behind the subtitles and controls drawn over it in the same plane.
                screen.components.set(ModelSortGroupComponent(group: .planarUIAlwaysBehind, order: 0))
                // The window is clear over the picture, so pinches on it land here.
                screen.components.set(InputTargetComponent())
                stage.addChild(screen)
                subscriptions = [
                    content.subscribe(to: VideoPlayerEvents.VideoSizeDidChange.self, on: screen) { event in
                        screenSize = event.screenMeshSize
                        screen.components.set(CollisionComponent(shapes: [
                            .generateBox(width: event.screenMeshSize.x, height: event.screenMeshSize.y, depth: 0.01),
                        ]))
                    },
                    content.subscribe(to: VideoPlayerEvents.ContentTypeDidChange.self, on: screen) { event in
                        coordinator.pictureIsStereo = event.contentType == .stereo
                    },
                ]
            } update: { content in
                guard let stage = content.entities.first, let screen = stage.findEntity(named: "screen"),
                      screenSize.x > 0, screenSize.y > 0 else { return }
                let bounds = content.convert(geometry.frame(in: .local), from: .local, to: stage)
                let scale = min(bounds.extents.x / screenSize.x, bounds.extents.y / screenSize.y)
                screen.scale = SIMD3(repeating: scale)
                screen.position = bounds.center
            }
            .gesture(TapGesture().targetedToAnyEntity().onEnded { _ in coordinator.screenTaps += 1 })
        }
        // Flat, in the window's plane with the views drawn over it.
        .frame(depth: 0)
    }
}

/// Takes the playback into the cinema, a dark theater with a big screen, and back to its window.
struct CinemaButton: View {
    var onUse: () -> Void = {}
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var failure: String?

    var body: some View {
        Button {
            onUse()
            Task { await toggle() }
        } label: {
            Label(player.isInCinema ? "Leave Cinema" : "Cinema", systemImage: player.isInCinema ? "popcorn.fill" : "popcorn")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.platformGlass)
        .accessibilityIdentifier("player.cinema")
        .alert("Couldn't Open the Cinema", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private func toggle() async {
        if player.isInCinema {
            await dismissImmersiveSpace()
            return
        }
        switch await openImmersiveSpace(id: CinemaSpace.id) {
        case .opened, .userCancelled:
            break
        case .error:
            failure = "Another app's space may be open. Close it and try again."
        @unknown default:
            failure = "visionOS didn't say why."
        }
    }
}

/// The cinema: a dark theater around the player's big screen. The player's window stays where
/// it was, clear, with its controls, which a pinch on the screen shows and hides.
struct CinemaSpace: View {
    static let id = "cinema"
    @Environment(PlayerCoordinator.self) private var player

    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "cinema")

    var body: some View {
        Group {
            if let model = player.presented {
                CinemaStage(model: model)
            }
        }
        .preferredSurroundingsEffect(.dark)
        .onAppear {
            player.isInCinema = true
            Self.setSoundStage(.large)
        }
        .onDisappear {
            player.isInCinema = false
            Self.setSoundStage(.automatic)
        }
    }

    /// A theater-sized sound in the cinema, the system's choice in a window.
    private static func setSoundStage(_ size: AVAudioSession.SoundStageSize) {
        do {
            try AVAudioSession.sharedInstance().setIntendedSpatialExperience(.headTracked(soundStageSize: size, anchoringStrategy: .automatic))
        } catch {
            log.error("Couldn't set the sound stage: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The theater, the screen and the subtitles on it. Distances are in meters from where the
/// viewer stood when the cinema opened.
private struct CinemaStage: View {
    let model: PlayerModel
    @Environment(PlayerCoordinator.self) private var coordinator
    @State private var player: AVPlayer?
    @State private var screenSize: SIMD2<Float> = .zero
    @State private var subscriptions: [EventSubscription] = []

    /// The middle of the screen: a little above eye level, twelve meters away.
    private static let screenCenter = SIMD3<Float>(0, 2.8, -12)
    /// The largest picture the screen shows, about 44 degrees across at 16:9.
    private static let screenBounds = SIMD2<Float>(9.6, 5.4)

    var body: some View {
        RealityView { content in
            content.add(Theater.room(screenCenter: Self.screenCenter, screenBounds: Self.screenBounds))
            let screen = Entity()
            screen.name = "screen"
            screen.position = Self.screenCenter
            content.add(screen)
            let overlay = Entity()
            overlay.name = "overlay"
            overlay.position = Self.screenCenter + SIMD3(0, 0, 0.02)
            overlay.components.set(ViewAttachmentComponent(rootView: ScreenOverlay(model: model)))
            content.add(overlay)
            // What a pinch on the picture lands on, in front of it, sized to it in `update`.
            let target = Entity()
            target.name = "target"
            target.position = Self.screenCenter + SIMD3(0, 0, 0.05)
            target.components.set(InputTargetComponent())
            content.add(target)
            subscriptions = [
                content.subscribe(to: VideoPlayerEvents.VideoSizeDidChange.self, on: screen) { event in
                    screenSize = event.screenMeshSize
                },
                content.subscribe(to: VideoPlayerEvents.ContentTypeDidChange.self, on: screen) { event in
                    coordinator.pictureIsStereo = event.contentType == .stereo
                },
            ]
        } update: { content in
            guard let screen = content.entities.first(where: { $0.name == "screen" }),
                  let overlay = content.entities.first(where: { $0.name == "overlay" }),
                  let target = content.entities.first(where: { $0.name == "target" }) else { return }
            if let player {
                if screen.components[VideoPlayerComponent.self]?.avPlayer !== player {
                    screen.components.set(VideoPlayerComponent(avPlayer: player))
                }
            } else {
                screen.components.remove(VideoPlayerComponent.self)
            }
            if screenSize.x > 0, screenSize.y > 0 {
                screen.scale = SIMD3(repeating: min(Self.screenBounds.x / screenSize.x, Self.screenBounds.y / screenSize.y))
            }
            let aspect = Float(ScreenOverlay.aspect(of: model))
            let width = min(Self.screenBounds.x, Self.screenBounds.y * aspect)
            // The overlay is laid out at a fixed width, so one scale fits it to the picture.
            if let bounds = overlay.components[ViewAttachmentComponent.self]?.bounds, bounds.extents.x > 0 {
                overlay.scale = SIMD3(repeating: width / bounds.extents.x)
            }
            target.components.set(CollisionComponent(shapes: [.generateBox(width: width, height: width / aspect, depth: 0.02)]))
        }
        // The window in front is clear here, so the screen is what's looked at and pinched.
        .gesture(TapGesture().targetedToAnyEntity().onEnded { _ in coordinator.screenTaps += 1 })
        .onReceive(model.engine.$currentAVPlayer) { player = $0 }
    }
}

/// What's laid over the cinema's screen: the subtitles and, for a title the engine decodes
/// itself, the picture, which has no AVPlayer for RealityKit to draw.
private struct ScreenOverlay: View {
    let model: PlayerModel
    @State private var drawsPicture = false

    /// The width it's laid out at, in points.
    private static let width: CGFloat = 1920

    /// The picture's shape, 16:9 until the video says.
    static func aspect(of model: PlayerModel) -> CGFloat {
        guard let size = model.videoSize, size.height > 0 else { return 16.0 / 9.0 }
        return size.width / size.height
    }

    var body: some View {
        ZStack {
            if drawsPicture {
                AetherPlayerSurface(engine: model.engine)
            }
            SubtitleOverlay(model: model, videoSize: model.videoSize)
        }
        .frame(width: Self.width, height: Self.width / Self.aspect(of: model))
        .onReceive(model.engine.$currentAVPlayer) { drawsPicture = $0 == nil }
    }
}

/// The cinema's room, built from planes: a floor, walls and a ceiling in near black, a matte
/// border around the screen, and dim aisle lights along the floor.
private enum Theater {
    static func room(screenCenter: SIMD3<Float>, screenBounds: SIMD2<Float>) -> Entity {
        let room = Entity()
        let width: Float = 26
        let height: Float = 10
        let front = screenCenter.z - 0.3
        let back: Float = 8
        let depth = back - front
        let middle = (front + back) / 2
        let wall = UnlitMaterial(color: UIColor(white: 0.035, alpha: 1))
        let floor = UnlitMaterial(color: UIColor(white: 0.06, alpha: 1))
        let ceiling = UnlitMaterial(color: UIColor(white: 0.02, alpha: 1))
        let border = UnlitMaterial(color: UIColor(white: 0.005, alpha: 1))
        let aisle = UnlitMaterial(color: UIColor(red: 0.55, green: 0.32, blue: 0.12, alpha: 1))

        func plane(width: Float, height: Float, material: UnlitMaterial, position: SIMD3<Float>, yaw: Float = 0, pitch: Float = 0) -> ModelEntity {
            let entity = ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [material])
            entity.position = position
            entity.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
            return entity
        }

        // Planes face +z; each is turned to face into the room.
        room.addChild(plane(width: width, height: height, material: wall, position: [0, height / 2, front]))
        room.addChild(plane(width: width, height: height, material: wall, position: [0, height / 2, back], yaw: .pi))
        room.addChild(plane(width: depth, height: height, material: wall, position: [-width / 2, height / 2, middle], yaw: .pi / 2))
        room.addChild(plane(width: depth, height: height, material: wall, position: [width / 2, height / 2, middle], yaw: -.pi / 2))
        room.addChild(plane(width: width, height: depth, material: floor, position: [0, 0, middle], pitch: -.pi / 2))
        room.addChild(plane(width: width, height: depth, material: ceiling, position: [0, height, middle], pitch: .pi / 2))
        room.addChild(plane(width: screenBounds.x + 0.6, height: screenBounds.y + 0.6, material: border,
                            position: [screenCenter.x, screenCenter.y, front + 0.1]))
        for side: Float in [-1, 1] {
            let light = ModelEntity(mesh: .generateBox(width: 0.06, height: 0.02, depth: depth - 1), materials: [aisle])
            light.position = [side * (width / 2 - 1.5), 0.01, middle]
            room.addChild(light)
        }
        return room
    }
}
#else
typealias PlayerSurface = AetherPlayerSurface
#endif
