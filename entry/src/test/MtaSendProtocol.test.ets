import { describe, it, expect } from '@ohos/hypium'
import {
  MtaSendFile,
  MtaSendProgress,
  MtaSenderStage,
  SendRequestPayload,
  SenderState,
  buildEntryName,
  isSamsungBrandId,
  mtaBrandNameOf,
  mtaSenderStageText,
  parseMtaAdvServiceData,
  randomGroupName,
  randomPassphrase,
  randomTaskId,
  resolveGroupBand,
  totalFileBytes
} from '../main/ets/model/mta/MtaSendModels'
import {
  MTA_BRAND_ID_THIRD_PARTY,
  isRegisteredMtaBrand,
  mtaSelectableBrandOf,
  mtaSelectableBrands,
  normalizeMtaBrandId,
  resolveMtaBrandDisplayName,
  resolveMtaBrandIcon,
  resolveMtaBrandName
} from '../main/ets/model/mta/MtaBrandRegistry'
import { MtaConstants } from '../main/ets/service/mta/MtaConstants'
import { buildWsMessage, bytesToHex, parseWsMessage } from '../main/ets/model/mta/MtaProtocolModels'

/** 测试辅助：十六进制字符串转字节数组 */
function hexToBytes(hex: string): Uint8Array {
  let out = new Uint8Array(hex.length / 2)
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16)
  }
  return out
}

// MTA 发送端纯函数测试：ZIP 条目命名、随机标识、阶段文案、状态快照与 WS 消息构造。
export default function MtaSendProtocolTest() {
  describe('MtaSendProtocolTest', () => {
    // ── ZIP 条目命名 ──

    it('build_entry_name_prefixes_sequence', 0, () => {
      expect(buildEntryName(0, 'photo.jpg')).assertEqual('1/photo.jpg')
      expect(buildEntryName(9, 'a.txt')).assertEqual('10/a.txt')
    })

    // ── 随机标识 ──

    it('random_passphrase_is_eight_chars', 0, () => {
      let passphrase = randomPassphrase()
      expect(passphrase.length).assertEqual(8)
      expect(new RegExp('^[a-z0-9]{8}$').test(passphrase)).assertTrue()
    })

    it('random_task_id_has_prefix', 0, () => {
      let taskId = randomTaskId()
      expect(taskId.startsWith('mta-')).assertTrue()
      expect(randomTaskId() !== taskId).assertTrue()
    })

    it('random_group_name_starts_with_direct', 0, () => {
      let groupName = randomGroupName()
      expect(groupName.startsWith('DIRECT-')).assertTrue()
      expect(groupName.length).assertEqual(15)
    })

    // ── 文件大小合计 ──

    it('total_file_bytes_sums', 0, () => {
      let a = new MtaSendFile()
      a.sizeBytes = 1024
      let b = new MtaSendFile()
      b.sizeBytes = 2048
      expect(totalFileBytes([a, b])).assertEqual(3072)
      expect(totalFileBytes([])).assertEqual(0)
    })

    // ── 阶段文案 ──

    it('stage_text_covers_known_stages', 0, () => {
      expect(mtaSenderStageText(MtaSenderStage.IDLE)).assertEqual('未启动')
      expect(mtaSenderStageText(MtaSenderStage.TRANSFERRING)).assertEqual('传输中')
      expect(mtaSenderStageText(MtaSenderStage.COMPLETED)).assertEqual('发送完成')
      expect(mtaSenderStageText(MtaSenderStage.CANCELLED)).assertEqual('已取消')
    })

    // ── 状态快照 ──

    it('sender_state_snapshot_is_independent', 0, () => {
      let state = new SenderState()
      state.stage = MtaSenderStage.TRANSFERRING
      state.devices = []
      let snapshot = state.snapshot()
      expect(snapshot.stage).assertEqual(MtaSenderStage.TRANSFERRING)
      // 修改原状态不影响快照
      state.stage = MtaSenderStage.FAILED
      expect(snapshot.stage).assertEqual(MtaSenderStage.TRANSFERRING)
      // progress 默认值
      expect(snapshot.progress.percent).assertEqual(0)
      expect(snapshot.serverRunning).assertFalse()
      expect(snapshot.groupCreated).assertFalse()
    })

    // ── sendRequest payload 默认值 ──

    it('send_request_payload_defaults', 0, () => {
      let payload = new SendRequestPayload()
      expect(payload.mimeType).assertEqual('application/zip')
      expect(payload.fileCount).assertEqual(0)
      expect(payload.totalSize).assertEqual(0)
      expect(payload.taskId).assertEqual('')
    })

    it('send_progress_defaults', 0, () => {
      let progress = new MtaSendProgress()
      expect(progress.sentBytes).assertEqual(0)
      expect(progress.totalBytes).assertEqual(0)
      expect(progress.percent).assertEqual(0)
    })

    // ── WS 消息构造/解析（发送端消息） ──

    it('build_sender_version_negotiation', 0, () => {
      let text = buildWsMessage('action', 0, 'versionNegotiation', '{"version":1,"versions":[1]}')
      expect(text).assertEqual('action:0:versionNegotiation?{"version":1,"versions":[1]}')
      let parsed = parseWsMessage(text)
      expect(parsed !== undefined).assertTrue()
      if (parsed !== undefined) {
        expect(parsed.type).assertEqual('action')
        expect(parsed.id).assertEqual(0)
        expect(parsed.name).assertEqual('versionNegotiation')
      }
    })

    it('parse_sender_ack', 0, () => {
      let parsed = parseWsMessage('ack:1:sendRequest')
      expect(parsed !== undefined).assertTrue()
      if (parsed !== undefined) {
        expect(parsed.type).assertEqual('ack')
        expect(parsed.id).assertEqual(1)
        expect(parsed.name).assertEqual('sendRequest')
      }
    })

    it('parse_receiver_status', 0, () => {
      let parsed = parseWsMessage('action:99:status?{"type":3,"reason":"user refuse"}')
      expect(parsed !== undefined).assertTrue()
      if (parsed !== undefined) {
        expect(parsed.name).assertEqual('status')
        expect(parsed.payload).assertEqual('{"type":3,"reason":"user refuse"}')
      }
    })

    // ── 建组频段决策（Samsung 品牌兼容） ──

    it('is_samsung_brand_id_interval', 0, () => {
      expect(isSamsungBrandId(70)).assertTrue()
      expect(isSamsungBrandId(75)).assertTrue()
      expect(isSamsungBrandId(69)).assertFalse()
      expect(isSamsungBrandId(76)).assertFalse()
      expect(isSamsungBrandId(-1)).assertFalse()
    })

    it('resolve_group_band_samsung_forces_2ghz', 0, () => {
      expect(resolveGroupBand(70, true)).assertEqual(MtaConstants.GROUP_OWNER_BAND_2GHZ)
      expect(resolveGroupBand(75, true)).assertEqual(MtaConstants.GROUP_OWNER_BAND_2GHZ)
      expect(resolveGroupBand(70, false)).assertEqual(MtaConstants.GROUP_OWNER_BAND_2GHZ)
    })

    it('resolve_group_band_non_samsung_follows_5ghz', 0, () => {
      expect(resolveGroupBand(11, true)).assertEqual(MtaConstants.GROUP_OWNER_BAND_AUTO)
      expect(resolveGroupBand(11, false)).assertEqual(MtaConstants.GROUP_OWNER_BAND_2GHZ)
    })

    it('resolve_group_band_unknown_brand_not_samsung', 0, () => {
      expect(isSamsungBrandId(-1)).assertFalse()
      expect(resolveGroupBand(-1, true)).assertEqual(MtaConstants.GROUP_OWNER_BAND_AUTO)
      expect(resolveGroupBand(-1, false)).assertEqual(MtaConstants.GROUP_OWNER_BAND_2GHZ)
    })

    // ── 品牌注册表：区间映射 ──

    it('brand_registry_range_mapping', 0, () => {
      expect(resolveMtaBrandName(10)).assertEqual('OPPO')
      expect(resolveMtaBrandName(19)).assertEqual('OPPO')
      expect(resolveMtaBrandName(20)).assertEqual('vivo')
      expect(resolveMtaBrandName(29)).assertEqual('vivo')
      expect(resolveMtaBrandName(30)).assertEqual('Xiaomi')
      expect(resolveMtaBrandName(39)).assertEqual('Xiaomi')
      expect(resolveMtaBrandName(42)).assertEqual('OnePlus')
      expect(resolveMtaBrandName(70)).assertEqual('Samsung')
      expect(resolveMtaBrandName(75)).assertEqual('Samsung')
      expect(resolveMtaBrandName(170)).assertEqual('Hisense')
      expect(resolveMtaBrandName(179)).assertEqual('Hisense')
    })

    // ── 品牌注册表：规范标识优先于通用区间 ──

    it('brand_registry_canonical_ids_override_ranges', 0, () => {
      expect(resolveMtaBrandName(11)).assertEqual('Realme')
      expect(resolveMtaBrandName(32)).assertEqual('Black Shark')
      expect(resolveMtaBrandName(66)).assertEqual('RedMagic')
      expect(resolveMtaBrandName(114)).assertEqual('Easy Share')
      expect(resolveMtaBrandName(160)).assertEqual('ROG')
    })

    // ── 品牌注册表：第三方默认 ──

    it('brand_registry_third_party_default', 0, () => {
      expect(MTA_BRAND_ID_THIRD_PARTY).assertEqual(255)
      expect(resolveMtaBrandName(MTA_BRAND_ID_THIRD_PARTY)).assertEqual('第三方')
      expect(mtaBrandNameOf(MTA_BRAND_ID_THIRD_PARTY)).assertEqual('第三方')
    })

    // ── 品牌注册表：未知回退 ──

    it('brand_registry_unknown_fallback', 0, () => {
      expect(resolveMtaBrandName(5)).assertEqual('未知(5)')
      expect(resolveMtaBrandName(-1)).assertEqual('未知(-1)')
      expect(resolveMtaBrandName(250)).assertEqual('未知(250)')
      expect(isRegisteredMtaBrand(250)).assertFalse()
      expect(isRegisteredMtaBrand(MTA_BRAND_ID_THIRD_PARTY)).assertTrue()
    })

    // ── 品牌注册表：识别映射不缩减（非主流品牌仍可识别） ──

    it('brand_registry_recognition_mapping_not_reduced', 0, () => {
      expect(resolveMtaBrandName(120)).assertEqual('NIO')
      expect(resolveMtaBrandName(129)).assertEqual('NIO')
      expect(resolveMtaBrandName(170)).assertEqual('Hisense')
      expect(resolveMtaBrandName(90)).assertEqual('Smartisan')
      expect(resolveMtaBrandName(32)).assertEqual('Black Shark')
      expect(resolveMtaBrandName(66)).assertEqual('RedMagic')
      expect(resolveMtaBrandName(80)).assertEqual('ZTE')
      expect(resolveMtaBrandName(105)).assertEqual('Lenovo')
      expect(resolveMtaBrandName(110)).assertEqual('Motorola')
      expect(resolveMtaBrandName(130)).assertEqual('Pixel')
      expect(resolveMtaBrandName(161)).assertEqual('ASUS')
      expect(resolveMtaBrandName(160)).assertEqual('ROG')
      expect(resolveMtaBrandName(140)).assertEqual('Honor')
    })

    // ── 品牌注册表：可模拟清单 = 第三方 + 8 主流品牌（顺序/唯一/图标/显示名） ──

    it('brand_registry_selectable_list_is_eight_plus_third_party', 0, () => {
      let list = mtaSelectableBrands()
      expect(list.length).assertEqual(9)
      expect(list[0].canonical).assertEqual(MTA_BRAND_ID_THIRD_PARTY)
      // 顺序固定：第三方 → Xiaomi → OPPO → vivo → Honor → OnePlus → realme → Samsung → Meizu
      let expectedIds: Array<number> = [MTA_BRAND_ID_THIRD_PARTY, 30, 10, 20, 140, 42, 11, 70, 50]
      let seen: Array<number> = []
      for (let i = 0; i < list.length; i++) {
        expect(list[i].canonical).assertEqual(expectedIds[i])
        expect(seen.indexOf(list[i].canonical) < 0).assertTrue()
        seen.push(list[i].canonical)
        // 每项含图标与本地化显示名资源
        expect(list[i].iconRes !== undefined).assertTrue()
        expect(list[i].displayNameRes !== undefined).assertTrue()
        // 可模拟项的规范英文名与识别映射查询一致
        expect(list[i].name).assertEqual(resolveMtaBrandName(list[i].canonical))
        expect(mtaSelectableBrandOf(list[i].canonical) !== undefined).assertTrue()
      }
      // 非主流品牌不在可模拟清单内
      expect(seen.indexOf(114) < 0).assertTrue()
      expect(seen.indexOf(32) < 0).assertTrue()
    })

    // ── 品牌注册表：显示名与图标查询（未知回退默认） ──

    it('brand_registry_display_name_and_icon_queries', 0, () => {
      // 可模拟项返回资源而非空
      expect(resolveMtaBrandDisplayName(30) !== undefined).assertTrue()
      expect(resolveMtaBrandIcon(30) !== undefined).assertTrue()
      // 已注册但不在可模拟清单内（历史选择）：显示名回退规范英文名
      expect(resolveMtaBrandDisplayName(32)).assertEqual('Black Shark')
      // 未注册：图标回退默认（仍返回有效资源）
      expect(resolveMtaBrandIcon(999) !== undefined).assertTrue()
      expect(resolveMtaBrandDisplayName(999) !== undefined).assertTrue()
    })

    // ── 品牌注册表：可模拟项查询未命中回退 ──

    it('brand_registry_selectable_unknown_queries_fall_back', 0, () => {
      expect(mtaSelectableBrandOf(999) === undefined).assertTrue()
      expect(mtaSelectableBrandOf(MTA_BRAND_ID_THIRD_PARTY) !== undefined).assertTrue()
    })

    // ── 品牌名查询委托注册表 ──

    it('mta_brand_name_of_delegates_registry', 0, () => {
      expect(mtaBrandNameOf(70)).assertEqual('Samsung')
      expect(mtaBrandNameOf(11)).assertEqual('Realme')
      expect(mtaBrandNameOf(1)).assertEqual('未知(1)')
    })

    // ── 主广播 UUID 品牌字节 ──

    it('main_adv_uuid_third_party_matches_current', 0, () => {
      expect(MtaConstants.mainAdvDataUuidForBrand(MtaConstants.BRAND_ID_THIRD_PARTY)).assertEqual(MtaConstants.ADV_DATA_UUID)
      expect(MtaConstants.mainAdvDataUuidForBrand(MTA_BRAND_ID_THIRD_PARTY)).assertEqual(MtaConstants.ADV_DATA_UUID)
    })

    it('main_adv_uuid_brand_byte', 0, () => {
      expect(MtaConstants.mainAdvDataUuidForBrand(70)).assertEqual('00000146-0000-1000-8000-00805f9b34fb')
      expect(MtaConstants.mainAdvDataUuidForBrand(10)).assertEqual('0000010a-0000-1000-8000-00805f9b34fb')
    })

    it('main_adv_uuid_out_of_range_falls_back_to_third_party', 0, () => {
      expect(MtaConstants.mainAdvDataUuidForBrand(normalizeMtaBrandId(300))).assertEqual(MtaConstants.ADV_DATA_UUID)
      expect(MtaConstants.mainAdvDataUuidForBrand(normalizeMtaBrandId(-1))).assertEqual(MtaConstants.ADV_DATA_UUID)
    })

    // ── 广播 serviceData 解析（按值长度分类，不依赖 UUID） ──

    it('adv_parse_honor_scan_response_by_length_not_uuid', 0, () => {
      // 荣耀：设备名在 UUID 为 00000000 的 27 字节 serviceData 中，须按长度识别
      let map = new Map<string, Uint8Array>()
      map.set('00000000-0000-1000-8000-00805F9B34FB',
        hexToBytes('677a4d454a47524446424a6f796365000000000000000000000001'))
      map.set('0000038C-0000-1000-8000-00805F9B34FB', hexToBytes('4f4546464e7a'))
      let result = parseMtaAdvServiceData(map)
      expect(result.senderIdHex).assertEqual('4642')
      expect(result.nameBytes.length).assertEqual(16)
      expect(bytesToHex(result.nameBytes)).assertEqual('4a6f7963650000000000000000000000')
      expect(result.brandId).assertEqual(140)
      expect(result.brandName).assertEqual('Honor')
      expect(result.is5Ghz).assertFalse()
      expect(result.anomalies.length).assertEqual(0)
    })

    it('adv_parse_standard_scan_response', 0, () => {
      // 标准 MTA：UUID 0000ffff 的 27 字节扫描响应（UUID 不再参与判断）
      let map = new Map<string, Uint8Array>()
      map.set('0000ffff-0000-1000-8000-00805f9b34fb',
        hexToBytes('000000000000000012344869000000000000000000000000000001'))
      let result = parseMtaAdvServiceData(map)
      expect(result.senderIdHex).assertEqual('1234')
      expect(bytesToHex(result.nameBytes)).assertEqual('48690000000000000000000000000000')
      expect(result.brandId).assertEqual(-1)
      expect(result.brandName).assertEqual('未知')
    })

    it('adv_parse_main_broadcast_brand_from_uuid', 0, () => {
      // 主广播 6 字节：5GHz 与品牌取自 serviceData UUID 的第 3、4 字节
      let map = new Map<string, Uint8Array>()
      map.set('000001ff-0000-1000-8000-00805f9b34fb', hexToBytes('186100000000'))
      let result = parseMtaAdvServiceData(map)
      expect(result.brandId).assertEqual(255)
      expect(result.brandName).assertEqual('第三方')
      expect(result.is5Ghz).assertTrue()
      expect(result.nameBytes.length).assertEqual(0)
    })

    it('adv_parse_unknown_length_is_ignored', 0, () => {
      let map = new Map<string, Uint8Array>()
      map.set('0000abcd-0000-1000-8000-00805f9b34fb', hexToBytes('0011223344'))
      let result = parseMtaAdvServiceData(map)
      expect(result.brandId).assertEqual(-1)
      expect(result.nameBytes.length).assertEqual(0)
      expect(result.anomalies.length).assertEqual(1)
      expect(result.rawServiceData.length > 0).assertTrue()
    })
  })
}
