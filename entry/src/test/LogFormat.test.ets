import { describe, it, expect } from '@ohos/hypium'
import { composeLogMessage, buildContextPrefix, LogContext } from '../main/ets/common/LogFormat'
import { LogLevels, normalizeLevel } from '../main/ets/common/LogLevels'

// 日志消息拼接与级别归一测试：
// - 模块标签集中前置为 `[标签] `
// - 形态顺序为 `[标签] [上下文] 内容`
// - 未传标签时与既有格式兼容（无 `[]` 前缀）
// - 级别 token 归一保持四级语义（trace 归一到 debug、未知兜底 info）
export default function LogFormatTest() {
  describe('LogFormatTest', () => {
    // ── 标签前置 ──

    it('label_is_prefixed_without_context', 0, () => {
      expect(composeLogMessage('发送', undefined, '开始发送')).assertEqual('[发送] 开始发送')
    })

    it('empty_label_is_omitted', 0, () => {
      expect(composeLogMessage('', undefined, '无标签日志')).assertEqual('无标签日志')
    })

    // ── `[标签] [上下文] 内容` 顺序 ──

    it('label_precedes_context', 0, () => {
      const ctx: LogContext = {
        sessionId: 'sess1234',
        direction: 'send',
        targetAlias: 'Pixel'
      }
      expect(composeLogMessage('传输', ctx, '完成'))
        .assertEqual('[传输] [sid=sess1234 dir=send alias=Pixel] 完成')
    })

    it('label_without_context_keeps_order', 0, () => {
      const ctx: LogContext = { direction: 'recv' }
      expect(composeLogMessage('接收', ctx, '收到请求'))
        .assertEqual('[接收] [dir=recv] 收到请求')
    })

    // ── 无标签兼容（既有调用点未传标签） ──

    it('no_label_with_context_matches_legacy_format', 0, () => {
      const ctx: LogContext = { direction: 'send' }
      expect(composeLogMessage('', ctx, '旧格式')).assertEqual('[dir=send] 旧格式')
    })

    it('missing_label_and_context_returns_raw_message', 0, () => {
      expect(composeLogMessage('', undefined, '裸消息')).assertEqual('裸消息')
    })

    // ── 上下文前缀细节 ──

    it('session_id_is_truncated_to_8', 0, () => {
      const ctx: LogContext = { sessionId: 'abcdefghijk' }
      expect(buildContextPrefix(ctx)).assertEqual('[sid=abcdefgh] ')
    })

    it('empty_context_fields_are_skipped', 0, () => {
      const ctx: LogContext = { direction: 'send', protocol: '' }
      expect(buildContextPrefix(ctx)).assertEqual('[dir=send] ')
    })

    // ── 级别归一（依赖 LogLevels） ──

    it('levels_normalize_within_four_tiers', 0, () => {
      expect(normalizeLevel('DEBUG')).assertEqual(LogLevels.DEBUG)
      expect(normalizeLevel('info')).assertEqual(LogLevels.INFO)
      expect(normalizeLevel('Warn')).assertEqual(LogLevels.WARN)
      expect(normalizeLevel('error')).assertEqual(LogLevels.ERROR)
    })

    it('trace_and_unknown_normalize', 0, () => {
      expect(normalizeLevel('trace')).assertEqual(LogLevels.DEBUG)
      expect(normalizeLevel('verbose')).assertEqual(LogLevels.INFO)
      expect(normalizeLevel('')).assertEqual(LogLevels.INFO)
    })
  })
}
