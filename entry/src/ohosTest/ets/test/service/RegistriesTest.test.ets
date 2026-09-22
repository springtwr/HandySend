import { describe, it, expect } from '@ohos/hypium'
import {
  registerSource,
  getSource,
  listSources,
  filterSeenSources,
  clearSources
} from '../../../../main/ets/service/transfer/DeviceSourceRegistry'
import {
  registerMethod,
  getMethod,
  listMethods,
  listMethodsByGroup,
  clearMethods
} from '../../../../main/ets/service/transfer/TransferMethodRegistry'
import {
  registerSettingsGroup,
  listSettingsGroups,
  clearSettingsGroups
} from '../../../../main/ets/service/transfer/SettingsGroupRegistry'
import {
  DeviceSourceDescriptor,
  TransferMethodDescriptor,
  TransferMethodGroup,
  SettingGroupDescriptor
} from '../../../../main/ets/model/transfer/Registries'
import { DiscoveredDevice } from '../../../../main/ets/model/Types'

function source(key: string, order: number): DeviceSourceDescriptor {
  return {
    key: key,
    label: key,
    subtitle: key,
    icon: $r('app.media.ic_tab_send'),
    order: order,
    favoritable: true,
    emptyState: { text: 'empty', hint: 'hint', hintVisible: () => false },
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

function group(key: string, order: number, protocol: boolean): SettingGroupDescriptor {
  return { key: key, title: key, order: order, protocol: protocol, sectionKey: key }
}

export default function RegistriesTest() {
  describe('RegistriesTest', () => {
    it('sources_sortedByOrder', 0, () => {
      clearSources()
      registerSource(source('mta', 20))
      registerSource(source('localsend', 10))
      let list = listSources()
      expect(list.length).assertEqual(2)
      expect(list[0].key).assertEqual('localsend')
      expect(getSource('mta') !== undefined).assertTrue()
      clearSources()
    })

    it('sources_filterSeenOnly', 0, () => {
      clearSources()
      registerSource(source('localsend', 10))
      registerSource(source('mta', 20))
      let seen = filterSeenSources(listSources(), ['mta'])
      expect(seen.length).assertEqual(1)
      expect(seen[0].key).assertEqual('mta')
      // 从未发现过的来源不出现
      expect(filterSeenSources(listSources(), []).length).assertEqual(0)
      clearSources()
    })

    it('methods_groupedAndSorted', 0, () => {
      clearMethods()
      registerMethod(method('web-send', TransferMethodGroup.web, 20))
      registerMethod(method('web-receive', TransferMethodGroup.web, 10))
      registerMethod(method('ip', TransferMethodGroup.other, 30))
      let all = listMethods()
      expect(all.length).assertEqual(3)
      expect(all[0].key).assertEqual('web-receive')
      let web = listMethodsByGroup(TransferMethodGroup.web)
      expect(web.length).assertEqual(2)
      let other = listMethodsByGroup(TransferMethodGroup.other)
      expect(other.length).assertEqual(1)
      expect(getMethod('ip') !== undefined).assertTrue()
      clearMethods()
    })

    it('settings_sortedByOrder', 0, () => {
      clearSettingsGroups()
      registerSettingsGroup(group('localsend', 30, true))
      registerSettingsGroup(group('network', 20, false))
      registerSettingsGroup(group('mta', 40, true))
      registerSettingsGroup(group('appearance', 10, false))
      let list = listSettingsGroups()
      expect(list.length).assertEqual(4)
      // 通用组与协议组共用同一 order 序列混排（按使用频率顺序）
      expect(list[0].key).assertEqual('appearance')
      expect(list[1].key).assertEqual('network')
      expect(list[2].key).assertEqual('localsend')
      expect(list[3].key).assertEqual('mta')
      clearSettingsGroups()
    })
  })
}
