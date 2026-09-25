import { describe, it, expect } from '@ohos/hypium'
import {
  buildMtaSendRequest,
  combineTextContents,
  isMtaDevice,
  mtaBrandBadgeText,
  mtaDeviceFromParams,
  mtaDeviceToDiscoveredDevice,
  mtaSendStageLabel
} from '../../../../main/ets/model/mta/MtaMainModels'
import {
  MtaDiscoveredDevice,
  MtaSenderStage,
  mtaBrandNameOf,
  mtaDeviceIdentityKey
} from '../../../../main/ets/model/mta/MtaSendModels'
import { parseSendRequestPayload } from '../../../../main/ets/model/mta/MtaProtocolModels'
import { DiscoveredDevice, TransferFileDescriptor } from '../../../../main/ets/model/Types'

// MTA 主流程纯函数测试：设备映射、页面参数构建、文本内容提取与阶段文案。
function sampleMtaDevice(): MtaDiscoveredDevice {
  let device = new MtaDiscoveredDevice()
  device.bleAddress = 'AA:BB:CC:DD:EE:FF'
  device.deviceName = 'CatShare-Phone'
  device.senderIdHex = '1a2b'
  device.brandName = 'Xiaomi'
  device.brandId = 30
  device.is5Ghz = true
  device.rssi = -42
  return device
}

export default function MtaMainFlowTest() {
  describe('MtaMainFlowTest', () => {
    // ── 设备映射 ──

    it('mta_device_to_discovered_maps_fields', 0, () => {
      let mapped: DiscoveredDevice = mtaDeviceToDiscoveredDevice(sampleMtaDevice(), 1700000000000)
      expect(mapped.alias).assertEqual('CatShare-Phone')
      expect(mapped.protocol).assertEqual('mta')
      expect(mapped.fingerprint).assertEqual('AA:BB:CC:DD:EE:FF')
      expect(mapped.mtaBleAddress).assertEqual('AA:BB:CC:DD:EE:FF')
      expect(mapped.mtaSenderIdHex).assertEqual('1a2b')
      expect(mapped.mtaBrandName).assertEqual('Xiaomi')
      expect(mapped.mtaBrandId).assertEqual(30)
      expect(mapped.mtaIs5Ghz).assertTrue()
      expect(mapped.mtaRssi).assertEqual(-42)
      expect(mapped.ip).assertEqual('')
      expect(mapped.port).assertEqual(0)
      expect(isMtaDevice(mapped)).assertTrue()
    })

    it('mta_device_alias_falls_back_to_ble_address', 0, () => {
      let device = sampleMtaDevice()
      device.deviceName = ''
      let mapped = mtaDeviceToDiscoveredDevice(device, 0)
      expect(mapped.alias).assertEqual('AA:BB:CC:DD:EE:FF')
    })

    it('local_send_device_is_not_mta', 0, () => {
      let local: DiscoveredDevice = {
        alias: 'pc',
        ip: '192.168.1.2',
        port: 53317,
        fingerprint: 'abcdef',
        version: '2.0',
        deviceModel: 'X',
        deviceType: 'desktop',
        protocol: 'https',
        lastSeen: 0,
        channels: []
      }
      expect(isMtaDevice(local)).assertFalse()
    })

    // ── 设备身份键 ──

    it('identity_key_prefers_sender_id_hex', 0, () => {
      let device = sampleMtaDevice()
      device.senderIdHex = ' 1A2B '
      device.bleAddress = 'AA:BB:CC:DD:EE:FF'
      expect(mtaDeviceIdentityKey(device)).assertEqual('1a2b')
    })

    it('identity_key_falls_back_to_ble_address', 0, () => {
      let device = sampleMtaDevice()
      device.senderIdHex = ''
      device.bleAddress = ' AA:BB:CC:DD:EE:FF '
      expect(mtaDeviceIdentityKey(device)).assertEqual('aa:bb:cc:dd:ee:ff')
    })

    it('identity_key_distinguishes_different_devices', 0, () => {
      let a = sampleMtaDevice()
      a.senderIdHex = '1111'
      a.bleAddress = 'AA:AA:AA:AA:AA:AA'
      let b = sampleMtaDevice()
      b.senderIdHex = '2222'
      b.bleAddress = 'AA:AA:AA:AA:AA:AA'
      expect(mtaDeviceIdentityKey(a) === mtaDeviceIdentityKey(b)).assertFalse()
    })

    // ── 品牌徽标 ──

    it('brand_badge_known_and_unknown', 0, () => {
      expect(mtaBrandBadgeText('Xiaomi')).assertEqual('Xiaomi')
      expect(mtaBrandBadgeText('未知')).assertEqual('Android')
      expect(mtaBrandBadgeText('未知(5)')).assertEqual('Android')
      expect(mtaBrandBadgeText('')).assertEqual('Android')
      expect(mtaBrandBadgeText(undefined)).assertEqual('Android')
    })

    it('brand_name_covers_registry', 0, () => {
      // 具体 ID 先于区间判定
      expect(mtaBrandNameOf(11)).assertEqual('Realme')
      expect(mtaBrandNameOf(32)).assertEqual('Black Shark')
      expect(mtaBrandNameOf(66)).assertEqual('RedMagic')
      expect(mtaBrandNameOf(114)).assertEqual('Easy Share')
      expect(mtaBrandNameOf(160)).assertEqual('ROG')
      // 区间品牌
      expect(mtaBrandNameOf(20)).assertEqual('vivo')
      expect(mtaBrandNameOf(60)).assertEqual('Nubia')
      expect(mtaBrandNameOf(70)).assertEqual('Samsung')
      expect(mtaBrandNameOf(80)).assertEqual('ZTE')
      expect(mtaBrandNameOf(100)).assertEqual('Lenovo')
      expect(mtaBrandNameOf(110)).assertEqual('Motorola')
      expect(mtaBrandNameOf(120)).assertEqual('NIO')
      expect(mtaBrandNameOf(130)).assertEqual('Pixel')
      expect(mtaBrandNameOf(140)).assertEqual('Honor')
      expect(mtaBrandNameOf(161)).assertEqual('ASUS')
      expect(mtaBrandNameOf(170)).assertEqual('Hisense')
      // 第三方与未知
      expect(mtaBrandNameOf(0xff)).assertEqual('第三方')
      expect(mtaBrandNameOf(199)).assertEqual('未知(199)')
    })

    // ── 发送请求构建 ──

    it('build_send_request_carries_target_and_files', 0, () => {
      let descriptor: TransferFileDescriptor = {
        fileId: '',
        fileName: 'a.jpg',
        size: 100,
        fileType: 'image/jpeg'
      }
      let params = buildMtaSendRequest(
        mtaDeviceToDiscoveredDevice(sampleMtaDevice(), 0), ['file://a.jpg'], [descriptor], false, '')
      expect(params.targetAlias).assertEqual('CatShare-Phone')
      expect(params.bleAddress).assertEqual('AA:BB:CC:DD:EE:FF')
      expect(params.brandId).assertEqual(30)
      expect(params.is5Ghz).assertTrue()
      expect(params.fileUris.length).assertEqual(1)
      expect(params.fileDescriptors[0].fileName).assertEqual('a.jpg')
      expect(params.isTextSend).assertFalse()
    })

    it('mta_device_from_params_roundtrip', 0, () => {
      let descriptor: TransferFileDescriptor = {
        fileId: '',
        fileName: 'a',
        size: 1,
        fileType: 'text/plain'
      }
      let params = buildMtaSendRequest(
        mtaDeviceToDiscoveredDevice(sampleMtaDevice(), 0), ['u'], [descriptor], false, '')
      let device = mtaDeviceFromParams(params)
      expect(device.bleAddress).assertEqual('AA:BB:CC:DD:EE:FF')
      expect(device.deviceName).assertEqual('CatShare-Phone')
      expect(device.senderIdHex).assertEqual('1a2b')
      expect(device.brandId).assertEqual(30)
      expect(device.is5Ghz).assertTrue()
    })

    // ── 文本内容提取 ──

    it('combine_text_contents_skips_empty', 0, () => {
      expect(combineTextContents(['a', '', 'b'])).assertEqual('a\nb')
      expect(combineTextContents(['', ''])).assertEqual('')
    })

    // ── 阶段文案 ──

    it('send_stage_labels', 0, () => {
      // 阶段文案以资源承载（随系统语言切换），此处校验返回的资源标识；
      // 先断言返回确为 Resource 对象，避免回归为字符串时用例零断言通过
      let transferring = mtaSendStageLabel(MtaSenderStage.TRANSFERRING)
      expect(typeof transferring === 'object').assertTrue()
      if (typeof transferring === 'object') {
        expect(transferring.id).assertEqual($r('app.string.mta_send_stage_transferring').id)
      }
      let completed = mtaSendStageLabel(MtaSenderStage.COMPLETED)
      expect(typeof completed === 'object').assertTrue()
      if (typeof completed === 'object') {
        expect(completed.id).assertEqual($r('app.string.mta_send_stage_completed').id)
      }
      let failed = mtaSendStageLabel(MtaSenderStage.FAILED)
      expect(typeof failed === 'object').assertTrue()
      if (typeof failed === 'object') {
        expect(failed.id).assertEqual($r('app.string.mta_send_stage_failed').id)
      }
      let cancelled = mtaSendStageLabel(MtaSenderStage.CANCELLED)
      expect(typeof cancelled === 'object').assertTrue()
      if (typeof cancelled === 'object') {
        expect(cancelled.id).assertEqual($r('app.string.mta_send_stage_cancelled').id)
      }
    })

    // ── 文本链路 ──

    it('build_send_request_text_mode', 0, () => {
      let params = buildMtaSendRequest(mtaDeviceToDiscoveredDevice(sampleMtaDevice(), 0), [], [], true, 'hello')
      expect(params.isTextSend).assertTrue()
      expect(params.textContent).assertEqual('hello')
      expect(params.fileUris.length).assertEqual(0)
      expect(params.fileDescriptors.length).assertEqual(0)
    })

    it('parse_send_request_reads_cat_share_text', 0, () => {
      let raw = '{"taskId":"t","senderId":"s","senderName":"n","fileName":"sharedText.txt",' +
        '"fileCount":1,"totalSize":5,"catShareText":"你好"}'
      let request = parseSendRequestPayload(raw)
      expect(request !== undefined).assertTrue()
      if (request !== undefined) {
        expect(request.textContent).assertEqual('你好')
        expect(request.fileCount).assertEqual(1)
      }
    })

    it('parse_send_request_without_text_is_empty', 0, () => {
      let request = parseSendRequestPayload('{"taskId":"t","fileCount":1}')
      expect(request !== undefined).assertTrue()
      if (request !== undefined) {
        expect(request.textContent).assertEqual('')
      }
    })
  })
}
