import { describe, it, expect } from '@ohos/hypium'
import { parseRustLogLine } from '../../../../main/ets/model/mta/MtaSendModels'

// MTA 发送页 Rust 日志解析测试：`level|target|message` 前缀按前两个分隔符拆分，无分隔符按 info 兜底。
export default function MtaSendLogFilterTest() {
  describe('MtaSendLogFilterTest', () => {
    it('parses_level_and_target_prefix', 0, () => {
      let parsed = parseRustLogLine(
        'info|localsend_core::bridge::mta::server|MTA 服务器已启动 port=42587 zip=136 bytes')
      expect(parsed.level).assertEqual('info')
      expect(parsed.message).assertEqual('MTA 服务器已启动 port=42587 zip=136 bytes')
    })

    it('parses_trace_prefix_for_shutdown_log', 0, () => {
      let parsed = parseRustLogLine(
        'trace|localsend_core::bridge::mta::ws|MTA 连接收尾: error shutting down connection')
      expect(parsed.level).assertEqual('trace')
      expect(parsed.message).assertEqual('MTA 连接收尾: error shutting down connection')
    })

    it('parses_debug_prefix', 0, () => {
      let parsed = parseRustLogLine(
        'debug|localsend_core::bridge::mta::ws|MTA 连接结束: 对端关闭了连接')
      expect(parsed.level).assertEqual('debug')
      expect(parsed.message).assertEqual('MTA 连接结束: 对端关闭了连接')
    })

    it('keeps_separator_inside_message', 0, () => {
      let parsed = parseRustLogLine('warn|localsend_core::bridge::mta::ws|MTA 异常: a|b')
      expect(parsed.level).assertEqual('warn')
      expect(parsed.message).assertEqual('MTA 异常: a|b')
    })

    it('falls_back_to_info_without_separator', 0, () => {
      let parsed = parseRustLogLine('MTA 服务器已启动 port=42587')
      expect(parsed.level).assertEqual('info')
      expect(parsed.message).assertEqual('MTA 服务器已启动 port=42587')
    })

    it('handles_empty_log', 0, () => {
      let parsed = parseRustLogLine('')
      expect(parsed.level).assertEqual('info')
      expect(parsed.message).assertEqual('')
    })
  })
}
