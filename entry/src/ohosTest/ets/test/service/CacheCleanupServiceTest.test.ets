// CacheCleanupServiceTest：缓存清理的目录遍历、字节统计、缺失目录兜底与传输占用判定
import { describe, it, expect } from '@ohos/hypium'
import { fileIo as fs } from '@kit.CoreFileKit'
import { getTestCacheDir } from '../helper/TestHelper'
import {
  DirectoryClearResult,
  clearDirectoryContents,
  directoryBytesOf,
  hasActiveTransferSessions
} from '../../../../main/ets/service/CacheCleanupService'
import {
  createSession,
  resetRegistry
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import {
  SessionCreateInput,
  SessionDataFlow,
  SessionInitiator,
  defaultCapabilities,
  emptyPeer
} from '../../../../main/ets/model/transfer/TransferSession'

function writeText(path: string, content: string): void {
  let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
  fs.writeSync(file.fd, content)
  fs.closeSync(file)
}

function makeOutboundInput(): SessionCreateInput {
  return {
    protocolKey: 'test-cache',
    protocolSessionId: 'cache-session',
    dataFlow: SessionDataFlow.outbound,
    initiatedBy: SessionInitiator.local,
    peer: emptyPeer(),
    files: [{
      fileId: 'f1',
      fileName: 'cache.bin',
      fileType: 'application/octet-stream',
      totalBytes: 1
    }],
    capabilities: defaultCapabilities()
  }
}

export default function CacheCleanupServiceTest() {
  describe('CacheCleanupServiceTest', () => {
    it('clearDirectoryContents_removesFilesAndSubdirs_keepsRoot', 0, () => {
      let root: string = getTestCacheDir() + '/clear_cache_test_' + Date.now().toString()
      fs.mkdirSync(root + '/sub', true)
      writeText(root + '/a.txt', 'a')
      writeText(root + '/sub/b.txt', 'b')

      expect(directoryBytesOf(root)).assertEqual(2)
      let result: DirectoryClearResult = clearDirectoryContents(root)

      expect(result.entries).assertEqual(2)
      expect(result.bytes).assertEqual(2)
      expect(fs.accessSync(root)).assertTrue()
      expect(fs.listFileSync(root).length).assertEqual(0)
      fs.rmdirSync(root)
    })

    it('clearDirectoryContents_missingDir_returnsZero', 0, () => {
      let missing: string = getTestCacheDir() + '/clear_cache_missing_' + Date.now().toString()
      let result: DirectoryClearResult = clearDirectoryContents(missing)
      expect(result.entries).assertEqual(0)
      expect(result.bytes).assertEqual(0)
      expect(directoryBytesOf(missing)).assertEqual(0)
    })

    it('hasActiveTransferSessions_tracksNonTerminalRegistrySessions', 0, () => {
      resetRegistry()
      try {
        expect(hasActiveTransferSessions()).assertFalse()
        createSession(makeOutboundInput())
        expect(hasActiveTransferSessions()).assertTrue()
      } finally {
        resetRegistry()
      }
    })
  })
}

