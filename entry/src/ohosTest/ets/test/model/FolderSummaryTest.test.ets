// FolderSummaryTest：入站相对路径 → 文件夹摘要。
import { describe, it, expect } from '@ohos/hypium'
import {
  buildFolderReceiveHistoryEntry,
  summarizeInboundFolder
} from '../../../../main/ets/model/transfer/FolderSummary'
import { ReceiveHistoryEntry } from '../../../../main/ets/model/Types'
import { SessionFileDescriptor, SessionFolderInfo } from '../../../../main/ets/model/transfer/TransferSession'

function file(name: string, size: number): SessionFileDescriptor {
  return { fileId: name, fileName: name, fileType: 'text/plain', totalBytes: size }
}

export default function FolderSummaryTest() {
  describe('FolderSummaryTest', () => {
    it('plain_files_return_undefined', 0, () => {
      let result: SessionFolderInfo | undefined =
        summarizeInboundFolder([file('a.txt', 1), file('b.txt', 2)]);
      expect(result === undefined).assertTrue();
    })

    it('single_root_summary', 0, () => {
      let result: SessionFolderInfo | undefined =
        summarizeInboundFolder([file('Photos/a.jpg', 10), file('Photos/sub/b.jpg', 20)]);
      expect(result !== undefined).assertTrue();
      if (result !== undefined) {
        expect(result.name).assertEqual('Photos');
        expect(result.rootCount).assertEqual(1);
        expect(result.fileCount).assertEqual(2);
        expect(result.totalBytes).assertEqual(30);
      }
    })

    it('folder_receive_history_is_one_entry', 0, () => {
      let entry: ReceiveHistoryEntry | undefined = buildFolderReceiveHistoryEntry('sess',
        ['Photos/a.txt', 'Photos/sub/b.txt'], [10, 20],
        '/storage/Users/currentUser/Download/Photos/sub/b.txt', 'Photos/sub/b.txt', 'peer', 100);
      expect(entry !== undefined).assertTrue();
      if (entry !== undefined) {
        expect(entry.isFolder).assertTrue();
        expect(entry.fileCount).assertEqual(2);
        expect(entry.fileSize).assertEqual(30);
        expect(entry.fileName).assertEqual('Photos');
        expect(entry.path).assertEqual('/storage/Users/currentUser/Download/Photos');
      }
    })

    it('multi_root_summary_has_no_name', 0, () => {
      let result: SessionFolderInfo | undefined =
        summarizeInboundFolder([file('A/a.txt', 1), file('B/b.txt', 2)]);
      expect(result !== undefined).assertTrue();
      if (result !== undefined) {
        expect(result.name).assertEqual('');
        expect(result.rootCount).assertEqual(2);
        expect(result.fileCount).assertEqual(2);
      }
    })
  })
}
