// ReceiveTargets.uniquePath 同名文件防覆盖回归测试。
// 历史问题：接收文件与目标目录已有文件同名时直接覆盖（用户反馈），
// 修复逻辑为在主干与扩展名之间插入 " (N)" 编号后缀。
import { describe, it, beforeAll, expect } from '@ohos/hypium'
import { fileIo as fs } from '@kit.CoreFileKit'
import {
  MAX_RECV_FILES,
  ReceivedFileEntry,
  RecvPrepareError,
  RecvPrepareOutcome,
  prepareRecvTargets,
  removeDirectoryIfEmpty,
  removeRecvTargetPaths,
  uniqueDirectoryName,
  uniquePath
} from '../../../../main/ets/service/repository/ReceiveTargets'
import {
  TEMP_DIR_NAME,
  TEMP_SUBDIR_LOCAL_SEND,
  TEMP_SUBDIR_WEB
} from '../../../../main/ets/model/transfer/TransferTempPaths'
import { getTestCacheDir, ensureDir } from '../helper/TestHelper'

// 在目标目录创建一个空文件（制造同名冲突场景）
function writeFile(dir: string, name: string): void {
  let file = fs.openSync(dir + '/' + name, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
  fs.closeSync(file)
}

export default function ReceiveTargetsTest() {
  describe('ReceiveTargetsTest', () => {
    let dir: string = ''

    beforeAll(() => {
      // 每轮运行使用独立子目录，避免上一轮残留文件干扰冲突判断
      dir = getTestCacheDir() + '/unique_path_test_' + Date.now()
      ensureDir(dir)
    })

    it('uniquePath_no_conflict_returns_original', 0, () => {
      expect(uniquePath(dir, 'fresh.txt')).assertEqual('fresh.txt')
    })

    it('uniquePath_conflict_appends_number_suffix', 0, () => {
      writeFile(dir, 'doc.txt')
      expect(uniquePath(dir, 'doc.txt')).assertEqual('doc (1).txt')
      // 已有 (1) 时递增到 (2)
      writeFile(dir, 'doc (1).txt')
      expect(uniquePath(dir, 'doc.txt')).assertEqual('doc (2).txt')
    })

    it('uniquePath_multi_dot_uses_last_dot', 0, () => {
      writeFile(dir, 'archive.tar.gz')
      // 多点号取最后一个点号分隔：主干 archive.tar、扩展名 .gz
      expect(uniquePath(dir, 'archive.tar.gz')).assertEqual('archive.tar (1).gz')
    })

    it('uniquePath_no_extension_appends_suffix', 0, () => {
      writeFile(dir, 'README')
      expect(uniquePath(dir, 'README')).assertEqual('README (1)')
    })

    it('uniquePath_hidden_file_treated_as_no_extension', 0, () => {
      writeFile(dir, '.hidden')
      // 以点号开头的隐藏文件不视为扩展名
      expect(uniquePath(dir, '.hidden')).assertEqual('.hidden (1)')
    })

    it('removeDirectoryIfEmpty_keeps_non_empty_dir', 0, () => {
      // OHOS rmdirSync 会递归删除目录内容，辅助函数必须先确认目录为空
      let nonEmpty = dir + '/remove_empty_keep'
      ensureDir(nonEmpty)
      writeFile(nonEmpty, 'keep.txt')
      removeDirectoryIfEmpty(nonEmpty)
      expect(fs.accessSync(nonEmpty)).assertTrue()
      expect(fs.accessSync(nonEmpty + '/keep.txt')).assertTrue()
      let empty = dir + '/remove_empty_drop'
      ensureDir(empty)
      removeDirectoryIfEmpty(empty)
      expect(fs.accessSync(empty)).assertFalse()
    })

    it('uniquePath_respects_temp_reservation', 0, () => {
      let tempDir = dir + '/' + TEMP_DIR_NAME + '/' + TEMP_SUBDIR_WEB
      ensureDir(tempDir)
      // 最终路径尚未出现，但其他协议已在临时区预留同名文件
      writeFile(tempDir, 'reserved.jpg')
      expect(uniquePath(dir, 'reserved.jpg')).assertEqual('reserved (1).jpg')
      // 预留文件存在时，带序号的名字也不能重复占用
      writeFile(tempDir, 'reserved (1).jpg')
      expect(uniquePath(dir, 'reserved.jpg')).assertEqual('reserved (2).jpg')
    })

    it('uniqueDirectoryName_no_conflict_returns_original', 0, () => {
      expect(uniqueDirectoryName(dir, 'folder_new', (): boolean => false))
        .assertEqual('folder_new')
    })

    it('uniqueDirectoryName_existing_dir_appends_suffix', 0, () => {
      // 已有同名文件夹：新文件夹整体改名，而不是把内容并入已有目录
      ensureDir(dir + '/folder_dup')
      expect(uniqueDirectoryName(dir, 'folder_dup', (): boolean => false))
        .assertEqual('folder_dup (1)')
      ensureDir(dir + '/folder_dup (1)')
      expect(uniqueDirectoryName(dir, 'folder_dup', (): boolean => false))
        .assertEqual('folder_dup (2)')
    })

    it('uniqueDirectoryName_existing_file_also_conflicts', 0, () => {
      // 同名普通文件同样不能让目录复用该路径
      writeFile(dir, 'folder_file_clash')
      expect(uniqueDirectoryName(dir, 'folder_file_clash', (): boolean => false))
        .assertEqual('folder_file_clash (1)')
    })

    it('uniqueDirectoryName_keeps_dots_in_name', 0, () => {
      // 目录名不拆分扩展名：点号属于名称本身
      ensureDir(dir + '/archive.tar.gz')
      expect(uniqueDirectoryName(dir, 'archive.tar.gz', (): boolean => false))
        .assertEqual('archive.tar.gz (1)')
    })

    it('uniqueDirectoryName_respects_batch_reservation', 0, () => {
      // 本批次已给其他根目录占用该名称时继续递增
      expect(uniqueDirectoryName(dir, 'folder_batch',
        (path: string): boolean => path === dir + '/folder_batch'))
        .assertEqual('folder_batch (1)')
    })

    it('uniqueDirectoryName_respects_temp_reservation', 0, () => {
      // 其他协议已在临时区预留同名文件时，目录不能占用该最终路径
      let tempDir = dir + '/' + TEMP_DIR_NAME + '/' + TEMP_SUBDIR_WEB
      ensureDir(tempDir)
      writeFile(tempDir, 'folder_reserved')
      expect(uniqueDirectoryName(dir, 'folder_reserved', (): boolean => false))
        .assertEqual('folder_reserved (1)')
    })

    it('removeRecvTargetPaths_removes_empty_temp_root', 0, () => {
      // 回归场景：中断清理只删协议子目录、漏删空的临时区根目录时，
      // 任务结束后会残留 .handysend-temp；同时已完成文件不得被清理。
      // 使用独立子目录，避免同套件其他用例在共享临时区根目录预留下的文件干扰空目录判定
      let caseDir = dir + '/remove_targets_case'
      let tempRoot = caseDir + '/' + TEMP_DIR_NAME
      let tempDir = tempRoot + '/' + TEMP_SUBDIR_LOCAL_SEND
      ensureDir(tempDir)
      writeFile(tempDir, 'keep.bin')
      writeFile(tempDir, 'drop.bin')
      let perTemp: Record<string, string> = {}
      perTemp['keep'] = tempDir + '/keep.bin'
      perTemp['drop'] = tempDir + '/drop.bin'
      let keep: Record<string, boolean> = {}
      keep['keep'] = true

      removeRecvTargetPaths(perTemp, keep)

      // 已完成文件保留，未完成临时文件删除
      expect(fs.accessSync(perTemp['keep'])).assertTrue()
      expect(fs.accessSync(perTemp['drop'])).assertFalse()
      // 子目录仍非空：子目录与临时区根目录都保留
      expect(fs.accessSync(tempDir)).assertTrue()
      expect(fs.accessSync(tempRoot)).assertTrue()

      // 模拟已完成文件提交改名后再清理：空的子目录与根目录一并移除
      fs.unlinkSync(perTemp['keep'])
      removeRecvTargetPaths(perTemp)
      expect(fs.accessSync(tempDir)).assertFalse()
      expect(fs.accessSync(tempRoot)).assertFalse()
    })

    it('prepare_rejects_more_than_max_files', 0, async (done: Function) => {
      // 文件数上限在目标规划/目录解析之前返回，不触碰文件系统
      let ids: Array<string> = []
      let entries: Array<ReceivedFileEntry> = []
      let count: number = MAX_RECV_FILES + 1
      for (let i = 0; i < count; i++) {
        let id: string = 'cap_' + i
        ids.push(id)
        entries.push({
          sessionId: 'cap_session',
          fileId: id,
          filePath: '',
          fileName: 'file_' + i + '.bin',
          fileType: 'application/octet-stream'
        })
      }
      let outcome: RecvPrepareOutcome = await prepareRecvTargets('cap_session', ids, entries)
      expect(outcome.error).assertEqual(RecvPrepareError.tooMany)
      expect(outcome.paths === undefined).assertTrue()
      done()
    })
  })
}
