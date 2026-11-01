import { describe, it, expect } from '@ohos/hypium'
import {
  formatLocalClockTime,
  formatLocalIsoTimestamp,
  formatLogLine,
  parseLogLine,
  utf8ByteLength
} from '../../../../main/ets/utils/LogFileFormat'

// 诊断日志文件行格式的纯逻辑测试。
export default function LogFileFormatTest() {
  describe('LogFileFormatTest', () => {
    it('formatAndParseLogLine_roundtrip', 0, () => {
      let line: string = formatLogLine('info', '发送', 'hello', 0)
      expect(line.includes('[info] [发送] hello')).assertTrue()
      let entry = parseLogLine(line.substring(0, line.length - 1), 128)
      expect(entry !== undefined).assertTrue()
      if (entry !== undefined) {
        expect(entry.level).assertEqual('info')
        expect(entry.tag).assertEqual('发送')
        expect(entry.message).assertEqual('hello')
        expect(entry.offset).assertEqual(128)
      }
    })

    it('parseLogLine_skipsMarker', 0, () => {
      expect(parseLogLine('# session-end 2026-01-01T00:00:00.000Z', 0) === undefined).assertTrue()
    })

    it('local_timestamp_roundtrips_and_has_offset', 0, () => {
      let text: string = formatLocalIsoTimestamp(0)
      expect(text.endsWith('Z')).assertFalse()
      expect(Date.parse(text)).assertEqual(0)
    })

    it('clock_time_is_24_hour', 0, () => {
      let text: string = formatLocalClockTime(0)
      expect(text.length).assertEqual(8)
      expect(text.includes('AM')).assertFalse()
      expect(text.includes('PM')).assertFalse()
    })

    it('utf8ByteLength_countsChineseAndAscii', 0, () => {
      expect(utf8ByteLength('中a')).assertEqual(4)
      expect(utf8ByteLength('abc')).assertEqual(3)
    })
  })
}
