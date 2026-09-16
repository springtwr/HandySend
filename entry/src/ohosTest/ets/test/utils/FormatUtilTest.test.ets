import { describe, it, expect } from '@ohos/hypium'
import { formatSizeDetailed, formatSpeed, formatDuration, formatTime } from '../../../../main/ets/utils/FormatUtil'

export default function FormatUtilTest() {
  describe('FormatUtilTest', () => {
    // ── formatSizeDetailed ──

    it('formatSize_bytes', 0, () => {
      expect(formatSizeDetailed(0)).assertEqual('0 B')
      expect(formatSizeDetailed(999)).assertEqual('999 B')
    })

    it('formatSize_kb', 0, () => {
      expect(formatSizeDetailed(1000)).assertEqual('1.0 KB')
      expect(formatSizeDetailed(1500)).assertEqual('1.5 KB')
      expect(formatSizeDetailed(999999)).assertEqual('1000.0 KB')
    })

    it('formatSize_mb', 0, () => {
      expect(formatSizeDetailed(1000 * 1000)).assertEqual('1.0 MB')
      expect(formatSizeDetailed(1500 * 1000)).assertEqual('1.5 MB')
    })

    it('formatSize_gb', 0, () => {
      expect(formatSizeDetailed(1000 * 1000 * 1000)).assertEqual('1.0 GB')
      expect(formatSizeDetailed(2500 * 1000 * 1000)).assertEqual('2.5 GB')
    })

    // ── formatSpeed ──

    it('formatSpeed_negative', 0, () => {
      expect(formatSpeed(-1)).assertEqual('0 B/s')
    })

    it('formatSpeed_zero', 0, () => {
      expect(formatSpeed(0)).assertEqual('0 B/s')
    })

    it('formatSpeed_bytes_per_sec', 0, () => {
      expect(formatSpeed(500)).assertEqual('500 B/s')
    })

    it('formatSpeed_kb_per_sec', 0, () => {
      expect(formatSpeed(2000)).assertEqual('2.0 KB/s')
    })

    it('formatSpeed_mb_per_sec', 0, () => {
      expect(formatSpeed(1000 * 1000)).assertEqual('1.0 MB/s')
    })

    it('formatSpeed_gb_per_sec', 0, () => {
      expect(formatSpeed(1000 * 1000 * 1000)).assertEqual('1.0 GB/s')
    })

    // ── formatDuration ──

    it('formatDuration_negative_returns_dash', 0, () => {
      expect(formatDuration(-1)).assertEqual('--')
    })

    it('formatDuration_infinity_returns_dash', 0, () => {
      expect(formatDuration(Infinity)).assertEqual('--')
    })

    it('formatDuration_zero', 0, () => {
      expect(formatDuration(0)).assertEqual('00:00')
    })

    it('formatDuration_seconds_only', 0, () => {
      expect(formatDuration(45)).assertEqual('00:45')
    })

    it('formatDuration_minutes_and_seconds', 0, () => {
      expect(formatDuration(125)).assertEqual('02:05')
    })

    it('formatDuration_over_one_hour', 0, () => {
      expect(formatDuration(3661)).assertEqual('1:01:01')
    })

    it('formatDuration_exact_one_hour', 0, () => {
      expect(formatDuration(3600)).assertEqual('1:00:00')
    })

    // ── formatTime ──

    it('formatTime_known_timestamp', 0, () => {
      // 1700000000000 ms → 2023-11-15 06:13（UTC+8）
      expect(formatTime(1700000000000)).assertEqual('2023-11-15 06:13')
    })

    it('formatTime_zero_timestamp', 0, () => {
      // epoch 0 → 1970-01-01 08:00（UTC+8）
      expect(formatTime(0)).assertEqual('1970-01-01 08:00')
    })
  })
}
