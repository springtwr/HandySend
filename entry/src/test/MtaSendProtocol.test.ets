import { describe, it, expect } from '@ohos/hypium'
import {
  MtaSendFile,
  MtaSendProgress,
  MtaSenderStage,
  SendRequestPayload,
  SenderState,
  buildEntryName,
  isSamsungBrandId,
  mtaSenderStageText,
  randomGroupName,
  randomPassphrase,
  randomTaskId,
  resolveGroupBand,
  totalFileBytes
} from '../main/ets/model/mta/MtaSendModels'
import { MtaConstants } from '../main/ets/service/mta/MtaConstants'
import { buildWsMessage, parseWsMessage } from '../main/ets/model/mta/MtaReceiveModels'

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
  })
}
