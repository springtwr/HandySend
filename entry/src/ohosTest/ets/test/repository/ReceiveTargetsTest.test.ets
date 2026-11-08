// ReceiveTargets.uniquePath 同名文件防覆盖回归测试。
// 历史问题：接收文件与目标目录已有文件同名时直接覆盖（用户反馈），
// 修复逻辑为在主干与扩展名之间插入 " (N)" 编号后缀。
import { describe, it, beforeAll, expect } from '@ohos/hypium'
import { fileIo as fs } from '@kit.CoreFileKit'
import {
  removeDirectoryIfEmpty,
  uniquePath
} from '../../../../main/ets/service/repository/ReceiveTargets'
import {
  TEMP_DIR_NAME,
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
  })
}
