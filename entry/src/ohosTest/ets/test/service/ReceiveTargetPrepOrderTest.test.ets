// 接收目标准备顺序测试：最终/临时路径必须在创建临时文件之前确定并回调，
// 保证强杀发生在文件创建与草稿写入之间时仍能按草稿清理临时区。
import { describe, it, beforeAll, expect } from '@ohos/hypium'
import { fileIo as fs } from '@kit.CoreFileKit'
import { getTestAppContext } from '../helper/TestContext'
import { setAppContext } from '../../../../main/ets/service/repository/AppCore'
import { initAllPreferences } from '../../../../main/ets/utils/PreferencesUtil'
import {
  ReceivedFileEntry,
  RecvPrepareError,
  RecvPrepareOutcome,
  prepareRecvTargets,
  removeDirectoryIfEmpty,
  removeRecvTargetFiles
} from '../../../../main/ets/service/repository/ReceiveTargets'
import {
  nativeDiscardRecvFileFds,
  nativeInit
} from '../../../../main/ets/service/NativeBridge'
import {
  dirNameOf,
  TEMP_SUBDIR_LOCAL_SEND,
  tempPathForFinal
} from '../../../../main/ets/model/transfer/TransferTempPaths'

export default function ReceiveTargetPrepOrderTest() {
  describe('ReceiveTargetPrepOrderTest', () => {
    beforeAll(() => {
      let ctx = getTestAppContext()
      if (ctx !== undefined) {
        setAppContext(ctx)
        initAllPreferences(ctx)
      }
      nativeInit('prep-order-test', 'phone')
    })

    it('paths_ready_before_temp_file_created', 0, async (done: Function) => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        done()
        return
      }
      let sessionId = 'prep-order-' + Date.now().toString()
      let fileName = 'order-' + Date.now().toString() + '.txt'
      let entry: ReceivedFileEntry = {
        sessionId: sessionId,
        fileId: 'f1',
        filePath: '',
        fileName: fileName,
        fileType: 'text/plain',
        preview: 'hello'
      }
      let callbackCount = 0
      let finalPathAtCallback = ''
      let tempPathAtCallback = ''
      let tempExistedAtCallback = true
      let outcome: RecvPrepareOutcome = await prepareRecvTargets(sessionId, ['f1'], [entry],
        (): void => {
          callbackCount++
          finalPathAtCallback = entry.filePath
          tempPathAtCallback = tempPathForFinal(entry.filePath, TEMP_SUBDIR_LOCAL_SEND)
          tempExistedAtCallback = fs.accessSync(tempPathAtCallback)
        })

      expect(callbackCount).assertEqual(1)
      expect(finalPathAtCallback.length > 0).assertTrue()
      // 回调发生在第二遍创建临时文件之前：此时临时文件尚不存在
      expect(tempPathAtCallback.length > 0).assertTrue()
      expect(tempExistedAtCallback).assertFalse()
      expect(outcome.paths !== undefined).assertTrue()
      if (outcome.paths !== undefined) {
        expect(outcome.paths['f1']).assertEqual(finalPathAtCallback)
      }
      // 准备完成后临时文件已创建
      expect(fs.accessSync(tempPathAtCallback)).assertTrue()

      nativeDiscardRecvFileFds(sessionId)
      try {
        fs.unlinkSync(tempPathAtCallback)
      } catch (_e) {
      }
      let tempDir = dirNameOf(tempPathAtCallback)
      removeDirectoryIfEmpty(tempDir)
      removeDirectoryIfEmpty(dirNameOf(tempDir))
      done()
    })

    it('nested_relative_path_creates_dirs_and_relative_name', 0, async (done: Function) => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        done()
        return
      }
      let sessionId = 'nested-' + Date.now().toString()
      let fileName = 'Photos/2024/a-' + Date.now().toString() + '.txt'
      let entry: ReceivedFileEntry = {
        sessionId: sessionId,
        fileId: 'f-nested',
        filePath: '',
        fileName: fileName,
        fileType: 'text/plain',
        preview: 'hello'
      }
      let outcome: RecvPrepareOutcome = await prepareRecvTargets(sessionId, ['f-nested'], [entry])
      expect(outcome.error).assertEqual(RecvPrepareError.none)
      expect(outcome.paths !== undefined).assertTrue()
      expect(entry.fileName).assertEqual(fileName)
      if (outcome.paths !== undefined) {
        let finalPath: string = outcome.paths['f-nested']
        expect(finalPath.endsWith('/Photos/2024/' + entry.fileName.split('/')[2])).assertTrue()
        let parent: string = dirNameOf(finalPath)
        expect(fs.accessSync(parent)).assertTrue()
        let tempPath: string = tempPathForFinal(finalPath, TEMP_SUBDIR_LOCAL_SEND)
        expect(fs.accessSync(tempPath)).assertTrue()
      }
      // 路径目标：临时文件创建后关闭，不保留 fd；清理后本次新建的空目录一并移除
      removeRecvTargetFiles(sessionId)
      expect(entry.filePath.length > 0).assertTrue()
      done()
    })

    it('reserved_temp_component_is_rejected', 0, async (done: Function) => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        done()
        return
      }
      let sessionId = 'reserved-' + Date.now().toString()
      let entry: ReceivedFileEntry = {
        sessionId: sessionId,
        fileId: 'f-reserved',
        filePath: '',
        fileName: '.handysend-temp/a.txt',
        fileType: 'text/plain',
        preview: 'hello'
      }
      let outcome: RecvPrepareOutcome = await prepareRecvTargets(sessionId, ['f-reserved'], [entry])
      expect(outcome.error).assertEqual(RecvPrepareError.reservedName)
      expect(outcome.paths === undefined).assertTrue()
      expect(entry.filePath.length).assertEqual(0)
      done()
    })
  })
}
