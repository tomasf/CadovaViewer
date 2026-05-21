import Foundation

@objc public protocol CadovaPreviewService {
    func openModel(named name: String,
                   threeMFData: Data,
                   reply: @escaping (Bool, String?) -> Void)
}

public enum CadovaPreview {
    public static let machServiceName = "se.tomasf.CadovaViewer.preview"

    public static var xpcInterface: NSXPCInterface {
        NSXPCInterface(with: CadovaPreviewService.self)
    }
}
