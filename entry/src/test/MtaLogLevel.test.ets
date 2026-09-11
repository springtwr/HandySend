import { describe, it, expect } from '@ohos/hypium'
import { LogLevels, normalizeLevel } from '../main/ets/common/LogLevels'

// MTA appendLog 级别归一测试。
// MtaSendService / MtaReceiveService 两处 appendLog 均以同一个 normalizeLevel 归一级别后
// 再经 logger.log 输出；本地单测环境不加载系统 Kit，故按调用点实际使用的级别 token 覆盖归一结果。
export default function MtaLogLevelTest() {
  describe('MtaLogLevelTest', () => {
    // MtaSendService.appendLog：调用点使用 LogLevels.INFO / LogLevels.ERROR
    it('mta_send_service_levels_normalize', 0, () => {
      expect(normalizeLevel(LogLevels.INFO)).assertEqual(LogLevels.INFO)
      expect(normalizeLevel(LogLevels.ERROR)).assertEqual(LogLevels.ERROR)
      expect(normalizeLevel(LogLevels.DEBUG)).assertEqual(LogLevels.DEBUG)
    })

    // MtaReceiveService.appendLog：调用点使用 LogLevels.INFO / LogLevels.ERROR
    it('mta_receive_service_levels_normalize', 0, () => {
      expect(normalizeLevel(LogLevels.INFO)).assertEqual(LogLevels.INFO)
      expect(normalizeLevel(LogLevels.ERROR)).assertEqual(LogLevels.ERROR)
    })

    // Rust 级别 token：trace 归一到 debug（连接收尾类日志展示为诊断级）
    it('rust_trace_token_normalizes_to_debug', 0, () => {
      expect(normalizeLevel('trace')).assertEqual(LogLevels.DEBUG)
      expect(normalizeLevel('TRACE')).assertEqual(LogLevels.DEBUG)
    })

    // 未知/非法 token 统一兜底为 info
    it('unknown_token_falls_back_to_info', 0, () => {
      expect(normalizeLevel('诊断')).assertEqual(LogLevels.INFO)
      expect(normalizeLevel('verbose')).assertEqual(LogLevels.INFO)
      expect(normalizeLevel('')).assertEqual(LogLevels.INFO)
    })
  })
}
