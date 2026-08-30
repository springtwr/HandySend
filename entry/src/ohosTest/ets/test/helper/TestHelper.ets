// TestHelper：Instrument Test 共享辅助工具
// 封装服务器启停、等待条件、测试数据构造等通用逻辑
// 各测试套件的 beforeAll/afterAll 应调用此模块以确保一致性

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
const TEST_SAVE_DIR: string = '/data/app/el2/100/base/com.springtwr.handysend/cache/handysend_test/'

// ── 服务器启停 ──

// 当前测试服务器句柄（模块级，供 beforeAll/afterAll 复用）
let currentHandle: NativeServerHandle | undefined = undefined

// 当前服务器实际绑定端口（port=0 时由 OS 分配）
let currentPort: number = 0

// 端口分配计数器：每个 describe 分配不同端口，避免 TIME_WAIT 冲突
// 基础端口 53317，每个套件递增 1
let nextPortOffset: number = 0

/**
 * 分配一个测试专用端口
 * 每次调用返回不同端口（53317, 53318, 53319, ...）
 * 避免测试套件间 TIME_WAIT 冲突
 */
export function allocateTestPort(): number {
  let port: number = 53317 + nextPortOffset
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
      filePath: '/data/storage/el2/base/haps/entry/files/test_file_' + i + '.txt',
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
export async function waitUntil(predicate: () => boolean, timeoutMs: number = DEFAULT_WAIT_TIMEOUT_MS): Promise<boolean> {
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
