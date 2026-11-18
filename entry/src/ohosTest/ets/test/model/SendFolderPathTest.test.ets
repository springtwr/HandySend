// SendFolderPathTest：发送文件夹相对路径的构造与净化边界。
import { describe, it, expect } from '@ohos/hypium'
import { ReceivedPathError } from '../../../../main/ets/model/transfer/ReceivedPath'
import { buildSendRelativePath, SendPathResult } from '../../../../main/ets/model/transfer/SendFolderPath'

function sanitizeComponent(name: string): string {
  let result: string = ''
  for (let i = 0; i < name.length; i++) {
    let ch: string = name.charAt(i)
    let code: number = name.charCodeAt(i)
    result += (ch === '/' || code < 0x20 || code === 0x7f) ? '_' : ch;
  }
  return result.length > 0 ? result : 'untitled';
}

export default function SendFolderPathTest() {
  describe('SendFolderPathTest', () => {
    it('builds_root_and_nested_relative_path', 0, () => {
      let result: SendPathResult = buildSendRelativePath('Photos', '2024/a.jpg', sanitizeComponent);
      expect(result.ok).assertTrue();
      expect(result.relativeName).assertEqual('Photos/2024/a.jpg');
    })

    it('strips_leading_slash_from_list_result', 0, () => {
      let result: SendPathResult = buildSendRelativePath('Photos', '/2024/a.jpg', sanitizeComponent);
      expect(result.ok).assertTrue();
      expect(result.relativeName).assertEqual('Photos/2024/a.jpg');
    })

    it('rejects_traversal', 0, () => {
      let result: SendPathResult = buildSendRelativePath('Photos', '../secret.txt', sanitizeComponent);
      expect(result.ok).assertFalse();
      expect(result.error).assertEqual(ReceivedPathError.traversal);
    })

    it('rejects_reserved_temp_component', 0, () => {
      let result: SendPathResult = buildSendRelativePath('Photos', '.handysend-temp/a.txt',
        sanitizeComponent);
      expect(result.ok).assertFalse();
      expect(result.error).assertEqual(ReceivedPathError.reserved);
    })

    it('rejects_empty_relative_path', 0, () => {
      let result: SendPathResult = buildSendRelativePath('Photos', '', sanitizeComponent);
      expect(result.ok).assertFalse();
      expect(result.error).assertEqual(ReceivedPathError.empty);
    })

    it('rejects_overlong_relative_path', 0, () => {
      let longName: string = '';
      for (let i = 0; i < 1100; i++) {
        longName += 'a';
      }
      let result: SendPathResult = buildSendRelativePath('Photos', longName, sanitizeComponent);
      expect(result.ok).assertFalse();
    })
  })
}
