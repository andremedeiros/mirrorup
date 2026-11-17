public import MirrorupPTP

/// Canon names layered over `PTPCatalog`: EOS operations, events, responses and object formats.
///
/// Provenance: libgphoto2 `camlibs/ptp2/ptp.h` (`PTP_OC_CANON_*`, `PTP_EC_CANON_*`, `PTP_RC_CANON_*`,
/// `PTP_OFC_CANON_*`) and `library.c` (object format → file type); the EventProc operations
/// 0x9050–0x9057 and 0x902F come from camlib's code list (danielc.dev/ptp/enums). Codes that a
/// reference lists only by number (libgphoto2 `PTP_OC_CANON_902C`, `PTP_RC_CANON_A009`) carry no
/// meaning and are not named here. Property names and value decoding live in
/// CanonPropertyDecoders.swift.
public enum CanonCatalog {
    /// Standard PTP/MTP or Canon operation name.
    public static func operationName(_ code: UInt16) -> String? {
        operations[code] ?? PTPCatalog.operationName(code)
    }

    /// Standard PTP/MTP event or Canon EOS GetEvent record name. EOS records are u32-coded.
    public static func eventName(_ code: UInt32) -> String? {
        events[code] ?? UInt16(exactly: code).flatMap(PTPCatalog.eventName)
    }

    public static func responseName(_ code: UInt16) -> String? {
        responses[code] ?? PTPCatalog.responseName(code)
    }

    public static func objectFormatName(_ code: UInt16) -> String? {
        objectFormats[code] ?? PTPCatalog.objectFormatName(code)
    }

    /// Canon EOS or standard device property name ("EVF Sharpness", "Battery Level").
    public static func propertyName(_ code: UInt32) -> String? {
        propertySpecs[code]?.label ?? UInt16(exactly: code).flatMap(PTPCatalog.propertyName)
    }

    /// "Name (0xHEX)", or just the hex when no reference names the code.
    static func describe(_ name: String?, code: UInt32) -> String {
        let hex = "0x" + String(code, radix: 16, uppercase: true)
        return name.map { "\($0) (\(hex))" } ?? hex
    }

    static let operations: [UInt16: String] = [
        // PowerShot-era operations that EOS bodies still list
        0x9001: "Canon_GetPartialObjectInfo",
        0x9002: "Canon_SetObjectArchive",
        0x9003: "Canon_KeepDeviceOn",
        0x9004: "Canon_LockDeviceUI",
        0x9005: "Canon_UnlockDeviceUI",
        0x9006: "Canon_GetObjectHandleByName",
        0x9008: "Canon_InitiateReleaseControl",
        0x9009: "Canon_TerminateReleaseControl",
        0x900A: "Canon_TerminatePlaybackMode",
        0x900B: "Canon_ViewfinderOn",
        0x900C: "Canon_ViewfinderOff",
        0x900D: "Canon_DoAeAfAwb",
        0x900E: "Canon_GetCustomizeSpec",
        0x900F: "Canon_GetCustomizeItemInfo",
        0x9010: "Canon_GetCustomizeData",
        0x9011: "Canon_SetCustomizeData",
        0x9012: "Canon_GetCaptureStatus",
        0x9013: "Canon_CheckEvent",
        0x9014: "Canon_FocusLock",
        0x9015: "Canon_FocusUnlock",
        0x9016: "Canon_GetLocalReleaseParam",
        0x9017: "Canon_SetLocalReleaseParam",
        0x9018: "Canon_AskAboutPcEvf",
        0x9019: "Canon_SendPartialObject",
        0x901A: "Canon_InitiateCaptureInMemory",
        0x901B: "Canon_GetPartialObjectEx",
        0x901C: "Canon_SetObjectTime",
        0x901D: "Canon_GetViewfinderImage",
        0x901E: "Canon_GetObjectAttributes",
        0x901F: "Canon_ChangeUSBProtocol",
        0x9020: "Canon_GetChanges",
        0x9021: "Canon_GetObjectInfoEx",
        0x9022: "Canon_InitiateDirectTransfer",
        0x9023: "Canon_TerminateDirectTransfer",
        0x9024: "Canon_SendObjectInfoByPath",
        0x9025: "Canon_SendObjectByPath",
        0x9026: "Canon_InitiateDirectTansferEx",
        0x9027: "Canon_GetAncillaryObjectHandles",
        0x9028: "Canon_GetTreeInfo",
        0x9029: "Canon_GetTreeSize",
        0x902A: "Canon_NotifyProgress",
        0x902B: "Canon_NotifyCancelAccepted",
        0x902D: "Canon_GetDirectory",
        0x902F: "Canon_DoNothing",  // camlib
        0x9030: "Canon_SetPairingInfo",
        0x9031: "Canon_GetPairingInfo",
        0x9032: "Canon_DeletePairingInfo",
        0x9033: "Canon_GetMACAddress",
        0x9034: "Canon_SetDisplayMonitor",
        0x9035: "Canon_PairingComplete",
        0x9036: "Canon_GetWirelessMAXChannel",
        0x9050: "EOS_EnableEventProc",  // camlib
        0x9052: "EOS_ExecuteEventProc",  // camlib
        0x9053: "EOS_GetEventProcReturnData",  // camlib
        0x9057: "EOS_IsEventProcRunning",  // camlib
        0x9068: "Canon_GetWebServiceSpec",
        0x9069: "Canon_GetWebServiceData",
        0x906A: "Canon_SetWebServiceData",
        0x906B: "Canon_DeleteWebServiceData",
        0x906C: "Canon_GetRootCertificateSpec",
        0x906D: "Canon_GetRootCertificateData",
        0x906E: "Canon_SetRootCertificateData",
        0x906F: "Canon_DeleteRootCertificateData",
        0x9075: "Canon_GetGpsMobilelinkObjectInfo",
        0x9076: "Canon_SendGpsTagInfo",
        0x9077: "Canon_GetTranscodeApproxSize",
        0x9078: "Canon_RequestTranscodeStart",
        0x9079: "Canon_RequestTranscodeCancel",
        0x9086: "Canon_SetRemoteShootingMode",
        0x9087: "Canon_GetDebugLog",
        0x9088: "Canon_SetModeDialDisable",
        0x9089: "Canon_Clear_CCAPI_UsageCount",
        0x908A: "Canon_SetMetaProperty",
        // EOS operations
        0x9101: "EOS_GetStorageIDs",
        0x9102: "EOS_GetStorageInfo",
        0x9103: "EOS_GetObjectInfo",
        0x9104: "EOS_GetObject",
        0x9105: "EOS_DeleteObject",
        0x9106: "EOS_FormatStore",
        0x9107: "EOS_GetPartialObject",
        0x9108: "EOS_GetDeviceInfoEx",
        0x9109: "EOS_GetObjectInfoEx",
        0x910A: "EOS_GetThumbEx",
        0x910B: "EOS_SendPartialObject",
        0x910C: "EOS_SetObjectAttributes",
        0x910D: "EOS_GetObjectTime",
        0x910E: "EOS_SetObjectTime",
        0x910F: "EOS_RemoteRelease",
        0x9110: "EOS_SetDevicePropValueEx",
        0x9113: "EOS_GetRemoteMode",
        0x9114: "EOS_SetRemoteMode",
        0x9115: "EOS_SetEventMode",
        0x9116: "EOS_GetEvent",
        0x9117: "EOS_TransferComplete",
        0x9118: "EOS_CancelTransfer",
        0x9119: "EOS_ResetTransfer",
        0x911A: "EOS_PCHDDCapacity",
        0x911B: "EOS_SetUILock",
        0x911C: "EOS_ResetUILock",
        0x911D: "EOS_KeepDeviceOn",
        0x911E: "EOS_SetNullPacketMode",
        0x911F: "EOS_UpdateFirmware",
        0x9120: "EOS_TransferCompleteDT",
        0x9121: "EOS_CancelTransferDT",
        0x9122: "EOS_SetWftProfile",
        0x9123: "EOS_GetWftProfile",
        0x9124: "EOS_SetProfileToWft",
        0x9125: "EOS_BulbStart",
        0x9126: "EOS_BulbEnd",
        0x9127: "EOS_RequestDevicePropValue",
        0x9128: "EOS_RemoteReleaseOn",
        0x9129: "EOS_RemoteReleaseOff",
        0x912A: "EOS_RegistBackgroundImage",
        0x912B: "EOS_ChangePhotoStudioMode",
        0x912C: "EOS_GetPartialObjectEx",
        0x9130: "EOS_ResetMirrorLockupState",
        0x9131: "EOS_PopupBuiltinFlash",
        0x9132: "EOS_EndGetPartialObjectEx",
        0x9133: "EOS_MovieSelectSWOn",
        0x9134: "EOS_MovieSelectSWOff",
        0x9135: "EOS_GetCTGInfo",
        0x9136: "EOS_GetLensAdjust",
        0x9137: "EOS_SetLensAdjust",
        0x9138: "EOS_ReadyToSendMusic",
        0x9139: "EOS_CreateHandle",
        0x913A: "EOS_SendPartialObjectEx",
        0x913B: "EOS_EndSendPartialObjectEx",
        0x913C: "EOS_SetCTGInfo",
        0x913D: "EOS_SetRequestOLCInfoGroup",
        0x913E: "EOS_SetRequestRollingPitchingLevel",
        0x913F: "EOS_GetCameraSupport",
        0x9140: "EOS_SetRating",
        0x9141: "EOS_RequestInnerDevelopStart",
        0x9142: "EOS_RequestInnerDevelopParamChange",
        0x9143: "EOS_RequestInnerDevelopEnd",
        0x9144: "EOS_GpsLoggingDataMode",
        0x9145: "EOS_GetGpsLogCurrentHandle",
        0x9146: "EOS_SetImageRecoveryData",
        0x9147: "EOS_GetImageRecoveryList",
        0x9148: "EOS_FormatImageRecoveryData",
        0x9149: "EOS_GetPresetLensAdjustParam",
        0x914A: "EOS_GetRawDispImage",
        0x914B: "EOS_SaveImageRecoveryData",
        0x914C: "EOS_RequestBLE",
        0x914D: "EOS_DrivePowerZoom",
        0x914F: "EOS_GetIptcData",
        0x9150: "EOS_SetIptcData",
        0x9151: "EOS_InitiateViewfinder",
        0x9152: "EOS_TerminateViewfinder",
        0x9153: "EOS_GetViewFinderData",
        0x9154: "EOS_DoAf",
        0x9155: "EOS_DriveLens",
        0x9156: "EOS_DepthOfFieldPreview",
        0x9157: "EOS_ClickWB",
        0x9158: "EOS_Zoom",
        0x9159: "EOS_ZoomPosition",
        0x915A: "EOS_SetLiveAfFrame",
        0x915B: "EOS_TouchAfPosition",
        0x915C: "EOS_SetLvPcFlavoreditMode",
        0x915D: "EOS_SetLvPcFlavoreditParam",
        0x915E: "EOS_RequestSensorCleaning",
        0x9160: "EOS_AfCancel",
        0x9166: "EOS_SetManipulationToggleImageSide",
        0x9167: "EOS_GetLensSerialNumHistory",
        0x916B: "EOS_SetImageRecoveryDataEx",
        0x916C: "EOS_GetImageRecoveryListEx",
        0x916D: "EOS_CompleteAutoSendImages",
        0x916E: "EOS_NotifyAutoTransferStatus",
        0x916F: "EOS_GetReducedObject",
        0x9170: "EOS_GetObjectInfo64",
        0x9171: "EOS_GetObject64",
        0x9172: "EOS_GetPartialObject64",
        0x9173: "EOS_GetObjectInfoEx64",
        0x9174: "EOS_GetPartialObjectEX64",
        0x9175: "EOS_CreateHandle64",
        0x9177: "EOS_NotifySaveComplete",
        0x9178: "EOS_GetTranscodedBlock",
        0x9179: "EOS_TransferCompleteTranscodedBlock",
        0x917B: "EOS_SetRemoteErrLogMode",
        0x917C: "EOS_GetRemoteErrLogMode",
        0x917D: "EOS_GetDebugLogEx",
        0x9182: "EOS_NotifyEstimateNumberofImport",
        0x9183: "EOS_NotifyNumberofImported",
        0x9184: "EOS_NotifySizeOfPartialDataTransfer",
        0x9185: "EOS_NotifyFinish",
        0x9186: "EOS_GetWFTData",
        0x9187: "EOS_SetWFTData",
        0x9188: "EOS_ChangeWFTSettingNumber",
        0x9189: "EOS_GetPictureStylePCFlavorParam",
        0x918A: "EOS_SetPictureStylePCFlavorParam",
        0x91AB: "EOS_GetObjectURL",
        0x91AC: "EOS_SetCAssistMode",
        0x91AD: "EOS_GetCAssistPresetThumb",
        0x91B1: "EOS_SendWifiSetting",
        0x91B2: "EOS_SendWifiDetailSetting",
        0x91B9: "EOS_SetFELock",
        0x91BA: "EOS_DeleteWFTSettingNumber",
        0x91BE: "EOS_SetDefaultCameraSetting",
        0x91BF: "EOS_GetAEData",
        0x91E4: "EOS_SendHostInfo",
        0x91E8: "EOS_NotifyNetworkError",
        0x91E9: "EOS_AdapterTransferProgress",
        0x91F0: "EOS_TransferCompleteFTP",
        0x91F1: "EOS_CancelTransferFTP",
        0x91F9: "EOS_NotifyBtStatus",
        0x91FD: "EOS_SetAdapterBatteryReport",
        0x91FE: "EOS_FAPIMessageTX",
        0x91FF: "EOS_FAPIMessageRX",
        0x9200: "EOS_EdgeFocusPosition",
        0x9201: "EOS_DriveFocusToEdge",
        0x9202: "EOS_DriveFocus",
        0x9401: "EOS_DV_Get_WavInfo",
        0x9402: "EOS_DV_Overwrite_Contents_XML",
        0x9403: "EOS_DV_Get_Template_XML",
    ]

    static let events: [UInt32: String] = [
        0xC005: "Canon_ExtendedErrorcode",
        0xC008: "Canon_ObjectInfoChanged",
        0xC009: "Canon_RequestObjectTransfer",
        0xC00B: "Canon_ShutterButtonPressed0",
        0xC00C: "Canon_CameraModeChanged",
        0xC00E: "Canon_ShutterButtonPressed1",
        0xC011: "Canon_StartDirectTransfer",
        0xC013: "Canon_StopDirectTransfer",
        0xC01B: "Canon_TranscodeProgress",
        // EOS GetEvent record codes
        0xC101: "EOS_RequestGetEvent",
        0xC180: "EOS_RequestCancelTransferMA",
        0xC181: "EOS_ObjectAddedEx",
        0xC182: "EOS_ObjectRemoved",
        0xC183: "EOS_RequestGetObjectInfoEx",
        0xC184: "EOS_StorageStatusChanged",
        0xC185: "EOS_StorageInfoChanged",
        0xC186: "EOS_RequestObjectTransfer",
        0xC187: "EOS_ObjectInfoChangedEx",
        0xC188: "EOS_ObjectContentChanged",
        0xC189: "EOS_PropValueChanged",
        0xC18A: "EOS_AvailListChanged",
        0xC18B: "EOS_CameraStatusChanged",
        0xC18D: "EOS_WillSoonShutdown",
        0xC18E: "EOS_ShutdownTimerUpdated",
        0xC18F: "EOS_RequestCancelTransfer",
        0xC190: "EOS_RequestObjectTransferDT",
        0xC191: "EOS_RequestCancelTransferDT",
        0xC192: "EOS_StoreAdded",
        0xC193: "EOS_StoreRemoved",
        0xC194: "EOS_BulbExposureTime",
        0xC195: "EOS_RecordingTime",
        0xC196: "EOS_InnerDevelopParam",
        0xC197: "EOS_RequestObjectTransferDevelop",
        0xC198: "EOS_GPSLogOutputProgress",
        0xC199: "EOS_GPSLogOutputComplete",
        0xC19A: "EOS_TouchTrans",
        0xC19B: "EOS_RequestObjectTransferExInfo",
        0xC19D: "EOS_PowerZoomInfoChanged",
        0xC19F: "EOS_RequestPushMode",
        0xC1A2: "EOS_RequestObjectTransferTS",
        0xC1A3: "EOS_AfResult",
        0xC1A4: "EOS_CTGInfoCheckComplete",
        0xC1A5: "EOS_OLCInfoChanged",
        0xC1A7: "EOS_ObjectAddedEx64",
        0xC1A8: "EOS_ObjectInfoChangedEx64",
        0xC1A9: "EOS_RequestObjectTransfer64",
        0xC1AA: "EOS_RequestObjectTransferDT64",
        0xC1AB: "EOS_RequestObjectTransferFTP64",
        0xC1AC: "EOS_RequestObjectTransferInfoEx64",
        0xC1AD: "EOS_RequestObjectTransferMA64",
        0xC1AF: "EOS_ImportError",
        0xC1B0: "EOS_BlePairing",
        0xC1B1: "EOS_RequestAutoSendImages",
        0xC1B2: "EOS_RequestTranscodedBlockTransfer",
        0xC1B4: "EOS_RequestCAssistImage",
        0xC1B5: "EOS_HiFreqFlickerlessAutodetectResult",
        0xC1B6: "EOS_ObjectAddedEx64LFN",
        0xC1B7: "EOS_ObjectInfoChangedEx64LFN",
        0xC1B8: "EOS_RequestObjectTransfer64LFN",
        0xC1F1: "EOS_RequestObjectTransferFTP",
    ]

    static let responses: [UInt16: String] = [
        0xA001: "Canon_UnknownCommand",
        0xA005: "Canon_OperationRefused",
        0xA006: "Canon_LensCoverClosed",
        0xA101: "Canon_LowBattery",
        0xA102: "Canon_ObjectNotReady",
        0xA104: "Canon_CannotMakeObject",
        0xA106: "Canon_MemoryStatusNotReady",
    ]

    static let objectFormats: [UInt16: String] = [
        0xB101: "Canon RAW (CRW)",
        0xB103: "Canon RAW (CR2)",
        0xB104: "Canon Movie (MOV)",
        0xB105: "Canon Movie (MOV, second variant)",
        0xB108: "Canon RAW (CR3)",
        0xB1FF: "CHDK RAW",
    ]
}

extension CanonOperation {
    /// Readable name for a standard or Canon opcode: "EOS_GetEvent (0x9116)".
    public static func describe(_ code: UInt16) -> String {
        CanonCatalog.describe(CanonCatalog.operationName(code), code: UInt32(code))
    }
}

extension CanonResponse {
    /// Readable name for a standard or Canon response code: "Canon_ObjectNotReady (0xA102)".
    public static func describe(_ code: PTPResponseCode) -> String {
        CanonCatalog.describe(CanonCatalog.responseName(code.rawValue), code: UInt32(code.rawValue))
    }
}
