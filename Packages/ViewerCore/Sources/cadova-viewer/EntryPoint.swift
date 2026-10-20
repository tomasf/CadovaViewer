import CadovaViewerCLI

/// The command implementation lives in CadovaViewerCLI so this entry point can be shared between
/// the SwiftPM executable and the Xcode target that's embedded in the app bundle.
@main
enum EntryPoint {
    static func main() async {
        await HeadlessViewer.main()
    }
}
