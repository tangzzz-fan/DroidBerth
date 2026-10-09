import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// DroidBerth 内部拖拽用的私有类型。
    ///
    /// 只用于同一进程内的窗格间拖拽，不写入磁盘、不对外声明为可打开的类型。
    static let droidBerthTransfer = UTType(exportedAs: "dev.tango.droidberth.transfer")
}

/// 窗格之间拖拽的载荷。
///
/// 除了自己发起的拖拽（`CodableRepresentation`），还通过
/// `ProxyRepresentation(importing: URL.self)` 接收从 Finder 拖进来的文件——
/// 两条来源最终归一成同一个类型，落点只需要处理一种载荷。
struct TransferDragPayload: Codable, Transferable, Sendable {
    /// 拖拽发生在哪一侧。
    enum Side: String, Codable, Sendable {
        case local
        case remote
    }

    /// 拖拽从哪来。用来区分「窗格内部拖拽」与「从 Finder 拖入」——
    /// 两者都是 `local`，但前者同侧移动、后者是上传（PRD §12.1 / §24）。
    enum Origin: String, Codable, Sendable {
        case pane
        case external
    }

    let side: Side
    let origin: Origin
    let paths: [String]

    init(side: Side, origin: Origin, paths: [String]) {
        self.side = side
        self.origin = origin
        self.paths = paths
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .droidBerthTransfer)
        ProxyRepresentation(importing: { (url: URL) in
            TransferDragPayload(side: .local, origin: .external, paths: [url.path])
        })
    }
}
