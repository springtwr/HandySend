// FolderScanTest：沙箱目录的递归扫描（不依赖 Picker UI）。
import { describe, it, expect } from '@ohos/hypium'
import { fileIo as fs, fileUri } from '@kit.CoreFileKit'
import {
  FolderScanPickResult,
  FolderScanStatus,
  scanFolderUri
} from '../../../../main/ets/service/repository/FolderScan'
import { getTestCacheDir } from '../helper/TestHelper'

function createDir(path: string): void {
  if (!fs.accessSync(path)) {
    fs.mkdirSync(path, true);
  }
}

function createFile(path: string, content: string): void {
  let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
  fs.writeSync(file.fd, content);
  fs.closeSync(file);
}

export default function FolderScanTest() {
  describe('FolderScanTest', () => {
    it('scans_nested_files_and_skips_reserved', 0, async () => {
      let root: string = getTestCacheDir() + '/folder_scan_' + Date.now();
      createDir(root + '/sub');
      createDir(root + '/.handysend-temp');
      createFile(root + '/a.txt', 'a');
      createFile(root + '/sub/b.txt', 'b');
      createFile(root + '/.handysend-temp/c.txt', 'c');
      let uri: string = fileUri.getUriFromPath(root);
      let picked: FolderScanPickResult = await scanFolderUri(uri);
      expect(picked.status).assertEqual(FolderScanStatus.success);
      expect(picked.result !== undefined).assertTrue();
      if (picked.result !== undefined) {
        expect(picked.result.entries.length).assertEqual(2);
        expect(picked.result.skipped).assertEqual(1);
        let names: Array<string> = [];
        for (let i = 0; i < picked.result.entries.length; i++) {
          names.push(picked.result.entries[i].relativeName);
        }
        expect(names.indexOf(picked.result.rootName + '/a.txt') >= 0).assertTrue();
        expect(names.indexOf(picked.result.rootName + '/sub/b.txt') >= 0).assertTrue();
      }
    })

    it('empty_folder_returns_empty', 0, async () => {
      let root: string = getTestCacheDir() + '/folder_scan_empty_' + Date.now();
      createDir(root);
      let picked: FolderScanPickResult = await scanFolderUri(fileUri.getUriFromPath(root));
      expect(picked.status).assertEqual(FolderScanStatus.empty);
      expect(picked.result === undefined).assertTrue();
    })
  })
}
