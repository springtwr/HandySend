import { describe, it, expect } from '@ohos/hypium'
import { fileIo as fs } from '@kit.CoreFileKit'
import {
  MTA_P2P_WRITE_MODE_NO_RESPONSE_TEXT,
  MTA_P2P_WRITE_MODE_WRITE_TEXT,
  MTA_PEER_ABANDONED_TEXT,
  MTA_PEER_BUSY_TEXT,
  MTA_PEER_REJECTED_TEXT,
  MtaCompanionPeerBehavior,
  MtaGroupCreationResult,
  MtaSendFile,
  MtaSendPreparation,
  MtaSendProgress,
  MtaSenderStage,
  SessionGroupIdentity,
  SenderState,
  bandLabelFromFrequency,
  buildEntryName,
  buildPeerInfoRecheckFailure,
  evaluatePeerInfoRecheck,
  formatCompanionPeerBehaviorSummary,
  formatCompanionWriteRequest,
  formatMtaP2pWriteDiagnostic,
  isMtaPeerBusy,
  isMtaSenderStageForward,
  isSamsungBrandId,
  isWeakBand,
  matchMtaGroupIdentity,
  mtaBrandNameOf,
  mtaPeerBusyReasonText,
  mtaRejectReasonText,
  mtaSenderStageOrder,
  normalizeMtaP2pMac,
  parseMtaAdvServiceData,
  randomGroupName,
  randomPassphrase,
  randomTaskId,
  resolveMtaP2pWriteModeText,
  resolvePreferredGroupBands,
  resolveSendWritebackReady,
  totalFileBytes
} from '../../../../main/ets/model/mta/MtaSendModels'
import { shouldRescanPeerAddress } from '../../../../main/ets/service/mta/MtaBleClient'
import {
  MTA_BRAND_ID_THIRD_PARTY,
  isRegisteredMtaBrand,
  mtaBrandEntryOf,
  mtaSelectableBrandOf,
  mtaSelectableBrands,
  normalizeMtaBrandId,
  resolveMtaBrandDisplayName,
  resolveMtaBrandIcon,
  resolveMtaBrandName,
  resolveMtaPhoneBrandIcon
} from '../../../../main/ets/model/mta/MtaBrandRegistry'
import { MtaConstants } from '../../../../main/ets/service/mta/MtaConstants'
import { buildWsMessage, bytesToHex, parseP2pInfo, parseWsMessage, P2pInfoJson } from '../../../../main/ets/model/mta/MtaProtocolModels'
import { getTestAppContext } from '../helper/TestContext'

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

    // ── 发送清单尺寸来源（以已打开句柄取属性，与将发送字节同源） ──

    it('send_entry_size_source_matches_handle_content', 0, () => {
      // 契约：条目尺寸取自其已打开句柄的 stat，必须与实际内容字节一致；
      // 否则对端声明尺寸与实际发送载荷不符，会导致载荷被截断
      let ctx = getTestAppContext()
      if (ctx === undefined) {
        // 非设备运行环境（无 UIAbility 上下文）：跳过文件系统契约断言
        expect(true).assertTrue()
        return
      }
      let dir = ctx.cacheDir + '/mta_send_size_test'
      try {
        fs.mkdirSync(dir, true)
      } catch (_e) {
      }
      let path = dir + '/payload.bin'
      let content = new Uint8Array(4096)
      for (let i = 0; i < content.length; i++) {
        content[i] = i % 251
      }
      let writer = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      fs.writeSync(writer.fd, content.buffer)
      fs.closeSync(writer)

      let handle = fs.openSync(path, fs.OpenMode.READ_ONLY)
      try {
        // 尺寸来源：句柄 stat（与 openSendFds 一致），与实际内容长度一致
        let stat = fs.statSync(handle.fd)
        expect(stat.size).assertEqual(content.length)
        // 修改时间可自句柄读出并换算为 Unix 毫秒（与 openSendFds 的换算口径一致）
        let lastModifiedMs = Math.floor(stat.mtime * 1000)
        expect(lastModifiedMs > 0).assertTrue()
        // 同源一致性：句柄声明尺寸应等于实际可读字节数（声明尺寸即实际将发送的字节），
        // 避免来源 URI 属性与句柄内容不一致导致对端声明尺寸失真、载荷被截断
        let readBuffer = new ArrayBuffer(stat.size)
        let readLen = fs.readSync(handle.fd, readBuffer)
        expect(readLen).assertEqual(stat.size)
        // 声明尺寸逐条目合计即进度分母（与 Rust 侧声明总大小一致）
        let entry = new MtaSendFile()
        entry.sizeBytes = stat.size
        expect(totalFileBytes([entry])).assertEqual(content.length)
      } finally {
        fs.closeSync(handle)
      }
    })

    // ── 对端拒绝原因 → 面向用户文案 ──

    it('reject_reason_text_maps_protocol_reasons', 0, () => {
      expect(mtaRejectReasonText('user refuse')).assertEqual(MTA_PEER_REJECTED_TEXT)
      expect(mtaRejectReasonText('timeout')).assertEqual('对方未在时限内响应')
      // 未知原因保留原文；空原因回退默认文案
      expect(mtaRejectReasonText('custom')).assertEqual('对方拒绝：custom')
      expect(mtaRejectReasonText('')).assertEqual(MTA_PEER_REJECTED_TEXT)
    })

    it('peer_abandoned_text_does_not_change_reject_reason_mapping', 0, () => {
      // 新增的「对方已放弃接收」文案常量与既有「对方拒绝接收」文案相互独立
      expect(MTA_PEER_ABANDONED_TEXT).assertEqual('对方已放弃接收')
      expect(MTA_PEER_ABANDONED_TEXT !== MTA_PEER_REJECTED_TEXT).assertTrue()
      // 拒绝原因映射语义不变：四类原因仍各自映射到既有文案
      expect(mtaRejectReasonText('user refuse')).assertEqual(MTA_PEER_REJECTED_TEXT)
      expect(mtaRejectReasonText('user refuse') !== MTA_PEER_ABANDONED_TEXT).assertTrue()
      expect(mtaRejectReasonText('timeout')).assertEqual('对方未在时限内响应')
      expect(mtaRejectReasonText('timeout') !== MTA_PEER_ABANDONED_TEXT).assertTrue()
      expect(mtaRejectReasonText('')).assertEqual(MTA_PEER_REJECTED_TEXT)
      expect(mtaRejectReasonText('custom')).assertEqual('对方拒绝：custom')
    })

    // ── 对端忙判定与忙原因文案 ──

    it('peer_busy_judgement_is_strict_non_ready', 0, () => {
      // 就绪值（0）判定为非忙；其余任何值（含未知码）一律判忙
      expect(isMtaPeerBusy(0)).assertFalse()
      expect(isMtaPeerBusy(1)).assertTrue()
      expect(isMtaPeerBusy(2)).assertTrue()
      expect(isMtaPeerBusy(99)).assertTrue()
      expect(isMtaPeerBusy(-1)).assertTrue()
    })

    it('peer_busy_reason_text_maps_known_codes', 0, () => {
      // 已知原因码映射为可读原因
      expect(mtaPeerBusyReasonText(1)).assertEqual('镜像占用')
      expect(mtaPeerBusyReasonText(2)).assertEqual('热点占用')
      // 未知码与缺省 0 回退通用文案
      expect(mtaPeerBusyReasonText(0)).assertEqual('未知原因')
      expect(mtaPeerBusyReasonText(9)).assertEqual('未知原因')
    })

    it('peer_busy_text_is_user_facing_constant', 0, () => {
      expect(MTA_PEER_BUSY_TEXT).assertEqual('对端设备正忙，请稍后重试')
    })

    it('peer_ready_does_not_short_circuit', 0, () => {
      // 就绪基准与判定口径一致：state 等于 DEVICE_INFO_STATE 时判定为非忙，不进入失败短路
      expect(MtaConstants.DEVICE_INFO_STATE).assertEqual(0)
      expect(isMtaPeerBusy(MtaConstants.DEVICE_INFO_STATE)).assertFalse()
      // 忙原因码常量语义稳定，供日志映射使用
      expect(mtaPeerBusyReasonText(MtaConstants.PEER_BUSY_REASON_MIRROR)).assertEqual('镜像占用')
      expect(mtaPeerBusyReasonText(MtaConstants.PEER_BUSY_REASON_HOTSPOT)).assertEqual('热点占用')
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

    it('resolve_preferred_bands_samsung_forces_2ghz', 0, () => {
      let samsungWith5g = resolvePreferredGroupBands(70, true)
      expect(samsungWith5g.length).assertEqual(1)
      expect(samsungWith5g[0].band).assertEqual(MtaConstants.GROUP_OWNER_BAND_2GHZ)
      expect(samsungWith5g[0].freqMhz).assertEqual(0)
      let samsung75 = resolvePreferredGroupBands(75, true)
      expect(samsung75.length).assertEqual(1)
      expect(samsung75[0].band).assertEqual(MtaConstants.GROUP_OWNER_BAND_2GHZ)
      let samsungNo5g = resolvePreferredGroupBands(70, false)
      expect(samsungNo5g.length).assertEqual(1)
      expect(samsungNo5g[0].band).assertEqual(MtaConstants.GROUP_OWNER_BAND_2GHZ)
    })

    it('resolve_preferred_bands_non_samsung_5ghz_prefers_5ghz', 0, () => {
      let bands = resolvePreferredGroupBands(11, true)
      expect(bands.length).assertEqual(2)
      expect(bands[0].band).assertEqual(MtaConstants.GROUP_OWNER_BAND_5GHZ)
      expect(bands[0].freqMhz).assertEqual(MtaConstants.GROUP_5GHZ_FREQUENCY_MHZ)
      expect(bands[1].band).assertEqual(MtaConstants.GROUP_OWNER_BAND_2GHZ)
      expect(bands[1].freqMhz).assertEqual(0)
      let no5g = resolvePreferredGroupBands(11, false)
      expect(no5g.length).assertEqual(1)
      expect(no5g[0].band).assertEqual(MtaConstants.GROUP_OWNER_BAND_2GHZ)
    })

    it('resolve_preferred_bands_unknown_brand_not_samsung', 0, () => {
      expect(isSamsungBrandId(-1)).assertFalse()
      let bands = resolvePreferredGroupBands(-1, true)
      expect(bands.length).assertEqual(2)
      expect(bands[0].band).assertEqual(MtaConstants.GROUP_OWNER_BAND_5GHZ)
      expect(bands[0].freqMhz).assertEqual(MtaConstants.GROUP_5GHZ_FREQUENCY_MHZ)
      expect(bands[1].band).assertEqual(MtaConstants.GROUP_OWNER_BAND_2GHZ)
      let no5g = resolvePreferredGroupBands(-1, false)
      expect(no5g.length).assertEqual(1)
      expect(no5g[0].band).assertEqual(MtaConstants.GROUP_OWNER_BAND_2GHZ)
    })

    it('band_label_from_frequency_maps_ranges', 0, () => {
      expect(bandLabelFromFrequency(2412)).assertEqual('2.4GHz')
      expect(bandLabelFromFrequency(2500)).assertEqual('2.4GHz')
      expect(bandLabelFromFrequency(5180)).assertEqual('5GHz')
      expect(bandLabelFromFrequency(5900)).assertEqual('5GHz')
      expect(bandLabelFromFrequency(0)).assertEqual('未知')
      expect(bandLabelFromFrequency(3000)).assertEqual('未知')
    })

    it('is_weak_band_only_2ghz_range', 0, () => {
      expect(isWeakBand(2400)).assertTrue()
      expect(isWeakBand(2437)).assertTrue()
      expect(isWeakBand(2500)).assertTrue()
      expect(isWeakBand(5180)).assertFalse()
      expect(isWeakBand(0)).assertFalse()
    })

    // ── 建组身份校验（就绪组名须等于本次请求创建的组名） ──

    it('group_identity_matches_when_names_equal', 0, () => {
      // 请求组名与观测组名完全相等 → 身份匹配，可采用其凭据
      let requested = randomGroupName()
      let identity = matchMtaGroupIdentity(requested, requested)
      expect(identity.requestedName).assertEqual(requested)
      expect(identity.observedName).assertEqual(requested)
      expect(identity.matched).assertTrue()
    })

    it('group_identity_rejects_residual_group_from_previous_session', 0, () => {
      // 观测到的是上一会话残留的组（组名不同）→ 身份不匹配，不得采用其无线凭据
      let requested = randomGroupName()
      let residual = randomGroupName()
      expect(residual !== requested).assertTrue()
      let identity = matchMtaGroupIdentity(requested, residual)
      expect(identity.matched).assertFalse()
      expect(identity.observedName).assertEqual(residual)
    })

    it('group_identity_rejects_missing_or_empty_names', 0, () => {
      // 观测组不可得（空串）或请求组名为空 → 一律不匹配
      let requested = randomGroupName()
      expect(matchMtaGroupIdentity(requested, '').matched).assertFalse()
      expect(matchMtaGroupIdentity('', requested).matched).assertFalse()
      expect(matchMtaGroupIdentity('', '').matched).assertFalse()
      // 默认身份为不匹配（未判定前不得视为就绪）
      let identity = new SessionGroupIdentity()
      expect(identity.matched).assertFalse()
      expect(identity.requestedName).assertEqual('')
      expect(identity.observedName).assertEqual('')
    })

    it('group_identity_mismatch_treated_as_not_ready_with_bounded_retry', 0, () => {
      // 身份契约：就绪判定等价于「观测组名 == 请求组名」；不匹配即视为未就绪，
      // 由有界的候选与身份尝试次数触发重建，且旧组有界处置超时为有界值，不引入无界等待
      let requested = randomGroupName()
      expect(matchMtaGroupIdentity(requested, requested).matched).assertTrue()
      expect(matchMtaGroupIdentity(requested, randomGroupName()).matched).assertFalse()
      // Samsung 仅有单个候选频段：其兜底依赖有界身份尝试次数
      expect(resolvePreferredGroupBands(70, true).length).assertEqual(1)
      expect(MtaConstants.GROUP_CREATE_IDENTITY_MAX_ATTEMPTS >= 1).assertTrue()
      expect(MtaConstants.GROUP_RESIDUAL_CLEAR_TIMEOUT_MS > 0).assertTrue()
      // 未取得身份匹配的组时建组结果不含可用群组信息（判为建组失败）
      let result = new MtaGroupCreationResult()
      expect(result.info === null).assertTrue()
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

    // ── 品牌注册表：对端手机品牌图标标注（18 专属品牌） ──

    it('brand_registry_phone_brand_icon_annotated_for_branded_ranges', 0, () => {
      // 18 个有专属图标的品牌，取各区间代表标识断言 iconRes 已标注
      let brandedIds: Array<number> = [11, 10, 20, 32, 30, 41, 50, 66, 60, 70, 80,
        100, 110, 130, 140, 160, 161, 170]
      expect(brandedIds.length).assertEqual(18)
      for (let i = 0; i < brandedIds.length; i++) {
        let entry = mtaBrandEntryOf(brandedIds[i])
        expect(entry !== undefined).assertTrue()
        if (entry !== undefined) {
          expect(entry.iconRes !== undefined).assertTrue()
        }
      }
    })

    // ── 品牌注册表：无专属图标品牌与未知标识回退默认 ──

    it('brand_registry_phone_brand_icon_absent_for_fallback_brands', 0, () => {
      // Smartisan / Easy Share / NIO / 第三方：已注册但无专属图标，解析回退默认兜底（仍为有效资源）
      let fallbackIds: Array<number> = [90, 114, 120, MTA_BRAND_ID_THIRD_PARTY]
      for (let i = 0; i < fallbackIds.length; i++) {
        let entry = mtaBrandEntryOf(fallbackIds[i])
        expect(entry !== undefined).assertTrue()
        if (entry !== undefined) {
          expect(entry.iconRes === undefined).assertTrue()
        }
        expect(resolveMtaPhoneBrandIcon(fallbackIds[i]) !== undefined).assertTrue()
      }
      // 未知标识：未命中注册表，解析同样回退默认兜底
      expect(mtaBrandEntryOf(999) === undefined).assertTrue()
      expect(resolveMtaPhoneBrandIcon(999) !== undefined).assertTrue()
    })

    // ── 品牌注册表：图标解析恒返回有效资源（渲染永不空白） ──

    it('brand_registry_phone_brand_icon_never_undefined', 0, () => {
      // 覆盖全部注册表区间的上下界（含无专属图标品牌）与未知标识
      let allIds: Array<number> = [11, 10, 19, 20, 29, 32, 30, 39, 41, 45, 50, 59, 66, 60, 69, 70, 75,
        80, 89, 90, 95, 100, 109, 114, 110, 119, 120, 129, 130, 139, 140, 149, 160, 161, 169, 170, 179,
        MTA_BRAND_ID_THIRD_PARTY, -1, 999]
      for (let i = 0; i < allIds.length; i++) {
        expect(resolveMtaPhoneBrandIcon(allIds[i]) !== undefined).assertTrue()
      }
    })

    // ── 品牌名查询委托注册表 ──

    it('mta_brand_name_of_delegates_registry', 0, () => {
      expect(mtaBrandNameOf(70)).assertEqual('Samsung')
      expect(mtaBrandNameOf(11)).assertEqual('Realme')
      expect(mtaBrandNameOf(1)).assertEqual('未知(1)')
    })

    // ── 主广播 UUID 品牌字节 ──

    it('main_adv_uuid_third_party_matches_current', 0, () => {
      expect(MtaConstants.mainAdvDataUuidForBrand(MtaConstants.BRAND_ID_THIRD_PARTY))
        .assertEqual(MtaConstants.ADV_DATA_UUID)
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
      // 标记字节 0x03 的 bit0=1：按最低有效位判定为支持 5GHz（旧实现按整字节相等会漏判）
      expect(result.is5GhzFlagByte).assertEqual(3)
      expect(result.is5Ghz).assertTrue()
      expect(result.is5GhzBasis).assertEqual('bit0=1 判定支持5GHz')
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
      // 仅扫描响应、无主广播时未解析到 5GHz 标记字节，判定依据为缺省文案
      expect(result.is5GhzFlagByte).assertEqual(-1)
      expect(result.is5GhzBasis).assertEqual('未解析到标记字节')
    })

    it('adv_parse_main_broadcast_brand_from_uuid', 0, () => {
      // 主广播 6 字节：5GHz 与品牌取自 serviceData UUID 的第 3、4 字节
      let map = new Map<string, Uint8Array>()
      map.set('000001ff-0000-1000-8000-00805f9b34fb', hexToBytes('186100000000'))
      let result = parseMtaAdvServiceData(map)
      expect(result.brandId).assertEqual(255)
      expect(result.brandName).assertEqual('第三方')
      expect(result.is5Ghz).assertTrue()
      // 标记原始字节值与判定依据一并填充，供诊断核对「原值—判定」一致
      expect(result.is5GhzFlagByte).assertEqual(1)
      expect(result.is5GhzBasis).assertEqual('bit0=1 判定支持5GHz')
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

    // ── 5GHz 判定按标记字节最低有效位 bit0（兼容同时置其他位的对端） ──

    it('adv_parse_flag_with_other_bits_non_samsung_supports_5ghz', 0, () => {
      // 中兴标记字节 0x03（bit0=1，另置 bit1）：按最低有效位判定为支持 5GHz；
      // 品牌为非 Samsung，建组候选应 5GHz 优先、2.4GHz 回退
      let map = new Map<string, Uint8Array>()
      map.set('00000350-0000-1000-8000-00805f9b34fb', hexToBytes('186100000000'))
      let result = parseMtaAdvServiceData(map)
      expect(result.brandId).assertEqual(80)
      expect(result.brandName).assertEqual('ZTE')
      expect(result.is5GhzFlagByte).assertEqual(3)
      expect(result.is5Ghz).assertTrue()
      expect(result.is5GhzBasis).assertEqual('bit0=1 判定支持5GHz')
      let bands = resolvePreferredGroupBands(result.brandId, result.is5Ghz)
      expect(bands.length).assertEqual(2)
      expect(bands[0].band).assertEqual(MtaConstants.GROUP_OWNER_BAND_5GHZ)
      expect(bands[0].freqMhz).assertEqual(MtaConstants.GROUP_5GHZ_FREQUENCY_MHZ)
      expect(bands[1].band).assertEqual(MtaConstants.GROUP_OWNER_BAND_2GHZ)
    })

    it('adv_parse_flag_bit0_zero_not_supports_5ghz', 0, () => {
      // 标记字节 0x02（bit0=0）虽非零仍判不支持 5GHz（不得按整字节非零判定）
      let map = new Map<string, Uint8Array>()
      map.set('00000250-0000-1000-8000-00805f9b34fb', hexToBytes('186100000000'))
      let result = parseMtaAdvServiceData(map)
      expect(result.is5GhzFlagByte).assertEqual(2)
      expect(result.is5Ghz).assertFalse()
      expect(result.is5GhzBasis).assertEqual('bit0=0 判定不支持5GHz')
      let bands = resolvePreferredGroupBands(result.brandId, result.is5Ghz)
      expect(bands.length).assertEqual(1)
      expect(bands[0].band).assertEqual(MtaConstants.GROUP_OWNER_BAND_2GHZ)
    })

    it('resolve_preferred_bands_samsung_with_flag_other_bits_stays_2ghz', 0, () => {
      // Samsung（brandId 70）即便标记字节含其他位（声明支持 5GHz）仍强制仅 2.4GHz
      let map = new Map<string, Uint8Array>()
      map.set('00000346-0000-1000-8000-00805f9b34fb', hexToBytes('186100000000'))
      let result = parseMtaAdvServiceData(map)
      expect(result.brandId).assertEqual(70)
      expect(result.brandName).assertEqual('Samsung')
      expect(result.is5Ghz).assertTrue()
      let bands = resolvePreferredGroupBands(result.brandId, result.is5Ghz)
      expect(bands.length).assertEqual(1)
      expect(bands[0].band).assertEqual(MtaConstants.GROUP_OWNER_BAND_2GHZ)
      expect(bands[0].freqMhz).assertEqual(0)
    })

    // ── P2pInfo 连接配置字段（G/M/P）序列化 ──

    it('p2p_info_serializes_gmp_when_non_zero', 0, () => {
      // 发送端填充的连接配置字段：引导网络/主网络/协议类型 = GATT / WiFi P2P / MIOV HTTP
      let info = new P2pInfoJson()
      info.id = 'a1b2'
      info.ssid = 's'
      info.psk = 'p'
      info.mac = 'm'
      info.port = 43210
      info.freq = 5180
      info.key = 'k'
      info.catShare = 7
      info.G = MtaConstants.P2P_BOOT_NETWORK_GATT
      info.M = MtaConstants.P2P_MAIN_NETWORK_WIFI_P2P
      info.P = MtaConstants.P2P_PROTOCOL_MIOV_HTTP
      let text = info.toJsonText()
      let parsed = JSON.parse(text) as Record<string, Object>
      expect(parsed['G'] as number).assertEqual(1)
      expect(parsed['M'] as number).assertEqual(1)
      expect(parsed['P'] as number).assertEqual(2)
      // 既有字段与取值不回归
      expect(parsed['id'] as string).assertEqual('a1b2')
      expect(parsed['ssid'] as string).assertEqual('s')
      expect(parsed['psk'] as string).assertEqual('p')
      expect(parsed['mac'] as string).assertEqual('m')
      expect(parsed['port'] as number).assertEqual(43210)
      expect(parsed['freq'] as number).assertEqual(5180)
      expect(parsed['key'] as string).assertEqual('k')
      expect(parsed['catShare'] as number).assertEqual(7)
      // 接收端解析不回归：既有字段照常解析，新增字段被其忽略
      let roundTrip = parseP2pInfo(text)
      expect(roundTrip !== undefined).assertTrue()
      if (roundTrip !== undefined) {
        expect(roundTrip.id).assertEqual('a1b2')
        expect(roundTrip.ssid).assertEqual('s')
        expect(roundTrip.psk).assertEqual('p')
        expect(roundTrip.mac).assertEqual('m')
        expect(roundTrip.port).assertEqual(43210)
        expect(roundTrip.key).assertEqual('k')
        expect(roundTrip.catShare).assertEqual(7)
      }
    })

    it('p2p_info_omits_gmp_when_zero', 0, () => {
      // 仅在非 0 时输出：缺省 0 时不出现 G/M/P 字段
      let info = new P2pInfoJson()
      info.id = 'a1'
      let text = info.toJsonText()
      expect(text.indexOf('"G"') < 0).assertTrue()
      expect(text.indexOf('"M"') < 0).assertTrue()
      expect(text.indexOf('"P"') < 0).assertTrue()
      // 既有字段始终输出且顺序不变（id 在最前）
      expect(text.startsWith('{"id":"a1",')).assertTrue()
      // 解析侧不因缺省字段报错
      let roundTrip = parseP2pInfo(text)
      expect(roundTrip !== undefined).assertTrue()
      if (roundTrip !== undefined) {
        expect(roundTrip.id).assertEqual('a1')
        expect(roundTrip.port).assertEqual(0)
      }
    })

    // ── 对外发送的本机 P2P 地址小写归一 ──

    it('normalize_p2p_mac_lowercases_hex', 0, () => {
      // 大写与混合大小写输入统一转为小写十六进制（冒号分隔），满足中兴严格相等、小米不敏感
      expect(normalizeMtaP2pMac('9A:B5:9B:EB:A7:15')).assertEqual('9a:b5:9b:eb:a7:15')
      expect(normalizeMtaP2pMac('9a:B5:9b:EB:a7:15')).assertEqual('9a:b5:9b:eb:a7:15')
      expect(normalizeMtaP2pMac('AA:BB:CC:DD:EE:FF')).assertEqual('aa:bb:cc:dd:ee:ff')
    })

    it('normalize_p2p_mac_keeps_empty_and_placeholder', 0, () => {
      // 空串（地址不可得）经归一后保持不变，不改变既有语义
      expect(normalizeMtaP2pMac('')).assertEqual('')
      // 纯数字占位地址不含字母，归一后不变（回退占位与全 0 地址）
      expect(normalizeMtaP2pMac(MtaConstants.FALLBACK_MAC)).assertEqual(MtaConstants.FALLBACK_MAC)
      expect(normalizeMtaP2pMac('00:00:00:00:00:00')).assertEqual('00:00:00:00:00:00')
    })

    it('normalize_p2p_mac_keeps_non_mac_form_unchanged', 0, () => {
      // 加密分支写入的 `mac` 为 Base64 密文（大小写敏感），非 MAC 形态必须原样返回，否则会破坏密文
      let cipher = 'QWxD+9abZxYz0/Base64Cipher=='
      expect(normalizeMtaP2pMac(cipher)).assertEqual(cipher)
    })

    // ── 写回 P2pInfo：按对端能力选择写模式与写诊断格式化 ──

    it('p2p_write_mode_selected_by_capability', 0, () => {
      // 对端声明支持无响应写 → 无响应写；否则 → 带响应写
      expect(MTA_P2P_WRITE_MODE_NO_RESPONSE_TEXT).assertEqual('无响应写(WRITE_NO_RESPONSE)')
      expect(MTA_P2P_WRITE_MODE_WRITE_TEXT).assertEqual('带响应写(WRITE)')
      expect(resolveMtaP2pWriteModeText(true)).assertEqual(MTA_P2P_WRITE_MODE_NO_RESPONSE_TEXT)
      expect(resolveMtaP2pWriteModeText(false)).assertEqual(MTA_P2P_WRITE_MODE_WRITE_TEXT)
    })

    it('p2p_write_diagnostic_formats_response_write_success', 0, () => {
      // 带响应写成功：等待并收到对端写回调
      let text = formatMtaP2pWriteDiagnostic(false, MtaConstants.CHAR_P2P_UUID, 512, 300, 42, true, '')
      expect(text.indexOf(`写方式=${MTA_P2P_WRITE_MODE_WRITE_TEXT}`) >= 0).assertTrue()
      expect(text.indexOf(`目标特征=${MtaConstants.CHAR_P2P_UUID}`) >= 0).assertTrue()
      expect(text.indexOf('MTU=512') >= 0).assertTrue()
      expect(text.indexOf('长度=300') >= 0).assertTrue()
      expect(text.indexOf('耗时=42ms') >= 0).assertTrue()
      expect(text.indexOf('写结果=成功（收到写回调）') >= 0).assertTrue()
    })

    it('p2p_write_diagnostic_formats_no_response_write_sent', 0, () => {
      // 无响应写：无对端写回调，「成功」仅代表本地已发出，不作为被处理的判据
      let text = formatMtaP2pWriteDiagnostic(true, MtaConstants.CHAR_P2P_UUID, 512, 300, 3, true, '')
      expect(text.indexOf(`写方式=${MTA_P2P_WRITE_MODE_NO_RESPONSE_TEXT}`) >= 0).assertTrue()
      expect(text.indexOf('写结果=成功（本地已发出，无写回调）') >= 0).assertTrue()
    })

    it('p2p_write_diagnostic_formats_failure_with_reason', 0, () => {
      let text = formatMtaP2pWriteDiagnostic(false, MtaConstants.CHAR_P2P_UUID, 23, 300, 8000, false, 'The operation is busy')
      expect(text.indexOf('MTU=23') >= 0).assertTrue()
      expect(text.indexOf('耗时=8000ms') >= 0).assertTrue()
      expect(text.indexOf('写结果=失败（The operation is busy）') >= 0).assertTrue()
      // 无响应写失败同样如实记录写方式与失败原因（写模式不影响失败格式化）
      let noResp = formatMtaP2pWriteDiagnostic(true, MtaConstants.CHAR_P2P_UUID, 23, 300, 5, false, '链路已断开')
      expect(noResp.indexOf(`写方式=${MTA_P2P_WRITE_MODE_NO_RESPONSE_TEXT}`) >= 0).assertTrue()
      expect(noResp.indexOf('写结果=失败（链路已断开）') >= 0).assertTrue()
      // 空失败原因回退「未知原因」，不产生空括号
      let fallback = formatMtaP2pWriteDiagnostic(false, MtaConstants.CHAR_P2P_UUID, 23, 1, 5, false, '')
      expect(fallback.indexOf('写结果=失败（未知原因）') >= 0).assertTrue()
    })

    // ── 写回后复读对端公开信息的比对结论 ──

    it('peer_info_recheck_state_changed_concludes_processed', 0, () => {
      let result = evaluatePeerInfoRecheck(0, '{"state":0,"mac":"a"}', 1, '{"state":1,"mac":"a"}')
      expect(result.success).assertTrue()
      expect(result.contentChanged).assertTrue()
      expect(result.stateChanged).assertTrue()
      expect(result.firstState).assertEqual(0)
      expect(result.recheckState).assertEqual(1)
      expect(result.conclusion.indexOf('已被对端处理') >= 0).assertTrue()
    })

    it('peer_info_recheck_unchanged_concludes_maybe_not_processed', 0, () => {
      let raw = '{"state":0,"mac":"a"}'
      let result = evaluatePeerInfoRecheck(0, raw, 0, raw)
      expect(result.success).assertTrue()
      expect(result.contentChanged).assertFalse()
      expect(result.stateChanged).assertFalse()
      expect(result.conclusion.indexOf('可能未被对端处理') >= 0).assertTrue()
    })

    it('peer_info_recheck_content_changed_without_state', 0, () => {
      // 仅非 state 字段变化：内容有变化但 state 未变，仍判定写回已被对端处理
      let result = evaluatePeerInfoRecheck(0, '{"state":0,"mac":"a"}', 0, '{"state":0,"mac":"b"}')
      expect(result.contentChanged).assertTrue()
      expect(result.stateChanged).assertFalse()
      expect(result.conclusion.indexOf('已被对端处理') >= 0).assertTrue()
    })

    it('peer_info_recheck_failure_concludes_link_unavailable', 0, () => {
      let result = buildPeerInfoRecheckFailure('读取超时')
      expect(result.success).assertFalse()
      expect(result.failureReason).assertEqual('读取超时')
      expect(result.conclusion.indexOf('链路已不可用') >= 0).assertTrue()
    })

    // ── 发送伴随外设的对端行为记录（纯函数） ──

    it('companion_peer_behavior_summary_defaults_zero', 0, () => {
      // 缺省累计全为 0、未收到 P2pInfo
      let behavior = new MtaCompanionPeerBehavior()
      let text = formatCompanionPeerBehaviorSummary(behavior)
      expect(text.indexOf('连接=0') >= 0).assertTrue()
      expect(text.indexOf('断开=0') >= 0).assertTrue()
      expect(text.indexOf('读=0') >= 0).assertTrue()
      expect(text.indexOf('写=0') >= 0).assertTrue()
      expect(text.indexOf('收到P2pInfo=否') >= 0).assertTrue()
    })

    it('companion_peer_behavior_summary_counts', 0, () => {
      // 各计数与「收到 P2pInfo」如实反映累计值
      let behavior = new MtaCompanionPeerBehavior()
      behavior.connectCount = 2
      behavior.disconnectCount = 1
      behavior.readCount = 3
      behavior.writeCount = 5
      behavior.p2pInfoReceived = true
      let text = formatCompanionPeerBehaviorSummary(behavior)
      expect(text.indexOf('连接=2') >= 0).assertTrue()
      expect(text.indexOf('断开=1') >= 0).assertTrue()
      expect(text.indexOf('读=3') >= 0).assertTrue()
      expect(text.indexOf('写=5') >= 0).assertTrue()
      expect(text.indexOf('收到P2pInfo=是') >= 0).assertTrue()
    })

    it('companion_write_request_includes_target_and_length', 0, () => {
      // 写请求记录含目标特征 UUID、分片偏移、累计长度与 prepared 标记
      let plain = formatCompanionWriteRequest(MtaConstants.CHAR_P2P_UUID, 0, 300, false)
      expect(plain.indexOf(`目标特征=${MtaConstants.CHAR_P2P_UUID}`) >= 0).assertTrue()
      expect(plain.indexOf('offset=0') >= 0).assertTrue()
      expect(plain.indexOf('累计长度=300') >= 0).assertTrue()
      expect(plain.indexOf('prepared=否') >= 0).assertTrue()
      // 分片写：offset 与 prepared 如实反映
      let prepared = formatCompanionWriteRequest(MtaConstants.CHAR_P2P_UUID, 20, 320, true)
      expect(prepared.indexOf('offset=20') >= 0).assertTrue()
      expect(prepared.indexOf('累计长度=320') >= 0).assertTrue()
      expect(prepared.indexOf('prepared=是') >= 0).assertTrue()
    })

    // ── 写回凭据关键路径就绪判定（并行本地准备） ──

    it('send_writeback_ready_requires_all_prerequisites', 0, () => {
      // 组就绪 + 对端信息可写 + 端口已知 三者同时满足才允许写回
      expect(resolveSendWritebackReady(true, true, 43210)).assertTrue()
      expect(resolveSendWritebackReady(true, true, -1)).assertFalse()
      expect(resolveSendWritebackReady(true, true, 0)).assertFalse()
      expect(resolveSendWritebackReady(false, true, 43210)).assertFalse()
      expect(resolveSendWritebackReady(true, false, 43210)).assertFalse()
    })

    it('send_preparation_defaults_are_not_ready', 0, () => {
      // 本地准备默认未就绪：预览/句柄不构成写回前置，但组与端口未就绪时不可写回
      let prep = new MtaSendPreparation()
      expect(prep.groupReady).assertFalse()
      expect(prep.serverPort).assertEqual(-1)
      expect(prep.fdsOpened).assertFalse()
      expect(prep.thumbnailReady).assertFalse()
      expect(prep.serverError).assertEqual('')
      expect(resolveSendWritebackReady(prep.groupReady, true, prep.serverPort)).assertFalse()
    })

    it('group_creation_result_defaults_empty', 0, () => {
      let result = new MtaGroupCreationResult()
      expect(result.info === null).assertTrue()
      expect(result.localMac).assertEqual('')
    })

    // ── 阶段推进单调性 ──

    it('send_stage_order_ranks_link_stages', 0, () => {
      expect(mtaSenderStageOrder(MtaSenderStage.GATT_CONNECTING) <
        mtaSenderStageOrder(MtaSenderStage.TRANSFERRING)).assertTrue()
      expect(mtaSenderStageOrder(MtaSenderStage.GROUP_CREATING) <
        mtaSenderStageOrder(MtaSenderStage.P2P_INFO_WRITTEN)).assertTrue()
      // 空闲与终态/取消相关阶段不在有序序列内
      expect(mtaSenderStageOrder(MtaSenderStage.IDLE)).assertEqual(-1)
      expect(mtaSenderStageOrder(MtaSenderStage.COMPLETED)).assertEqual(-1)
      expect(mtaSenderStageOrder(MtaSenderStage.FAILED)).assertEqual(-1)
      expect(mtaSenderStageOrder(MtaSenderStage.CANCELLED)).assertEqual(-1)
    })

    it('send_stage_forward_allows_new_session_and_terminal', 0, () => {
      // 新会话起始（上一会话为终态）与终态收束不受单调限制
      expect(isMtaSenderStageForward(MtaSenderStage.COMPLETED, MtaSenderStage.GATT_CONNECTING)).assertTrue()
      expect(isMtaSenderStageForward(MtaSenderStage.CANCELLED, MtaSenderStage.GATT_CONNECTING)).assertTrue()
      expect(isMtaSenderStageForward(MtaSenderStage.TRANSFERRING, MtaSenderStage.FAILED)).assertTrue()
      expect(isMtaSenderStageForward(MtaSenderStage.TRANSFERRING, MtaSenderStage.CANCEL_NOTIFYING)).assertTrue()
    })

    it('send_stage_forward_rejects_regression_between_link_stages', 0, () => {
      // 同为有序阶段时不得回退；同阶段与向前推进均允许
      expect(isMtaSenderStageForward(MtaSenderStage.NEGOTIATED, MtaSenderStage.WAITING_WS)).assertFalse()
      expect(isMtaSenderStageForward(MtaSenderStage.WAITING_WS, MtaSenderStage.WAITING_WS)).assertTrue()
      expect(isMtaSenderStageForward(MtaSenderStage.GATT_CONNECTING, MtaSenderStage.GROUP_CREATING)).assertTrue()
    })

    // ── 对端地址「先用后扫」 ──

    it('should_rescan_peer_address_only_when_needed', 0, () => {
      // 有记录地址：首次直接用，失败重试（第 2 次起）才重扫
      expect(shouldRescanPeerAddress('AA:BB:CC:DD:EE:FF', 1)).assertFalse()
      expect(shouldRescanPeerAddress('AA:BB:CC:DD:EE:FF', 2)).assertTrue()
      expect(shouldRescanPeerAddress('AA:BB:CC:DD:EE:FF', 3)).assertTrue()
      // 无记录地址（缺省或空白）：首次即需重扫取当前地址
      expect(shouldRescanPeerAddress('', 1)).assertTrue()
      expect(shouldRescanPeerAddress('   ', 1)).assertTrue()
    })
  })
}
