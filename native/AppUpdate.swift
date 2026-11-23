import AppKit
import Darwin

struct AppUpdate {
    let tag: String
    var version: String { String(tag.dropFirst()) }
    var releaseURL: URL { URL(string: "https://github.com/sponge1645/ytdl/releases/tag/\(tag)")! }
    private var archiveName: String { "Media-Downloader-\(version).zip" }

    private enum Failure: Error {
        case download, invalidBundle, verification, replacement
    }

    private func download(_ name: String, to destination: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let url = URL(string: "https://github.com/sponge1645/ytdl/releases/download/\(tag)/\(name)")!
        URLSession.shared.downloadTask(with: url) { temporary, response, error in
            do {
                if let error = error { throw error }
                guard let temporary = temporary, let http = response as? HTTPURLResponse,
                      http.statusCode == 200 else { throw Failure.download }
                try FileManager.default.moveItem(at: temporary, to: destination)
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }.resume()
    }

    func prepare(completion: @escaping (Result<URL, Error>) -> Void) {
        let files = FileManager.default
        do {
            let directory = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: Bundle.main.bundleURL, create: true)
            let archive = directory.appendingPathComponent(archiveName)
            let signature = directory.appendingPathComponent(archiveName + ".sig")
            func finish(_ result: Result<URL, Error>) {
                if case .failure = result { try? files.removeItem(at: directory) }
                DispatchQueue.main.async { completion(result) }
            }
            download(archiveName + ".sig", to: signature) { result in
                if case .failure(let error) = result { finish(.failure(error)); return }
                download(archiveName, to: archive) { result in
                    do {
                        try result.get()
                        guard let key = Bundle.main.url(forResource: "tools-update-public", withExtension: "pem") else {
                            throw Failure.verification
                        }
                        try run("/usr/bin/openssl", ["dgst", "-sha256", "-verify", key.path,
                                                    "-signature", signature.path, archive.path])
                        try run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
                        let app = directory.appendingPathComponent("Media Downloader.app", isDirectory: true)
                        guard let bundle = Bundle(url: app),
                              let identifier = Bundle.main.bundleIdentifier, bundle.bundleIdentifier == identifier,
                              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
                            throw Failure.invalidBundle
                        }
                        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
                        finish(.success(app))
                    } catch { finish(.failure(error)) }
                }
            }
        } catch { completion(.failure(error)) }
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.verification }
    }

    static func swap(_ staged: URL, with installed: URL) throws {
        let result = staged.withUnsafeFileSystemRepresentation { source in
            installed.withUnsafeFileSystemRepresentation { destination in
                guard let source = source, let destination = destination else { return Int32(-1) }
                return renamex_np(source, destination, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else { throw Failure.replacement }
    }
}
