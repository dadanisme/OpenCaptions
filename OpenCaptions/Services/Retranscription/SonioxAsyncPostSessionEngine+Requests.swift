//
//  SonioxAsyncPostSessionEngine+Requests.swift
//  OpenCaptions
//
//  The Soniox async REST calls: upload the audio, create the transcription job,
//  poll for completion, fetch the transcript, and delete the server-side artifacts.
//  Split from the engine core to stay under the line limit.
//

import Foundation

extension SonioxAsyncPostSessionEngine {

    // MARK: - Upload

    /// `POST /v1/files` (multipart) → file id. Reads the `.m4a` into memory (a
    /// 1-hour session ≈ 14 MB at the recorder's 32 kbps, so this is safe).
    func uploadFile(_ url: URL, key: String) async throws -> String {
        let audio: Data
        do {
            audio = try Data(contentsOf: url)
        } catch {
            throw PostSessionEngineError.audioUnavailable
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("files"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent)\"\r\n".utf8))
        body.append(Data("Content-Type: audio/m4a\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        guard let id = Self.json(data)?["id"] as? String else {
            throw PostSessionEngineError.provider("Upload returned no file id.")
        }
        return id
    }

    // MARK: - Create

    /// `POST /v1/transcriptions` → transcription id (job starts `queued`).
    func createTranscription(fileId: String, key: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "model": model,
            "file_id": fileId,
            "enable_speaker_diarization": true,
            "language_hints": ["id", "en", "ar"],
        ]
        // Same serialization the live config uses, so the two paths bias identically.
        // Omitted entirely when empty rather than sent as an empty object.
        let contextDict = sonioxContext.toDictionary()
        if !contextDict.isEmpty {
            payload["context"] = contextDict
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        guard let id = Self.json(data)?["id"] as? String else {
            throw PostSessionEngineError.provider("Create returned no transcription id.")
        }
        return id
    }

    // MARK: - Poll

    /// `GET /v1/transcriptions/{id}` every 2 s until `completed` (or `error`).
    /// Cooperatively cancellable via `Task.sleep`.
    func pollUntilComplete(transcriptionId: String, key: String) async throws {
        let url = baseURL.appendingPathComponent("transcriptions").appendingPathComponent(transcriptionId)
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.check(response, data)

            let obj = Self.json(data)
            switch obj?["status"] as? String {
            case "completed":
                return
            case "error":
                throw PostSessionEngineError.provider(
                    obj?["error_message"] as? String ?? "Transcription failed.")
            default:
                break  // queued / processing
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    // MARK: - Fetch

    /// `GET /v1/transcriptions/{id}/transcript` → ordered tokens.
    func fetchTranscript(transcriptionId: String, key: String) async throws -> [PostSessionToken] {
        let url = baseURL.appendingPathComponent("transcriptions")
            .appendingPathComponent(transcriptionId)
            .appendingPathComponent("transcript")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        guard let raw = Self.json(data)?["tokens"] as? [[String: Any]] else { return [] }
        return raw.compactMap { Self.token(from: $0) }
    }

    // MARK: - Cleanup

    /// Best-effort deletion of the server-side job + file (ignores failures). Static so
    /// the fire-and-forget cleanup `Task` captures only Sendable values, not `self`.
    static func cleanup(baseURL: URL, fileId: String?, transcriptionId: String?, key: String) async {
        if let transcriptionId {
            await delete(baseURL: baseURL, path: "transcriptions/\(transcriptionId)", key: key)
        }
        if let fileId {
            await delete(baseURL: baseURL, path: "files/\(fileId)", key: key)
        }
    }

    private static func delete(baseURL: URL, path: String, key: String) async {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Helpers

    /// Parses a JSON object body, or nil.
    static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Throws a descriptive error for any non-2xx response.
    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PostSessionEngineError.network("Invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = json(data)?["error_message"] as? String
            throw PostSessionEngineError.provider(message ?? "HTTP \(http.statusCode)")
        }
    }
}
