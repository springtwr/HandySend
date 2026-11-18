// SendLogic.test：发送协议协商纯逻辑测试
// 覆盖 resolveSendProtocol 的 4 种本地/远程 HTTPS 组合
import { describe, it, expect } from '@ohos/hypium'
import {
  buildPathFallbackItems,
  resolveSendProtocol
} from '../../../../main/ets/service/repository/SendRepository'
import { SendFileItem } from '../../../../main/ets/model/Types'

export default function SendLogicTest() {
  describe('SendLogicTest', () => {

    // ── 加密不可降级 ──

    it('local_https_remote_http_returns_null', 0, () => {
      // 本地要求加密但远程不支持——必须拒绝
      let result: string | null = resolveSendProtocol(true, false)
      expect(result === null).assertTrue()
    })

    // ── 双方 HTTPS ──

    it('local_https_remote_https_returns_https', 0, () => {
      let result: string | null = resolveSendProtocol(true, true)
      expect(result === 'https').assertTrue()
    })

    // ── 本地 HTTP 远程 HTTPS（升级） ──

    it('local_http_remote_https_returns_https', 0, () => {
      // 远程只监听 HTTPS，必须升级才能连上
      let result: string | null = resolveSendProtocol(false, true)
      expect(result === 'https').assertTrue()
    })

    // ── 双方 HTTP ──

    it('local_http_remote_http_returns_http', 0, () => {
      let result: string | null = resolveSendProtocol(false, false)
      expect(result === 'http').assertTrue()
    })

    // ── 路径模式失败 → 句柄模式回退选择 ──

    it('pathFallback_onlyFailedPathItems_asFdCopies', 0, () => {
      let files: Array<SendFileItem> = [{
        fileId: 'p1', filePath: '/data/a.txt', fileName: 'folder/a.txt',
        fileType: 'text/plain', size: 10, pathSource: true, sourceFd: 12
      }, {
        fileId: 'p2', filePath: '/data/b.txt', fileName: 'folder/b.txt',
        fileType: 'text/plain', size: 20, pathSource: true
      }, {
        fileId: 'f1', filePath: '/data/c.txt', fileName: 'c.txt',
        fileType: 'text/plain', size: 30
      }]
      let items: Array<SendFileItem> = buildPathFallbackItems(files, ['p1', 'f1'])
      // 只回退失败的路径条目；普通 fd 条目不在回退范围
      expect(items.length).assertEqual(1)
      if (items.length === 1) {
        expect(items[0].fileId).assertEqual('p1')
        expect(items[0].pathSource).assertFalse()
        // 暂存句柄可复用：回退阶段优先 dup，而不是重新按路径打开
        expect(items[0].sourceFd).assertEqual(12)
        expect(items[0].fileName).assertEqual('folder/a.txt')
      }
    })

    it('pathFallback_noCandidate_returnsEmpty', 0, () => {
      let files: Array<SendFileItem> = [{
        fileId: 'f1', filePath: '/data/c.txt', fileName: 'c.txt',
        fileType: 'text/plain', size: 30
      }]
      expect(buildPathFallbackItems(files, ['f1']).length).assertEqual(0)
      expect(buildPathFallbackItems(files, []).length).assertEqual(0)
    })
  })
}
