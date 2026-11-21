// LoopbackTransferTest：回环文件传输端到端链路测试
//
// 单设备条件下验证完整传输链路（不依赖第二台设备/浏览器/人工操作）：
//   写真实文件到沙箱 → nativeSendFiles 发送到本机服务器 → 订阅事件收到
//   prepareUpload → nativeRespondTransfer 接受 → Rust 自动落盘到接收目录
//   → 校验接收文件字节内容与发送一致 → sessionEnd(Finished) 会话正常结束。
//
// 覆盖此前仅靠人工验证的"发送→接收→保存→完成"应用级链路。
import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium'
import { fileIo as fs } from '@kit.CoreFileKit'
import {
  nativeSendFiles,
  nativeRespondTransfer,
  nativeRegisterRecvFileFd,
  nativeHashFileStream,
  nativeInit,
  nativePollDebugLogWithLevels,
  onBridgeEvent,
  offBridgeEvent
} from '../../../../main/ets/service/NativeBridge'
import {
  NativeEvent,
  NativePrepareUploadEvent,
  NativeSessionEndEvent,
  NativeSendResult,
  NativeTargetDevice,
  NativeFileToSend
} from '../../../../main/ets/model/NativeTypes'
import {
  startServer,
  stopServer,
  allocateTestPort,
  writeTestFileToSandbox,
  readFileContent,
  fileExists,
  ensureDir,
  getTestCacheDir,
  sleep
} from '../helper/TestHelper'
import { sendToDevice } from '../../../../main/ets/service/repository/SendRepository'
import { DiscoveredDevice, SendFileItem } from '../../../../main/ets/model/Types'
import {
  getHttpsEnabled,
  setHttpsEnabled
} from '../../../../main/ets/service/repository/SettingsRepository'
import {
  TEMP_DIR_NAME,
  TEMP_SUBDIR_LOCAL_SEND,
  tempPathForFinal
} from '../../../../main/ets/model/transfer/TransferTempPaths'

// 接收保存目录：惰性获取（context 在 TestAbility.onCreate 注入，模块加载时
// 不可用；服务器保存文件需目录预先存在）。
function getRecvDir(): string {
  return getTestCacheDir() + '/handysend_e2e/'
}

function getRecvDirHttps(): string {
  return getTestCacheDir() + '/handysend_e2e_https/'
}

function getRecvDirPin(): string {
  return getTestCacheDir() + '/handysend_e2e_pin/'
}

// 失败诊断：排空 Rust 日志缓冲（Rust 侧 log 输出仅在进程内缓冲，
// 测试进程无人消费，失败时取出嵌入错误消息供定位）
function dumpRustLogs(): string {
  let lines: Array<string> = nativePollDebugLogWithLevels()
  if (lines.length === 0) {
    return '(Rust 日志缓冲为空)'
  }
  // 单行拼接：测试框架错误输出仅展示首行，换行符会丢失后续内容
  return lines.join(' | ')
}

// 预注册接收目标并接受会话：路径目标模式要求 accept 前创建最终目录与空临时文件，
// 然后注册 fd = -1（最终路径）；Rust 在上传到达时用 O_NOFOLLOW 打开临时文件，
// 写入完成后 rename 到最终路径，否则服务器无落盘目标，上传以 500 失败。
function acceptWithRecvTargets(e: NativeEvent, recvDir: string): void {
  if (e.type !== 'prepareUpload') {
    return
  }
  let pe = e as NativePrepareUploadEvent
  let ids: Array<string> = []
  for (let i = 0; i < pe.files.length; i++) {
    let destPath: string = recvDir + pe.files[i].fileName
    let finalDir: string = destPath.substring(0, destPath.lastIndexOf('/'))
    ensureDir(finalDir)
    let tempPath: string = tempPathForFinal(destPath, TEMP_SUBDIR_LOCAL_SEND)
    let tempDir: string = tempPath.substring(0, tempPath.lastIndexOf('/'))
    ensureDir(tempDir)
    let file = fs.openSync(tempPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE |
      fs.OpenMode.TRUNC)
    fs.closeSync(file)
    nativeRegisterRecvFileFd(pe.sessionId, pe.files[i].fileId, -1, destPath)
    ids.push(pe.files[i].fileId)
  }
  nativeRespondTransfer(pe.sessionId, true, ids)
}

/// 完整"发送→事件接受→落盘验证→会话结束"链路（参数化 target/目录/内容）。
async function sendLoopbackAndVerify(
  target: NativeTargetDevice,
  recvDir: string,
  fileName: string,
  content: string,
  fileId: string
): Promise<void> {
  let sendPath: string = writeTestFileToSandbox(fileName, content)

  let prepFlag: boolean = false
  let endFlag: boolean = false
  let prepareHandler = (e: NativeEvent): void => {
    if (e.type === 'prepareUpload') {
      prepFlag = true
      acceptWithRecvTargets(e, recvDir)
    }
  }
  let endHandler = (e: NativeEvent): void => {
    if (e.type === 'sessionEnd') {
      let se = e as NativeSessionEndEvent
      if (se.reason === 'finished') {
        endFlag = true
      }
    }
  }
  onBridgeEvent('prepareUpload', prepareHandler)
  onBridgeEvent('sessionEnd', endHandler)

  // 计算 SHA-256（服务器 verifyChecksums 开启时上传需携带）
  let hash: string = await nativeHashFileStream(sendPath, undefined)
  let files: Array<NativeFileToSend> = [{
    fileId: fileId,
    filePath: sendPath,
    fileName: fileName,
    fileType: 'text/plain',
    size: content.length,
    preview: undefined,
    sha256: hash
  }]
  let result: NativeSendResult = await nativeSendFiles(target, 'HandySendTest', files, 'loopback_transfer_1')

  // 轮询落盘（最多 10s）
  let recvPath: string = recvDir + fileName
  let saved: boolean = false
  let deadline: number = Date.now() + 10000
  while (Date.now() < deadline) {
    if (fileExists(recvPath)) {
      saved = true
      break
    }
    await sleep(200)
  }

  if (!result.success) {
    throw new Error('[E2E] send failed: ' + JSON.stringify(result.error) + ' [Rust 日志] ' + dumpRustLogs())
  }
  expect(result.success).assertTrue()
  if (!saved) {
    throw new Error('[E2E] 接收文件未落盘: ' + recvPath + ' [Rust 日志] ' + dumpRustLogs())
  }
  expect(saved).assertTrue()
  if (saved) {
    expect(readFileContent(recvPath) === content).assertTrue()
  }
  // Rust 提交后应移除空的本地协议临时区
  expect(fs.accessSync(recvDir + TEMP_DIR_NAME)).assertFalse()
  // 会话以 finished 结束（异步推送，轮询最多 5s）
  let endDeadline: number = Date.now() + 5000
  while (!endFlag && Date.now() < endDeadline) {
    await sleep(100)
  }
  if (!endFlag) {
    throw new Error('[E2E] 会话未以 finished 结束 [Rust 日志] ' + dumpRustLogs())
  }
  expect(endFlag).assertTrue()

  offBridgeEvent('prepareUpload', prepareHandler)
  offBridgeEvent('sessionEnd', endHandler)
}

export default function LoopbackTransferTest() {
  describe('LoopbackTransferTest', () => {
    let suitePort: number = allocateTestPort()
    // 唯一文件名避免重复运行残留冲突
    const SEND_FILE_NAME: string = 'e2e_send_' + Date.now().toString() + '.txt'
    const SEND_CONTENT: string = 'HandySend-E2E-' + Date.now().toString() + '-0123456789abcdef'
    let prepareHandled: boolean = false
    let sessionEnded: boolean = false

    beforeAll(async (done: Function) => {
      // 初始化桥接层 logger（Rust 日志写入缓冲，供失败诊断 pollDebugLog 读取）
      nativeInit('HandySendTest', 'mobile')
      ensureDir(getRecvDir())
      await startServer({
        alias: 'HandySendTest',
        deviceModel: 'TestModel',
        deviceType: 'mobile',
        port: suitePort,
        saveDir: getRecvDir(),
        useHttps: false
      })
      done()
    })

    afterAll(async (done: Function) => {
      await stopServer()
      done()
    })

    it('loopback_transfer_end_to_end_content_matches', 0, async (done: Function) => {
      // 1. 写真实发送文件
      let sendPath: string = writeTestFileToSandbox(SEND_FILE_NAME, SEND_CONTENT)

      // 2. 订阅接收侧事件：prepareUpload → 自动接受；sessionEnd → 标记完成
      let prepareHandler = (e: NativeEvent): void => {
        if (e.type === 'prepareUpload') {
          prepareHandled = true
          acceptWithRecvTargets(e, getRecvDir())
        }
      }
      let endHandler = (e: NativeEvent): void => {
        if (e.type === 'sessionEnd') {
          let se = e as NativeSessionEndEvent
          if (se.reason === 'finished') {
            sessionEnded = true
          }
        }
      }
      onBridgeEvent('prepareUpload', prepareHandler)
      onBridgeEvent('sessionEnd', endHandler)

      // 3. 计算文件 SHA-256（服务器 verifyChecksums 开启时上传需携带）
      let hash: string = await nativeHashFileStream(sendPath, undefined)

      // 4. 发送真实文件到本机服务器
      let target: NativeTargetDevice = {
        ip: '127.0.0.1',
        port: suitePort,
        fingerprint: 'test_fp',
        protocol: 'http'
      }
      let files: Array<NativeFileToSend> = [{
        fileId: 'e2e_file_1',
        filePath: sendPath,
        fileName: SEND_FILE_NAME,
        fileType: 'text/plain',
        size: SEND_CONTENT.length,
        preview: undefined,
        sha256: hash
      }]
      let result: NativeSendResult = await nativeSendFiles(target, 'HandySendTest', files, 'loopback_transfer_2')

      // 4. 等待接收文件落盘（轮询，最多 10s）
      let recvPath: string = getRecvDir() + SEND_FILE_NAME
      let saved: boolean = false
      let deadline: number = Date.now() + 10000
      while (Date.now() < deadline) {
        if (fileExists(recvPath)) {
          saved = true
          break
        }
        await sleep(200)
      }

      // 5. 断言链路完整
      if (!result.success) {
        throw new Error('[E2E] send failed: ' + JSON.stringify(result.error) + ' [Rust 日志] ' + dumpRustLogs())
      }
      expect(result.success).assertTrue()
      if (!saved) {
        throw new Error('[E2E] 接收文件未落盘: ' + recvPath + ' [Rust 日志] ' + dumpRustLogs())
      }
      expect(saved).assertTrue()
      if (saved) {
        // 接收内容与发送内容逐字节一致
        let content: string = readFileContent(recvPath)
        expect(content === SEND_CONTENT).assertTrue()
      }
      // Rust 提交后应移除空的本地协议临时区
      expect(fs.accessSync(getRecvDir() + TEMP_DIR_NAME)).assertFalse()
      // 接收侧收到过 prepareUpload 决策事件
      expect(prepareHandled).assertTrue()
      // 等待 sessionEnd(finished) 事件（异步推送，轮询最多 5s）
      let endDeadline: number = Date.now() + 5000
      while (!sessionEnded && Date.now() < endDeadline) {
        await sleep(100)
      }
      // 会话以 finished 正常结束
      if (!sessionEnded) {
        throw new Error('[E2E] 会话未以 finished 结束 [Rust 日志] ' + dumpRustLogs())
      }
      expect(sessionEnded).assertTrue()

      offBridgeEvent('prepareUpload', prepareHandler)
      offBridgeEvent('sessionEnd', endHandler)
      done()
    })

    it('loopback_path_failure_keeps_other_files', 0, async (done: Function) => {
      // 路径模式：一个文件路径不可读不应拖垮整批；其余文件照常上传，
      // 结果以 partialFailure 收口并只报告失败文件。
      let fileName: string = 'e2e_path_ok_' + Date.now().toString() + '.txt'
      let content: string = 'PATH-OK-' + Date.now().toString()
      let sendPath: string = writeTestFileToSandbox(fileName, content)
      let missingPath: string = getTestCacheDir() + '/missing_' + Date.now().toString() + '.txt'
      let okId: string = 'e2e_path_ok'
      let missingId: string = 'e2e_path_missing'
      let prepareHandler = (e: NativeEvent): void => {
        if (e.type !== 'prepareUpload') {
          return
        }
        let pe = e as NativePrepareUploadEvent
        let ids: Array<string> = []
        for (let i = 0; i < pe.files.length; i++) {
          if (pe.files[i].fileId !== okId) {
            continue
          }
          let destPath: string = getRecvDir() + pe.files[i].fileName
          let finalDir: string = destPath.substring(0, destPath.lastIndexOf('/'))
          ensureDir(finalDir)
          let tempPath: string = tempPathForFinal(destPath, TEMP_SUBDIR_LOCAL_SEND)
          let tempDir: string = tempPath.substring(0, tempPath.lastIndexOf('/'))
          ensureDir(tempDir)
          let file = fs.openSync(tempPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE |
            fs.OpenMode.TRUNC)
          fs.closeSync(file)
          nativeRegisterRecvFileFd(pe.sessionId, pe.files[i].fileId, -1, destPath)
          ids.push(pe.files[i].fileId)
        }
        nativeRespondTransfer(pe.sessionId, true, ids)
      }
      onBridgeEvent('prepareUpload', prepareHandler)
      try {
        let hash: string = await nativeHashFileStream(sendPath, undefined)
        let target: NativeTargetDevice = {
          ip: '127.0.0.1',
          port: suitePort,
          fingerprint: 'test_fp',
          protocol: 'http'
        }
        let files: Array<NativeFileToSend> = [{
          fileId: okId,
          filePath: sendPath,
          fileName: fileName,
          fileType: 'text/plain',
          size: content.length,
          preview: undefined,
          sha256: hash
        }, {
          fileId: missingId,
          filePath: missingPath,
          fileName: 'missing.txt',
          fileType: 'text/plain',
          size: 5,
          preview: undefined,
          sha256: undefined
        }]
        let result: NativeSendResult = await nativeSendFiles(target, 'HandySendTest', files,
          'loopback_transfer_path_failure')
        expect(result.success).assertFalse()
        if (result.error !== undefined) {
          expect(result.error.kind).assertEqual('partialFailure')
        }
        expect(result.failedFiles.length).assertEqual(1)
        if (result.failedFiles.length === 1) {
          expect(result.failedFiles[0]).assertEqual(missingId)
        }
        let recvPath: string = getRecvDir() + fileName
        let saved: boolean = false
        let deadline: number = Date.now() + 10000
        while (Date.now() < deadline) {
          if (fileExists(recvPath)) {
            saved = true
            break
          }
          await sleep(200)
        }
        if (!saved) {
          throw new Error('[E2E] 正常文件未落盘: ' + recvPath + ' [Rust 日志] ' + dumpRustLogs())
        }
        expect(readFileContent(recvPath) === content).assertTrue()
      } finally {
        offBridgeEvent('prepareUpload', prepareHandler)
      }
      done()
    })

    it('loopback_path_failure_falls_back_to_fd', 0, async (done: Function) => {
      // 端到端回退：路径模式发送前源路径已失效，但暂存句柄仍有效。
      // 首次会话按路径失败 → 取消 → 用句柄副本重发，内容仍应完整送达。
      let fileName: string = 'e2e_fallback_' + Date.now().toString() + '.txt'
      let content: string = 'FALLBACK-' + Date.now().toString() + '-0123456789abcdef'
      let sendPath: string = writeTestFileToSandbox(fileName, content)
      let hash: string = await nativeHashFileStream(sendPath, undefined)
      let source: fs.File = await fs.open(sendPath, fs.OpenMode.READ_ONLY)
      // 删除路径后仅句柄可读：模拟原生路径模式失败、句柄仍可用的场景
      fs.unlinkSync(sendPath)
      let prepareHandler = (e: NativeEvent): void => {
        if (e.type === 'prepareUpload') {
          acceptWithRecvTargets(e, getRecvDir())
        }
      }
      onBridgeEvent('prepareUpload', prepareHandler)
      // 测试服务器固定 HTTP；临时关闭本地加密，避免协议协商按默认加密拒绝
      let originalHttps: boolean = getHttpsEnabled()
      setHttpsEnabled(false)
      try {
        let device: DiscoveredDevice = {
          alias: 'HandySendTest',
          ip: '127.0.0.1',
          port: suitePort,
          fingerprint: 'test_fp',
          version: '2.2',
          deviceModel: 'TestModel',
          deviceType: 'desktop',
          protocol: 'http',
          lastSeen: Date.now(),
          channels: []
        }
        let files: Array<SendFileItem> = [{
          fileId: 'e2e_fallback_1',
          filePath: sendPath,
          fileName: fileName,
          fileType: 'text/plain',
          size: content.length,
          hash: hash,
          sourceFd: source.fd,
          pathSource: true
        }]
        let result = await sendToDevice(device, files, 'loopback_fallback_key', '')
        if (!result.success) {
          throw new Error('[E2E] 句柄回退失败: ' + JSON.stringify(result.error) +
            ' [Rust 日志] ' + dumpRustLogs())
        }
        expect(result.success).assertTrue()
        let recvPath: string = getRecvDir() + fileName
        let saved: boolean = false
        let deadline: number = Date.now() + 10000
        while (Date.now() < deadline) {
          if (fileExists(recvPath)) {
            saved = true
            break
          }
          await sleep(200)
        }
        if (!saved) {
          throw new Error('[E2E] 回退文件未落盘: ' + recvPath + ' [Rust 日志] ' + dumpRustLogs())
        }
        expect(readFileContent(recvPath) === content).assertTrue()
      } finally {
        offBridgeEvent('prepareUpload', prepareHandler)
        setHttpsEnabled(originalHttps)
        try {
          fs.closeSync(source)
        } catch (_e) {
        }
      }
      done()
    })

    it('loopback_transfer_fd_content_matches', 0, async (done: Function) => {
      // 回归：fd 读取走 Rust pread，从文件头开始，不依赖共享偏移。
      // 先把句柄偏移推到末尾：旧实现（顺序 read）会从末尾读到 0 字节。
      let fileName: string = 'e2e_fd_' + Date.now().toString() + '.txt'
      let content: string = 'FD-PREAD-' + Date.now().toString() + '-0123456789abcdef'
      let sendPath: string = writeTestFileToSandbox(fileName, content)
      let source: fs.File = await fs.open(sendPath, fs.OpenMode.READ_ONLY)
      let probe: ArrayBuffer = new ArrayBuffer(content.length)
      fs.readSync(source.fd, probe)

      let prepareHandler = (e: NativeEvent): void => {
        if (e.type === 'prepareUpload') {
          acceptWithRecvTargets(e, getRecvDir())
        }
      }
      onBridgeEvent('prepareUpload', prepareHandler)
      try {
        let hash: string = await nativeHashFileStream(sendPath, undefined)
        let target: NativeTargetDevice = {
          ip: '127.0.0.1',
          port: suitePort,
          fingerprint: 'test_fp',
          protocol: 'http'
        }
        // 句柄所有权随 nativeSendFiles 移交 Rust，用例内不再关闭
        let files: Array<NativeFileToSend> = [{
          fileId: 'e2e_fd_1',
          filePath: sendPath,
          fileName: fileName,
          fileType: 'text/plain',
          size: content.length,
          fd: source.fd,
          preview: undefined,
          sha256: hash
        }]
        let result: NativeSendResult = await nativeSendFiles(target, 'HandySendTest', files, 'loopback_transfer_3')
        if (!result.success) {
          throw new Error('[E2E] fd send failed: ' + JSON.stringify(result.error) +
            ' [Rust 日志] ' + dumpRustLogs())
        }
        let recvPath: string = getRecvDir() + fileName
        let saved: boolean = false
        let deadline: number = Date.now() + 10000
        while (Date.now() < deadline) {
          if (fileExists(recvPath)) {
            saved = true
            break
          }
          await sleep(200)
        }
        if (!saved) {
          throw new Error('[E2E] fd 接收文件未落盘: ' + recvPath + ' [Rust 日志] ' + dumpRustLogs())
        }
        expect(readFileContent(recvPath) === content).assertTrue()
      } finally {
        offBridgeEvent('prepareUpload', prepareHandler)
      }
      done()
    })

    it('loopback_nested_relative_path_preserves_directories', 0, async (done: Function) => {
      let sendName: string = 'nested_src_' + Date.now().toString() + '.txt'
      let recvName: string = 'outer/inner/nested_' + Date.now().toString() + '.txt'
      let content: string = 'NESTED-' + Date.now().toString() + '-0123456789abcdef'
      let sendPath: string = writeTestFileToSandbox(sendName, content)

      let prepareHandler = (e: NativeEvent): void => {
        if (e.type === 'prepareUpload') {
          acceptWithRecvTargets(e, getRecvDir())
        }
      }
      onBridgeEvent('prepareUpload', prepareHandler)
      try {
        let hash: string = await nativeHashFileStream(sendPath, undefined)
        let target: NativeTargetDevice = {
          ip: '127.0.0.1',
          port: suitePort,
          fingerprint: 'test_fp',
          protocol: 'http'
        }
        let files: Array<NativeFileToSend> = [{
          fileId: 'e2e_nested_1',
          filePath: sendPath,
          fileName: recvName,
          fileType: 'text/plain',
          size: content.length,
          preview: undefined,
          sha256: hash
        }]
        let result: NativeSendResult = await nativeSendFiles(target, 'HandySendTest', files,
          'loopback_transfer_nested')
        if (!result.success) {
          throw new Error('[E2E] nested send failed: ' + JSON.stringify(result.error) +
            ' [Rust 日志] ' + dumpRustLogs())
        }
        let recvPath: string = getRecvDir() + recvName
        let saved: boolean = false
        let deadline: number = Date.now() + 10000
        while (Date.now() < deadline) {
          if (fileExists(recvPath)) {
            saved = true
            break
          }
          await sleep(200)
        }
        if (!saved) {
          throw new Error('[E2E] nested 接收文件未落盘: ' + recvPath + ' [Rust 日志] ' + dumpRustLogs())
        }
        expect(readFileContent(recvPath) === content).assertTrue()
        // 嵌套最终目录下的临时区清空后应被移除
        expect(fs.accessSync(getRecvDir() + 'outer/inner/' + TEMP_DIR_NAME)).assertFalse()
      } finally {
        offBridgeEvent('prepareUpload', prepareHandler)
      }
      done()
    })
  })

  // ── HTTPS 开关开启：TLS + 指纹校验下的完整回环传输 ──

  describe('LoopbackTransferTest_Https', () => {
    let suitePort: number = allocateTestPort()
    let serverFp: string = ''

    beforeAll(async (done: Function) => {
      ensureDir(getRecvDirHttps())
      let handle = await startServer({
        alias: 'HandySendTest',
        deviceModel: 'TestModel',
        deviceType: 'mobile',
        port: suitePort,
        saveDir: getRecvDirHttps(),
        useHttps: true
      })
      serverFp = handle.fingerprint
      done()
    })

    afterAll(async (done: Function) => {
      await stopServer()
      done()
    })

    it('https_loopback_transfer_content_matches', 0, async (done: Function) => {
      let fileName: string = 'https_send_' + Date.now().toString() + '.txt'
      let content: string = 'HTTPS-E2E-' + Date.now().toString() + '-secret'
      // HTTPS 目标：携带服务器指纹供证书校验
      let target: NativeTargetDevice = {
        ip: '127.0.0.1',
        port: suitePort,
        fingerprint: serverFp,
        protocol: 'https'
      }
      await sendLoopbackAndVerify(target, getRecvDirHttps(), fileName, content, 'https_1')
      done()
    })
  })

  // ── PIN 保护开启：无 pin 拒绝 / 正确 pin 成功 ──

  describe('LoopbackTransferTest_Pin', () => {
    let suitePort: number = allocateTestPort()

    beforeAll(async (done: Function) => {
      ensureDir(getRecvDirPin())
      await startServer({
        alias: 'HandySendTest',
        deviceModel: 'TestModel',
        deviceType: 'mobile',
        port: suitePort,
        saveDir: getRecvDirPin(),
        useHttps: false,
        pin: '1234'
      })
      done()
    })

    afterAll(async (done: Function) => {
      await stopServer()
      done()
    })

    it('pin_without_pin_rejected', 0, async (done: Function) => {
      // 不带 pin → prepare-upload 返回 401 → sendFiles 失败
      let sendPath: string = writeTestFileToSandbox('pin_no_' + Date.now().toString() + '.txt', 'no pin')
      let hash: string = await nativeHashFileStream(sendPath, undefined)
      let target: NativeTargetDevice = {
        ip: '127.0.0.1',
        port: suitePort,
        fingerprint: '',
        protocol: 'http'
      }
      let files: Array<NativeFileToSend> = [{
        fileId: 'pin_no_1',
        filePath: sendPath,
        fileName: 'pin_no.txt',
        fileType: 'text/plain',
        size: 6,
        preview: undefined,
        sha256: hash
      }]
      let result: NativeSendResult = await nativeSendFiles(target, 'HandySendTest', files, 'loopback_transfer_4')
      // 无 pin 应被拒绝（发送失败）
      expect(result.success).assertFalse()
      done()
    })

    it('pin_with_correct_pin_succeeds', 0, async (done: Function) => {
      let fileName: string = 'pin_ok_' + Date.now().toString() + '.txt'
      let content: string = 'PIN-OK-' + Date.now().toString()
      let target: NativeTargetDevice = {
        ip: '127.0.0.1',
        port: suitePort,
        fingerprint: '',
        protocol: 'http',
        pin: '1234'
      }
      await sendLoopbackAndVerify(target, getRecvDirPin(), fileName, content, 'pin_ok_1')
      done()
    })
  })
}
