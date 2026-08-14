import Foundation

enum RpcError: LocalizedError {
    case http(Int)
    case parse(String)
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .parse(let msg): return "解析失败：\(msg)"
        case .rpc(let msg): return msg
        }
    }
}

/// Minimal DSH /api HTTP RPC client (client-request envelope over POST /api/<method>).
final class DshRpc {
    private(set) var base: String

    init(port: Int) {
        base = "http://127.0.0.1:\(port)"
    }

    func updatePort(_ port: Int) {
        base = "http://127.0.0.1:\(port)"
    }

    func call(_ method: String,
              payload: [String: Any] = [:],
              timeout: TimeInterval = 4,
              completion: @escaping (Result<Any, Error>) -> Void) {
        guard let url = URL(string: "\(base)/api/\(method)") else {
            completion(.failure(RpcError.parse("bad url")))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let envelope: [String: Any] = [
            "type": "client-request",
            "rpcId": UUID().uuidString,
            "method": method,
            "payload": payload,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: envelope) else {
            completion(.failure(RpcError.parse("cannot encode envelope")))
            return
        }
        request.httpBody = body
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(RpcError.parse("no http response")))
                return
            }
            guard http.statusCode == 200, let data else {
                completion(.failure(RpcError.http(http.statusCode)))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(RpcError.parse("body is not json")))
                return
            }
            guard let result = json["result"] as? [String: Any] else {
                completion(.failure(RpcError.parse("missing result")))
                return
            }
            if let ok = result["ok"] as? Bool, ok {
                completion(.success(result["value"] ?? NSNull()))
            } else if let err = result["error"] as? [String: Any] {
                completion(.failure(RpcError.rpc(err["message"] as? String ?? "rpc error")))
            } else {
                completion(.failure(RpcError.parse("unrecognized result")))
            }
        }.resume()
    }

    /// Blocking variant for health checks (short timeouts only).
    func callSync(_ method: String,
                  payload: [String: Any] = [:],
                  timeout: TimeInterval = 2.5) -> Result<Any, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<Any, Error> = .failure(RpcError.rpc("no response"))
        call(method, payload: payload, timeout: timeout) { result in
            outcome = result
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout + 0.5)
        return outcome
    }

    /// Answer a tool approval: POST /api/respond with a client-response
    /// echoing the request's rpcId. Completion reports whether the server
    /// accepted the answer.
    func respondApproval(_ info: ApprovalInfo, outcome: String,
                         completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(base)/api/respond") else {
            completion(false)
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let envelope: [String: Any] = [
            "type": "client-response",
            "rpcId": info.rpcId,
            "result": [
                "ok": true,
                "value": [
                    "sessionId": info.sessionId,
                    "approvalId": info.approvalId,
                    "outcome": outcome,
                ],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: envelope)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(false)
                return
            }
            let accepted = json["accepted"] as? Bool ?? false
            completion(accepted)
        }.resume()
    }
}
