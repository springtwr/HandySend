// ReceivedPath：接收相对路径的纯逻辑测试
// 覆盖目录拆分、相对/绝对/穿越、保留临时区名与逐段净化。
import { describe, it, expect } from '@ohos/hypium'
import {
  ParsedRelativePath,
  ReceivedPathError,
  ReceivedPathParseResult,
  parseReceivedPath,
  relativePathOf,
  sanitizeReceivedPath
} from '../../../../main/ets/model/transfer/ReceivedPath'

// 模拟 nativeSanitizeFileName（Posix 规则）：控制字符与 '/' 替换为 '_'
function sanitizeComponent(name: string): string {
  let result: string = ''
  for (let i = 0; i < name.length; i++) {
    let ch: string = name.charAt(i)
    let code: number = name.charCodeAt(i)
    result += (ch === '/' || code < 0x20 || code === 0x7f) ? '_' : ch
  }
  return result.length > 0 ? result : 'untitled'
}

function expectParsed(raw: string, dirs: Array<string>, name: string): void {
  let result: ReceivedPathParseResult = parseReceivedPath(raw)
  expect(result.error).assertEqual(ReceivedPathError.none)
  expect(result.path !== undefined).assertTrue()
  if (result.path !== undefined) {
    expect(result.path.name).assertEqual(name)
    expect(result.path.dirs.length).assertEqual(dirs.length)
    for (let i = 0; i < dirs.length; i++) {
      expect(result.path.dirs[i]).assertEqual(dirs[i])
    }
  }
}

function expectError(raw: string, error: ReceivedPathError): void {
  let result: ReceivedPathParseResult = parseReceivedPath(raw)
  expect(result.error).assertEqual(error)
  expect(result.path === undefined).assertTrue()
}

export default function ReceivedPathTest() {
  describe('ReceivedPathTest', () => {
    it('parses_nested_relative_path', 0, () => {
      expectParsed('a/b/c.txt', ['a', 'b'], 'c.txt')
      expectParsed('./a//b.txt', ['a'], 'b.txt')
      expectParsed('a//b/c', ['a', 'b'], 'c')
    })

    it('rejects_missing_file_name', 0, () => {
      expectError('', ReceivedPathError.empty)
      expectError('a/', ReceivedPathError.missingName)
      expectError('a/.', ReceivedPathError.missingName)
      expectError('/', ReceivedPathError.absolute)
    })

    it('rejects_absolute_and_drive_paths', 0, () => {
      expectError('/etc/passwd', ReceivedPathError.absolute)
      expectError('C:/Windows/x', ReceivedPathError.absolute)
      expectError('C:\\Windows\\x', ReceivedPathError.absolute)
      expectError('\\\\server\\share\\x', ReceivedPathError.absolute)
    })

    it('rejects_path_traversal', 0, () => {
      expectError('../x.txt', ReceivedPathError.traversal)
      expectError('a/../x.txt', ReceivedPathError.traversal)
      expectError('a/b/..', ReceivedPathError.traversal)
    })

    it('rejects_reserved_temp_components', 0, () => {
      expectError('.handysend-temp/a.txt', ReceivedPathError.reserved)
      expectError('a/.handysend-temp/b.txt', ReceivedPathError.reserved)
      expectError('a/.handysend-upload-part', ReceivedPathError.reserved)
    })

    it('keeps_backslash_as_literal_name', 0, () => {
      // OHOS 的 '\' 是合法文件名字符；上游 Windows 发送端已把分隔符转成 '/'
      expectParsed('a\\b.txt', [], 'a\\b.txt')
    })

    it('sanitizes_each_component', 0, () => {
      let parsed: ReceivedPathParseResult = parseReceivedPath('a\u0001/b\u0002/c\u0003.txt')
      expect(parsed.path !== undefined).assertTrue()
      if (parsed.path === undefined) {
        return
      }
      let sanitized: ReceivedPathParseResult =
        sanitizeReceivedPath(parsed.path, (name: string): string => sanitizeComponent(name))
      expect(sanitized.error).assertEqual(ReceivedPathError.none)
      expect(sanitized.path !== undefined).assertTrue()
      if (sanitized.path !== undefined) {
        expect(sanitized.path.dirs[0]).assertEqual('a_')
        expect(sanitized.path.dirs[1]).assertEqual('b_')
        expect(sanitized.path.name).assertEqual('c_.txt')
        expect(relativePathOf(sanitized.path)).assertEqual('a_/b_/c_.txt')
      }
    })

    it('sanitize_checks_reserved_after_normalization', 0, () => {
      // 构造一个净化后才变成保留名的目录段，净化后仍需拒绝
      let path: ParsedRelativePath = new ParsedRelativePath(['.handysend-temp'], 'a.txt')
      let sanitized: ReceivedPathParseResult =
        sanitizeReceivedPath(path, (name: string): string => name)
      expect(sanitized.error).assertEqual(ReceivedPathError.reserved)
      expect(sanitized.path === undefined).assertTrue()
    })
  })
}
