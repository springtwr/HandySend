// NetworkInterfaceSelection 纯函数测试：
// IPv4 语法校验、网段匹配、按对端 IP 选择本机接口，以及默认路由接口的优先级
import { describe, it, expect } from '@ohos/hypium'
import { NetworkInterface, NetworkType } from '../../../../main/ets/model/Types'
import {
  isIpv4Address,
  isIpv4InSubnet,
  selectDefaultRouteInterface,
  selectInterfaceForPeer
} from '../../../../main/ets/utils/NetworkInterfaceSelection'

function makeInterface(name: string, ip: string, prefixLength: number,
  type: NetworkType, isDefault: boolean = false): NetworkInterface {
  return {
    name: name,
    ip: ip,
    prefixLength: prefixLength,
    type: type,
    isDefault: isDefault,
    isHotspot: false
  }
}

export default function NetworkInterfaceSelectionTest() {
  describe('NetworkInterfaceSelectionTest', () => {
    // ── isIpv4Address ──

    it('isIpv4Address_basic', 0, () => {
      expect(isIpv4Address('192.168.1.5')).assertTrue()
      expect(isIpv4Address('0.0.0.0')).assertTrue()
      expect(isIpv4Address('192.168.1.256')).assertFalse()
      expect(isIpv4Address('192.168.1')).assertFalse()
      expect(isIpv4Address('192.168.01.5')).assertFalse()
      expect(isIpv4Address('web-token')).assertFalse()
    })

    // ── isIpv4InSubnet ──

    it('isIpv4InSubnet_24', 0, () => {
      expect(isIpv4InSubnet('192.168.1.20', '192.168.1.5', 24)).assertTrue()
      expect(isIpv4InSubnet('192.168.2.20', '192.168.1.5', 24)).assertFalse()
    })

    it('isIpv4InSubnet_16_and_8', 0, () => {
      expect(isIpv4InSubnet('10.1.200.5', '10.1.0.2', 16)).assertTrue()
      expect(isIpv4InSubnet('10.2.0.5', '10.1.0.2', 16)).assertFalse()
      expect(isIpv4InSubnet('10.9.9.9', '10.1.0.2', 8)).assertTrue()
      expect(isIpv4InSubnet('11.0.0.1', '10.1.0.2', 8)).assertFalse()
    })

    it('isIpv4InSubnet_partial_byte', 0, () => {
      // /25：前半段 0-127，后半段 128-255
      expect(isIpv4InSubnet('192.168.1.100', '192.168.1.10', 25)).assertTrue()
      expect(isIpv4InSubnet('192.168.1.200', '192.168.1.10', 25)).assertFalse()
      expect(isIpv4InSubnet('192.168.1.10', '192.168.1.10', 32)).assertTrue()
      expect(isIpv4InSubnet('192.168.1.11', '192.168.1.10', 32)).assertFalse()
    })

    it('isIpv4InSubnet_invalid_input', 0, () => {
      // 前缀 0/越界、地址非法均不可判定
      expect(isIpv4InSubnet('10.0.0.1', '10.0.0.2', 0)).assertFalse()
      expect(isIpv4InSubnet('10.0.0.1', '10.0.0.2', 33)).assertFalse()
      expect(isIpv4InSubnet('', '10.0.0.2', 24)).assertFalse()
      expect(isIpv4InSubnet('10.0.0', '10.0.0.2', 24)).assertFalse()
      expect(isIpv4InSubnet('10.0.0.256', '10.0.0.2', 24)).assertFalse()
      expect(isIpv4InSubnet('10.0.0.1', '10.0.0.2', 24.5)).assertFalse()
    })

    // ── selectInterfaceForPeer ──

    it('selectInterfaceForPeer_matches_non_primary_interface', 0, () => {
      // WiFi 是主接口，但对端位于以太网网段：应取以太网接口
      let interfaces: Array<NetworkInterface> = [
        makeInterface('wlan0', '192.168.1.5', 24, NetworkType.wifi, true),
        makeInterface('eth0', '10.0.0.2', 24, NetworkType.ethernet)
      ]
      let selected = selectInterfaceForPeer(interfaces, '10.0.0.9')
      expect(selected !== undefined && selected.name === 'eth0').assertTrue()
    })

    it('selectInterfaceForPeer_matches_primary_interface', 0, () => {
      let interfaces: Array<NetworkInterface> = [
        makeInterface('wlan0', '192.168.1.5', 24, NetworkType.wifi, true),
        makeInterface('eth0', '10.0.0.2', 24, NetworkType.ethernet)
      ]
      let selected = selectInterfaceForPeer(interfaces, '192.168.1.9')
      expect(selected !== undefined && selected.name === 'wlan0').assertTrue()
    })

    it('selectInterfaceForPeer_longest_prefix_wins', 0, () => {
      // /24 比 /16 更具体，即使 /16 接口是默认网络也取 /24
      let interfaces: Array<NetworkInterface> = [
        makeInterface('tun0', '192.168.0.10', 16, NetworkType.vpn, true),
        makeInterface('eth0', '192.168.5.20', 24, NetworkType.ethernet)
      ]
      let selected = selectInterfaceForPeer(interfaces, '192.168.5.30')
      expect(selected !== undefined && selected.name === 'eth0').assertTrue()
    })

    it('selectInterfaceForPeer_default_wins_on_tie', 0, () => {
      let interfaces: Array<NetworkInterface> = [
        makeInterface('eth0', '192.168.1.2', 24, NetworkType.ethernet),
        makeInterface('wlan0', '192.168.1.3', 24, NetworkType.wifi, true)
      ]
      let selected = selectInterfaceForPeer(interfaces, '192.168.1.9')
      expect(selected !== undefined && selected.name === 'wlan0').assertTrue()
    })

    it('selectInterfaceForPeer_no_match_returns_undefined', 0, () => {
      let interfaces: Array<NetworkInterface> = [
        makeInterface('wlan0', '192.168.1.5', 24, NetworkType.wifi, true)
      ]
      expect(selectInterfaceForPeer(interfaces, '10.0.0.9') === undefined).assertTrue()
      // 对端 IP 缺失（MTA 等无 IP 协议）或非 IP 文本时不参与匹配
      expect(selectInterfaceForPeer(interfaces, '') === undefined).assertTrue()
      expect(selectInterfaceForPeer(interfaces, 'web-token') === undefined).assertTrue()
      expect(selectInterfaceForPeer([], '192.168.1.9') === undefined).assertTrue()
    })

    it('selectInterfaceForPeer_skips_unusable_local_ip', 0, () => {
      let interfaces: Array<NetworkInterface> = [
        makeInterface('', '0.0.0.0', 24, NetworkType.unknown, true),
        makeInterface('lo', '127.0.0.1', 8, NetworkType.unknown),
        makeInterface('wlan0', '192.168.1.5', 24, NetworkType.wifi)
      ]
      expect(selectInterfaceForPeer(interfaces, '127.0.0.2') === undefined).assertTrue()
      let selected = selectInterfaceForPeer(interfaces, '192.168.1.9')
      expect(selected !== undefined && selected.name === 'wlan0').assertTrue()
    })

    it('selectInterfaceForPeer_matches_link_local', 0, () => {
      // 直连链路未分配 DHCP 地址时双方均为 169.254.x，链路本地地址仍应参与匹配
      let interfaces: Array<NetworkInterface> = [
        makeInterface('wlan0', '192.168.1.5', 24, NetworkType.wifi, true),
        makeInterface('eth0', '169.254.10.2', 16, NetworkType.ethernet)
      ]
      let selected = selectInterfaceForPeer(interfaces, '169.254.10.9')
      expect(selected !== undefined && selected.name === 'eth0').assertTrue()
    })

    // ── selectDefaultRouteInterface ──

    it('selectDefaultRouteInterface_returns_default', 0, () => {
      let interfaces: Array<NetworkInterface> = [
        makeInterface('wlan0', '192.168.1.5', 24, NetworkType.wifi),
        makeInterface('tun0', '10.8.0.2', 32, NetworkType.vpn, true)
      ]
      let selected = selectDefaultRouteInterface(interfaces)
      // WireGuard/Tailscale 常用 /32 地址，网段匹配覆盖不到，靠默认网络兜底
      expect(selected !== undefined && selected.name === 'tun0').assertTrue()
    })

    it('selectDefaultRouteInterface_skips_unusable_and_missing', 0, () => {
      let interfaces: Array<NetworkInterface> = [
        makeInterface('', '0.0.0.0', 24, NetworkType.unknown, true),
        makeInterface('wlan0', '192.168.1.5', 24, NetworkType.wifi)
      ]
      expect(selectDefaultRouteInterface(interfaces) === undefined).assertTrue()
      expect(selectDefaultRouteInterface([]) === undefined).assertTrue()
    })
  })
}
