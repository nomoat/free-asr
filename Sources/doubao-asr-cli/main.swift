import Foundation
import AVFoundation
import DoubaoASR
#if canImport(AppKit)
import AppKit
#endif

@main
struct DoubaoASRCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        var filePath: String?
        var sayText: String?
        var pasteToApp = false

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--file", "-f":
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
                break
            }
            i += 1
        }

        if let text = sayText {
            let tmpWav = "/tmp/doubao_cli_say.wav"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", "Tingting", "-o", tmpWav, "--data-format=LEI16@16000", text]
            try? p.run()
            p.waitUntilExit()
            filePath = tmpWav
        }

        do {
            let session = DoubaoASRSession()
            let events = try session.start()

            if let path = filePath {
                let pcm = try loadPCM16kMono(from: URL(fileURLWithPath: path))
                Task.detached {
                    var offset = pcm.startIndex
                    while offset < pcm.endIndex {
                        let end = min(offset + DoubaoASRSession.chunkBytes, pcm.endIndex)
                        session.sendPCM(Data(pcm[offset..<end]))
                        offset = end
                        try? await Task.sleep(nanoseconds: 40_000_000)
                    }
                    session.finishAudio()
                }
            } else {
                let mic = DoubaoMicrophoneStreamer()
                try mic.start { pcm in
                    session.sendPCM(pcm)
                }
                fputs("🎙️  Listening from microphone... (Press Enter to stop)\n", stderr)
                Task.detached {
                    _ = readLine()
                    mic.stop()
                    session.finishAudio()
                }
            }

            var finalTranscript = ""
            for try await event in events {
                switch event {
                case .sessionStarted(let tid):
                    fputs("Connected (task_id=\(tid))\n", stderr)
                case .vadStarted:
                    break
                case let .partialResult(text, _, _):
                    fputs("\r\u{1B}[K⋯ \(text)", stderr)
                    fflush(stderr)
                case let .finalResult(text, latencyMs, _):
                    finalTranscript = text
                    let latStr = latencyMs.map { " (\($0) ms)" } ?? ""
                    fputs("\r\u{1B}[K✓ \(text)\(latStr)\n", stderr)
                    print(text)
                    fflush(stdout)
                case .sessionFinished, .taskFinished, .taskStarted:
                    break
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
        // Fast path for 16kHz 16-bit mono WAV produced by `say --data-format=LEI16@16000`
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
        Usage: doubao-asr-cli [options]
          (no args)          Record live from Mac microphone until Enter is pressed
          --file, -f <path>  Stream a 16kHz 16-bit mono WAV/PCM file
          --say, -s <text>   Synthesize speech with macOS `say` and transcribe it
          --paste, -p        Copy final transcript to clipboard
        """)
    }
}
