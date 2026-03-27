import AngyCore
import AppKit
import Foundation

protocol SoundPlaybackBackend {
    @discardableResult
    func playResource(at url: URL) -> Bool

    @discardableResult
    func playSystemSound(named name: String) -> Bool

    func beep()
}

struct SystemSoundPlaybackBackend: SoundPlaybackBackend {
    @discardableResult
    func playResource(at url: URL) -> Bool {
        let sound = NSSound(contentsOf: url, byReference: false)
        return sound?.play() ?? false
    }

    @discardableResult
    func playSystemSound(named name: String) -> Bool {
        let sound = NSSound(named: NSSound.Name(name))
        return sound?.play() ?? false
    }

    func beep() {
        NSSound.beep()
    }
}

@MainActor
final class SoundEffectPlayer {
    private let isEnabled: Bool
    private let bundle: Bundle
    private let backend: any SoundPlaybackBackend

    init(
        config: AppConfig,
        bundle: Bundle = .module,
        backend: any SoundPlaybackBackend = SystemSoundPlaybackBackend()
    ) {
        isEnabled = config.soundEnabled
        self.bundle = bundle
        self.backend = backend
    }

    func play(_ event: SoundEffectEvent) {
        guard isEnabled else {
            return
        }

        if let resourceURL = bundledSoundURL(for: event),
           backend.playResource(at: resourceURL) {
            return
        }

        if let systemSoundName = systemSoundName(for: event),
           backend.playSystemSound(named: systemSoundName) {
            return
        }

        backend.beep()
    }

    private func bundledSoundURL(for event: SoundEffectEvent) -> URL? {
        let supportedExtensions = ["wav", "aiff", "aif", "m4a", "mp3"]

        for fileExtension in supportedExtensions {
            if let url = bundle.url(
                forResource: event.rawValue,
                withExtension: fileExtension,
                subdirectory: "Sounds"
            ) {
                return url
            }
        }

        return nil
    }

    private func systemSoundName(for event: SoundEffectEvent) -> String? {
        switch event {
        case .blocked:
            return "Funk"
        case .furious:
            return "Sosumi"
        case .critical:
            return "Blow"
        case .explode:
            return "Glass"
        }
    }
}
