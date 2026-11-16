// SendFolderStagingTest：文件夹聚合条目的计数、移除与清空，以及批量上限提示。
import { describe, it, expect } from '@ohos/hypium'
import {
  BatchNoticeKind,
  SendViewModel,
  countNewStagedUris
} from '../../../../main/ets/viewmodel/SendViewModel'
import { MAX_BATCH_FILES } from '../../../../main/ets/model/TransferLimits'
import { DiscoveredDevice, StagedFile } from '../../../../main/ets/model/Types'

function folderItem(name: string, count: number): StagedFile {
  return {
    uri: 'file://docs/storage/Users/currentUser/Download/' + name,
    fileName: name,
    fileType: 'folder',
    isImage: false,
    isFolder: true,
    folderFileCount: count,
    folderTotalBytes: count * 10,
    folderScanId: 'scan_' + name,
    size: count * 10
  }
}

function normalItem(name: string): StagedFile {
  return {
    uri: 'file://docs/storage/Users/currentUser/Download/' + name,
    fileName: name,
    fileType: 'text/plain',
    isImage: false
  }
}

export default function SendFolderStagingTest() {
  describe('SendFolderStagingTest', () => {
    it('folder_counts_as_its_file_count', 0, () => {
      let vm: SendViewModel = new SendViewModel();
      vm.stagedFiles = [folderItem('Photos', 3), normalItem('a.txt')];
      expect(vm.hasFolderBatch()).assertTrue();
      expect(vm.stagedFileCount()).assertEqual(4);
      expect(vm.stagedFolderCount()).assertEqual(1);
    })

    it('new_uri_count_excludes_existing_and_duplicates', 0, () => {
      let staged: Array<StagedFile> = [normalItem('a.txt')];
      let uris: Array<string> = [
        'file://docs/storage/Users/currentUser/Download/a.txt',
        'file://docs/storage/Users/currentUser/Download/b.txt',
        'file://docs/storage/Users/currentUser/Download/b.txt',
        'file://docs/storage/Users/currentUser/Download/c.txt'
      ];
      expect(countNewStagedUris(uris, staged)).assertEqual(2);
      expect(countNewStagedUris([], staged)).assertEqual(0);
      expect(countNewStagedUris(uris, [])).assertEqual(3);
    })

    it('mta_rejects_folder_batch', 0, () => {
      let vm: SendViewModel = new SendViewModel();
      vm.stagedFiles = [folderItem('Photos', 3)];
      let device: DiscoveredDevice = {
        alias: 'peer', ip: '10.0.0.2', port: 53317, fingerprint: 'fp', version: '2.2',
        deviceModel: 'Phone', deviceType: 'mobile', protocol: 'https', lastSeen: 0, channels: []
      };
      let request = vm.buildMtaSendParams(device);
      expect(request === undefined).assertTrue();
      expect(vm.batchNotice).assertEqual(BatchNoticeKind.mtaFolderUnsupported);
    })

    it('over_limit_notice_shows_limit_not_total', 0, () => {
      let vm: SendViewModel = new SendViewModel();
      let staged: Array<StagedFile> = [];
      for (let i = 0; i < MAX_BATCH_FILES; i++) {
        staged.push(normalItem('f' + i + '.txt'));
      }
      vm.stagedFiles = staged;
      vm.applyDroppedContent({
        uris: ['file://docs/storage/Users/currentUser/Download/extra.txt'],
        texts: []
      });
      expect(vm.batchNotice).assertEqual(BatchNoticeKind.overLimit);
      // 文案中的数字是单次上限，不是本次尝试发送的总数
      expect(vm.batchNoticeCount).assertEqual(MAX_BATCH_FILES);
    })

    it('remove_and_clear_update_count', 0, () => {
      let vm: SendViewModel = new SendViewModel();
      vm.stagedFiles = [folderItem('Photos', 3), normalItem('a.txt')];
      vm.removeStagedFile(0);
      expect(vm.stagedFileCount()).assertEqual(1);
      expect(vm.stagedFolderCount()).assertEqual(0);
      expect(vm.hasFolderBatch()).assertFalse();
      vm.clearStagedFiles();
      expect(vm.stagedFileCount()).assertEqual(0);
      expect(vm.stagedFiles.length).assertEqual(0);
    })
  })
}
