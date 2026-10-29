import Foundation
import AVFoundation
import WeTypeASR
#if canImport(AppKit)
import AppKit
#endif

@main
struct WeTypeASRCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        var filePath: String?
        var sayText: String?
        var pasteToApp = false

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--file", "--wav", "-f":
                if i + 1 < args.count {
                    filePath = args[i + 1]
                    i += 1
                }
            case "--say", "-s":
                if i + 1 < args.count {
                    sayText = args[i + 1]
                    i += 1
                }
            case "--paste", "-p":
                pasteToApp = true
            case "--help", "-h":
                printUsage()
                return
            default:
                if !args[i].hasPrefix("-"), sayText == nil, filePath == nil {
                    sayText = args[i]
                }
            }
            i += 1
        }

        if let text = sayText {
            let tmpWav = "/tmp/wetype_cli_say_\(ProcessInfo.processInfo.processIdentifier).wav"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", "Tingting", "-o", tmpWav, "--data-format=LEI16@16000", text]
            try? p.run()
            p.waitUntilExit()
            filePath = tmpWav
        }

        do {
            let session = WeTypeASRSession()
            let events = try session.start()

            if let path = filePath {
                let pcm = try loadPCM16kMono(from: URL(fileURLWithPath: path))
                Task.detached {
                    do {
                        try await session.bootstrapIfNeeded()
                        var offset = pcm.startIndex
                        while offset < pcm.endIndex {
                            let end = min(offset + WeTypeASRSession.chunkBytes, pcm.endIndex)
                            try await session.sendPCM(Data(pcm[offset..<end]))
                            offset = end
                        }
                        try await session.finishAudio()
                    } catch {
                        fputs("\nError: \(error.localizedDescription)\n", stderr)
                        session.close()
                    }
                }
            } else {
                try await session.bootstrapIfNeeded()
                let mic = WeTypeMicrophoneStreamer()
                try mic.start { pcm in
                    Task {
                        try? await session.sendPCM(pcm)
                    }
                }
                fputs("🎙️  Listening from microphone... (Press Enter to stop)\n", stderr)
                Task.detached {
                    _ = readLine()
                    mic.stop()
                    try? await session.finishAudio()
                }
            }

            var finalTranscript = ""
            for try await event in events {
                switch event {
                case let .sessionStarted(uin, voiceId):
                    fputs("Connected (uin=\(uin), voice_id=\(voiceId))\n", stderr)
                case let .partialResult(text, _):
                    finalTranscript = text
                    fputs("\r\u{1B}[K⋯ \(text)", stderr)
                    fflush(stderr)
                case let .finalResult(text, _):
                    finalTranscript = text
                    fputs("\r\u{1B}[K✓ \(text)\n", stderr)
                    print(text)
                    fflush(stdout)
                }
            }

            if pasteToApp, !finalTranscript.isEmpty {
                pasteText(finalTranscript)
            }
        } catch {
            fputs("\nError: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func loadPCM16kMono(from url: URL) throws -> Data {
        let raw = try Data(contentsOf: url)
        if let dataRange = raw.range(of: Data("data".utf8)), dataRange.upperBound + 4 <= raw.count {
            let pcmStart = dataRange.upperBound + 4
            return Data(raw[pcmStart...])
        }
        return raw
    }

    static func pasteText(_ text: String) {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        fputs("📋 Copied to clipboard.\n", stderr)
        #endif
    }

    static func printUsage() {
        print("""
        Usage:
          wetype-asr-cli                          Live microphone streaming (press Enter to stop)
          wetype-asr-cli --paste                  Live microphone + copy final transcript to clipboard
          wetype-asr-cli --file <audio.wav>       Transcribe a 16kHz 16-bit mono WAV/PCM file
          wetype-asr-cli --say "你好世界"          Synthesize TTS via macOS `say` and transcribe it
        """)
    }
}
