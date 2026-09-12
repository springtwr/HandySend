import { describe, it, expect } from '@ohos/hypium'
import {
  WsAttemptRecord,
  WsFailureKind,
  WsHandshakeResult,
  buildWsHandshakeSummary,
  formatWsAttemptLine,
  isVersionNegotiationSupported,
  truncateUtf8Text,
  wsFailureKindText
} from '../main/ets/model/mta/MtaProtocolModels'

// 连接路线文本与 WS 握手诊断纯函数测试（路线文案、失败类型文案、尝试时间线、结果摘要）。
export default function MtaProtocolModelsTest() {
  describe('MtaProtocolModelsTest', () => {
    // ── WS 失败类型文本 ──

    it('ws_failure_kind_text', 0, () => {
      expect(wsFailureKindText(WsFailureKind.NONE)).assertEqual('无')
      expect(wsFailureKindText(WsFailureKind.TIMEOUT)).assertEqual('超时')
      expect(wsFailureKindText(WsFailureKind.ERROR)).assertEqual('error 事件')
      expect(wsFailureKindText(WsFailureKind.CONNECT_REJECT)).assertEqual('发起拒绝')
    })

    // ── WS 尝试时间线 ──

    it('format_ws_attempt_success', 0, () => {
      let record = new WsAttemptRecord()
      record.round = 2
      record.success = true
      record.costMs = 120
      expect(formatWsAttemptLine(record)).assertEqual('第 2 轮：成功 耗时 120ms')
    })

    it('format_ws_attempt_timeout_without_code', 0, () => {
      let record = new WsAttemptRecord()
      record.round = 1
      record.success = false
      record.costMs = 3001
      record.failureKind = WsFailureKind.TIMEOUT
      record.failureCode = ''
      record.failureText = 'WS 连接超时（3000ms）'
      expect(formatWsAttemptLine(record)).assertEqual('第 1 轮：失败（超时） 耗时 3001ms WS 连接超时（3000ms）')
    })

    it('format_ws_attempt_error_event_with_code', 0, () => {
      let record = new WsAttemptRecord()
      record.round = 3
      record.success = false
      record.costMs = 45
      record.failureKind = WsFailureKind.ERROR
      record.failureCode = '2301002'
      record.failureText = '连接错误'
      expect(formatWsAttemptLine(record)).assertEqual('第 3 轮：失败（error 事件） 耗时 45ms code=2301002 连接错误')
    })

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
      // 中文（每字 3 字节）：4 字节上限容不下一个汉字，截为空
      expect(truncateUtf8Text('中文字', 4)).assertEqual('')
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
