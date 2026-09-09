import { describe, it, expect } from '@ohos/hypium'
import {
  BleEventHandlers,
  ScannedMtaDeviceView,
  GattClientStateView,
  VerifyLogEntry,
  formatTimeText
} from '../main/ets/model/mta/BleVerifyModels'

// MTA BLE 验证页纯数据类型与纯函数的本地单元测试（无系统 API / UIContext 依赖）。
export default function BleVerifyModelsTest() {
  describe('BleVerifyModelsTest', () => {
    // ── formatTimeText 时间格式化 ──

    it('time_pads_single_digit_fields', 0, () => {
      let date = new Date(2026, 0, 1, 9, 5, 3, 7)
      expect(formatTimeText(date)).assertEqual('09:05:03.007')
    })

    it('time_no_pad_for_two_digit_fields', 0, () => {
      let date = new Date(2026, 11, 31, 23, 59, 58, 123)
      expect(formatTimeText(date)).assertEqual('23:59:58.123')
    })

    // ── ScannedMtaDeviceView 默认值 ──

    it('scanned_device_defaults', 0, () => {
      let device = new ScannedMtaDeviceView()
      expect(device.deviceId).assertEqual('')
      expect(device.deviceName).assertEqual('')
      expect(device.senderIdHex).assertEqual('')
      expect(device.brandName).assertEqual('')
      expect(device.is5Ghz).assertFalse()
      expect(device.rssi).assertEqual(0)
      expect(device.foundTimeText).assertEqual('')
    })

    // ── GattClientStateView 默认值 ──

    it('gatt_client_state_defaults', 0, () => {
      let state = new GattClientStateView()
      expect(state.targetDeviceId).assertEqual('')
      expect(state.connectionStateText).assertEqual('未连接')
      expect(state.deviceInfoText).assertEqual('')
    })

    // ── VerifyLogEntry 默认值 ──

    it('log_entry_default_level_is_info', 0, () => {
      let entry = new VerifyLogEntry()
      expect(entry.timeText).assertEqual('')
      expect(entry.source).assertEqual('')
      expect(entry.level).assertEqual('info')
      expect(entry.content).assertEqual('')
    })

    // ── BleEventHandlers 默认回调可安全调用（no-op） ──

    it('event_handlers_default_noop', 0, () => {
      let handlers = new BleEventHandlers()
      handlers.onBluetoothStateChange('开启')
      handlers.onAdvertiseStateChange(true, 'detail')
      handlers.onGattConnectionChange('id', '已连接')
      handlers.onGattReadRequest('id', 0)
      handlers.onGattWriteProgress('id', 0, 10, true)
      handlers.onGattWriteComplete('id', '{}')
      handlers.onDeviceFound(new ScannedMtaDeviceView())
      handlers.onGattClientConnectionChange('已连接')
      handlers.onGattClientDeviceInfo('{}')
      handlers.onError('source', 'message')
      expect(true).assertTrue()
    })
  })
}
