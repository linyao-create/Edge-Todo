import Foundation

enum ArchiveTransportError: Error, LocalizedError {
    case invalidResponse, missingCLI, processFailed, timedOut
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "飞书返回无法确认归档结果"
        case .missingCLI: "找不到已安装的飞书 CLI"
        case .processFailed: "飞书 CLI 执行失败，请检查网络和用户授权"
        case .timedOut: "飞书 CLI 超时"
        }
    }
}
