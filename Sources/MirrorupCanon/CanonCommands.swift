public import MirrorupPTP

/// Canon EOS vendor operations used by Mirrorup. Codes and semantics: docs/canon-eos-ptp.md.
public enum CanonOperation {
    public static let getStorageIDs = PTPOperationCode(0x9101)
    public static let getDeviceInfoEx = PTPOperationCode(0x9108)
    public static let setDevicePropValueEx = PTPOperationCode(0x9110)
    public static let getRemoteMode = PTPOperationCode(0x9113)
    public static let setRemoteMode = PTPOperationCode(0x9114)
    public static let setEventMode = PTPOperationCode(0x9115)
    public static let getEvent = PTPOperationCode(0x9116)
    public static let keepDeviceOn = PTPOperationCode(0x911D)
    public static let requestDevicePropValue = PTPOperationCode(0x9127)
    public static let remoteReleaseOn = PTPOperationCode(0x9128)
    public static let remoteReleaseOff = PTPOperationCode(0x9129)
    public static let initiateViewfinder = PTPOperationCode(0x9151)
    public static let terminateViewfinder = PTPOperationCode(0x9152)
    public static let getViewfinderData = PTPOperationCode(0x9153)
    public static let doAF = PTPOperationCode(0x9154)
    public static let driveLens = PTPOperationCode(0x9155)
    public static let zoom = PTPOperationCode(0x9158)
    public static let zoomPosition = PTPOperationCode(0x9159)
    public static let afCancel = PTPOperationCode(0x9160)
}

/// Canon vendor response codes (docs/canon-eos-ptp.md §6).
public enum CanonResponse {
    public static let unknownCommand = PTPResponseCode(0xA001)
    public static let operationRefused = PTPResponseCode(0xA005)
    public static let lensCoverClosed = PTPResponseCode(0xA006)
    public static let lowBattery = PTPResponseCode(0xA101)
    /// Live-view frame not ready yet; retry shortly.
    public static let objectNotReady = PTPResponseCode(0xA102)
    public static let cannotMakeObject = PTPResponseCode(0xA104)
    public static let memoryStatusNotReady = PTPResponseCode(0xA106)
}
