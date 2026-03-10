import Foundation

final class FileWatcher {
    private let claudeDir: String
    private let parser = JSONLParser()
    private var timer: DispatchSourceTimer?
    private var watchedFiles: [String: WatchedFile] = [:]
    var onEvent: ((DetectedEvent) -> Void)?

    struct WatchedFile {
        let path: String
        let sessionId: String
        let projectName: String
        var fileOffset: UInt64
        var lineBuffer: String
    }

    init(claudeDir: String? = nil) {
        self.claudeDir = claudeDir ?? (NSHomeDirectory() + "/.claude/projects")
    }

    func start() {
        let queue = DispatchQueue(label: "com.ccbar.filewatcher")
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer?.schedule(deadline: .now(), repeating: 1.0)
        timer?.setEventHandler { [weak self] in
            self?.scan()
        }
        timer?.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        watchedFiles.removeAll()
    }

    private func scan() {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: claudeDir) else { return }

        var currentFiles = Set<String>()

        for projectDir in projectDirs {
            let projectPath = (claudeDir as NSString).appendingPathComponent(projectDir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let fullPath = (projectPath as NSString).appendingPathComponent(file)
                currentFiles.insert(fullPath)

                if watchedFiles[fullPath] == nil {
                    let sessionId = String(file.dropLast(6))  // remove .jsonl
                    let attrs = try? fm.attributesOfItem(atPath: fullPath)
                    let fileSize = (attrs?[.size] as? UInt64) ?? 0
                    let decodedPath = Self.decodeProjectDir(projectDir)
                    watchedFiles[fullPath] = WatchedFile(
                        path: fullPath,
                        sessionId: sessionId,
                        projectName: decodedPath,
                        fileOffset: fileSize,
                        lineBuffer: ""
                    )
                }

                readNewLines(path: fullPath)
            }
        }

        let removedPaths = Set(watchedFiles.keys).subtracting(currentFiles)
        for path in removedPaths {
            if let watched = watchedFiles[path] {
                onEvent?(.sessionEnded(sessionId: watched.sessionId))
            }
            watchedFiles.removeValue(forKey: path)
        }
    }

    private func readNewLines(path: String) {
        guard var watched = watchedFiles[path] else { return }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { handle.closeFile() }

        handle.seek(toFileOffset: watched.fileOffset)
        let newData = handle.readDataToEndOfFile()
        guard !newData.isEmpty else { return }
        watched.fileOffset += UInt64(newData.count)

        guard let newText = String(data: newData, encoding: .utf8) else {
            watchedFiles[path] = watched
            return
        }

        let combined = watched.lineBuffer + newText
        var lines = combined.components(separatedBy: "\n")

        if !combined.hasSuffix("\n") {
            watched.lineBuffer = lines.removeLast()
        } else {
            watched.lineBuffer = ""
            if lines.last == "" { lines.removeLast() }
        }

        watchedFiles[path] = watched

        for line in lines where !line.isEmpty {
            for event in parser.parseLineEvents(line) {
                onEvent?(event)
            }
        }
    }

    func startFromBeginning(forPath path: String) {
        if var watched = watchedFiles[path] {
            watched.fileOffset = 0
            watchedFiles[path] = watched
        }
    }

    func scanNow() {
        scan()
    }

    /// Extract a display name from Claude's encoded project directory name.
    /// Claude encodes paths by replacing non-alphanumeric chars with "-",
    /// so the encoding is lossy. We use the last segment as the display name.
    /// e.g. "-Users-cody-my-project" -> "my-project"
    static func decodeProjectDir(_ encoded: String) -> String {
        guard encoded.hasPrefix("-") else { return encoded }
        // Split on the path-separator pattern: a hyphen preceded by a lowercase/digit
        // and followed by an uppercase letter indicates a new path segment.
        // Fallback: use everything after the last segment that looks like a common prefix.
        let path = encoded.replacingOccurrences(of: "-", with: "/")
        return (path as NSString).lastPathComponent
    }
}
