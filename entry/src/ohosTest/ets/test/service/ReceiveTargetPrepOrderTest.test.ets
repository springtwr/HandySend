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
  ensureRecvTextDir,
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

    it('existing_root_folder_is_renamed_as_a_whole', 0, async (done: Function) => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        done()
        return
      }
      let stamp = Date.now().toString()
      let rootName = 'root-conflict-' + stamp
      let textDir = ensureRecvTextDir()
      expect(textDir.length > 0).assertTrue()
      // 目标中已有同名文件夹（模拟此前接收的文件夹）
      fs.mkdirSync(textDir + '/' + rootName, true)
      let existingFile = fs.openSync(textDir + '/' + rootName + '/keep.txt',
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)
      fs.closeSync(existingFile)

      let sessionId = 'root-conflict-' + stamp
      let first: ReceivedFileEntry = {
        sessionId: sessionId,
        fileId: 'root-1',
        filePath: '',
        fileName: rootName + '/a.txt',
        fileType: 'text/plain',
        preview: 'hello'
      }
      let second: ReceivedFileEntry = {
        sessionId: sessionId,
        fileId: 'root-2',
        filePath: '',
        fileName: rootName + '/sub/b.txt',
        fileType: 'text/plain',
        preview: 'hello'
      }
      let outcome: RecvPrepareOutcome =
        await prepareRecvTargets(sessionId, ['root-1', 'root-2'], [first, second])
      expect(outcome.error).assertEqual(RecvPrepareError.none)
      expect(outcome.paths !== undefined).assertTrue()
      // 同一根目录整体改名（同批次共用映射），而不是逐个文件改名
      expect(first.fileName).assertEqual(rootName + ' (1)/a.txt')
      expect(second.fileName).assertEqual(rootName + ' (1)/sub/b.txt')
      if (outcome.paths !== undefined) {
        expect(outcome.paths['root-1']).assertEqual(textDir + '/' + rootName + ' (1)/a.txt')
        expect(outcome.paths['root-2']).assertEqual(textDir + '/' + rootName + ' (1)/sub/b.txt')
      }
      // 已有文件夹内容保持原样，新内容不会混入其中
      expect(fs.accessSync(textDir + '/' + rootName + '/keep.txt')).assertTrue()
      expect(fs.accessSync(textDir + '/' + rootName + '/a.txt')).assertFalse()

      nativeDiscardRecvFileFds(sessionId)
      removeRecvTargetFiles(sessionId)
      // 本次新建的改名目录随清理移除；预先存在的文件夹保留（内容非空）
      expect(fs.accessSync(textDir + '/' + rootName + ' (1)')).assertFalse()
      expect(fs.accessSync(textDir + '/' + rootName + '/keep.txt')).assertTrue()
      fs.rmdirSync(textDir + '/' + rootName)
      done()
    })

    it('renamed_root_does_not_reject_loose_file', 0, async (done: Function) => {
      let ctx = getTestAppContext()
      expect(ctx !== undefined).assertTrue()
      if (ctx === undefined) {
        done()
        return
      }
      let stamp = Date.now().toString()
      let sessionId = 'root-loose-session-' + stamp
      let rootName = 'root-loose-' + stamp
      let textDir = ensureRecvTextDir()
      expect(textDir.length > 0).assertTrue()
      fs.mkdirSync(textDir + '/' + rootName, true)
      let folderEntry: ReceivedFileEntry = {
        sessionId: sessionId,
        fileId: 'loose-folder',
        filePath: '',
        fileName: rootName + '/a.txt',
        fileType: 'text/plain',
        preview: 'hello'
      }
      // 独立文件恰好与改名后的根目录同名：不能因此拒绝整个请求
      let looseEntry: ReceivedFileEntry = {
        sessionId: sessionId,
        fileId: 'loose-file',
        filePath: '',
        fileName: rootName + ' (1)',
        fileType: 'text/plain',
        preview: 'bye'
      }
      let outcome: RecvPrepareOutcome = await prepareRecvTargets(sessionId,
        ['loose-folder', 'loose-file'], [folderEntry, looseEntry])
      expect(outcome.error).assertEqual(RecvPrepareError.none)
      expect(outcome.paths !== undefined).assertTrue()
      expect(folderEntry.fileName).assertEqual(rootName + ' (1)/a.txt')
      // 独立文件继续消歧，与文件夹路径不同
      expect(looseEntry.fileName === rootName + ' (1)').assertFalse()
      if (outcome.paths !== undefined) {
        expect(outcome.paths['loose-folder'] !== outcome.paths['loose-file']).assertTrue()
      }
      nativeDiscardRecvFileFds(sessionId)
      removeRecvTargetFiles(sessionId)
      fs.rmdirSync(textDir + '/' + rootName)
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
