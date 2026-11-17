import MirrorupCanon
public import MirrorupDevices

extension CameraRegistry {
    /// Every driver Mirrorup ships, in matching order. Adding a camera maker means adding its driver
    /// module and listing it here (docs/adding-a-camera.md).
    public static let builtIn = CameraRegistry(drivers: [
        CanonDriver(),
    ])
}
