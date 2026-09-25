import { describe, it, expect } from '@ohos/hypium'
import {
  WsHandshakeResult,
  buildWsHandshakeSummary,
  isVersionNegotiationSupported,
  truncateUtf8Text,
  parseDeviceInfo
} from '../../../../main/ets/model/mta/MtaProtocolModels'

// 连接路线文本与 WS 握手诊断纯函数测试（结果摘要、版本协商兼容性等）。
export default function MtaProtocolModelsTest() {
  describe('MtaProtocolModelsTest', () => {
    // ── WS 握手结果摘要 ──

    it('build_ws_handshake_summary_counts_attempts', 0, () => {
      let result = new WsHandshakeResult()
      result.targetUrl = 'wss://192.168.49.1:43210/websocket'
      result.success = false
      result.totalMs = 12000
      result.attemptCount = 2
      expect(buildWsHandshakeSummary(result))
        .assertEqual('目标 wss://192.168.49.1:43210/websocket：失败，共 2 轮，总耗时 12000ms')
    })

    // ── 版本协商兼容性 ──

    it('version_negotiation_lenient', 0, () => {
      // 空串 / 解析失败 / 无版本字段：宽松视为支持
      expect(isVersionNegotiationSupported('', 1)).assertTrue()
      expect(isVersionNegotiationSupported('not-json', 1)).assertTrue()
      expect(isVersionNegotiationSupported('{}', 1)).assertTrue()
      expect(isVersionNegotiationSupported('{"threadLimit":5}', 1)).assertTrue()
    })

    it('version_negotiation_matches', 0, () => {
      // version 字段
      expect(isVersionNegotiationSupported('{"version":1,"versions":[1]}', 1)).assertTrue()
      expect(isVersionNegotiationSupported('{"version":2,"versions":[2]}', 1)).assertFalse()
      // 仅 versions 数组
      expect(isVersionNegotiationSupported('{"versions":[2, 3]}', 1)).assertFalse()
      expect(isVersionNegotiationSupported('{"versions":[1, 2]}', 1)).assertTrue()
    })

    // ── catShareText 超限截断 ──

    it('truncate_utf8_text_within_limit', 0, () => {
      expect(truncateUtf8Text('', 100)).assertEqual('')
      expect(truncateUtf8Text('abc', 100)).assertEqual('abc')
      expect(truncateUtf8Text('中文', 100)).assertEqual('中文')
    })

    it('truncate_utf8_text_over_limit', 0, () => {
      // ASCII：10 字节上限截到 10 个字符
      expect(truncateUtf8Text('abcdefghijk', 10)).assertEqual('abcdefghij')
      // 中文（每字 3 字节）：4 字节上限可放下 '中'（3 字节），'文' 放不下时在 '文' 前截断
      expect(truncateUtf8Text('中文字', 4)).assertEqual('中')
      expect(truncateUtf8Text('中文字', 6)).assertEqual('中文')
      // 代理对（emoji 占 4 字节）：不在代理对中间截断
      let emoji = 'ab😀cd'
      expect(truncateUtf8Text(emoji, 4)).assertEqual('ab')
      expect(truncateUtf8Text(emoji, 6)).assertEqual('ab😀')
      expect(truncateUtf8Text(emoji, 7)).assertEqual('ab😀c')
      expect(truncateUtf8Text(emoji, 8)).assertEqual('ab😀cd')
      // 单个 emoji：4 字节恰好放下；预算不足时整体舍弃，不产生孤立高代理项
      expect(truncateUtf8Text('😀', 4)).assertEqual('😀')
      expect(truncateUtf8Text('😀', 3)).assertEqual('')
    })

    // ── 默认值 ──

    it('ws_handshake_result_defaults', 0, () => {
      let result = new WsHandshakeResult()
      expect(result.targetUrl).assertEqual('')
      expect(result.success).assertFalse()
      expect(result.totalMs).assertEqual(0)
      expect(result.attemptCount).assertEqual(0)
      expect(result.summary).assertEqual('')
    })

    // ── parseDeviceInfo：DeviceInfo JSON 容错解析 ──

    it('parseDeviceInfo_full_json', 0, () => {
      let info = parseDeviceInfo('{"state":0,"mac":"AA:BB:CC:DD:EE:FF","key":"k123","catShare":2}')
      expect(info !== undefined).assertTrue()
      if (info !== undefined) {
        expect(info.state).assertEqual(0)
        expect(info.mac).assertEqual('AA:BB:CC:DD:EE:FF')
        expect(info.key).assertEqual('k123')
        expect(info.catShare).assertEqual(2)
      }
    })

    it('parseDeviceInfo_missing_fields_use_defaults', 0, () => {
      let info = parseDeviceInfo('{}')
      expect(info !== undefined).assertTrue()
      if (info !== undefined) {
        expect(info.state).assertEqual(0)
        expect(info.mac).assertEqual('')
        expect(info.key).assertEqual('')
        expect(info.catShare).assertEqual(0)
      }
    })

    it('parseDeviceInfo_type_mismatch_falls_back_to_defaults', 0, () => {
      // 字段类型不符时取默认值而非报错
      let info = parseDeviceInfo('{"state":"abc","mac":123}')
      expect(info !== undefined).assertTrue()
      if (info !== undefined) {
        expect(info.state).assertEqual(0)
        expect(info.mac).assertEqual('')
      }
    })

    it('parseDeviceInfo_busy_state_without_mac', 0, () => {
      // 对端忙：state 非就绪值、不再返回 mac，并附带 busy 原因码
      let info = parseDeviceInfo('{"state":1,"reason":2}')
      expect(info !== undefined).assertTrue()
      if (info !== undefined) {
        expect(info.state).assertEqual(1)
        expect(info.mac).assertEqual('')
        expect(info.reason).assertEqual(2)
      }
    })

    it('parseDeviceInfo_reason_defaults_to_zero', 0, () => {
      // reason 缺省时为 0（就绪设备不带原因码，空对象同样回退 0）
      let withoutReason = parseDeviceInfo('{"state":1,"mac":"AA:BB:CC:DD:EE:FF"}')
      expect(withoutReason !== undefined).assertTrue()
      if (withoutReason !== undefined) {
        expect(withoutReason.reason).assertEqual(0)
      }
      let empty = parseDeviceInfo('{}')
      expect(empty !== undefined).assertTrue()
      if (empty !== undefined) {
        expect(empty.reason).assertEqual(0)
      }
    })

    it('parseDeviceInfo_reason_type_mismatch_falls_back_to_zero', 0, () => {
      // reason 类型不符时回退默认 0，且不影响其他字段解析
      let info = parseDeviceInfo('{"state":1,"reason":"busy"}')
      expect(info !== undefined).assertTrue()
      if (info !== undefined) {
        expect(info.reason).assertEqual(0)
        expect(info.state).assertEqual(1)
      }
    })

    it('parseDeviceInfo_invalid_json_returns_undefined', 0, () => {
      expect(parseDeviceInfo('not-json') === undefined).assertTrue()
      expect(parseDeviceInfo('') === undefined).assertTrue()
    })

  })
}
