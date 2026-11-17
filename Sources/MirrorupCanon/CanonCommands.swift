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

    public static let names: [UInt16: String] = [
        0x9101: "EOS_GetStorageIDs", 0x9102: "EOS_GetStorageInfo", 0x9103: "EOS_GetObjectInfo",
        0x9104: "EOS_GetObject", 0x9105: "EOS_DeleteObject", 0x9106: "EOS_FormatStore",
        0x9107: "EOS_GetPartialObject", 0x9108: "EOS_GetDeviceInfoEx", 0x9109: "EOS_GetObjectInfoEx",
        0x910A: "EOS_GetThumbEx", 0x910B: "EOS_SendPartialObject", 0x910C: "EOS_SetObjectAttributes",
        0x910D: "EOS_GetObjectTime", 0x910E: "EOS_SetObjectTime", 0x910F: "EOS_RemoteRelease",
        0x9110: "EOS_SetDevicePropValueEx", 0x9113: "EOS_GetRemoteMode", 0x9114: "EOS_SetRemoteMode",
        0x9115: "EOS_SetEventMode", 0x9116: "EOS_GetEvent", 0x9117: "EOS_TransferComplete",
        0x9118: "EOS_CancelTransfer", 0x9119: "EOS_ResetTransfer", 0x911A: "EOS_PCHDDCapacity",
        0x911B: "EOS_SetUILock", 0x911C: "EOS_ResetUILock", 0x911D: "EOS_KeepDeviceOn",
        0x911E: "EOS_SetNullPacketMode", 0x911F: "EOS_UpdateFirmware", 0x9120: "EOS_TransferCompleteDT",
        0x9121: "EOS_CancelTransferDT", 0x9122: "EOS_SetWftProfile", 0x9123: "EOS_GetWftProfile",
        0x9124: "EOS_SetProfileToWft", 0x9125: "EOS_BulbStart", 0x9126: "EOS_BulbEnd",
        0x9127: "EOS_RequestDevicePropValue", 0x9128: "EOS_RemoteReleaseOn", 0x9129: "EOS_RemoteReleaseOff",
        0x912A: "EOS_RegistBackgroundImage", 0x912B: "EOS_ChangePhotoStudioMode", 0x912C: "EOS_GetPartialObjectEx",
        0x9130: "EOS_ResetMirrorLockupState", 0x9131: "EOS_PopupBuiltinFlash", 0x9132: "EOS_EndGetPartialObjectEx",
        0x9133: "EOS_MovieSelectSWOn", 0x9134: "EOS_MovieSelectSWOff", 0x9135: "EOS_GetCTGInfo",
        0x9136: "EOS_GetLensAdjust", 0x9137: "EOS_SetLensAdjust", 0x9138: "EOS_ReadyToSendMusic",
        0x9139: "EOS_CreateHandle", 0x913A: "EOS_SendPartialObjectEx", 0x913B: "EOS_EndSendPartialObjectEx",
        0x913C: "EOS_SetCTGInfo", 0x913D: "EOS_SetRequestOLCInfoGroup", 0x913E: "EOS_SetRequestRollingPitchingLevel",
        0x913F: "EOS_GetCameraSupport", 0x9140: "EOS_SetRating", 0x9141: "EOS_RequestInnerDevelopStart",
        0x9151: "EOS_InitiateViewfinder", 0x9152: "EOS_TerminateViewfinder", 0x9153: "EOS_GetViewFinderData",
        0x9154: "EOS_DoAf", 0x9155: "EOS_DriveLens", 0x9156: "EOS_DepthOfFieldPreview",
        0x9157: "EOS_ClickWB", 0x9158: "EOS_Zoom", 0x9159: "EOS_ZoomPosition", 0x915A: "EOS_SetLiveAfFrame",
        0x915B: "EOS_TouchAfPosition", 0x915C: "EOS_SetLvPcFlavoreditMode", 0x915D: "EOS_SetLvPcFlavoreditParam",
        0x9160: "EOS_AfCancel", 0x91FE: "EOS_FAPIMessageTX", 0x91FF: "EOS_FAPIMessageRX",
    ]

    /// Readable name for a standard or Canon opcode.
    public static func describe(_ code: UInt16) -> String {
        let hex = "0x" + String(code, radix: 16, uppercase: true)
        if let name = PTPOperationCode(code).name ?? names[code] { return "\(name) (\(hex))" }
        return hex
    }
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

    static let names: [UInt16: String] = [
        0xA001: "Canon_UnknownCommand", 0xA005: "Canon_OperationRefused", 0xA006: "Canon_LensCoverClosed",
        0xA101: "Canon_LowBattery", 0xA102: "Canon_ObjectNotReady", 0xA104: "Canon_CannotMakeObject",
        0xA106: "Canon_MemoryStatusNotReady",
    ]

    public static func describe(_ code: PTPResponseCode) -> String {
        if code.name != nil { return code.description }
        let hex = "0x" + String(code.rawValue, radix: 16, uppercase: true)
        return names[code.rawValue].map { "\($0) (\(hex))" } ?? hex
    }
}
