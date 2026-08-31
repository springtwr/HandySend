// NativeEventParseTest：NativeTypes 事件解析函数测试
// 覆盖 parseNativeEvent 及各子类型（camelCase 契约，与 Rust
// BridgeEvent 序列化一致，见 bridge/event.rs rename_all_fields）：
//   serverStarted、serverStopped、register、prepareUpload、prepareUploadAborted、
//   cancelReceived、uploadProgress、sessionEnd、fileUpload、deviceFound、
//   deviceLost、webSendPrepareDownload、webSendFileDownload、webSendSessionEnd、error
// 边界条件：缺少可选字段、null 值、空数组、无法识别的事件类型、无效 JSON
import { describe, it, expect } from '@ohos/hypium'
import {
  parseNativeEvent,
  NativeEvent,
  NativeServerStartedEvent,
  NativeServerStoppedEvent,
  NativeRegisterEvent,
  NativePrepareUploadEvent,
  NativePrepareUploadAbortedEvent,
  NativeCancelReceivedEvent,
  NativeProgressEvent,
  NativeSessionEndEvent,
  NativeFileUploadEvent,
  NativeDeviceFoundEvent,
  NativeDeviceLostEvent,
  NativeWebSendPrepareDownloadEvent,
  NativeWebSendFileDownloadEvent,
  NativeWebSendSessionEndEvent,
  NativeErrorEvent
} from '../../../../main/ets/model/NativeTypes'

export default function NativeEventParseTest() {
  describe('NativeEventParseTest', () => {
    // ── serverStarted 事件 ──

    it('parse_server_started_event', 0, () => {
      let json = '{"type":"serverStarted","payload":{"port":53317}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeServerStartedEvent = event as NativeServerStartedEvent
      expect(e.type === 'serverStarted').assertTrue()
      expect(e.port === 53317).assertTrue()
    })

    // ── serverStopped 事件（unit variant，无 payload）──

    it('parse_server_stopped_event', 0, () => {
      let json = '{"type":"serverStopped"}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeServerStoppedEvent = event as NativeServerStoppedEvent
      expect(e.type === 'serverStopped').assertTrue()
    })

    // ── register 事件 ──

    it('parse_register_event', 0, () => {
      let json =
        '{"type":"register","payload":{"ip":"192.168.1.100","info":{"alias":"TestPC","version":"1.18.1","fingerprint":"abc123","download":true,"port":53317,"protocol":"http"}}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeRegisterEvent = event as NativeRegisterEvent
      expect(e.type === 'register').assertTrue()
      expect(e.ip === '192.168.1.100').assertTrue()
      expect(e.info.alias === 'TestPC').assertTrue()
      expect(e.info.version === '1.18.1').assertTrue()
      expect(e.info.fingerprint === 'abc123').assertTrue()
      expect(e.info.download).assertTrue()
      expect(e.info.port === 53317).assertTrue()
      expect(e.info.protocol === 'http').assertTrue()
    })

    it('parse_register_event_with_optional_fields', 0, () => {
      let json =
        '{"type":"register","payload":{"ip":"192.168.1.100","info":{"alias":"TestPC","version":"1.18.1","deviceModel":"Desktop","deviceType":"desktop","fingerprint":"abc123","download":true,"port":53317,"protocol":"https"}}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeRegisterEvent = event as NativeRegisterEvent
      expect(e.info.deviceModel === 'Desktop').assertTrue()
      expect(e.info.deviceType === 'desktop').assertTrue()
      expect(e.info.protocol === 'https').assertTrue()
    })

    it('parse_register_event_missing_optional_info_fields', 0, () => {
      let json =
        '{"type":"register","payload":{"ip":"192.168.1.100","info":{"alias":"TestPC","version":"1.18.1","fingerprint":"abc123","download":false,"port":53317}}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeRegisterEvent = event as NativeRegisterEvent
      // 可选字段缺失时应有默认值
      expect(e.info.download).assertFalse()
      expect(e.info.deviceModel === undefined).assertTrue()
      expect(e.info.deviceType === undefined).assertTrue()
      // protocol 缺失时默认 'https'
      expect(e.info.protocol === 'https').assertTrue()
    })

    // ── prepareUpload 事件 ──

    it('parse_prepare_upload_event', 0, () => {
      let json =
        '{"type":"prepareUpload","payload":{"sessionId":"session_001","senderIp":"192.168.1.100","senderAlias":"SenderPC","senderFingerprint":"sender_fp","senderDeviceType":"mobile","senderDeviceModel":"HarmonyOS","certFingerprint":"","files":[{"id":"file_1","fileName":"test.txt","size":100,"fileType":"text/plain"}]}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativePrepareUploadEvent = event as NativePrepareUploadEvent
      expect(e.type === 'prepareUpload').assertTrue()
      expect(e.sessionId === 'session_001').assertTrue()
      expect(e.senderIp === '192.168.1.100').assertTrue()
      expect(e.senderAlias === 'SenderPC').assertTrue()
      expect(e.senderFingerprint === 'sender_fp').assertTrue()
      expect(e.senderDeviceType === 'mobile').assertTrue()
      expect(e.senderDeviceModel === 'HarmonyOS').assertTrue()
      expect(e.files.length === 1).assertTrue()
      expect(e.files[0].fileId === 'file_1').assertTrue()
      expect(e.files[0].fileName === 'test.txt').assertTrue()
      expect(e.files[0].size === 100).assertTrue()
      expect(e.files[0].fileType === 'text/plain').assertTrue()
    })

    it('parse_prepare_upload_event_with_cert_fingerprint', 0, () => {
      let json =
        '{"type":"prepareUpload","payload":{"sessionId":"session_002","senderIp":"192.168.1.100","senderAlias":"SenderPC","senderFingerprint":"sender_fp","senderDeviceType":"mobile","senderDeviceModel":"HarmonyOS","certFingerprint":"cert_sha256_hash","files":[{"id":"file_1","fileName":"photo.jpg","size":2048,"fileType":"image/jpeg"}]}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativePrepareUploadEvent = event as NativePrepareUploadEvent
      expect(e.certFingerprint === 'cert_sha256_hash').assertTrue()
      expect(e.files[0].fileName === 'photo.jpg').assertTrue()
      expect(e.files[0].size === 2048).assertTrue()
    })

    it('parse_prepare_upload_with_empty_files', 0, () => {
      let json =
        '{"type":"prepareUpload","payload":{"sessionId":"session_003","senderIp":"192.168.1.100","senderAlias":"PC","senderFingerprint":"fp","senderDeviceType":"mobile","senderDeviceModel":"M","certFingerprint":"","files":[]}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativePrepareUploadEvent = event as NativePrepareUploadEvent
      expect(e.sessionId === 'session_003').assertTrue()
      // 空文件列表应解析为 length === 0，而非 undefined
      expect(e.files.length === 0).assertTrue()
    })

    // ── prepareUploadAborted 事件 ──

    it('parse_prepare_upload_aborted_event', 0, () => {
      let json = '{"type":"prepareUploadAborted","payload":{"sessionId":"session_001"}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativePrepareUploadAbortedEvent = event as NativePrepareUploadAbortedEvent
      expect(e.type === 'prepareUploadAborted').assertTrue()
      expect(e.sessionId === 'session_001').assertTrue()
    })

    // ── cancelReceived 事件 ──

    it('parse_cancel_received_event', 0, () => {
      let json = '{"type":"cancelReceived","payload":{"ip":"192.168.1.100","sessionId":"session_001"}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeCancelReceivedEvent = event as NativeCancelReceivedEvent
      expect(e.type === 'cancelReceived').assertTrue()
      expect(e.ip === '192.168.1.100').assertTrue()
      expect(e.sessionId === 'session_001').assertTrue()
    })

    // ── uploadProgress 事件（新事件仅携带 progress/speed）──

    it('parse_upload_progress_event', 0, () => {
      let json =
        '{"type":"uploadProgress","payload":{"sessionId":"session_001","fileId":"file_1","direction":"recv","progress":0.5,"speed":1024}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeProgressEvent = event as NativeProgressEvent
      expect(e.type === 'uploadProgress').assertTrue()
      expect(e.direction === 'recv').assertTrue()
      expect(e.sessionId === 'session_001').assertTrue()
      expect(e.fileId === 'file_1').assertTrue()
      expect(e.progress === 0.5).assertTrue()
      expect(e.speed === 1024).assertTrue()
    })

    it('parse_upload_progress_send_direction', 0, () => {
      let json =
        '{"type":"uploadProgress","payload":{"sessionId":"session_dl","fileId":"f1","direction":"send","progress":1,"speed":0}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeProgressEvent = event as NativeProgressEvent
      expect(e.direction === 'send').assertTrue()
      expect(e.progress === 1).assertTrue()
    })

    // ── sessionEnd 事件（reason: finished/cancelled）──

    it('parse_session_end_event', 0, () => {
      let json = '{"type":"sessionEnd","payload":{"sessionId":"session_001","reason":"finished"}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeSessionEndEvent = event as NativeSessionEndEvent
      expect(e.type === 'sessionEnd').assertTrue()
      expect(e.sessionId === 'session_001').assertTrue()
      expect(e.reason === 'finished').assertTrue()
    })

    it('parse_session_end_cancelled', 0, () => {
      let json = '{"type":"sessionEnd","payload":{"sessionId":"session_002","reason":"cancelled"}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeSessionEndEvent = event as NativeSessionEndEvent
      expect(e.reason === 'cancelled').assertTrue()
    })

    // ── fileUpload 事件（fileName/size 展平在 payload 顶层，与 Rust 一致）──

    it('parse_file_upload_event', 0, () => {
      let json =
        '{"type":"fileUpload","payload":{"sessionId":"session_001","fileId":"file_1","fileName":"test.txt","size":100}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeFileUploadEvent = event as NativeFileUploadEvent
      expect(e.type === 'fileUpload').assertTrue()
      expect(e.sessionId === 'session_001').assertTrue()
      expect(e.fileId === 'file_1').assertTrue()
      expect(e.fileName === 'test.txt').assertTrue()
      expect(e.size === 100).assertTrue()
    })

    // ── deviceFound 事件（device 为结构化 NativeDiscoveredDevice）──

    it('parse_device_found_event', 0, () => {
      let json =
        '{"type":"deviceFound","payload":{"device":{"alias":"Device2","fingerprint":"fp_002","version":"1.18.1","deviceModel":"Pixel","deviceType":"mobile","download":true,"host":"192.168.1.60","port":53317,"protocol":"http","channels":[{"host":"192.168.1.60","port":53317,"protocol":"http"}]}}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeDeviceFoundEvent = event as NativeDeviceFoundEvent
      expect(e.type === 'deviceFound').assertTrue()
      expect(e.device.alias === 'Device2').assertTrue()
      expect(e.device.fingerprint === 'fp_002').assertTrue()
      expect(e.device.host === '192.168.1.60').assertTrue()
      expect(e.device.port === 53317).assertTrue()
      expect(e.device.channels.length === 1).assertTrue()
      expect(e.device.channels[0].protocol === 'http').assertTrue()
    })

    // ── deviceLost 事件 ──

    it('parse_device_lost_event', 0, () => {
      let json = '{"type":"deviceLost","payload":{"fingerprint":"fp_003"}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeDeviceLostEvent = event as NativeDeviceLostEvent
      expect(e.type === 'deviceLost').assertTrue()
      expect(e.fingerprint === 'fp_003').assertTrue()
    })

    // ── webSendPrepareDownload 事件 ──

    it('parse_web_send_prepare_download_event', 0, () => {
      let json =
        '{"type":"webSendPrepareDownload","payload":{"sessionId":"web_session_001","ip":"192.168.1.200","userAgent":"Mozilla/5.0"}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeWebSendPrepareDownloadEvent = event as NativeWebSendPrepareDownloadEvent
      expect(e.type === 'webSendPrepareDownload').assertTrue()
      expect(e.sessionId === 'web_session_001').assertTrue()
      expect(e.ip === '192.168.1.200').assertTrue()
      expect(e.userAgent === 'Mozilla/5.0').assertTrue()
    })

    it('parse_web_send_prepare_download_without_user_agent', 0, () => {
      let json = '{"type":"webSendPrepareDownload","payload":{"sessionId":"web_session_002","ip":"192.168.1.200"}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeWebSendPrepareDownloadEvent = event as NativeWebSendPrepareDownloadEvent
      expect(e.sessionId === 'web_session_002').assertTrue()
      // userAgent 缺失时应为 undefined
      expect(e.userAgent === undefined).assertTrue()
    })

    // ── webSendFileDownload 事件 ──

    it('parse_web_send_file_download_event', 0, () => {
      let json =
        '{"type":"webSendFileDownload","payload":{"sessionId":"web_session_001","fileId":"file_1","fileName":"document.pdf","size":4096}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeWebSendFileDownloadEvent = event as NativeWebSendFileDownloadEvent
      expect(e.type === 'webSendFileDownload').assertTrue()
      expect(e.sessionId === 'web_session_001').assertTrue()
      expect(e.fileId === 'file_1').assertTrue()
      expect(e.fileName === 'document.pdf').assertTrue()
      expect(e.size === 4096).assertTrue()
    })

    // ── webSendSessionEnd 事件 ──

    it('parse_web_send_session_end_event', 0, () => {
      let json = '{"type":"webSendSessionEnd","payload":{"sessionId":"web_session_001"}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeWebSendSessionEndEvent = event as NativeWebSendSessionEndEvent
      expect(e.type === 'webSendSessionEnd').assertTrue()
      expect(e.sessionId === 'web_session_001').assertTrue()
    })

    // ── error 事件 ──

    it('parse_error_event', 0, () => {
      let json = '{"type":"error","payload":{"context":"upload:s1:f1","message":"connection reset"}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeErrorEvent = event as NativeErrorEvent
      expect(e.type === 'error').assertTrue()
      expect(e.context === 'upload:s1:f1').assertTrue()
      expect(e.message === 'connection reset').assertTrue()
    })

    // ── 边界条件 ──

    it('parse_invalid_json_returns_undefined', 0, () => {
      let event: NativeEvent | undefined = parseNativeEvent('not valid json {{{')
      expect(event === undefined).assertTrue()
    })

    it('parse_unknown_event_type_returns_undefined', 0, () => {
      let json = '{"type":"unknown_type_xyz"}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event === undefined).assertTrue()
    })

    it('parse_empty_object_returns_undefined', 0, () => {
      let json = '{}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      // 空 JSON 无 type 字段——应返回 undefined
      expect(event === undefined).assertTrue()
    })

    it('parse_missing_type_returns_undefined', 0, () => {
      let json = '{"ip":"192.168.1.1"}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event === undefined).assertTrue()
    })

    it('parse_empty_string_returns_undefined', 0, () => {
      let event: NativeEvent | undefined = parseNativeEvent('')
      expect(event === undefined).assertTrue()
    })

    it('parse_register_with_null_optional_fields', 0, () => {
      let json =
        '{"type":"register","payload":{"ip":"192.168.1.100","info":{"alias":"TestPC","version":"1.18.1","deviceModel":null,"deviceType":null,"fingerprint":"abc123","download":false,"port":53317,"protocol":null}}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeRegisterEvent = event as NativeRegisterEvent
      // null 可选字段应被解析为 undefined（非字符串 "null"）
      expect(e.info.deviceModel === undefined).assertTrue()
      expect(e.info.deviceType === undefined).assertTrue()
      // protocol 为 null 时应回退到默认值 'https'
      expect(e.info.protocol === 'https').assertTrue()
    })

    it('parse_register_with_null_info_returns_defaults', 0, () => {
      // info 为 null 时 parseRegisterInfo 应返回默认值
      let json = '{"type":"register","payload":{"ip":"192.168.1.1","info":null}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeRegisterEvent = event as NativeRegisterEvent
      expect(e.info.alias === '').assertTrue()
      expect(e.info.version === '').assertTrue()
      expect(e.info.fingerprint === '').assertTrue()
      expect(e.info.download).assertFalse()
      expect(e.info.port === 0).assertTrue()
      expect(e.info.protocol === 'https').assertTrue()
    })
  })
}
