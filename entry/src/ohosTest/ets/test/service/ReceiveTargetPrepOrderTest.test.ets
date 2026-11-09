// 接收目标准备顺序测试：最终/临时路径必须在创建临时文件之前确定并回调，
// 保证强杀发生在文件创建与草稿写入之间时仍能按草稿清理临时区。
import { describe, it, beforeAll, expect } from '@ohos/hypium'
import { fileIo as fs } from '@kit.CoreFileKit'
import { getTestAppContext } from '../helper/TestContext'
import { setAppContext } from '../../../../main/ets/service/repository/AppCore'
import { initAllPreferences } from '../../../../main/ets/utils/PreferencesUtil'
import {
  ReceivedFileEntry,
  prepareRecvTargets,
  removeDirectoryIfEmpty
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
      let paths = await prepareRecvTargets(sessionId, ['f1'], [entry], (): void => {
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
      expect(paths !== undefined).assertTrue()
      if (paths !== undefined) {
        expect(paths['f1']).assertEqual(finalPathAtCallback)
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
  })
}
