import { describe, it, expect } from '@ohos/hypium'
import {
  DeviceSourceDescriptor,
  TransferMethodDescriptor,
  TransferMethodGroup
} from '../../../../main/ets/model/transfer/Registries'
import {
  filterSeenSources,
  listSources,
  registerSource,
  clearSources
} from '../../../../main/ets/service/transfer/DeviceSourceRegistry'
import {
  listMethodsByGroup,
  registerMethod,
  clearMethods
} from '../../../../main/ets/service/transfer/TransferMethodRegistry'
import { DiscoveredDevice, FavoriteDevice, StagedFile } from '../../../../main/ets/model/Types'
import { SessionStage } from '../../../../main/ets/model/transfer/TransferSession'
import { DeviceTypePartition } from '../../../../main/ets/model/SendDeviceGrouping'
import {
  beginLocalSendSession,
  finishLocalSend
} from '../../../../main/ets/service/transfer/adapters/LocalSendSendAdapter'
import {
  getAllSessions,
  getSession,
  resetRegistry
} from '../../../../main/ets/service/transfer/TransferSessionRegistry'
import {
  SendInitiateResult,
  SendViewModel,
  decideSendInitiateResult,
  pruneMissingManualTextFiles,
  filterDevicesByProtocolToggles,
  filterFavoritesByProtocolToggles,
  filterSeenSourceKeysByProtocolToggles,
  shouldShowProtocolDisabledHint
} from '../../../../main/ets/viewmodel/SendViewModel'

function source(key: string, order: number): DeviceSourceDescriptor {
  return {
    key: key,
    label: key,
    subtitle: key,
    icon: $r('app.media.ic_tab_send'),
    order: order,
    favoritable: key === 'localsend',
    emptyState: { text: 'empty', hint: 'hint', hintVisible: () => true },
    discoveryProvider: (): Array<DiscoveredDevice> => []
  }
}

function method(key: string, group: TransferMethodGroup, order: number): TransferMethodDescriptor {
  return {
    key: key,
    label: key,
    icon: $r('app.media.ic_tab_send'),
    group: group,
    order: order,
    available: () => true,
    action: () => {
    }
  }
}

function device(alias: string, ip: string): DiscoveredDevice {
  return {
    alias: alias,
    ip: ip,
    port: 53317,
    fingerprint: 'fp-' + alias,
    version: '2.1',
    deviceModel: 'M',
    deviceType: 'mobile',
    protocol: 'http',
    lastSeen: 0,
    channels: []
  }
}

export default function SendPageTest() {
  describe('SendPageTest', () => {
    it('sourceLabel_appearsOnlyWhenSeen', 0, () => {
      clearSources()
      registerSource(source('localsend', 10))
      registerSource(source('mta', 20))
      // 从未发现过 MTA：仅出现 LocalSend 来源（来源数 1 → 不展示标签）
      let seen = filterSeenSources(listSources(), ['localsend'])
      expect(seen.length).assertEqual(1)
      expect(seen[0].key).assertEqual('localsend')
      // 曾发现过 MTA：两个来源均出现（来源数 ≥2 → 展示分段标签）
      let both = filterSeenSources(listSources(), ['localsend', 'mta'])
      expect(both.length).assertEqual(2)
      expect(both[0].key).assertEqual('localsend')
      expect(both[1].key).assertEqual('mta')
      clearSources()
    })

    it('methods_grouped_webBeforeOther', 0, () => {
      clearMethods()
      registerMethod(method('web-send', TransferMethodGroup.web, 10))
      registerMethod(method('web-receive', TransferMethodGroup.web, 20))
      registerMethod(method('by-ip', TransferMethodGroup.other, 30))
      let web = listMethodsByGroup(TransferMethodGroup.web)
      expect(web.length).assertEqual(2)
      expect(web[0].key).assertEqual('web-send')
      let other = listMethodsByGroup(TransferMethodGroup.other)
      expect(other.length).assertEqual(1)
      expect(other[0].key).assertEqual('by-ip')
      clearMethods()
    })

    it('clickDevice_createsOneSessionPerClick', 0, () => {
      resetRegistry()
      let a = beginLocalSendSession('single_a', device('A', '10.0.0.1'),
        [{
          fileId: 'fa',
          filePath: '/a',
          fileName: 'a',
          fileType: '',
          size: 10
        }])
      let b = beginLocalSendSession('single_b', device('B', '10.0.0.2'),
        [{
          fileId: 'fb',
          filePath: '/b',
          fileName: 'b',
          fileType: '',
          size: 10
        }])
      let c = beginLocalSendSession('single_c', device('C', '10.0.0.3'),
        [{
          fileId: 'fc',
          filePath: '/c',
          fileName: 'c',
          fileType: '',
          size: 10
        }])
      // 连续点击 3 台设备 → 3 个彼此独立的会话
      expect(getAllSessions().length).assertEqual(3)
      expect(a === b || b === c || a === c).assertFalse()
      // 各自独立终结互不影响：终态只落在被终结的那个会话
      finishLocalSend(b, true)
      expect(getAllSessions().length).assertEqual(3)
      let sessionB = getSession(b)
      expect(sessionB !== undefined ? sessionB.stage : SessionStage.active).assertEqual(SessionStage.succeeded)
      let sessionA = getSession(a)
      expect(sessionA !== undefined ? sessionA.stage : SessionStage.active).assertEqual(SessionStage.active)
      resetRegistry()
    })

    it('sourceOptions_sortedByOrder', 0, () => {
      clearSources()
      registerSource(source('mta', 20))
      registerSource(source('localsend', 10))
      let all = listSources()
      expect(all[0].key).assertEqual('localsend')
      expect(all[1].key).assertEqual('mta')
      clearSources()
    })

    it('clickDevice_sendInitiateThreeStates', 0, async (done: Function) => {
      // 三态判定：在途/已有活跃会话优先判为被拦截，其次无内容，最后视为已发起
      expect(decideSendInitiateResult(false, false, true)).assertEqual(SendInitiateResult.initiated)
      expect(decideSendInitiateResult(true, false, true)).assertEqual(SendInitiateResult.blocked)
      expect(decideSendInitiateResult(false, true, true)).assertEqual(SendInitiateResult.blocked)
      expect(decideSendInitiateResult(false, false, false)).assertEqual(SendInitiateResult.noContent)

      resetRegistry()
      // 目标设备已有进行中发送会话：真实入口判定为被拦截，且不产生新会话
      let target = device('Busy', '10.9.9.9')
      let activeId = beginLocalSendSession('busy_1', target,
        [{
          fileId: 'f1',
          filePath: '/a',
          fileName: 'a',
          fileType: '',
          size: 10
        }])
      let before = getAllSessions().length
      let viewModel = new SendViewModel()
      let result = await viewModel.sendToMultipleDeviceInline(target)
      expect(result).assertEqual(SendInitiateResult.blocked)
      expect(getAllSessions().length).assertEqual(before)
      // 前提消失（会话终态）后重试：无冲突，判定为已发起
      finishLocalSend(activeId, true)
      let finished = getSession(activeId)
      let hasActive = finished !== undefined && finished.stage === SessionStage.active
      expect(decideSendInitiateResult(false, hasActive, true)).assertEqual(SendInitiateResult.initiated)
      resetRegistry()
      done()
    })

    it('sendInitiate_blockedWhileActive_thenFreshEntryAfterFinish', 0, async (done: Function) => {
      resetRegistry()
      // 无进行中传输时：拦截不误伤正常发送（判定为已发起）
      expect(decideSendInitiateResult(false, false, true)).assertEqual(SendInitiateResult.initiated)

      let target = device('Repeat', '10.8.8.8')
      let firstId = beginLocalSendSession('repeat_1', target,
        [{
          fileId: 'f1',
          filePath: '/a',
          fileName: 'a',
          fileType: '',
          size: 10
        }])
      let countBefore = getAllSessions().length

      // 未完成拦截：真实入口明确返回被拦截（视图层据此给出可见提示），且新增条目数为 0
      let viewModel = new SendViewModel()
      let blocked = await viewModel.sendToMultipleDeviceInline(target)
      expect(blocked).assertEqual(SendInitiateResult.blocked)
      expect(blocked === SendInitiateResult.initiated).assertFalse()
      expect(blocked === SendInitiateResult.noContent).assertFalse()
      expect(getAllSessions().length).assertEqual(countBefore)

      // 上一条完成后：判定不再被拦截，可产生全新条目
      finishLocalSend(firstId, true)
      let finished = getSession(firstId)
      let hasActive = finished !== undefined && finished.stage === SessionStage.active
      expect(decideSendInitiateResult(false, hasActive, true)).assertEqual(SendInitiateResult.initiated)

      // 再次发送产生全新条目（会话标识唯一），上一条传输记录仍保留
      let secondId = beginLocalSendSession('repeat_2', target,
        [{
          fileId: 'f2',
          filePath: '/b',
          fileName: 'b',
          fileType: '',
          size: 20
        }])
      expect(secondId === firstId).assertFalse()
      expect(getAllSessions().length).assertEqual(countBefore + 1)
      expect(getSession(firstId) !== undefined).assertTrue()
      resetRegistry()
      done()
    })

    it('pruneMissingManualTextFiles_removesOnlyMissingManualText', 0, () => {
      // 文件存在性注入：仅 /keep.txt 存在
      let fileExists = (uri: string): boolean => uri === '/keep.txt'
      let files: Array<StagedFile> = [
        {
          uri: '/keep.txt',
          fileName: 'keep.txt',
          fileType: 'text/plain',
          isImage: false,
          isManualText: true
        },
        {
          uri: '/gone.txt',
          fileName: 'gone.txt',
          fileType: 'text/plain',
          isImage: false,
          isManualText: true
        },
        // 非手动文本条目（picker 等外部来源）：底层文件不存在也应保留，不被误删
        {
          uri: '/picker.doc',
          fileName: 'picker.doc',
          fileType: 'application/msword',
          isImage: false
        }
      ]
      let kept = pruneMissingManualTextFiles(files, fileExists)
      expect(kept.length).assertEqual(2)
      expect(kept[0].uri).assertEqual('/keep.txt')
      expect(kept[1].uri).assertEqual('/picker.doc')
    })

    it('protocolToggles_filterDevicesFavoritesAndSeenKeys', 0, () => {
      // 设备分组：局域网 2 台 + 互传 1 台
      let localA: DiscoveredDevice = device('LA', '10.1.1.1')
      let localB: DiscoveredDevice = device('LB', '10.1.1.2')
      let mtaOne: DiscoveredDevice = device('MT', '10.2.2.2')
      let partition: DeviceTypePartition = { local: [localA, localB], mta: [mtaOne] }

      // 两开关均开：两组设备全部保留
      let all = filterDevicesByProtocolToggles(partition, true, true)
      expect(all.local.length).assertEqual(2)
      expect(all.mta.length).assertEqual(1)

      // LocalSend 关闭：局域网组清空，互传组不受影响
      let noLocal = filterDevicesByProtocolToggles(partition, false, true)
      expect(noLocal.local.length).assertEqual(0)
      expect(noLocal.mta.length).assertEqual(1)

      // MTA 关闭：互传组清空，局域网组不受影响
      let noMta = filterDevicesByProtocolToggles(partition, true, false)
      expect(noMta.local.length).assertEqual(2)
      expect(noMta.mta.length).assertEqual(0)

      // 收藏（均为局域网来源设备）：LocalSend 关闭时全部隐藏，开启时原样保留
      let favorites: Array<FavoriteDevice> = [{
        id: 'fav1',
        fingerprint: 'fp-1',
        ip: '10.1.1.1',
        port: 53317,
        alias: 'F1',
        customAlias: false
      }, {
        id: 'fav2',
        fingerprint: 'fp-2',
        ip: '10.1.1.2',
        port: 53317,
        alias: 'F2',
        customAlias: true
      }]
      expect(filterFavoritesByProtocolToggles(favorites, true).length).assertEqual(2)
      expect(filterFavoritesByProtocolToggles(favorites, false).length).assertEqual(0)

      // 来源键：禁用协议对应的来源键从「曾发现过设备的来源」集合移除
      expect(filterSeenSourceKeysByProtocolToggles(['localsend', 'mta'], true, true).length).assertEqual(2)
      let onlyMta = filterSeenSourceKeysByProtocolToggles(['localsend', 'mta'], false, true)
      expect(onlyMta.length).assertEqual(1)
      expect(onlyMta[0]).assertEqual('mta')
      let onlyLocal = filterSeenSourceKeysByProtocolToggles(['localsend', 'mta'], true, false)
      expect(onlyLocal.length).assertEqual(1)
      expect(onlyLocal[0]).assertEqual('localsend')
    })

    it('protocolDisabledHint_shownOnlyWhenBothOffAndNotDismissed', 0, () => {
      // 单一协议禁用：不显示任何常驻提示
      expect(shouldShowProtocolDisabledHint(false, true, false)).assertFalse()
      expect(shouldShowProtocolDisabledHint(true, false, false)).assertFalse()
      // 两者均开启：不显示
      expect(shouldShowProtocolDisabledHint(true, true, false)).assertFalse()
      // 两个协议均关闭且未关闭提示：显示
      expect(shouldShowProtocolDisabledHint(false, false, false)).assertTrue()
      // 已在本次会话内关闭提示：不再显示
      expect(shouldShowProtocolDisabledHint(false, false, true)).assertFalse()
    })
  })
}
