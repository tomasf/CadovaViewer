import ArgumentParser

/// Headless Cadova Viewer: the viewer's model loading and rendering as a command-line tool, for
/// scripts and coding agents.
public struct HeadlessViewer: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "cadova-viewer",
        abstract: "Headless Cadova Viewer: works with 3MF model files from the command line.",
        subcommands: [RenderCommand.self, InfoCommand.self]
    )

    public init() {}
}
