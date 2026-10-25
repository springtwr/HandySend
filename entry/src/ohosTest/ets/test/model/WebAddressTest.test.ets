// WebAddressTest：网页地址筛选、排序、选择与端口校验的纯函数测试
import { describe, it, expect } from '@ohos/hypium'
import {
  buildWebUrl,
  isEligibleWebInterface,
  isWebPortFallback,
  listWebAddresses,
  pickWebAddress,
  validateWebPort,
  WebAddress,
  WebPortError
} from '../../../../main/ets/model/WebAddress'
import { NetworkInterface, NetworkType } from '../../../../main/ets/model/Types'

function iface(name: string, ip: string, type: NetworkType, isDefault: boolean): NetworkInterface {
  return {
    name: name,
    ip: ip,
    type: type,
    isDefault: isDefault,
    prefixLength: 24
  }
}

export default function WebAddressTest() {
  describe('WebAddressTest', () => {

    it('filters_ineligible_interfaces', 0, () => {
      expect(isEligibleWebInterface(iface('wlan0', '192.168.1.5', NetworkType.wifi, true))).assertTrue()
      expect(isEligibleWebInterface(iface('lo', '127.0.0.1', NetworkType.unknown, false))).assertFalse()
      expect(isEligibleWebInterface(iface('eth1', '169.254.1.1', NetworkType.ethernet, false))).assertFalse()
      expect(isEligibleWebInterface(iface('rmnet0', '10.1.1.1', NetworkType.cellular, false))).assertTrue()
      expect(isEligibleWebInterface(iface('any', '0.0.0.0', NetworkType.unknown, false))).assertFalse()
      expect(isEligibleWebInterface(iface('bad', 'not-an-ip', NetworkType.wifi, false))).assertFalse()
    })

    it('sorts_and_dedupes_by_priority', 0, () => {
      let list: Array<NetworkInterface> = [
        iface('tun0', '10.8.0.1', NetworkType.vpn, false),
        iface('eth0', '10.0.0.2', NetworkType.ethernet, false),
        iface('wlan0', '192.168.1.5', NetworkType.wifi, true),
        iface('wlan1', '10.0.0.2', NetworkType.wifi, false),
        iface('rmnet0', '10.1.1.1', NetworkType.cellular, false)
      ]
      let result: Array<WebAddress> = listWebAddresses(list, [], [])
      expect(result.length).assertEqual(3)
      expect(result[0].name).assertEqual('wlan0')
      // 同 IP 由 Wi-Fi 优先保留，有线条目被去重
      expect(result[1].name).assertEqual('wlan1')
      expect(result[2].name).assertEqual('tun0')
    })

    it('applies_default_policy_and_interface_filters', 0, () => {
      let list: Array<NetworkInterface> = [
        iface('wlan0', '192.168.1.5', NetworkType.wifi, true),
        iface('eth0', '10.0.0.2', NetworkType.ethernet, false),
        iface('rmnet0', '10.1.1.1', NetworkType.cellular, false),
        iface('docker0', '172.17.0.1', NetworkType.bridge, false),
        iface('unknown0', '10.9.0.1', NetworkType.unknown, false)
      ]
      // 默认仅放行 Wi-Fi/有线/VPN，蜂窝/网桥/未知不展示
      let defaults: Array<WebAddress> = listWebAddresses(list, [], [])
      expect(defaults.length).assertEqual(2)
      // 白名单可强制启用蜂窝；黑名单优先于类型默认
      let cellular: Array<WebAddress> = listWebAddresses(list, ['rmnet0'], [])
      expect(cellular.length).assertEqual(3)
      let disabled: Array<WebAddress> = listWebAddresses(list, ['eth0'], ['eth0'])
      expect(disabled.length).assertEqual(1)
      expect(disabled[0].name).assertEqual('wlan0')
      // 黑名单关闭默认接口，只保留显式启用的以太网
      let onlyEth: Array<WebAddress> = listWebAddresses(list, [], ['wlan0'])
      expect(onlyEth.length).assertEqual(1)
      expect(onlyEth[0].name).assertEqual('eth0')
    })

    it('picks_selected_or_falls_back_to_first', 0, () => {
      let list: Array<NetworkInterface> = [
        iface('wlan0', '192.168.1.5', NetworkType.wifi, true),
        iface('eth0', '10.0.0.2', NetworkType.ethernet, false)
      ]
      let addresses: Array<WebAddress> = listWebAddresses(list, [], [])
      let selected = pickWebAddress(addresses, '10.0.0.2')
      expect(selected !== undefined && selected.name === 'eth0').assertTrue()
      let fallback = pickWebAddress(addresses, 'missing')
      expect(fallback !== undefined && fallback.name === 'wlan0').assertTrue()
      let empty = pickWebAddress([], '192.168.1.5')
      expect(empty === undefined).assertTrue()
    })

    it('builds_url_with_scheme_and_port', 0, () => {
      expect(buildWebUrl(false, '192.168.1.5', 53310)).assertEqual('http://192.168.1.5:53310')
      expect(buildWebUrl(true, '192.168.1.5', 53310)).assertEqual('https://192.168.1.5:53310')
      expect(buildWebUrl(false, '', 53310)).assertEqual('')
      expect(buildWebUrl(false, '192.168.1.5', 0)).assertEqual('')
    })

    it('validates_port_range_and_localsend_conflict', 0, () => {
      expect(validateWebPort(53310, 53317)).assertEqual(WebPortError.none)
      expect(validateWebPort(1023, 53317)).assertEqual(WebPortError.invalid)
      expect(validateWebPort(65536, 53317)).assertEqual(WebPortError.invalid)
      expect(validateWebPort(53317, 53317)).assertEqual(WebPortError.conflict)
      expect(validateWebPort(53318, 53317)).assertEqual(WebPortError.none)
    })

    it('detects_port_fallback', 0, () => {
      expect(isWebPortFallback(53310, 53310)).assertFalse()
      expect(isWebPortFallback(53310, 54321)).assertTrue()
      expect(isWebPortFallback(0, 54321)).assertFalse()
    })
  })
}
