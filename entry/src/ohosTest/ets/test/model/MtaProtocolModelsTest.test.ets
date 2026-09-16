import { describe, it, expect } from '@ohos/hypium'
import {
  WsAttemptRecord,
  WsHandshakeResult,
  buildWsHandshakeSummary,
  isVersionNegotiationSupported,
  truncateUtf8Text
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
      let first = new WsAttemptRecord()
      first.round = 1
      result.attempts.push(first)
      let second = new WsAttemptRecord()
      second.round = 2
      result.attempts.push(second)
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
    })

    // ── 默认值 ──

    it('ws_handshake_result_defaults', 0, () => {
      let result = new WsHandshakeResult()
      expect(result.targetUrl).assertEqual('')
      expect(result.success).assertFalse()
      expect(result.totalMs).assertEqual(0)
      expect(result.summary).assertEqual('')
      expect(result.attempts.length).assertEqual(0)
    })

  })
}
