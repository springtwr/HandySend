// NetworkSettingsViewModel 纯函数测试：
// 接口排序/比较、白/黑名单解析与判定、脏状态检测（hasUnsavedChanges 期望态算法）
import { describe, it, expect } from '@ohos/hypium'
import { NetworkInterface, NetworkType } from '../../../../main/ets/model/Types'
import { NetworkSettingsViewModel } from '../../../../main/ets/viewmodel/NetworkSettingsViewModel'

function makeInterface(name: string, type: NetworkType, ip: string = '192.168.1.2'): NetworkInterface {
  return {
    ip: ip,
    prefixLength: 24,
    type: type,
    isDefault: false,
    name: name
  }
}

export default function NetworkSettingsViewModelTest() {
  describe('NetworkSettingsViewModelTest', () => {
    let vm: NetworkSettingsViewModel = new NetworkSettingsViewModel()

    it('parseList_emptyAndSeparators', 0, () => {
      expect(vm.parseList('').length).assertEqual(0)
      expect(JSON.stringify(vm.parseList('a, b，c\n d,,e'))).assertEqual('["a","b","c","d","e"]')
      expect(JSON.stringify(vm.parseList('  '))).assertEqual('[]')
    })

    it('parseList_trimsAndDropsEmpty', 0, () => {
      expect(JSON.stringify(vm.parseList(' wlan0 ,, eth0 '))).assertEqual('["wlan0","eth0"]')
    })

    it('isInterfaceListEmpty', 0, () => {
      expect(vm.isInterfaceListEmpty([])).assertTrue()
      expect(vm.isInterfaceListEmpty([makeInterface('wlan0', NetworkType.wifi, '0.0.0.0')])).assertTrue()
      expect(vm.isInterfaceListEmpty([makeInterface('wlan0', NetworkType.wifi)])).assertFalse()
      expect(vm.isInterfaceListEmpty([
        makeInterface('wlan0', NetworkType.wifi, '0.0.0.0'),
        makeInterface('eth0', NetworkType.ethernet)
      ])).assertFalse()
    })

    it('getNetworkTypePriority_order', 0, () => {
      expect(vm.getNetworkTypePriority(NetworkType.wifi) < vm.getNetworkTypePriority(NetworkType.ethernet)).assertTrue()
      expect(vm.getNetworkTypePriority(NetworkType.ethernet) < vm.getNetworkTypePriority(NetworkType.vpn))
        .assertTrue()
      expect(vm.getNetworkTypePriority(NetworkType.vpn) < vm.getNetworkTypePriority(NetworkType.bridge))
        .assertTrue()
      expect(vm.getNetworkTypePriority(NetworkType.bridge) < vm.getNetworkTypePriority(NetworkType.unknown))
        .assertTrue()
      expect(vm.getNetworkTypePriority(NetworkType.unknown) < vm.getNetworkTypePriority(NetworkType.cellular))
        .assertTrue()
    })

    it('sortInterfaces_byPriority', 0, () => {
      let cellular = makeInterface('cell0', NetworkType.cellular)
      let wifi = makeInterface('wlan0', NetworkType.wifi)
      let ethernet = makeInterface('eth0', NetworkType.ethernet)
      let unknown = makeInterface('anc0', NetworkType.unknown)
      let sorted = vm.sortInterfaces([cellular, unknown, ethernet, wifi])
      expect(sorted[0].name).assertEqual('wlan0')
      expect(sorted[1].name).assertEqual('eth0')
      expect(sorted[2].name).assertEqual('anc0')
      expect(sorted[3].name).assertEqual('cell0')
    })

    it('sortInterfaces_keepsEqualPriorityStable', 0, () => {
      let a = makeInterface('wlan0', NetworkType.wifi, '192.168.1.2')
      let b = makeInterface('wlan1', NetworkType.wifi, '192.168.2.2')
      let sorted = vm.sortInterfaces([a, b])
      expect(sorted[0].ip).assertEqual('192.168.1.2')
      expect(sorted[1].ip).assertEqual('192.168.2.2')
    })

    it('interfacesEqual', 0, () => {
      let a: Array<NetworkInterface> = [makeInterface('wlan0', NetworkType.wifi)]
      expect(vm.interfacesEqual(a, [makeInterface('wlan0', NetworkType.wifi)])).assertTrue()
      expect(vm.interfacesEqual(a, [])).assertFalse()
      expect(vm.interfacesEqual(a, [makeInterface('wlan1', NetworkType.wifi)])).assertFalse()
      expect(vm.interfacesEqual(a, [makeInterface('wlan0', NetworkType.ethernet)])).assertFalse()
      let asDefault = makeInterface('wlan0', NetworkType.wifi)
      asDefault.isDefault = true
      expect(vm.interfacesEqual(a, [asDefault])).assertFalse()
    })

    it('isInList', 0, () => {
      expect(vm.isInList('wlan0', ['eth0', 'wlan0'])).assertTrue()
      expect(vm.isInList('wlan0', ['eth0'])).assertFalse()
      expect(vm.isInList('wlan0', [])).assertFalse()
    })

    it('isInterfaceEnabled_blacklistWins', 0, () => {
      expect(vm.isInterfaceEnabled('wlan0', NetworkType.wifi, ['wlan0'], [])).assertTrue()
      // 黑名单优先：同时在两名单中视为关闭
      expect(vm.isInterfaceEnabled('wlan0', NetworkType.wifi, ['wlan0'], ['wlan0'])).assertFalse()
    })

    it('isInterfaceEnabled_defaultByType', 0, () => {
      // 两名单都未列出：WiFi/以太网/VPN 默认开启，容器网桥/蜂窝/未知默认关闭
      expect(vm.isInterfaceEnabled('wlan1', NetworkType.wifi, [], [])).assertTrue()
      expect(vm.isInterfaceEnabled('eth0', NetworkType.ethernet, [], [])).assertTrue()
      expect(vm.isInterfaceEnabled('tun0', NetworkType.vpn, [], [])).assertTrue()
      expect(vm.isInterfaceEnabled('ancowlan0', NetworkType.bridge, [], [])).assertFalse()
      expect(vm.isInterfaceEnabled('rmnet0', NetworkType.cellular, [], [])).assertFalse()
      expect(vm.isInterfaceEnabled('anc0', NetworkType.unknown, [], [])).assertFalse()
    })

    it('removeFromList', 0, () => {
      expect(JSON.stringify(vm.removeFromList(['a', 'b', 'a'], 'a'))).assertEqual('["b"]')
      expect(JSON.stringify(vm.removeFromList(['a'], 'b'))).assertEqual('["a"]')
      expect(JSON.stringify(vm.removeFromList([], 'a'))).assertEqual('[]')
    })

    it('activeListsEqual_ignoresInactiveEntries', 0, () => {
      let ifaces: Array<NetworkInterface> = [makeInterface('wlan0', NetworkType.wifi)]
      expect(vm.activeListsEqual(['wlan0'], ['wlan0'], ifaces)).assertTrue()
      // 已消失接口的残留条目不参与比较
      expect(vm.activeListsEqual(['wlan0', 'gone0'], ['wlan0'], ifaces)).assertTrue()
      expect(vm.activeListsEqual(['wlan0'], ['eth0'], ifaces)).assertFalse()
      // 两边的非活跃条目均忽略：比较活跃接口名集合
      expect(vm.activeListsEqual(['wlan0', 'eth0'], ['wlan0'], ifaces)).assertTrue()
    })

    it('hasUnsavedChanges_noChange', 0, () => {
      let ifaces: Array<NetworkInterface> = [
        makeInterface('wlan0', NetworkType.wifi),
        makeInterface('eth0', NetworkType.ethernet)
      ]
      // 存储值与本地状态一致：无修改
      expect(vm.hasUnsavedChanges('wlan0,eth0', '', ['wlan0', 'eth0'], [], ifaces)).assertFalse()
      expect(vm.hasUnsavedChanges('wlan0', 'eth0', ['wlan0'], ['eth0'], ifaces)).assertFalse()
    })

    it('hasUnsavedChanges_listEdited', 0, () => {
      let ifaces: Array<NetworkInterface> = [makeInterface('wlan0', NetworkType.wifi)]
      // 白名单被移除
      expect(vm.hasUnsavedChanges('wlan0', '', [], [], ifaces)).assertTrue()
      // 黑名单新增
      expect(vm.hasUnsavedChanges('', '', [], ['wlan0'], ifaces)).assertTrue()
    })

    it('hasUnsavedChanges_newInterfaceNotDirty', 0, () => {
      // 新出现的接口既不落存储也不写入本地状态（默认状态按类型推导）：不算修改
      let ifaces: Array<NetworkInterface> = [
        makeInterface('wlan0', NetworkType.wifi),
        makeInterface('cell0', NetworkType.cellular)
      ]
      expect(vm.hasUnsavedChanges('wlan0', '', ['wlan0'], [], ifaces)).assertFalse()
      // 用户把新接口移入黑名单：算修改
      expect(vm.hasUnsavedChanges('wlan0', '', ['wlan0'], ['cell0'], ifaces)).assertTrue()
    })

    it('hasUnsavedChanges_ignoresVanishedInterfaceResidue', 0, () => {
      // 存储值中已消失接口的残留不影响脏判定
      let ifaces: Array<NetworkInterface> = [makeInterface('wlan0', NetworkType.wifi)]
      expect(vm.hasUnsavedChanges('wlan0, gone0', '', ['wlan0'], [], ifaces)).assertFalse()
    })

    it('hasUnsavedChanges_emptyNameSkipped', 0, () => {
      // 空名接口跳过期望态构建
      let ifaces: Array<NetworkInterface> = [
        makeInterface('wlan0', NetworkType.wifi),
        makeInterface('', NetworkType.wifi)
      ]
      expect(vm.hasUnsavedChanges('wlan0', '', ['wlan0'], [], ifaces)).assertFalse()
    })
  })
}
