import { describe, it, expect } from '@ohos/hypium'
import { LogLevels, isValidLevel, normalizeLevel } from '../../../../main/ets/common/LogLevels'

// LogLevels 纯函数测试：校验与归一（含 Rust trace 与未知兜底）。
export default function LogLevelsTest() {
  describe('LogLevelsTest', () => {
    // ── isValidLevel ──

    it('isValidLevel_accepts_five_levels', 0, () => {
      expect(isValidLevel(LogLevels.DEBUG)).assertTrue()
      expect(isValidLevel(LogLevels.INFO)).assertTrue()
      expect(isValidLevel(LogLevels.WARN)).assertTrue()
      expect(isValidLevel(LogLevels.ERROR)).assertTrue()
      expect(isValidLevel(LogLevels.FATAL)).assertTrue()
    })

    it('isValidLevel_rejects_unknown_and_trace', 0, () => {
      expect(isValidLevel('trace')).assertFalse()
      expect(isValidLevel('verbose')).assertFalse()
      expect(isValidLevel('')).assertFalse()
      expect(isValidLevel('信息')).assertFalse()
      expect(isValidLevel('INFO')).assertFalse()
    })

    // ── normalizeLevel ──

    it('normalizeLevel_keeps_valid_tokens', 0, () => {
      expect(normalizeLevel(LogLevels.DEBUG)).assertEqual(LogLevels.DEBUG)
      expect(normalizeLevel(LogLevels.INFO)).assertEqual(LogLevels.INFO)
      expect(normalizeLevel(LogLevels.WARN)).assertEqual(LogLevels.WARN)
      expect(normalizeLevel(LogLevels.ERROR)).assertEqual(LogLevels.ERROR)
      expect(normalizeLevel(LogLevels.FATAL)).assertEqual(LogLevels.FATAL)
    })

    it('normalizeLevel_maps_trace_to_debug', 0, () => {
      expect(normalizeLevel('trace')).assertEqual(LogLevels.DEBUG)
      expect(normalizeLevel('TRACE')).assertEqual(LogLevels.DEBUG)
    })

    it('normalizeLevel_lowercases_case_insensitive', 0, () => {
      expect(normalizeLevel('ERROR')).assertEqual(LogLevels.ERROR)
      expect(normalizeLevel('Warn')).assertEqual(LogLevels.WARN)
    })

    it('normalizeLevel_falls_back_to_info', 0, () => {
      expect(normalizeLevel('verbose')).assertEqual(LogLevels.INFO)
      expect(normalizeLevel('')).assertEqual(LogLevels.INFO)
      expect(normalizeLevel('信息')).assertEqual(LogLevels.INFO)
    })
  })
}
