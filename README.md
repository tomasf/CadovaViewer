# Cadova Viewer

Cadova Viewer is a macOS app for viewing 3MF 3D model files, designed as a companion to the [Cadova Swift library](https://github.com/tomasf/Cadova) for programmatic 3D modeling.

It’s a lightweight, fast viewer that updates automatically as files change, ideal for iterative workflows where Cadova regenerates models on disk.

## Features
* Live reloading: Automatically refreshes when the 3MF file changes on disk.
* Materials & Colors: Supports the core 3MF spec, plus colors from the 3MF Materials and Properties Extension, including PBR.
* Object management: View all 3MF objects in a list, with toggleable visibility.
* SpaceMouse support: Navigate freely with 3DConnexion’s SpaceMouse.
* macOS-native: Built with native APIs for smooth integration with the macOS ecosystem.

Cadova Viewer uses [ThreeMF](https://github.com/tomasf/ThreeMF) and [NavLibSwift](https://github.com/tomasf/NavLibSwift).

## Contributions

Contributions are welcome! If you have ideas, suggestions, or improvements, feel free to open an issue or submit a pull request.

## License

This project is licensed under the MIT License. See the LICENSE file for details.