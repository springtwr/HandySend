import { describe, it, expect } from '@ohos/hypium'
import {
  MTA_MODE_RECEIVE,
  MTA_MODE_SEND,
  buildMtaReceivePageParams,
  buildMtaSendPageParams,
  combineTextContents,
  isAllManualText,
  isMtaDevice,
  mtaBrandBadgeText,
  mtaDeviceFromParams,
  mtaDeviceToDiscoveredDevice,
  mtaReceiveStageLabel,
  mtaSendStageLabel
} from '../main/ets/model/mta/MtaMainModels'
import { MtaDiscoveredDevice, MtaSenderStage } from '../main/ets/model/mta/MtaSendModels'
import { ReceiverStage, parseSendRequestPayload } from '../main/ets/model/mta/MtaReceiveModels'
import { DiscoveredDevice, TransferFileDescriptor } from '../main/ets/model/Types'

// MTA 主流程纯函数测试：设备映射、页面参数构建、文本判定/提取与阶段文案。
export default function MtaMainFlowTest() {
  describe('MtaMainFlowTest', () => {
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

    // ── 品牌徽标 ──

    it('brand_badge_known_and_unknown', 0, () => {
      expect(mtaBrandBadgeText('Xiaomi')).assertEqual('Xiaomi')
      expect(mtaBrandBadgeText('未知')).assertEqual('Android')
      expect(mtaBrandBadgeText('未知(5)')).assertEqual('Android')
      expect(mtaBrandBadgeText('')).assertEqual('Android')
      expect(mtaBrandBadgeText(undefined)).assertEqual('Android')
    })

    // ── 页面参数构建 ──

    it('build_send_params_carries_target_and_files', 0, () => {
      let descriptor: TransferFileDescriptor = {
        fileId: '',
        fileName: 'a.jpg',
        size: 100,
        fileType: 'image/jpeg'
      }
      let params = buildMtaSendPageParams(
        mtaDeviceToDiscoveredDevice(sampleMtaDevice(), 0), ['file://a.jpg'], [descriptor], false, '')
      expect(params.mode).assertEqual(MTA_MODE_SEND)
      expect(params.targetAlias).assertEqual('CatShare-Phone')
      expect(params.bleAddress).assertEqual('AA:BB:CC:DD:EE:FF')
      expect(params.brandId).assertEqual(30)
      expect(params.is5Ghz).assertTrue()
      expect(params.fileUris.length).assertEqual(1)
      expect(params.fileDescriptors[0].fileName).assertEqual('a.jpg')
      expect(params.isTextSend).assertFalse()
    })

    it('mta_device_from_params_roundtrip', 0, () => {
      let descriptor: TransferFileDescriptor = { fileId: '', fileName: 'a', size: 1, fileType: 'text/plain' }
      let params = buildMtaSendPageParams(
        mtaDeviceToDiscoveredDevice(sampleMtaDevice(), 0), ['u'], [descriptor], false, '')
      let device = mtaDeviceFromParams(params)
      expect(device.bleAddress).assertEqual('AA:BB:CC:DD:EE:FF')
      expect(device.deviceName).assertEqual('CatShare-Phone')
      expect(device.senderIdHex).assertEqual('1a2b')
      expect(device.brandId).assertEqual(30)
      expect(device.is5Ghz).assertTrue()
    })

    it('build_receive_params_defaults', 0, () => {
      let params = buildMtaReceivePageParams()
      expect(params.mode).assertEqual(MTA_MODE_RECEIVE)
      expect(params.fileUris.length).assertEqual(0)
      expect(params.textContent).assertEqual('')
    })

    // ── 文本判定与提取 ──

    it('is_all_manual_text', 0, () => {
      expect(isAllManualText([])).assertFalse()
      expect(isAllManualText([true, true])).assertTrue()
      expect(isAllManualText([true, false])).assertFalse()
    })

    it('combine_text_contents_skips_empty', 0, () => {
      expect(combineTextContents(['a', '', 'b'])).assertEqual('a\nb')
      expect(combineTextContents(['', ''])).assertEqual('')
    })

    // ── 阶段文案 ──

    it('send_stage_labels', 0, () => {
      expect(mtaSendStageLabel(MtaSenderStage.SCANNING)).assertEqual('正在搜索设备')
      expect(mtaSendStageLabel(MtaSenderStage.TRANSFERRING)).assertEqual('正在发送')
      expect(mtaSendStageLabel(MtaSenderStage.COMPLETED)).assertEqual('发送完成')
      expect(mtaSendStageLabel(MtaSenderStage.FAILED)).assertEqual('发送失败')
      expect(mtaSendStageLabel(MtaSenderStage.CANCELLED)).assertEqual('已取消')
    })

    it('receive_stage_labels', 0, () => {
      expect(mtaReceiveStageLabel(ReceiverStage.REQUEST_RECEIVED)).assertEqual('等待确认')
      expect(mtaReceiveStageLabel(ReceiverStage.DOWNLOADING)).assertEqual('正在接收')
      expect(mtaReceiveStageLabel(ReceiverStage.COMPLETED)).assertEqual('接收完成')
      expect(mtaReceiveStageLabel(ReceiverStage.FAILED)).assertEqual('接收失败')
    })

    // ── 文本链路 ──

    it('build_send_params_text_mode', 0, () => {
      let params = buildMtaSendPageParams(mtaDeviceToDiscoveredDevice(sampleMtaDevice(), 0), [], [], true, 'hello')
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
