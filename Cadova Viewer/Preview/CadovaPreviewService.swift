import Foundation

@objc protocol CadovaPreviewService {
    func openModel(named name: String,
                   threeMFData: Data,
                   reply: @escaping (Bool, String?) -> Void)
}

enum CadovaPreview {
    static let machServiceName = "se.tomasf.CadovaViewer.preview"

    static var xpcInterface: NSXPCInterface {
        NSXPCInterface(with: CadovaPreviewService.self)
    }
}
