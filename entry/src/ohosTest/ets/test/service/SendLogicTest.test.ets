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
      let items: Array<SendFileItem> = buildPathFallbackItems(files, ['p1', 'f1'], ['p1', 'f1'])
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

    it('pathFallback_singleTextMessage_returnsEmpty', 0, () => {
      // 整批仅一条文本消息：正文已随 prepare-upload 的 preview 送达，
      // 回退重发会让接收方收到重复消息
      let files: Array<SendFileItem> = [{
        fileId: 't1', filePath: '/data/clipboard_1.txt', fileName: 'clipboard_1.txt',
        fileType: 'text/plain', size: 4, preview: 'hello', pathSource: true, sourceFd: 9
      }]
      expect(buildPathFallbackItems(files, ['t1'], ['t1']).length).assertEqual(0)
    })

    it('pathFallback_mixedBatch_keepsTextItem', 0, () => {
      // 混合批次不展示文本预览，文本条目按普通文本文件参与回退
      let files: Array<SendFileItem> = [{
        fileId: 't1', filePath: '/data/clipboard_1.txt', fileName: 'clipboard_1.txt',
        fileType: 'text/plain', size: 4, preview: 'hello', pathSource: true, sourceFd: 9
      }, {
        fileId: 'p1', filePath: '/data/a.txt', fileName: 'a.txt',
        fileType: 'text/plain', size: 10, pathSource: true
      }]
      let items: Array<SendFileItem> = buildPathFallbackItems(files, ['t1', 'p1'], ['t1', 'p1'])
      expect(items.length).assertEqual(2)
      if (items.length === 2) {
        expect(items[0].fileId).assertEqual('t1')
        expect(items[1].fileId).assertEqual('p1')
      }
    })

    it('pathFallback_noCandidate_returnsEmpty', 0, () => {
      let files: Array<SendFileItem> = [{
        fileId: 'f1', filePath: '/data/c.txt', fileName: 'c.txt',
        fileType: 'text/plain', size: 30
      }]
      expect(buildPathFallbackItems(files, ['f1'], ['f1']).length).assertEqual(0)
      expect(buildPathFallbackItems(files, [], []).length).assertEqual(0)
    })

    it('pathFallback_receiverFailure_returnsEmpty', 0, () => {
      // 对端 HTTP 错误（如保存目录无权限/不存在的 500）不是本地源文件读取失败：
      // 不得回退句柄重发，否则对端会重复收到发送请求
      let files: Array<SendFileItem> = [{
        fileId: 'p1', filePath: '/data/a.txt', fileName: 'a.txt',
        fileType: 'text/plain', size: 10, pathSource: true, sourceFd: 12
      }]
      expect(buildPathFallbackItems(files, ['p1'], []).length).assertEqual(0)
    })
  })
}
