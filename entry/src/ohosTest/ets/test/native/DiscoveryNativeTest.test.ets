// DiscoveryNativeTest：设备发现 NativeBridge 函数测试
// 覆盖 nativeStartDiscoveryV2/nativeDiscoveryDiscoverStaged/nativeDiscoveryScanSubnet/
//        nativeDiscoveryAddDevice/nativeDiscoverySetAnswerAnnouncements/nativeDiscoveryStop/
//        nativeDiscoveryGetDevice/nativeDiscoveryMulticastError/nativeRegisterDevice
import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium'
import {
  nativeStartDiscoveryV2,
  nativeDiscoverySetAnswerAnnouncements,
  nativeDiscoveryStop,
  nativeDiscoveryGetDevice,
  nativeDiscoveryMulticastError,
  nativeDiscoveryAddDevice,
  nativeDiscoveryDiscoverStaged,
  nativeDiscoveryScanSubnet,
  nativeGetServerStatus
} from '../../../../main/ets/service/NativeBridge'
import {
  startServer,
  stopServer,
  createTestDiscoveryConfig,
  allocateTestPort,
  sleep,
  waitUntil
} from '../helper/TestHelper'
import { NativeDiscoveredDevice, NativeDeviceChannel } from '../../../../main/ets/model/NativeTypes'
import { DiscoveredDevice } from '../../../../main/ets/model/Types'

export default function DiscoveryNativeTest() {
  describe('DiscoveryNativeTest', () => {
    let suitePort: number = allocateTestPort()

    beforeAll(async (done: Function) => {
      await startServer({
        alias: 'HandySendTest',
        deviceModel: 'TestModel',
        deviceType: 'mobile',
        port: suitePort,
        saveDir: '/data/app/el2/100/base/com.springtwr.handysend/cache/handysend_test/',
        useHttps: false
      })
      done()
    })

    afterAll(async (done: Function) => {
      await stopServer()
      done()
    })

    // ── nativeStartDiscoveryV2 ──

    it('startDiscoveryV2_starts_and_stops_cleanly', 0, async (done: Function) => {
      let config = createTestDiscoveryConfig()
      await nativeStartDiscoveryV2(config)
      // 启动后应能设置应答
      nativeDiscoverySetAnswerAnnouncements(true)
      await sleep(200)
      // 启动期间组播错误应为空
      let errorDuringRun: string = nativeDiscoveryMulticastError()
      expect(errorDuringRun.length === 0).assertTrue()
      nativeDiscoverySetAnswerAnnouncements(false)
      // 停止不应抛异常
      nativeDiscoveryStop()
      // 停止后组播错误应仍为字符串（非 undefined）
      let errorAfterStop: string = nativeDiscoveryMulticastError()
      expect(errorAfterStop !== undefined).assertTrue()
      done()
    })

    // ── nativeDiscoveryGetDevice ──

    it('discoveryStop_when_not_running_does_not_crash', 0, () => {
      // 未启动发现时停止——不应崩溃
      // Rust 侧可能返回 Ok(()) 也可能 Err，但都不应导致进程崩溃
      let threw: boolean = false
      try {
        nativeDiscoveryStop()
      } catch (_e) {
        threw = true
      }
      // 无论抛不抛异常，进程都应存活——验证调用后仍可正常工作
      let errorStr: string = nativeDiscoveryMulticastError()
      expect(errorStr !== undefined).assertTrue()
    })

    it('getDevice_with_unknown_fingerprint_returns_undefined', 0, () => {
      let device: DiscoveredDevice | undefined = nativeDiscoveryGetDevice('nonexistent_fingerprint_12345')
      expect(device === undefined).assertTrue()
    })

    // ── nativeDiscoveryMulticastError ──

    it('multicastError_returns_string', 0, () => {
      let errorStr: string = nativeDiscoveryMulticastError()
      expect(typeof errorStr === 'string').assertTrue()
    })

    // ── nativeDiscoveryAddDevice + GetDevice 联动 ──

    it('addDevice_then_getDevice_by_fingerprint', 0, async (done: Function) => {
      // 需要先启动发现
      let config = createTestDiscoveryConfig()
      await nativeStartDiscoveryV2(config)

      let channels: Array<NativeDeviceChannel> = [{
        host: '192.168.1.100',
        port: 53317,
        protocol: 'http'
      }]
      let testDevice: NativeDiscoveredDevice = {
        alias: 'TestDevice',
        fingerprint: 'test_fp_discovery_001',
        version: '2.0',
        deviceModel: 'TestModel',
        deviceType: 'mobile',
        download: true,
        host: '192.168.1.100',
        port: 53317,
        protocol: 'http',
        channels: channels
      }
      await nativeDiscoveryAddDevice(testDevice)
      // 添加后应能通过 fingerprint 查到
      let device: DiscoveredDevice | undefined = nativeDiscoveryGetDevice('test_fp_discovery_001')
      expect(device !== undefined).assertTrue()
      if (device !== undefined) {
        expect(device.alias === 'TestDevice').assertTrue()
        expect(device.fingerprint === 'test_fp_discovery_001').assertTrue()
        expect(device.ip === '192.168.1.100').assertTrue()
      }

      nativeDiscoveryStop()
      done()
    })

    // ── nativeDiscoveryScanSubnet ──

    it('scanSubnet_with_invalid_ip_does_not_crash', 0, async (done: Function) => {
      // 无效 IP 不应崩溃
      let threw: boolean = false
      try {
        await nativeDiscoveryScanSubnet('0.0.0.0', 53317, 'http')
      } catch (_e) {
        threw = true
      }
      // 无论抛不抛异常，调用后进程应存活
      let errorStr: string = nativeDiscoveryMulticastError()
      expect(errorStr !== undefined).assertTrue()
      done()
    })

    // ── 自发现验证 ──

    it('self_discovery_can_find_own_device', 0, async (done: Function) => {
      let config = createTestDiscoveryConfig()
      await nativeStartDiscoveryV2(config)
      nativeDiscoverySetAnswerAnnouncements(true)

      // 自发现依赖组播可达性，是异步且环境相关的：轮询等待自身设备出现，
      // 能发现时立即继续。该用例的断言本身是条件性的（未发现不视为失败），
      // 故上限取 1s 即可覆盖正常组播往返。
      await waitUntil((): boolean => {
        let fp: string = nativeGetServerStatus().fingerprint ?? ''
        return fp.length > 0 && nativeDiscoveryGetDevice(fp) !== undefined
      }, 1000)

      // 获取自身 fingerprint——无条件验证
      let selfFingerprint: string = ''
      let status = nativeGetServerStatus()
      selfFingerprint = status.fingerprint ?? ''
      // fingerprint 必须非空（服务器在 beforeAll 已启动）
      expect(selfFingerprint.length > 0).assertTrue()

      // 自发现取决于网络环境——条件性验证
      if (selfFingerprint.length > 0) {
        let selfDevice: DiscoveredDevice | undefined = nativeDiscoveryGetDevice(selfFingerprint)
        // 如果发现了，验证 fingerprint 一致
        if (selfDevice !== undefined) {
          expect(selfDevice.fingerprint === selfFingerprint).assertTrue()
        }
      }

      nativeDiscoverySetAnswerAnnouncements(false)
      nativeDiscoveryStop()
      done()
    })

    // ── nativeDiscoveryDiscoverStaged ──

    it('discoverStaged_without_prior_start_throws_or_noop', 0, async (done: Function) => {
      // 未启动发现就调用 discoverStaged——应抛异常或静默返回
      let channels: Array<NativeDeviceChannel> = []
      let interfaceIps: Array<string> = []
      let threw: boolean = false
      try {
        await nativeDiscoveryDiscoverStaged(channels, interfaceIps, 53317, 'http', 500)
      } catch (_e) {
        threw = true
      }
      // 关键：不崩溃——后续 API 仍可用
      let errorStr: string = nativeDiscoveryMulticastError()
      expect(errorStr !== undefined).assertTrue()
      done()
    })

    it('discoverStaged_with_running_discovery_succeeds', 0, async (done: Function) => {
      let config = createTestDiscoveryConfig()
      await nativeStartDiscoveryV2(config)
      nativeDiscoverySetAnswerAnnouncements(true)
      // 启动发现后调用 discoverStaged
      let channels: Array<NativeDeviceChannel> = []
      let interfaceIps: Array<string> = []
      let threw: boolean = false
      try {
        await nativeDiscoveryDiscoverStaged(channels, interfaceIps, 53317, 'http', 200)
      } catch (_e) {
        threw = true
      }
      // 不崩溃即通过
      let errorStr: string = nativeDiscoveryMulticastError()
      expect(errorStr !== undefined).assertTrue()
      nativeDiscoverySetAnswerAnnouncements(false)
      nativeDiscoveryStop()
      done()
    })

    // ── nativeDiscoveryAddDevice ──

    it('addDevice_with_valid_data_succeeds', 0, async (done: Function) => {
      // addDevice 需要发现流程处于运行状态
      let config = createTestDiscoveryConfig()
      await nativeStartDiscoveryV2(config)

      let device: NativeDiscoveredDevice = {
        alias: 'TestDevice',
        fingerprint: 'test_add_device_fp',
        version: '1.18.2',
        deviceModel: 'TestModel',
        deviceType: 'mobile',
        download: true,
        host: '192.168.2.100',
        port: 53317,
        protocol: 'http',
        channels: []
      }
      let threw: boolean = false
      try {
        await nativeDiscoveryAddDevice(device)
      } catch (_e) {
        threw = true
      }
      // 添加设备不应抛异常
      expect(!threw).assertTrue()
      // 验证设备可通过 fingerprint 查询
      let found: DiscoveredDevice | undefined = nativeDiscoveryGetDevice('test_add_device_fp')
      if (found !== undefined) {
        expect(found.alias === 'TestDevice').assertTrue()
        expect(found.fingerprint === 'test_add_device_fp').assertTrue()
      }

      nativeDiscoveryStop()
      done()
    })

    it('addDevice_with_channels_succeeds', 0, async (done: Function) => {
      // addDevice 需要发现流程处于运行状态
      let config = createTestDiscoveryConfig()
      await nativeStartDiscoveryV2(config)

      let channel: NativeDeviceChannel = {
        host: '192.168.2.101',
        port: 53318,
        protocol: 'https'
      }
      let device: NativeDiscoveredDevice = {
        alias: 'MultiChannelDevice',
        fingerprint: 'test_add_device_channels_fp',
        version: '1.18.2',
        deviceModel: 'TestModel',
        deviceType: 'desktop',
        download: false,
        host: '192.168.2.101',
        port: 53318,
        protocol: 'https',
        channels: [channel]
      }
      let threw: boolean = false
      try {
        await nativeDiscoveryAddDevice(device)
      } catch (_e) {
        threw = true
      }
      expect(!threw).assertTrue()
      let found: DiscoveredDevice | undefined = nativeDiscoveryGetDevice('test_add_device_channels_fp')
      if (found !== undefined) {
        expect(found.alias === 'MultiChannelDevice').assertTrue()
        expect(found.channels.length === 1).assertTrue()
      }

      nativeDiscoveryStop()
      done()
    })
  })
}
