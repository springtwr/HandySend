import { describe, it, expect } from '@ohos/hypium'
import { parseNativeEvent } from '../main/ets/model/NativeTypes'

export default function NativeTypesTest() {
  describe('NativeTypesTest', () => {
    // ── 正常解析 ──

    it('parse_valid_event', 0, () => {
      let event = parseNativeEvent('{"type":"serverStarted","payload":{"port":53317}}')
      expect(event !== undefined).assertTrue()
      if (event !== undefined && event.type === 'serverStarted') {
        expect(event.port).assertEqual(53317)
      }
    })

    it('parse_event_without_payload_fields', 0, () => {
      // serverStopped 无必需字段，空 payload 应正常解析
      let event = parseNativeEvent('{"type":"serverStopped","payload":{}}')
      expect(event !== undefined).assertTrue()
    })

    // ── 必需字段缺失丢弃 ──

    it('missing_required_field_dropped', 0, () => {
      let event = parseNativeEvent('{"type":"uploadProgress","payload":{"fileId":"f1"}}')
      expect(event).assertUndefined()
    })

    it('null_required_field_dropped', 0, () => {
      let event = parseNativeEvent('{"type":"sessionEnd","payload":{"sessionId":null,"reason":"done"}}')
      expect(event).assertUndefined()
    })

    it('all_required_fields_present_passes', 0, () => {
      let json = '{"type":"uploadProgress","payload":{"sessionId":"s1","fileId":"f1",' +
        '"direction":"send","progress":50,"speed":1024}}'
      let event = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event !== undefined && event.type === 'uploadProgress') {
        expect(event.sessionId).assertEqual('s1')
        expect(event.progress).assertEqual(50)
      }
    })

    it('parse_mta_receive_progress', 0, () => {
      let json = '{"type":"mtaReceiveProgress","payload":{' +
        '"receivedBytes":512,"totalBytes":1024,"percent":50}}'
      let event = parseNativeEvent(json)
      expect(event !== undefined).assertTrue()
      if (event !== undefined && event.type === 'mtaReceiveProgress') {
        expect(event.receivedBytes).assertEqual(512)
        expect(event.totalBytes).assertEqual(1024)
        expect(event.percent).assertEqual(50)
      }
    })

    it('mta_receive_progress_missing_field_dropped', 0, () => {
      let json = '{"type":"mtaReceiveProgress","payload":{"receivedBytes":1,"totalBytes":2}}'
      expect(parseNativeEvent(json)).assertUndefined()
    })

    // ── 坏输入 ──

    it('invalid_json_returns_undefined', 0, () => {
      expect(parseNativeEvent('not-json')).assertUndefined()
    })

    it('unknown_type_returns_undefined', 0, () => {
      expect(parseNativeEvent('{"type":"nonexistent","payload":{"a":1}}')).assertUndefined()
    })

    it('missing_type_returns_undefined', 0, () => {
      expect(parseNativeEvent('{"payload":{"port":1}}')).assertUndefined()
    })
  })
}
