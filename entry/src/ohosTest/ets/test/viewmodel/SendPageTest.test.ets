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
import { DiscoveredDevice } from '../../../../main/ets/model/Types'
import { SessionStage } from '../../../../main/ets/model/transfer/TransferSession'
import { beginLocalSendSession, finishLocalSend } from '../../../../main/ets/service/transfer/adapters/LocalSendSendAdapter'
import { getAllSessions, getSession, resetRegistry } from '../../../../main/ets/service/transfer/TransferSessionRegistry'

function source(key: string, order: number): DeviceSourceDescriptor {
  return {
    key: key,
    label: key,
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
        [{ fileId: 'fa', filePath: '/a', fileName: 'a', fileType: '', size: 10 }])
      let b = beginLocalSendSession('single_b', device('B', '10.0.0.2'),
        [{ fileId: 'fb', filePath: '/b', fileName: 'b', fileType: '', size: 10 }])
      let c = beginLocalSendSession('single_c', device('C', '10.0.0.3'),
        [{ fileId: 'fc', filePath: '/c', fileName: 'c', fileType: '', size: 10 }])
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
  })
}
