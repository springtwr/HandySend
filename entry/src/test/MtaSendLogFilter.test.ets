import { describe, it, expect } from '@ohos/hypium'
import { isBenignRustConnectionLog } from '../main/ets/model/mta/MtaSendModels'

// MTA 发送页 Rust 日志分级测试：连接收尾类噪音应被识别为可降级展示。
export default function MtaSendLogFilterTest() {
  describe('MtaSendLogFilterTest', () => {
    it('detects_shutdown_connection_log', 0, () => {
      expect(isBenignRustConnectionLog('MTA 连接结束: error shutting down connection')).assertTrue()
    })

    it('ignores_normal_lifecycle_log', 0, () => {
      expect(isBenignRustConnectionLog('MTA 服务器已启动 port=42587 zip=136 bytes')).assertFalse()
    })

    it('ignores_other_connection_end_log', 0, () => {
      expect(isBenignRustConnectionLog('MTA 连接结束: 对端关闭了连接')).assertFalse()
    })

    it('handles_empty_log', 0, () => {
      expect(isBenignRustConnectionLog('')).assertFalse()
    })
  })
}
