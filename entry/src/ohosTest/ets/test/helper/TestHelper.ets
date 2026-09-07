// TestHelper：Instrument Test 共享辅助工具
// 封装服务器启停、等待条件、测试数据构造等通用逻辑
// 各测试套件的 beforeAll/afterAll 应调用此模块以确保一致性

import { fileIo as fs } from '@kit.CoreFileKit'
import { getTestAppContext } from './TestContext'
import {
  nativeCreateServer,
  nativeStopServer,
  nativeGetServerStatus,
  nativeDiscoverySetAnswerAnnouncements,
  nativeDiscoveryStop
} from '../../../../main/ets/service/NativeBridge'
import {
  NativeServerConfig,
  NativeServerHandle,
  NativeServerStatus,
  NativeFileToSend,
  NativeDiscoveryConfig,
  NativeTargetDevice,
  NativeCancelTarget
} from '../../../../main/ets/model/NativeTypes'

// ── 默认测试配置 ──

const TEST_ALIAS: string = 'HandySendTest'
const TEST_DEVICE_MODEL: string = 'TestModel'
const TEST_DEVICE_TYPE: string = 'mobile'
const DEFAULT_WAIT_TIMEOUT_MS: number = 5000
const POLL_INTERVAL_MS: number = 100

// 测试用可写 saveDir：App 沙箱 cache 子目录
// Rust reset_security_context 需要写盘保存 TLS 身份，
// 使用 App 沙箱 cache 目录确保写盘成功
export const TEST_SAVE_DIR: string = '/data/app/el2/100/base/com.springtwr.handysend/cache/handysend_test/'

// ── 服务器启停 ──

// 当前测试服务器句柄（模块级，供 beforeAll/afterAll 复用）
let currentHandle: NativeServerHandle | undefined = undefined

// 当前服务器实际绑定端口（port=0 时由 OS 分配）
let currentPort: number = 0

// 端口分配计数器：每个 describe 分配不同端口，避免套件间 TIME_WAIT 冲突
// 起始端口每轮随机化（20000-29999）：固定起点在连续全量跑时，
// 末位套件的端口会撞上上一轮 TIME_WAIT（60s）未释放。
// 必须避开临时端口范围 32768-60999：落入该范围的端口可能被本进程/其他
// 进程的 TCP 客户端选作源端口，连接关闭后留下 TIME_WAIT，阻塞无
// SO_REUSEADDR 的同端口 bind（服务器库未设置该选项）；61000+ 实测有
// 系统服务监听，1024-32767 实测无占用。
let nextPortOffset: number = 0
let basePort: number = 20000 + Math.floor(Math.random() * 10000)

/**
 * 分配一个测试专用端口
 * 每次调用返回不同端口（basePort, basePort+1, ...）
 * 进程内递增避免套件间冲突；起始端口随运行轮次随机变化，
 * 避免跨测试轮次复用同一端口导致 TIME_WAIT 占用。
 */
export function allocateTestPort(): number {
  let port: number = basePort + nextPortOffset
  nextPortOffset++
  return port
}

/**
 * 获取当前服务器实际端口
 */
export function getCurrentPort(): number {
  return currentPort
}

const SERVER_START_MAX_RETRIES: number = 4
const SERVER_START_RETRY_DELAY_MS: number = 500

/**
 * 启动测试服务器（使用默认测试配置或自定义配置）
 * 内置重试机制：端口 TIME_WAIT 期间绑定失败时自动等待重试
 * @param config 自定义配置，不传则使用默认测试配置（端口由 allocateTestPort 分配）
 * @returns 服务器句柄（fingerprint + port）
 */
export async function startServer(config?: NativeServerConfig): Promise<NativeServerHandle> {
  // 若服务器已在运行，先停止
  try {
    let status: NativeServerStatus = nativeGetServerStatus()
    if (status.running) {
      await stopServer()
      // 等待端口释放
      await sleep(SERVER_START_RETRY_DELAY_MS)
    }
  } catch (_e) {
    // 查询失败——继续尝试创建
  }

  let serverConfig: NativeServerConfig = config !== undefined ? config : createTestServerConfig()
  let lastError: Error = Error('Failed to start server after retries')
  for (let i = 0; i < SERVER_START_MAX_RETRIES; i++) {
    try {
      let handle: NativeServerHandle = await nativeCreateServer(serverConfig)
      currentHandle = handle
      currentPort = handle.port
      return handle
    } catch (e) {
      // e 是 catch 绑定变量，ArkTS 限制不允许 as 断言
      // 用 String() 安全提取信息构造 Error
      lastError = Error('Server start attempt ' + (i + 1) + ' failed: ' + String(e))
      let errStr: string = String(e)
      // 套件间服务器状态残留（前序套件未清理干净）——强制停止后重试，
      // 与开头"running 则先停"互补，覆盖 getServerStatus 与 Rust 实际状态
      // 不一致的竞态场景。
      if (errStr.indexOf('服务器已运行') >= 0 || errStr.indexOf('already running') >= 0) {
        try {
          await nativeStopServer()
        } catch (_e2) {
          // 停止失败——继续等待重试
        }
        await sleep(SERVER_START_RETRY_DELAY_MS * 2)
        continue
      }
      // 端口占用（TIME_WAIT 残留）——等待更久后重试
      if (errStr.indexOf('Address in use') >= 0 || errStr.indexOf('os error 98') >= 0) {
        await sleep(SERVER_START_RETRY_DELAY_MS * 4)
        continue
      }
      // 端口冲突或暂时不可用——等待后重试
      await sleep(SERVER_START_RETRY_DELAY_MS)
    }
  }
  throw lastError
}

/**
 * 停止测试服务器
 */
export async function stopServer(): Promise<void> {
  try {
    nativeDiscoverySetAnswerAnnouncements(false)
    nativeDiscoveryStop()
  } catch (_e) {
    // 停止发现失败——忽略
  }
  try {
    await nativeStopServer()
  } catch (_e) {
    // 停止服务器失败——忽略
  }
  currentHandle = undefined
}

/**
 * 获取当前服务器句柄
 */
export function getCurrentHandle(): NativeServerHandle | undefined {
  return currentHandle
}

// ── 测试数据构造 ──

/**
 * 构造默认测试用 NativeServerConfig
 * @param saveDir 接收文件保存目录，不传则使用测试专用可写目录
 * @param port 服务器端口，不传则由 allocateTestPort() 分配
 */
export function createTestServerConfig(saveDir?: string, port?: number): NativeServerConfig {
  let config: NativeServerConfig = {
    alias: TEST_ALIAS,
    deviceModel: TEST_DEVICE_MODEL,
    deviceType: TEST_DEVICE_TYPE,
    port: port !== undefined ? port : allocateTestPort(),
    saveDir: saveDir !== undefined ? saveDir : TEST_SAVE_DIR,
    useHttps: false
  }
  return config
}

/**
 * 构造测试用 NativeFileToSend 列表
 * @param count 文件数量，默认 1
 */
export function createTestFileToSend(count: number = 1): Array<NativeFileToSend> {
  let files: Array<NativeFileToSend> = []
  for (let i = 0; i < count; i++) {
    let file: NativeFileToSend = {
      fileId: 'test_file_' + i,
      filePath: '/data/storage/el2/base/haps/entry/cache/test_file_' + i + '.txt',
      fileName: 'test_file_' + i + '.txt',
      fileType: 'text/plain',
      size: 100 * (i + 1),
      preview: undefined,
      sha256: undefined
    }
    files.push(file)
  }
  return files
}

/**
 * 构造测试用 NativeTargetDevice
 * @param ip 目标 IP
 * @param port 目标端口，不传则使用当前服务器端口
 * @param fingerprint 目标指纹
 */
export function createTestTargetDevice(ip: string, port?: number,
  fingerprint: string = 'test_fp'): NativeTargetDevice {
  let target: NativeTargetDevice = {
    ip: ip,
    port: port !== undefined ? port : getCurrentPort(),
    fingerprint: fingerprint,
    protocol: 'http'
  }
  return target
}

/**
 * 构造测试用 NativeCancelTarget
 */
export function createTestCancelTarget(ip: string, port?: number,
  fingerprint: string = 'test_fp'): NativeCancelTarget {
  let target: NativeCancelTarget = {
    ip: ip,
    port: port !== undefined ? port : getCurrentPort(),
    fingerprint: fingerprint,
    protocol: 'http'
  }
  return target
}

/**
 * 构造测试用 NativeDiscoveryConfig
 * @param port 发现端口，不传则使用当前服务器端口（getCurrentPort）
 */
export function createTestDiscoveryConfig(port?: number): NativeDiscoveryConfig {
  let config: NativeDiscoveryConfig = {
    port: port !== undefined ? port : getCurrentPort(),
    protocol: 'http',
    multicastGroup: '224.0.0.167',
    discoveryTimeoutMs: 1000,
    download: true
  }
  return config
}

// ── 等待条件 ──

/**
 * 轮询等待条件满足
 * @param predicate 条件判断函数，返回 true 表示满足
 * @param timeoutMs 超时毫秒数，默认 5000
 * @returns 是否在超时内满足条件
 */
export async function waitUntil(predicate: () => boolean,
  timeoutMs: number = DEFAULT_WAIT_TIMEOUT_MS): Promise<boolean> {
  let start: number = Date.now()
  while (Date.now() - start < timeoutMs) {
    if (predicate()) {
      return true
    }
    await sleep(POLL_INTERVAL_MS)
  }
  return predicate()
}

/**
 * 等待指定毫秒数
 */
export function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: (value: void) => void) => {
    setTimeout(() => {
      resolve()
    }, ms)
  })
}

// ── 测试文件辅助（真实文件读写，供回环传输链路验证）──

/**
 * 测试进程的 cache 沙箱目录（测试临时文件统一存放于此，可写）。
 * context 未注入时返回空串。
 */
export function getTestCacheDir(): string {
  let ctx = getTestAppContext()
  if (ctx === undefined) {
    return ''
  }
  return ctx.cacheDir
}

/**
 * 在测试 cache 沙箱写入一个真实文本文件（测试临时文件），返回其完整路径。
 */
export function writeTestFileToSandbox(fileName: string, content: string): string {
  let dir: string = getTestCacheDir()
  let path: string = dir + '/' + fileName
  let file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
  fs.writeSync(file.fd, content)
  fs.closeSync(file)
  return path
}

/**
 * 递归创建目录（接收保存目录等，幂等）。
 */
export function ensureDir(dir: string): void {
  if (!fs.accessSync(dir)) {
    fs.mkdirSync(dir, true)
  }
}

/**
 * 读取文本文件内容。
 */
export function readFileContent(filePath: string): string {
  return fs.readTextSync(filePath)
}

/**
 * 文件是否存在。
 */
export function fileExists(filePath: string): boolean {
  return fs.accessSync(filePath)
}

// ── 断言辅助 ──

/**
 * 判断服务器是否正在运行
 */
export function isServerRunning(): boolean {
  try {
    let status: NativeServerStatus = nativeGetServerStatus()
    return status.running
  } catch (_e) {
    return false
  }
}
