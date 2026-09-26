import { describe, it, expect } from '@ohos/hypium'
import {
  MtaBluetoothObservation,
  MtaBluetoothStatus,
  MtaDeviceListClearedEvent,
  MtaDeviceListClearReason,
  MtaDeviceListClearScene,
  MtaDiscoveryIntent,
  buildMtaDeviceListClearedEvent,
  buildMtaScanHealth,
  formatMtaDeviceListClearedLog,
  isMtaClearReasonDistinct,
  isMissingSinceRescan,
  isStaleByTtl,
  mapMtaBluetoothObservation,
  mtaClearReasonText,
  resolveMtaShouldScan,
  shouldClearMtaOnBluetoothStatus,
  shouldAttemptMtaScanRearm,
  shouldPruneStaleDevices,
  shouldTriggerScanRecovery,
  withMtaSendSuspended,
  withMtaVisibilityDesired
} from '../../../../main/ets/model/mta/MtaDiscoveryModels'

// 互传发现守卫纯逻辑测试套件：
// 覆盖蓝牙三态映射、发现意图解析、扫描健康度/停顿判定、清空原因分类与诊断事件等
// 无设备依赖的纯判定逻辑（按功能域独立验证）。
export default function MtaDiscoveryGuardTest() {
  describe('MtaDiscoveryGuardTest', () => {
    // ── 套件骨架自检 ──
    it('model_smoke_loaded', 0, () => {
      expect(mapMtaBluetoothObservation(MtaBluetoothObservation.ON))
        .assertEqual(MtaBluetoothStatus.ENABLED)
    })

    // ── 正常使用中互传设备列表保持稳定 ──
    // 发送暂停只临时挂起扫描，不抹除可见性期望

    it('send_pause_keeps_visibility_intent', 0, () => {
      let intent = new MtaDiscoveryIntent()
      intent.visibilityDesired = true
      intent.sendSuspended = false
      expect(resolveMtaShouldScan(intent)).assertTrue()

      // 发送暂停：扫描应挂起，但可见性期望必须保留
      let paused = withMtaSendSuspended(intent, true)
      expect(resolveMtaShouldScan(paused)).assertFalse()
      expect(paused.visibilityDesired).assertTrue()

      // 发送结束：按保留的可见性期望恢复
      let resumed = withMtaSendSuspended(paused, false)
      expect(resolveMtaShouldScan(resumed)).assertTrue()
    })

    it('visibility_toggle_preserves_existing_entries', 0, () => {
      let intent = new MtaDiscoveryIntent()
      intent.visibilityDesired = true
      intent.sendSuspended = false

      // 切走/进入详情页：只更新可见性期望，不影响发送暂停意图
      let hidden = withMtaVisibilityDesired(intent, false)
      expect(resolveMtaShouldScan(hidden)).assertFalse()
      expect(hidden.sendSuspended).assertFalse()

      // 未在扫描（可见性期望为假）时，陈旧剔除必须被跳过，既有条目不被移除
      let health = buildMtaScanHealth(false, 0, 0, 100000, 30000)
      expect(shouldPruneStaleDevices(health)).assertFalse()

      // 返回发送页：可见性期望恢复即应重新扫描
      let visibleAgain = withMtaVisibilityDesired(hidden, true)
      expect(resolveMtaShouldScan(visibleAgain)).assertTrue()
    })

    it('send_end_restores_by_visibility_expectation', 0, () => {
      // 页面可见：发送结束后应恢复发现
      let visible = new MtaDiscoveryIntent()
      visible.visibilityDesired = true
      visible.sendSuspended = true
      expect(resolveMtaShouldScan(withMtaSendSuspended(visible, false))).assertTrue()

      // 页面不可见：发送结束后不得起扫（按可见性期望恢复）
      let hidden = new MtaDiscoveryIntent()
      hidden.visibilityDesired = false
      hidden.sendSuspended = true
      expect(resolveMtaShouldScan(withMtaSendSuspended(hidden, false))).assertFalse()
    })

    // ── 蓝牙真实开关状态下的行为正确 ──
    // 三态映射：查询异常与中间态一律归为「不可确定」

    it('bluetooth_three_state_mapping', 0, () => {
      expect(mapMtaBluetoothObservation(MtaBluetoothObservation.ON))
        .assertEqual(MtaBluetoothStatus.ENABLED)
      expect(mapMtaBluetoothObservation(MtaBluetoothObservation.OFF))
        .assertEqual(MtaBluetoothStatus.DISABLED)
      // 中间态与查询失败均不得折叠为「已关闭」
      expect(mapMtaBluetoothObservation(MtaBluetoothObservation.TRANSITIONAL))
        .assertEqual(MtaBluetoothStatus.UNKNOWN)
      expect(mapMtaBluetoothObservation(MtaBluetoothObservation.UNAVAILABLE))
        .assertEqual(MtaBluetoothStatus.UNKNOWN)
    })

    it('only_confirmed_off_clears', 0, () => {
      // 仅「确认关闭」允许触发清空
      expect(shouldClearMtaOnBluetoothStatus(MtaBluetoothStatus.DISABLED)).assertTrue()
      // 已开启不触发
      expect(shouldClearMtaOnBluetoothStatus(MtaBluetoothStatus.ENABLED)).assertFalse()
      // 不可确定不清空（状态查询失败不等于关闭）
      expect(shouldClearMtaOnBluetoothStatus(MtaBluetoothStatus.UNKNOWN)).assertFalse()
    })

    // ── 互传分组清空可被诊断定位 ──
    // 清空原因分类互斥且可区分，诊断事件字段完整

    it('clear_reasons_are_distinct', 0, () => {
      let reasons: Array<MtaDeviceListClearReason> = [
        MtaDeviceListClearReason.BLUETOOTH_DISABLED,
        MtaDeviceListClearReason.BLUETOOTH_STATE_MISJUDGED,
        MtaDeviceListClearReason.STALE_PRUNE,
        MtaDeviceListClearReason.SCAN_STALL,
        MtaDeviceListClearReason.UNKNOWN
      ]
      // 两两互斥：任意两个不同原因都判定为可区分，且文本互不相同
      for (let i = 0; i < reasons.length; i++) {
        for (let j = 0; j < reasons.length; j++) {
          if (i === j) {
            expect(isMtaClearReasonDistinct(reasons[i], reasons[j])).assertFalse()
          } else {
            expect(isMtaClearReasonDistinct(reasons[i], reasons[j])).assertTrue()
            expect(mtaClearReasonText(reasons[i]) === mtaClearReasonText(reasons[j])).assertFalse()
          }
        }
      }
    })

    it('clear_event_fields_complete', 0, () => {
      let event: MtaDeviceListClearedEvent = buildMtaDeviceListClearedEvent(
        MtaDeviceListClearReason.BLUETOOTH_DISABLED, 3, 1700000000000,
        MtaDeviceListClearScene.BLUETOOTH_EVENT)
      expect(event.reason).assertEqual(MtaDeviceListClearReason.BLUETOOTH_DISABLED)
      expect(event.countBefore).assertEqual(3)
      expect(event.occurredAtMs).assertEqual(1700000000000)
      expect(event.scene).assertEqual(MtaDeviceListClearScene.BLUETOOTH_EVENT)

      // 负数条目数归一到 0，保证诊断字段始终可用
      expect(buildMtaDeviceListClearedEvent(MtaDeviceListClearReason.UNKNOWN, -5, 1,
        MtaDeviceListClearScene.UNKNOWN).countBefore).assertEqual(0)

      // 诊断文本包含原因与清空前条目数，便于检索与区分
      let text: string = formatMtaDeviceListClearedLog(event)
      expect(text.includes(mtaClearReasonText(MtaDeviceListClearReason.BLUETOOTH_DISABLED))).assertTrue()
      expect(text.includes('清空前条目数=3')).assertTrue()
    })

    // ── 发现扫描停顿可自愈，不逐步清空列表 ──
    // 停顿判定阈值、扫描不健康时跳过剔除、疑似停顿触发恢复

    it('scan_stall_threshold_detection', 0, () => {
      let ttl = 30000
      // 未在扫描：永不疑似停顿
      expect(buildMtaScanHealth(false, 0, 1000, 1000000, ttl).suspectedStall).assertFalse()
      // 会话起始为基准：刚好未达阈值不算停顿，达到阈值即算停顿
      expect(buildMtaScanHealth(true, 0, 1000, 1000 + ttl - 1, ttl).suspectedStall).assertFalse()
      expect(buildMtaScanHealth(true, 0, 1000, 1000 + ttl, ttl).suspectedStall).assertTrue()
      // 有发现结果后以最近发现结果为基准
      expect(buildMtaScanHealth(true, 5000, 1000, 5000 + ttl - 1, ttl).suspectedStall).assertFalse()
      expect(buildMtaScanHealth(true, 5000, 1000, 5000 + ttl, ttl).suspectedStall).assertTrue()
    })

    it('unhealthy_scan_skips_prune', 0, () => {
      let ttl = 30000
      // 未在扫描：跳过剔除，既有条目保留
      expect(shouldPruneStaleDevices(buildMtaScanHealth(false, 5000, 1000, 9000, ttl))).assertFalse()
      // 扫描中但疑似停顿：跳过剔除
      expect(shouldPruneStaleDevices(buildMtaScanHealth(true, 5000, 1000, 5000 + ttl, ttl))).assertFalse()
      // 扫描中且有近期发现结果：允许剔除
      expect(shouldPruneStaleDevices(buildMtaScanHealth(true, 5000, 1000, 5000 + ttl - 1, ttl))).assertTrue()
    })

    it('suspected_stall_triggers_recovery', 0, () => {
      let ttl = 30000
      let stalled = buildMtaScanHealth(true, 5000, 1000, 5000 + ttl, ttl)
      // 疑似停顿且已超出恢复冷却：触发恢复
      expect(shouldTriggerScanRecovery(stalled, 5000 + ttl, 0, ttl)).assertTrue()
      // 恢复冷却窗口内：不重复触发
      expect(shouldTriggerScanRecovery(stalled, 5000 + ttl, 5000 + ttl - 1, ttl)).assertFalse()
      // 未疑似停顿：不触发恢复
      let healthy = buildMtaScanHealth(true, 5000, 1000, 5000 + ttl - 1, ttl)
      expect(shouldTriggerScanRecovery(healthy, 5000 + ttl, 0, ttl)).assertFalse()
    })

    // ── 发现扫描自愈重试（起扫失败后自动恢复，无需用户手动刷新/切页） ──

    it('scan_rearm_gating_by_bluetooth_and_cooldown', 0, () => {
      let blockedUntil = 10000
      // 冷却期内：不起扫（由间隔定时器在冷却结束后再试）
      expect(shouldAttemptMtaScanRearm(MtaBluetoothStatus.ENABLED, 9999, blockedUntil)).assertFalse()
      // 冷却结束：可重试
      expect(shouldAttemptMtaScanRearm(MtaBluetoothStatus.ENABLED, blockedUntil, blockedUntil)).assertTrue()
      // 蓝牙不可确定（查询失败/中间态）：仍可重试，不折叠为关闭
      expect(shouldAttemptMtaScanRearm(MtaBluetoothStatus.UNKNOWN, 20000, blockedUntil)).assertTrue()
      // 蓝牙确认关闭：不起扫（交由蓝牙状态事件在开启后恢复）
      expect(shouldAttemptMtaScanRearm(MtaBluetoothStatus.DISABLED, 20000, blockedUntil)).assertFalse()
    })

    it('ttl_stale_judgement', 0, () => {
      let ttl = 30000
      let now = 1000000
      // 恰好达到存活时长：仍在列表内
      expect(isStaleByTtl(now - ttl, now, ttl)).assertFalse()
      // 超过存活时长：判为陈旧
      expect(isStaleByTtl(now - ttl - 1, now, ttl)).assertTrue()
      // 近期仍在广播：不陈旧
      expect(isStaleByTtl(now - 1, now, ttl)).assertFalse()
    })

    // ── 主动刷新即时剔除离线设备（无需等满存活期 TTL） ──

    it('rescan_missing_device_detection', 0, () => {
      let epoch = 1000000
      // 刷新基准之后重新上报（在线）：保留
      expect(isMissingSinceRescan(epoch + 1, epoch)).assertFalse()
      expect(isMissingSinceRescan(epoch + 5000, epoch)).assertFalse()
      // 刷新基准之前最后一次上报（离线）：判为缺失并剔除
      expect(isMissingSinceRescan(epoch - 1, epoch)).assertTrue()
      // 刷新同一毫秒的上报按保留处理（保守不剔）
      expect(isMissingSinceRescan(epoch, epoch)).assertFalse()
      // 未布置刷新确认（基准为 0）：一律不判为缺失
      expect(isMissingSinceRescan(0, 0)).assertFalse()
      expect(isMissingSinceRescan(epoch, 0)).assertFalse()
    })
  })
}
