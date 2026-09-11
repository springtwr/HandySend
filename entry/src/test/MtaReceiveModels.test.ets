import { describe, it, expect } from '@ohos/hypium'
import {
  WsAttemptRecord,
  WsFailureKind,
  WsHandshakeResult,
  buildWsHandshakeSummary,
  formatWsAttemptLine,
  wsFailureKindText
} from '../main/ets/model/mta/MtaReceiveModels'

// 连接路线文本与 WS 握手诊断纯函数测试（路线文案、失败类型文案、尝试时间线、结果摘要）。
export default function MtaReceiveModelsTest() {
  describe('MtaReceiveModelsTest', () => {
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
