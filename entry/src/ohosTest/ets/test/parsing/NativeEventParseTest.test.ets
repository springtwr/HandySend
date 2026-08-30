// NativeEventParseTest：NativeTypes 事件解析函数测试
// 覆盖 parseNativeEvent 及各子类型：
//   device_found、discovery_update、register、prepare_upload、file_upload、
//   session_end、cancel_received、progress_update、prepare_upload_aborted、
//   web_prepare_download、web_file_download
// 边界条件：缺少可选字段、null 值、空数组、无法识别的事件类型、无效 JSON
import { describe, it, expect } from '@ohos/hypium'
import {
  parseNativeEvent,
  NativeEvent,
  NativeServerRegisterEvent,
  NativePrepareUploadEvent,
  NativeFileUploadEvent,
  NativeSessionEndEvent,
  NativePrepareUploadAbortedEvent,
  NativeCancelReceivedEvent,
  NativeProgressUpdateEvent,
  NativeDiscoveryUpdateEvent,
  NativeDeviceFoundEvent,
  NativeWebSendPrepare,
  NativeWebSendFileDownload
} from '../../../../main/ets/model/NativeTypes'

export default function NativeEventParseTest() {
  describe('NativeEventParseTest', () => {
    // ── register 事件 ──

    it('parse_register_event', 0, () => {
      let json = '{"type":"register","ip":"192.168.1.100","info":{"alias":"TestPC","version":"1.18.1","fingerprint":"abc123","download":true,"port":53317,"protocol":"http"}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeServerRegisterEvent = event as NativeServerRegisterEvent
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
      let json = '{"type":"register","ip":"192.168.1.100","info":{"alias":"TestPC","version":"1.18.1","deviceModel":"Desktop","deviceType":"desktop","fingerprint":"abc123","download":true,"port":53317,"protocol":"https"}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeServerRegisterEvent = event as NativeServerRegisterEvent
      expect(e.info.deviceModel === 'Desktop').assertTrue()
      expect(e.info.deviceType === 'desktop').assertTrue()
      expect(e.info.protocol === 'https').assertTrue()
    })

    it('parse_register_event_missing_optional_info_fields', 0, () => {
      let json = '{"type":"register","ip":"192.168.1.100","info":{"alias":"TestPC","version":"1.18.1","fingerprint":"abc123","download":false,"port":53317}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeServerRegisterEvent = event as NativeServerRegisterEvent
      // 可选字段缺失时应有默认值
      expect(e.info.download).assertFalse()
      expect(e.info.deviceModel === undefined).assertTrue()
      expect(e.info.deviceType === undefined).assertTrue()
      // protocol 缺失时默认 'https'
      expect(e.info.protocol === 'https').assertTrue()
    })

    // ── prepare_upload 事件 ──

    it('parse_prepare_upload_event', 0, () => {
      let json = '{"type":"prepare_upload","sessionId":"session_001","ip":"192.168.1.100","info":{"alias":"SenderPC","version":"1.18.1","fingerprint":"sender_fp","download":true,"port":53317,"protocol":"http"},"files":[{"id":"file_1","fileName":"test.txt","size":100,"fileType":"text/plain"}]}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativePrepareUploadEvent = event as NativePrepareUploadEvent
      expect(e.type === 'prepare_upload').assertTrue()
      expect(e.sessionId === 'session_001').assertTrue()
      expect(e.ip === '192.168.1.100').assertTrue()
      expect(e.info.alias === 'SenderPC').assertTrue()
      expect(e.files.length === 1).assertTrue()
      expect(e.files[0].fileId === 'file_1').assertTrue()
      expect(e.files[0].fileName === 'test.txt').assertTrue()
      expect(e.files[0].size === 100).assertTrue()
      expect(e.files[0].fileType === 'text/plain').assertTrue()
      // 无 certFingerprint 时应为 undefined
      expect(e.certFingerprint === undefined).assertTrue()
    })

    it('parse_prepare_upload_event_with_cert_fingerprint', 0, () => {
      let json = '{"type":"prepare_upload","sessionId":"session_002","ip":"192.168.1.100","info":{"alias":"SenderPC","version":"1.18.1","fingerprint":"sender_fp","download":true,"port":53317,"protocol":"https"},"certFingerprint":"cert_sha256_hash","files":[{"id":"file_1","fileName":"photo.jpg","size":2048,"fileType":"image/jpeg"}]}'
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

    // ── file_upload 事件 ──

    it('parse_file_upload_event', 0, () => {
      let json = '{"type":"file_upload","sessionId":"session_001","fileId":"file_1","file":{"id":"file_1","fileName":"test.txt","size":100,"fileType":"text/plain"}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeFileUploadEvent = event as NativeFileUploadEvent
      expect(e.type === 'file_upload').assertTrue()
      expect(e.sessionId === 'session_001').assertTrue()
      expect(e.fileId === 'file_1').assertTrue()
      expect(e.file.fileId === 'file_1').assertTrue()
      expect(e.file.fileName === 'test.txt').assertTrue()
      expect(e.file.size === 100).assertTrue()
      expect(e.file.fileType === 'text/plain').assertTrue()
    })

    // ── session_end 事件 ──

    it('parse_session_end_event', 0, () => {
      let json = '{"type":"session_end","sessionId":"session_001","reason":"completed"}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeSessionEndEvent = event as NativeSessionEndEvent
      expect(e.type === 'session_end').assertTrue()
      expect(e.sessionId === 'session_001').assertTrue()
      expect(e.reason === 'completed').assertTrue()
    })

    // ── cancel_received 事件 ──

    it('parse_cancel_received_event', 0, () => {
      let json = '{"type":"cancel_received","ip":"192.168.1.100","sessionId":"session_001"}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeCancelReceivedEvent = event as NativeCancelReceivedEvent
      expect(e.type === 'cancel_received').assertTrue()
      expect(e.ip === '192.168.1.100').assertTrue()
      expect(e.sessionId === 'session_001').assertTrue()
    })

    // ── progress_update 事件 ──

    it('parse_progress_update_event', 0, () => {
      let json = '{"type":"progress_update","direction":"upload","sessionId":"session_001","fileId":"file_1","bytesSent":50,"totalBytes":100,"filePath":"/data/local/tmp/test.txt"}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeProgressUpdateEvent = event as NativeProgressUpdateEvent
      expect(e.type === 'progress_update').assertTrue()
      expect(e.direction === 'upload').assertTrue()
      expect(e.sessionId === 'session_001').assertTrue()
      expect(e.fileId === 'file_1').assertTrue()
      expect(e.bytesSent === 50).assertTrue()
      expect(e.totalBytes === 100).assertTrue()
      expect(e.filePath === '/data/local/tmp/test.txt').assertTrue()
    })

    // ── prepare_upload_aborted 事件 ──

    it('parse_prepare_upload_aborted_event', 0, () => {
      let json = '{"type":"prepare_upload_aborted","sessionId":"session_001"}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativePrepareUploadAbortedEvent = event as NativePrepareUploadAbortedEvent
      expect(e.type === 'prepare_upload_aborted').assertTrue()
      expect(e.sessionId === 'session_001').assertTrue()
    })

    // ── discovery_update 事件 ──

    it('parse_discovery_update_event', 0, () => {
      let json = '{"type":"discovery_update","devices":[{"alias":"Device1","fingerprint":"fp_001","version":"1.18.1","deviceModel":"Desktop","deviceType":"desktop","download":true,"host":"192.168.1.50","port":53317,"protocol":"http","channels":[{"host":"192.168.1.50","port":53317,"protocol":"http"}]}]}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeDiscoveryUpdateEvent = event as NativeDiscoveryUpdateEvent
      expect(e.type === 'discovery_update').assertTrue()
      expect(e.devices.length === 1).assertTrue()
      expect(e.devices[0].alias === 'Device1').assertTrue()
      expect(e.devices[0].fingerprint === 'fp_001').assertTrue()
      expect(e.devices[0].host === '192.168.1.50').assertTrue()
      expect(e.devices[0].port === 53317).assertTrue()
      expect(e.devices[0].channels.length === 1).assertTrue()
      expect(e.devices[0].channels[0].protocol === 'http').assertTrue()
    })

    // ── device_found 事件 ──

    it('parse_device_found_event', 0, () => {
      let json = '{"type":"device_found","device":{"alias":"Device2","fingerprint":"fp_002","version":"1.18.1","host":"192.168.1.60","port":53317,"protocol":"http"}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeDeviceFoundEvent = event as NativeDeviceFoundEvent
      expect(e.type === 'device_found').assertTrue()
      // device 是 Record<string, Object>，验证关键字段存在
      expect(e.device['alias'] !== undefined).assertTrue()
      expect(e.device['fingerprint'] !== undefined).assertTrue()
    })

    // ── web_prepare_download 事件 ──

    it('parse_web_prepare_download_event', 0, () => {
      let json = '{"type":"web_prepare_download","sessionId":"web_session_001","ip":"192.168.1.200","userAgent":"Mozilla/5.0"}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeWebSendPrepare = event as NativeWebSendPrepare
      expect(e.type === 'web_prepare_download').assertTrue()
      expect(e.sessionId === 'web_session_001').assertTrue()
      expect(e.ip === '192.168.1.200').assertTrue()
      expect(e.userAgent === 'Mozilla/5.0').assertTrue()
    })

    it('parse_web_prepare_download_without_user_agent', 0, () => {
      let json = '{"type":"web_prepare_download","sessionId":"web_session_002","ip":"192.168.1.200"}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeWebSendPrepare = event as NativeWebSendPrepare
      expect(e.sessionId === 'web_session_002').assertTrue()
      // userAgent 缺失时应为 undefined
      expect(e.userAgent === undefined).assertTrue()
    })

    // ── web_file_download 事件 ──

    it('parse_web_file_download_event', 0, () => {
      let json = '{"type":"web_file_download","sessionId":"web_session_001","fileId":"file_1","fileName":"document.pdf","size":4096,"fileType":"application/pdf"}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeWebSendFileDownload = event as NativeWebSendFileDownload
      expect(e.type === 'web_file_download').assertTrue()
      expect(e.sessionId === 'web_session_001').assertTrue()
      expect(e.fileId === 'file_1').assertTrue()
      expect(e.fileName === 'document.pdf').assertTrue()
      expect(e.size === 4096).assertTrue()
      expect(e.fileType === 'application/pdf').assertTrue()
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

    it('parse_prepare_upload_with_empty_files', 0, () => {
      let json = '{"type":"prepare_upload","sessionId":"session_003","ip":"192.168.1.100","info":{"alias":"SenderPC","version":"1.18.1","fingerprint":"sender_fp","download":true,"port":53317},"files":[]}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativePrepareUploadEvent = event as NativePrepareUploadEvent
      expect(e.sessionId === 'session_003').assertTrue()
      expect(e.ip === '192.168.1.100').assertTrue()
      // 空文件列表应解析为 length === 0，而非 undefined
      expect(e.files.length === 0).assertTrue()
    })

    it('parse_register_with_null_optional_fields', 0, () => {
      let json = '{"type":"register","ip":"192.168.1.100","info":{"alias":"TestPC","version":"1.18.1","deviceModel":null,"deviceType":null,"fingerprint":"abc123","download":false,"port":53317,"protocol":null}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeServerRegisterEvent = event as NativeServerRegisterEvent
      // null 可选字段应被解析为 undefined（非字符串 "null"）
      expect(e.info.deviceModel === undefined).assertTrue()
      expect(e.info.deviceType === undefined).assertTrue()
      // protocol 为 null 时应回退到默认值 'https'
      expect(e.info.protocol === 'https').assertTrue()
    })

    it('parse_empty_string_returns_undefined', 0, () => {
      let event: NativeEvent | undefined = parseNativeEvent('')
      expect(event === undefined).assertTrue()
    })

    // ── 补充边界场景 ──

    it('parse_prepare_upload_with_null_certFingerprint', 0, () => {
      // certFingerprint 显式为 null 时应解析为 undefined
      let json = '{"type":"prepare_upload","sessionId":"session_cf_null","ip":"10.0.0.1","info":{"alias":"PC","version":"1.0","fingerprint":"fp","download":true,"port":53317},"certFingerprint":null,"files":[]}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativePrepareUploadEvent = event as NativePrepareUploadEvent
      expect(e.certFingerprint === undefined).assertTrue()
    })

    it('parse_progress_update_direction_download', 0, () => {
      let json = '{"type":"progress_update","direction":"download","sessionId":"session_dl","fileId":"f1","bytesSent":2048,"totalBytes":8192,"filePath":"/recv/photo.jpg"}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeProgressUpdateEvent = event as NativeProgressUpdateEvent
      expect(e.direction === 'download').assertTrue()
      expect(e.bytesSent === 2048).assertTrue()
      expect(e.totalBytes === 8192).assertTrue()
    })

    it('parse_file_upload_with_preview_and_sha256', 0, () => {
      // parseTransferFileInfo 可选字段 preview 和 sha256
      let json = '{"type":"file_upload","sessionId":"s1","fileId":"f1","file":{"id":"f1","fileName":"img.png","size":5120,"fileType":"image/png","preview":"base64data","sha256":"abc123def"}}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeFileUploadEvent = event as NativeFileUploadEvent
      expect(e.file.preview === 'base64data').assertTrue()
      expect(e.file.sha256 === 'abc123def').assertTrue()
    })

    it('parse_discovery_update_empty_devices', 0, () => {
      let json = '{"type":"discovery_update","devices":[]}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeDiscoveryUpdateEvent = event as NativeDiscoveryUpdateEvent
      expect(e.devices.length === 0).assertTrue()
    })

    it('parse_register_with_null_info_returns_defaults', 0, () => {
      // info 为 null 时 parseRegisterInfo 应返回默认值
      let json = '{"type":"register","ip":"192.168.1.1","info":null}'
      let event: NativeEvent | undefined = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event === undefined) {
        return
      }
      let e: NativeServerRegisterEvent = event as NativeServerRegisterEvent
      expect(e.info.alias === '').assertTrue()
      expect(e.info.version === '').assertTrue()
      expect(e.info.fingerprint === '').assertTrue()
      expect(e.info.download).assertFalse()
      expect(e.info.port === 0).assertTrue()
      expect(e.info.protocol === 'https').assertTrue()
    })
  })
}
